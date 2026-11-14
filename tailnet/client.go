// Package tailnet owns an embedded node. It does not install system VPN routes.
package tailnet

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/tailscale/wireguard-go/tun"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
	"time"
)

type Config struct {
	Tun      tun.Device
	StateDir string
	Hostname string
	// Empty selects Tailscale; an HTTPS URL selects a Headscale server.
	ControlURL string
	AuthKey    string
	ExitNodeIP string
}

func (c Config) Validate() error {
	if !filepath.IsAbs(c.StateDir) {
		return errors.New("state directory must be absolute")
	}
	if strings.TrimSpace(c.Hostname) == "" {
		return errors.New("hostname is required")
	}
	if c.ControlURL != "" {
		u, err := url.Parse(c.ControlURL)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return errors.New("control server must be an HTTPS URL without credentials, query or fragment")
		}
	}
	if c.ExitNodeIP != "" {
		if _, err := netip.ParseAddr(c.ExitNodeIP); err != nil {
			return errors.New("invalid exit node IP")
		}
	}
	return nil
}

type Client struct {
	mu              sync.RWMutex
	server          *tsnet.Server
	closed          bool
	lastNetworkPoll time.Time
}

// New starts a node without waiting for interactive login. Status exposes AuthURL.
// Each account/server must have its own private state directory.
func New(c Config) (*Client, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(c.StateDir, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(c.StateDir, 0700); err != nil {
		return nil, err
	}
	netns.SetEnabled(false)
	s := &tsnet.Server{Tun: c.Tun, Dir: c.StateDir, Hostname: c.Hostname, ControlURL: c.ControlURL, AuthKey: c.AuthKey,
		UserLogf: func(string, ...any) {}, Logf: func(string, ...any) {}}
	if err := s.Start(); err != nil {
		s.Close()
		return nil, err
	}
	lc, err := s.LocalClient()
	if err != nil {
		s.Close()
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	prefs := &ipn.MaskedPrefs{Prefs: ipn.Prefs{RouteAll: true}, RouteAllSet: true}
	if c.ExitNodeIP != "" {
		prefs.ExitNodeIP, _ = netip.ParseAddr(c.ExitNodeIP)
		prefs.ExitNodeIPSet = true
		prefs.ExitNodeIDSet = true
	}
	if _, err = lc.EditPrefs(ctx, prefs); err != nil {
		s.Close()
		return nil, err
	}
	return &Client{server: s}, nil
}

func (c *Client) Status(ctx context.Context) (*ipnstate.Status, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil, net.ErrClosed
	}
	if time.Since(c.lastNetworkPoll) >= 15*time.Second {
		c.server.Sys().NetMon.Get().Poll()
		c.lastNetworkPoll = time.Now()
	}
	lc, err := c.server.LocalClient()
	if err != nil {
		return nil, err
	}
	return lc.Status(ctx)
}

func (c *Client) Dial(ctx context.Context, network, address string) (net.Conn, error) {
	c.mu.RLock()
	if c.closed {
		c.mu.RUnlock()
		return nil, net.ErrClosed
	}
	s := c.server
	c.mu.RUnlock()
	return s.Dial(ctx, network, address)
}

func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	return c.server.Close()
}

// DialTunnel never falls back to a physical-network connection for a selected rule.
func (c *Client) DialTunnel(ctx context.Context, network, address string) (net.Conn, error) {
	c.mu.RLock()
	if c.closed {
		c.mu.RUnlock()
		return nil, net.ErrClosed
	}
	d := c.server.Sys().Dialer.Get()
	c.mu.RUnlock()
	ip, via, err := d.UserDialPlan(ctx, network, address)
	if err != nil {
		return nil, err
	}
	if !via {
		return nil, errors.New("selected network has no route; configure an exit node or subnet route")
	}
	if strings.HasPrefix(network, "udp") {
		return d.NetstackDialUDP(ctx, ip)
	}
	return d.NetstackDialTCP(ctx, ip)
}

func (c *Client) NetworkChanged() {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if !c.closed {
		sys := c.server.Sys()
		sys.NetMon.Get().InjectEvent()
		// Harmony's interface monitor may miss a default-network identity change.
		// Explicitly discard old transport bindings while preserving the tailnet session.
		sys.MagicSock.Get().Rebind()
		sys.MagicSock.Get().ReSTUN("harmony-network-change")
	}
}

func (c *Client) SetExitNode(ctx context.Context, ip string) error {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.closed {
		return net.ErrClosed
	}
	lc, err := c.server.LocalClient()
	if err != nil {
		return err
	}
	prefs := &ipn.MaskedPrefs{ExitNodeIPSet: true, ExitNodeIDSet: true}
	if ip != "" {
		prefs.ExitNodeIP, err = netip.ParseAddr(ip)
		if err != nil {
			return err
		}
	}
	_, err = lc.EditPrefs(ctx, prefs)
	return err
}
