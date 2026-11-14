package multinet

import (
	"context"
	"errors"
	"fmt"
	"harmony/tailnet"
	"net"
	"net/netip"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"tailscale.com/ipn/ipnstate"
	"time"
)

type NodeStatus struct {
	ID, Name, BackendState, AuthURL, Error, DNSSuffix string
	TailscaleIPs                                      []string
	ExitNodes                                         []string
	PeerIPs, PeerNames, SubnetRoutes                  []string
}
type managedClient interface {
	Status(context.Context) (*ipnstate.Status, error)
	SetExitNode(context.Context, string) error
	DialTunnel(context.Context, string, string) (net.Conn, error)
	NetworkChanged()
	Close() error
}
type node struct {
	mu        sync.RWMutex
	client    managedClient
	exitReady bool
	status    NodeStatus
}
type Manager struct {
	dnsMu    sync.RWMutex
	ctx      context.Context
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	nodes    map[string]*node
	policy   *Policy
	config   Config
	resolver *net.Resolver
}

// NodeCount is immutable after New and does not poll network/account status.
func (m *Manager) NodeCount() int { return len(m.nodes) }

func profileStateDir(dir string, p Profile) string {
	if p.LegacyState {
		key := p.ControlURL
		if key == "" {
			key = "tailscale"
		}
		key = strings.ReplaceAll(url.QueryEscape(key), "+", "%20")
		for _, ch := range []string{"!", "'", "(", ")", "*"} {
			key = strings.ReplaceAll(key, fmt.Sprintf("%%%02X", ch[0]), ch)
		}
		return filepath.Join(dir, "tailnet", key)
	}
	return filepath.Join(dir, "networks", p.ID)
}
func New(c Config) (*Manager, error) {
	if !filepath.IsAbs(c.Directory) || len(c.Profiles) == 0 || len(c.Profiles) > 16 {
		return nil, errors.New("invalid multi-network configuration")
	}
	p, err := Compile(c)
	if err != nil {
		return nil, err
	}
	for _, profile := range c.Profiles {
		if err := (tailnet.Config{StateDir: profileStateDir(c.Directory, profile), Hostname: profile.Hostname, ControlURL: profile.ControlURL, ExitNodeIP: profile.ExitNodeIP}).Validate(); err != nil {
			return nil, err
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	m := &Manager{ctx: ctx, cancel: cancel, policy: p, config: c, nodes: map[string]*node{}}
	if len(c.DNS) == 0 {
		cancel()
		return nil, errors.New("physical network DNS is unavailable")
	}
	for _, ip := range c.DNS {
		if _, err := netip.ParseAddr(ip); err != nil {
			cancel()
			return nil, fmt.Errorf("invalid DNS server")
		}
	}
	m.resolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort(m.DNS()[0], "53"))
	}}
	for _, profile := range c.Profiles {
		n := &node{status: NodeStatus{ID: profile.ID, Name: profile.Name, BackendState: "Starting", TailscaleIPs: []string{}, ExitNodes: []string{}, PeerIPs: []string{}, PeerNames: []string{}, SubnetRoutes: []string{}}}
		m.nodes[profile.ID] = n
		m.wg.Add(1)
		go m.run(n, profile)
	}
	return m, nil
}
func (m *Manager) run(n *node, p Profile) {
	defer m.wg.Done()
	defer func() {
		n.mu.Lock()
		c := n.client
		n.client = nil
		n.mu.Unlock()
		if c != nil {
			c.Close()
		}
	}()
	delay := time.Second
	exitConfigured := false
	for m.ctx.Err() == nil {
		n.mu.RLock()
		c := n.client
		n.mu.RUnlock()
		var err error
		if c == nil {
			exitConfigured = false
			c, err = tailnet.New(tailnet.Config{StateDir: profileStateDir(m.config.Directory, p), Hostname: p.Hostname, ControlURL: p.ControlURL})
			if err == nil {
				n.mu.Lock()
				n.client = c
				n.exitReady = false
				n.mu.Unlock()
			}
		}
		if err == nil {
			ctx, cancel := context.WithTimeout(m.ctx, 2*time.Second)
			s, e := c.Status(ctx)
			cancel()
			err = e
			if err == nil {
				status := NodeStatus{ID: p.ID, Name: p.Name, BackendState: s.BackendState, AuthURL: s.AuthURL, TailscaleIPs: []string{}, ExitNodes: []string{}, PeerIPs: []string{}, PeerNames: []string{}, SubnetRoutes: []string{}}
				for _, ip := range s.TailscaleIPs {
					status.TailscaleIPs = append(status.TailscaleIPs, ip.String())
				}
				if s.CurrentTailnet != nil {
					status.DNSSuffix = s.CurrentTailnet.MagicDNSSuffix
				}
				for _, peer := range s.Peer {
					if peer != nil {
						if name := normalizeName(peer.DNSName); name != "" {
							status.PeerNames = append(status.PeerNames, name)
						}
						for _, ip := range peer.TailscaleIPs {
							status.PeerIPs = append(status.PeerIPs, ip.String())
						}
						if peer.PrimaryRoutes != nil {
							for _, route := range peer.PrimaryRoutes.All() {
								if route.Bits() > 0 {
									status.SubnetRoutes = append(status.SubnetRoutes, route.String())
								}
							}
						}
					}
					if peer != nil && peer.ExitNodeOption && len(peer.TailscaleIPs) > 0 {
						status.ExitNodes = append(status.ExitNodes, peer.TailscaleIPs[0].String()+" "+peer.HostName)
					}
				}
				if status.BackendState == "Running" && !exitConfigured {
					ctx, cancel := context.WithTimeout(m.ctx, 3*time.Second)
					exitErr := c.SetExitNode(ctx, p.ExitNodeIP)
					cancel()
					if exitErr != nil {
						status.Error = "出口配置失败: " + exitErr.Error()
					} else {
						exitConfigured = true
					}
				}
				n.mu.Lock()
				n.status = status
				n.exitReady = exitConfigured
				n.mu.Unlock()
				delay = time.Second
			}
		}
		wait := 3 * time.Second
		if err != nil {
			n.mu.Lock()
			n.client = nil
			n.exitReady = false
			n.status.BackendState = "Reconnecting"
			n.status.Error = err.Error()
			n.mu.Unlock()
			if c != nil {
				c.Close()
			}
			wait = delay
			delay = min(delay*2, 60*time.Second)
		}
		select {
		case <-m.ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}
func (m *Manager) Status() []NodeStatus {
	out := make([]NodeStatus, 0, len(m.config.Profiles))
	for _, p := range m.config.Profiles {
		n := m.nodes[p.ID]
		n.mu.RLock()
		out = append(out, n.status)
		n.mu.RUnlock()
	}
	return out
}
func (m *Manager) Domain(name string) string {
	if id := m.policy.Domain(name); id != "" {
		return id
	}
	return m.AutomaticDomain(name)
}
func (m *Manager) PolicyDomain(name string) (string, int) { return m.policy.DomainMatch(name) }
func (m *Manager) PolicyIP(ip netip.Addr) (string, int)   { return m.policy.IPMatch(ip) }
func (m *Manager) DescribeDomain(name string) string      { return m.policy.DescribeDomain(name) }
func (m *Manager) DescribeIP(ip netip.Addr) string        { return m.policy.DescribeIP(ip) }
func (m *Manager) AutomaticDomain(name string) string {
	name = normalizeName(name)
	owner := ""
	for _, s := range m.Status() {
		suffix := normalizeName(s.DNSSuffix)
		if suffix != "" && (name == suffix || strings.HasSuffix(name, "."+suffix)) || shortPeerCanonical(s, name) != "" {
			if owner != "" && owner != s.ID {
				return "!ambiguous"
			}
			owner = s.ID
		}
	}
	return owner
}

// shortPeerCanonical accepts only a true peer DNS label immediately under this
// tailnet's suffix. HostName may differ after a control-server name collision.
func shortPeerCanonical(status NodeStatus, name string) string {
	name = normalizeName(name)
	suffix := normalizeName(status.DNSSuffix)
	if name == "" || strings.Contains(name, ".") || suffix == "" {
		return ""
	}
	for _, full := range status.PeerNames {
		full = normalizeName(full)
		if strings.HasSuffix(full, "."+suffix) && strings.TrimSuffix(full, "."+suffix) == name {
			return full
		}
	}
	return ""
}
func canonicalPeerAddress(status NodeStatus, address string) string {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return address
	}
	if full := shortPeerCanonical(status, host); full != "" {
		return net.JoinHostPort(full, port)
	}
	return address
}
func (m *Manager) Dial(ctx context.Context, owner, network, address string) (net.Conn, error) {
	if owner == "" {
		return (&net.Dialer{Timeout: 15 * time.Second, Resolver: m.resolver}).DialContext(ctx, network, address)
	}
	n := m.nodes[owner]
	if n == nil {
		return nil, errors.New("unknown network")
	}
	n.mu.RLock()
	c := n.client
	running := n.status.BackendState == "Running" && n.exitReady && n.status.Error == ""
	address = canonicalPeerAddress(n.status, address)
	n.mu.RUnlock()
	if c == nil || !running {
		return nil, errors.New("network reconnecting")
	}
	return c.DialTunnel(ctx, network, address)
}
func (m *Manager) Close() { m.cancel(); m.wg.Wait() }

func (m *Manager) IP(ip netip.Addr) string {
	if owner := m.policy.IP(ip); owner != "" {
		return owner
	}
	return m.AutomaticIP(ip)
}
func (m *Manager) AutomaticIP(ip netip.Addr) string {
	best, bits := "", -1
	for _, s := range m.Status() {
		for _, raw := range append(append([]string{}, s.PeerIPs...), s.SubnetRoutes...) {
			prefix, err := netip.ParsePrefix(raw)
			if err != nil {
				addr, e := netip.ParseAddr(raw)
				if e != nil {
					continue
				}
				prefix = netip.PrefixFrom(addr, addr.BitLen())
			}
			if prefix.Bits() == 0 {
				continue
			}
			if prefix.Contains(ip) && prefix.Bits() > bits {
				best, bits = s.ID, prefix.Bits()
			} else if prefix.Contains(ip) && prefix.Bits() == bits && best != s.ID {
				best = "!ambiguous"
			}
		}
	}
	return best
}
func (m *Manager) DNS() []string {
	m.dnsMu.RLock()
	defer m.dnsMu.RUnlock()
	return append([]string{}, m.config.DNS...)
}
func (m *Manager) NetworkChanged(dns []string) error {
	if len(dns) == 0 {
		return errors.New("empty DNS list")
	}
	for _, ip := range dns {
		if _, err := netip.ParseAddr(ip); err != nil {
			return err
		}
	}
	m.dnsMu.Lock()
	m.config.DNS = append([]string{}, dns...)
	m.dnsMu.Unlock()
	for _, n := range m.nodes {
		n.mu.RLock()
		c := n.client
		n.mu.RUnlock()
		if c != nil {
			c.NetworkChanged()
		}
	}
	return nil
}
