package multinet

import (
	"context"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"testing"
	"time"
)

type testRouter struct {
	mu    sync.Mutex
	calls []string
}

func (r *testRouter) Domain(name string) string {
	if name == "a.example" {
		return "alpha"
	}
	if name == "b.example" {
		return "beta"
	}
	return ""
}
func (r *testRouter) IP(ip netip.Addr) string { return "" }
func (r *testRouter) DNS() []string           { return nil }
func (r *testRouter) Dial(ctx context.Context, owner, network, address string) (net.Conn, error) {
	r.mu.Lock()
	r.calls = append(r.calls, owner+" "+network+" "+address)
	r.mu.Unlock()
	a, b := net.Pipe()
	go func() {
		defer b.Close()
		buf := make([]byte, 64)
		for {
			n, e := b.Read(buf)
			if e != nil {
				return
			}
			if _, e = b.Write(append([]byte(owner+":"), buf[:n]...)); e != nil {
				return
			}
		}
	}()
	return a, nil
}
func TestGatewayDNSAndConcurrentNetworks(t *testing.T) {
	r := &testRouter{}
	g, e := NewGateway(r)
	if e != nil {
		t.Fatal(e)
	}
	fds, e := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if e != nil {
		t.Fatal(e)
	}
	peer := os.NewFile(uintptr(fds[1]), "peer")
	defer peer.Close()
	if e = g.Tun.Attach(fds[0]); e != nil {
		t.Fatal(e)
	}
	unix.Close(fds[0])
	host := stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol}, TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	link := channel.New(64, 1280, "")
	host.CreateNIC(1, link)
	host.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: tcpip.AddressWithPrefix{Address: tcpip.AddrFrom4([4]byte{10, 0, 0, 2}), PrefixLen: 32}}, stack.AddressProperties{})
	host.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		for {
			p := link.ReadContext(ctx)
			if p == nil {
				return
			}
			v := p.ToView()
			peer.Write(v.AsSlice())
			v.Release()
			p.DecRef()
		}
	}()
	go func() {
		b := make([]byte, 65535)
		for {
			n, e := peer.Read(b)
			if e != nil {
				return
			}
			p := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte{}, b[:n]...))})
			link.InjectInbound(ipv4.ProtocolNumber, p)
			p.DecRef()
		}
	}()
	defer func() {
		cancel()
		peer.Close()
		host.Close()
		link.Close()
		g.Close()
		host.Wait()
	}()
	dial := func(network string, ip netip.Addr, port uint16) net.Conn {
		t.Helper()
		addr := tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4(ip.As4()), Port: port}
		if network == "tcp" {
			ctx, c := context.WithTimeout(context.Background(), 3*time.Second)
			defer c()
			conn, e := gonet.DialContextTCP(ctx, host, addr, ipv4.ProtocolNumber)
			if e != nil {
				t.Fatal(e)
			}
			return conn
		}
		conn, e := gonet.DialUDP(host, nil, &addr, ipv4.ProtocolNumber)
		if e != nil {
			t.Fatal(e)
		}
		return conn
	}
	resolve := func(name string) netip.Addr {
		t.Helper()
		c := dial("udp", netip.MustParseAddr("198.18.0.1"), 53)
		defer c.Close()
		c.SetDeadline(time.Now().Add(3 * time.Second))
		q := dnsmessage.Message{Header: dnsmessage.Header{ID: 12, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name + "."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
		raw, _ := q.Pack()
		c.Write(raw)
		b := make([]byte, 512)
		n, e := c.Read(b)
		if e != nil {
			t.Fatal(e)
		}
		var reply dnsmessage.Message
		if e = reply.Unpack(b[:n]); e != nil || len(reply.Answers) != 1 {
			t.Fatalf("DNS: %+v %v", reply, e)
		}
		return netip.AddrFrom4(reply.Answers[0].Body.(*dnsmessage.AResource).A)
	}
	a, b := resolve("a.example"), resolve("b.example")
	if a == b || a.String() == "198.18.0.1" {
		t.Fatal("fake DNS collision")
	}
	cases := []struct {
		ip             netip.Addr
		owner, network string
	}{{a, "alpha", "tcp"}, {b, "beta", "tcp"}, {a, "alpha", "udp"}, {netip.MustParseAddr("8.8.8.8"), "", "tcp"}}
	for _, test := range cases {
		c := dial(test.network, test.ip, 80)
		c.SetDeadline(time.Now().Add(3 * time.Second))
		c.Write([]byte("hello"))
		want := test.owner + ":hello"
		out := make([]byte, len(want))
		if _, e := io.ReadFull(c, out); e != nil {
			t.Fatal(e)
		}
		c.Close()
		if string(out) != want {
			t.Fatalf("%s != %s", out, want)
		}
	}
	if _, e := g.target(netip.MustParseAddr("198.19.255.254")); e == nil {
		t.Fatal("unknown fake IP must never bypass tunnel")
	}
}
