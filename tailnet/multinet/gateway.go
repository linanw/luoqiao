package multinet

import (
	"context"
	"encoding/binary"
	"errors"
	"golang.org/x/net/dns/dnsmessage"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
	"harmony/tailnet"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type destination struct{ host, owner string }
type FlowRouter interface {
	Domain(string) string
	IP(netip.Addr) string
	DNS() []string
	Dial(context.Context, string, string, string) (net.Conn, error)
}
type Gateway struct {
	lastError atomic.Value
	manager   FlowRouter
	Tun       *tailnet.Tunnel
	s         *stack.Stack
	link      *channel.Endpoint
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	mu        sync.Mutex
	fake      map[netip.Addr]destination
	names     map[string]netip.Addr
	next      uint32
	conns     map[net.Conn]bool
	slots     chan struct{}
	closed    bool
}

// ResourceCounts returns numeric sizes without exposing routing or flow data.
func (g *Gateway) ResourceCounts() (flows, connections, aliases int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.slots), len(g.conns), len(g.fake)
}

func NewGateway(m FlowRouter) (*Gateway, error) {
	ctx, cancel := context.WithCancel(context.Background())
	g := &Gateway{manager: m, Tun: tailnet.NewTunnel(), ctx: ctx, cancel: cancel, fake: map[netip.Addr]destination{}, names: map[string]netip.Addr{}, next: 2, conns: map[net.Conn]bool{}, slots: make(chan struct{}, 512)}
	g.s = stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol}, TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	g.link = channel.New(512, 1280, "")
	if e := g.s.CreateNIC(1, g.link); e != nil {
		g.Close()
		return nil, errors.New(e.String())
	}
	g.s.SetPromiscuousMode(1, true)
	g.s.SetSpoofing(1, true)
	g.s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}, {Destination: header.IPv6EmptySubnet, NIC: 1}})
	tf := tcp.NewForwarder(g.s, 0, 256, func(r *tcp.ForwarderRequest) {
		if !g.acquire() {
			r.Complete(true)
			return
		}
		go func() {
			defer g.wg.Done()
			defer g.free()
			var wq waiter.Queue
			id := r.ID()
			ep, e := r.CreateEndpoint(&wq)
			r.Complete(e != nil)
			if e != nil {
				return
			}
			conn := gonet.NewTCPConn(&wq, ep)
			g.forward(conn, id, "tcp")
		}()
	})
	udpHandler := func(id stack.TransportEndpointID, pkt *stack.PacketBuffer) bool {
		// Handle synchronously using the borrowed packet; NewForwarder clones it
		// without exposing a release operation in this pinned gVisor version.
		r := udp.NewForwarderRequest(g.s, id, pkt)
		if !g.acquire() {
			return false
		}
		var wq waiter.Queue
		ep, e := r.CreateEndpoint(&wq)
		if e != nil {
			g.free()
			g.wg.Done()
			return false
		}
		conn := gonet.NewUDPConn(&wq, ep)
		id = r.ID()
		go func() { defer g.wg.Done(); defer g.free(); g.forward(conn, id, "udp") }()
		return true
	}
	g.s.SetTransportProtocolHandler(tcp.ProtocolNumber, tf.HandlePacket)
	g.s.SetTransportProtocolHandler(udp.ProtocolNumber, udpHandler)
	g.wg.Add(2)
	go g.read()
	go g.write()
	return g, nil
}
func (g *Gateway) acquire() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closed {
		return false
	}
	select {
	case g.slots <- struct{}{}:
		g.wg.Add(1)
		return true
	default:
		return false
	}
}
func (g *Gateway) free() { <-g.slots }
func (g *Gateway) track(c net.Conn) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closed {
		c.Close()
		return false
	}
	g.conns[c] = true
	return true
}
func (g *Gateway) untrack(c net.Conn) { c.Close(); g.mu.Lock(); delete(g.conns, c); g.mu.Unlock() }
func (g *Gateway) read() {
	defer g.wg.Done()
	b := make([]byte, 65536)
	sizes := make([]int, 1)
	for {
		_, e := g.Tun.Read([][]byte{b}, sizes, 0)
		if e != nil {
			return
		}
		if sizes[0] == 0 {
			continue
		}
		proto := ipv4.ProtocolNumber
		if b[0]>>4 == 6 {
			proto = ipv6.ProtocolNumber
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte{}, b[:sizes[0]]...))})
		g.link.InjectInbound(proto, pkt)
		pkt.DecRef()
	}
}
func (g *Gateway) write() {
	defer g.wg.Done()
	for {
		pkt := g.link.ReadContext(g.ctx)
		if pkt == nil {
			return
		}
		v := pkt.ToView()
		b := append([]byte{}, v.AsSlice()...)
		v.Release()
		pkt.DecRef()
		if _, e := g.Tun.Write([][]byte{b}, 0); e != nil {
			return
		}
	}
}
func normalizeName(s string) string { return strings.ToLower(strings.TrimSuffix(s, ".")) }
func (g *Gateway) allocate(name, owner string, v6 bool) (netip.Addr, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	key := owner + "|" + name + "|" + strconv.FormatBool(v6)
	if ip, ok := g.names[key]; ok {
		return ip, nil
	}
	// Never recycle fake addresses within a VPN session; cached DNS cannot switch owners.
	if g.next >= 131070 {
		return netip.Addr{}, errors.New("domain address pool full")
	}
	n := g.next
	g.next++
	ip := netip.AddrFrom4([4]byte{198, byte(18 + (n >> 16)), byte(n >> 8), byte(n)})
	if v6 {
		v := [16]byte{0xfd, 0x7e, 0x74, 0x6e}
		binary.BigEndian.PutUint32(v[12:], n)
		ip = netip.AddrFrom16(v)
	}
	g.names[key] = ip
	g.fake[ip] = destination{name, owner}
	return ip, nil
}
func (g *Gateway) target(ip netip.Addr) (destination, error) {
	g.mu.Lock()
	d, ok := g.fake[ip]
	g.mu.Unlock()
	if ok {
		return d, nil
	}
	if netip.MustParsePrefix("198.18.0.0/15").Contains(ip) || netip.MustParsePrefix("fd7e:746e::/32").Contains(ip) {
		return destination{}, errors.New("expired synthetic DNS address")
	}
	return destination{ip.String(), g.manager.IP(ip)}, nil
}
func (g *Gateway) forward(local net.Conn, id stack.TransportEndpointID, network string) {
	if !g.track(local) {
		return
	}
	defer g.untrack(local)
	ip, ok := netip.AddrFromSlice(id.LocalAddress.AsSlice())
	if !ok {
		return
	}
	if id.LocalPort == 53 && (ip.String() == "198.18.0.1" || ip.String() == "fd7e:746e::1") {
		g.serveDNS(local, network)
		return
	}
	dst, err := g.target(ip)
	if err != nil {
		g.lastError.Store(err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(g.ctx, 20*time.Second)
	remote, err := g.manager.Dial(ctx, dst.owner, network, net.JoinHostPort(dst.host, strconv.Itoa(int(id.LocalPort))))
	cancel()
	if err != nil {
		g.lastError.Store(err.Error())
		return
	}
	g.lastError.Store("")
	if !g.track(remote) {
		return
	}
	defer g.untrack(remote)
	if network == "udp" {
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer local.Close()
			b := make([]byte, 65535)
			for {
				remote.SetReadDeadline(time.Now().Add(90 * time.Second))
				n, e := remote.Read(b)
				if e != nil {
					return
				}
				local.SetReadDeadline(time.Now().Add(90 * time.Second))
				if _, e = local.Write(b[:n]); e != nil {
					return
				}
			}
		}()
		b := make([]byte, 65535)
		for {
			local.SetReadDeadline(time.Now().Add(90 * time.Second))
			n, e := local.Read(b)
			if e != nil {
				break
			}
			remote.SetReadDeadline(time.Now().Add(90 * time.Second))
			if _, e = remote.Write(b[:n]); e != nil {
				break
			}
		}
		remote.Close()
		<-done
		return
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		io.Copy(local, remote)
		if c, ok := local.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
		}
	}()
	io.Copy(remote, local)
	if c, ok := remote.(interface{ CloseWrite() error }); ok {
		c.CloseWrite()
	}
	<-done
}
func (g *Gateway) serveDNS(c net.Conn, network string) {
	b := make([]byte, 65535)
	for {
		c.SetReadDeadline(time.Now().Add(30 * time.Second))
		var n int
		var err error
		if network == "tcp" {
			var size [2]byte
			if _, err = io.ReadFull(c, size[:]); err != nil {
				return
			}
			n = int(binary.BigEndian.Uint16(size[:]))
			_, err = io.ReadFull(c, b[:n])
		} else {
			n, err = c.Read(b)
		}
		if err != nil {
			return
		}
		reply := g.dns(b[:n])
		if len(reply) == 0 {
			return
		}
		if network == "tcp" {
			out := make([]byte, len(reply)+2)
			binary.BigEndian.PutUint16(out, uint16(len(reply)))
			copy(out[2:], reply)
			_, err = c.Write(out)
		} else {
			_, err = c.Write(reply)
		}
		if err != nil {
			return
		}
	}
}
func (g *Gateway) dns(raw []byte) []byte {
	var q dnsmessage.Message
	if q.Unpack(raw) != nil || q.Header.Response || len(q.Questions) != 1 {
		return nil
	}
	question := q.Questions[0]
	name := normalizeName(question.Name.String())
	owner := g.manager.Domain(name)
	if owner == "!ambiguous" {
		q.Header.RCode = dnsmessage.RCodeServerFailure
	} else if owner == "" {
		ctx, cancel := context.WithTimeout(g.ctx, 5*time.Second)
		defer cancel()
		for _, server := range g.manager.DNS() {
			c, e := (&net.Dialer{}).DialContext(ctx, "udp", net.JoinHostPort(server, "53"))
			if e != nil {
				continue
			}
			c.SetDeadline(time.Now().Add(5 * time.Second))
			_, e = c.Write(raw)
			if e == nil {
				b := make([]byte, 65535)
				n, e := c.Read(b)
				c.Close()
				if e == nil {
					return b[:n]
				}
			} else {
				c.Close()
			}
		}
		q.Header.RCode = dnsmessage.RCodeServerFailure
	} else {
		q.Answers = nil
		q.Authorities = nil
		q.Additionals = nil
		if question.Type == dnsmessage.TypeA || question.Type == dnsmessage.TypeAAAA {
			ip, e := g.allocate(name, owner, question.Type == dnsmessage.TypeAAAA)
			if e != nil {
				q.Header.RCode = dnsmessage.RCodeServerFailure
			} else {
				h := dnsmessage.ResourceHeader{Name: question.Name, Type: question.Type, Class: dnsmessage.ClassINET, TTL: 60}
				if ip.Is4() {
					q.Answers = []dnsmessage.Resource{{Header: h, Body: &dnsmessage.AResource{A: ip.As4()}}}
				} else {
					q.Answers = []dnsmessage.Resource{{Header: h, Body: &dnsmessage.AAAAResource{AAAA: ip.As16()}}}
				}
			}
		}
	}
	q.Header.Response = true
	q.Header.RecursionAvailable = true
	q.Header.AuthenticData = false
	b, _ := q.Pack()
	return b
}
func (g *Gateway) Close() {
	g.mu.Lock()
	g.closed = true
	for c := range g.conns {
		c.Close()
	}
	g.mu.Unlock()
	g.cancel()
	g.Tun.Close()
	if g.s != nil {
		g.s.Close()
	}
	if g.link != nil {
		g.link.Close()
	}
	g.wg.Wait()
	if g.s != nil {
		g.s.Wait()
	}
}

func (g *Gateway) FlowError() string {
	if s, ok := g.lastError.Load().(string); ok {
		return s
	}
	return ""
}
