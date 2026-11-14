package main

import (
	"context"
	"errors"
	"fmt"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
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
	"io"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRoutedPolicy(t *testing.T) {
	m := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{
		{ID: "broad", Domains: []string{"example.com"}, CIDRs: []string{"10.0.0.0/8"}},
		{ID: "specific", Domains: []string{"sub.example.com"}, Exacts: []string{"api.example.com"}, CIDRs: []string{"10.2.0.0/16"}},
	}})
	for name, want := range map[string]string{"EXAMPLE.COM.": "broad", "a.example.com": "broad", "a.sub.example.com": "specific", "api.example.com": "specific", "notexample.com": "", "unrelated.test": ""} {
		if got := m.Domain(name); got != wgOwner(want) {
			t.Errorf("Domain(%q)=%q want %q", name, got, want)
		}
	}
	if m.IP(netip.MustParseAddr("10.2.9.1")) != "wg:specific" || m.IP(netip.MustParseAddr("10.3.9.1")) != "wg:broad" || m.IP(netip.MustParseAddr("11.2.9.1")) != "" {
		t.Fatal("CIDR longest match failed")
	}
	defaultV4 := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{{ID: "default", Default: true, CIDRs: []string{"0.0.0.0/0"}}}})
	if defaultV4.Domain("public.test") != "wg:default" || defaultV4.IP(netip.MustParseAddr("203.0.113.1")) != "wg:default" || defaultV4.IP(netip.MustParseAddr("2001:db8::1")) != "" {
		t.Fatal("default domain route must preserve address-family restrictions for literal IP flows")
	}
	ambiguous := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{{ID: "a", Domains: []string{"same.test"}}, {ID: "b", Domains: []string{"same.test"}}}})
	if ambiguous.Domain("same.test") != "!ambiguous" {
		t.Fatal("equal conflicting domains must fail closed")
	}
}

type recordingDialer struct {
	calls atomic.Int32
	err   error
}

func (d *recordingDialer) DialContext(context.Context, string, string) (net.Conn, error) {
	d.calls.Add(1)
	return nil, d.err
}
func TestSelectedWireGuardFailureNeverFallsBack(t *testing.T) {
	selected := &recordingDialer{err: errors.New("tunnel unavailable")}
	direct := &recordingDialer{err: errors.New("direct must not run")}
	m := newRoutedManager(RoutedConfig{})
	m.direct = direct
	m.dialers["only"] = selected
	if _, err := m.Dial(context.Background(), "only", "tcp", "private.example:443"); err == nil {
		t.Fatal("expected failure")
	}
	if _, err := m.Dial(context.Background(), "missing", "tcp", "private.example:443"); err == nil {
		t.Fatal("missing network must fail closed")
	}
	if selected.calls.Load() != 1 || direct.calls.Load() != 0 {
		t.Fatal("selected failure used direct connection")
	}
	m.Dial(context.Background(), "", "tcp", "192.0.2.1:443")
	if direct.calls.Load() != 1 {
		t.Fatal("unselected flow must use physical dialer")
	}
}
func TestRoutedConfigValidationAndDNSFamily(t *testing.T) {
	good := `{"DNS":["8.8.8.8"],"Profiles":[{"ID":"one","Addresses":["10.0.0.2"],"Domains":["ifconfig.co"]}]}`
	config, err := parseRoutedConfig(good, 1)
	if err != nil {
		t.Fatal(err)
	}
	addresses, dns := tunnelAddresses(config.Profiles[0])
	if len(addresses) != 1 || len(dns) != 1 || dns[0].String() != "1.1.1.1" {
		t.Fatal("bad fallback DNS", addresses, dns)
	}
	for _, bad := range []string{strings.Replace(good, "8.8.8.8", "198.18.0.1", 1), strings.Replace(good, "10.0.0.2", "bad", 1), strings.Replace(good, "ifconfig.co", "https://ifconfig.co", 1)} {
		if _, err := parseRoutedConfig(bad, 1); err == nil {
			t.Fatal("invalid document accepted")
		}
	}
	if _, err := parseRoutedConfig(good, 2); err == nil {
		t.Fatal("count mismatch accepted")
	}
}

// Two actual WireGuard devices transport DNS and TCP/UDP over loopback. The
// browser-side flow uses fake IPv6 while the selected WireGuard network is IPv4 only.
func TestRoutedFakeIPv6ThroughIPv4WireGuard(t *testing.T) {
	a, aPort, closeA := testSocket(t)
	b, bPort, closeB := testSocket(t)
	aKey, bKey := testKey(t), testKey(t)
	aIP, bIP := netip.MustParseAddr("10.44.0.2"), netip.MustParseAddr("10.44.0.1")
	serverTun, serverNet, err := netstack.CreateNetTUN([]netip.Addr{bIP}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	serverBind, err := newProtectedBind(b)
	if err != nil {
		serverTun.Close()
		t.Fatal(err)
	}
	server := device.NewDevice(serverTun, serverBind, device.NewLogger(device.LogLevelSilent, ""))
	t.Cleanup(server.Close)
	serverConf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=%s/32\n", bKey.Bytes(), aKey.PublicKey().Bytes(), aPort, aIP)
	if err := server.IpcSet(serverConf); err != nil {
		t.Fatal(err)
	}
	if err := server.Up(); err != nil {
		t.Fatal(err)
	}
	closeB()
	dnsListener, err := serverNet.ListenUDPAddrPort(netip.AddrPortFrom(bIP, 53))
	if err != nil {
		t.Fatal(err)
	}
	defer dnsListener.Close()
	var dnsQueries atomic.Int32
	go func() {
		buf := make([]byte, 4096)
		for {
			n, addr, err := dnsListener.ReadFrom(buf)
			if err != nil {
				return
			}
			var q dnsmessage.Message
			if q.Unpack(buf[:n]) != nil || len(q.Questions) != 1 {
				continue
			}
			dnsQueries.Add(1)
			q.Header.Response = true
			q.Header.RecursionAvailable = true
			q.Answers = nil
			question := q.Questions[0]
			if normalizeName(question.Name.String()) == "only-wg.test" && question.Type == dnsmessage.TypeA {
				q.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: bIP.As4()}}}
			} else {
				q.Header.RCode = dnsmessage.RCodeNameError
			}
			reply, _ := q.Pack()
			dnsListener.WriteTo(reply, addr)
		}
	}()
	listener, err := serverNet.ListenTCPAddrPort(netip.AddrPortFrom(bIP, 8080))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go echoListener(listener, "wireguard:")
	packets, err := serverNet.ListenUDPAddrPort(netip.AddrPortFrom(bIP, 8080))
	if err != nil {
		t.Fatal(err)
	}
	defer packets.Close()
	go func() {
		b := make([]byte, 512)
		for {
			n, addr, err := packets.ReadFrom(b)
			if err != nil {
				return
			}
			packets.WriteTo(append([]byte("wireguard:"), b[:n]...), addr)
		}
	}()
	pair := testTunPair(t)
	clientConf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=0.0.0.0/0\n", aKey.Bytes(), bKey.PublicKey().Bytes(), bPort)
	config := RoutedConfig{Profiles: []RoutedProfile{{ID: "v4-wg", Addresses: []string{aIP.String()}, DNS: []string{bIP.String()}, Domains: []string{"only-wg.test"}}}}
	group, result := startRoutedTunnels(pair[0], 1280, []int{a}, []string{clientConf}, config)
	if result != 0 {
		t.Fatalf("routed WireGuard start failed (%d)", result)
	}
	t.Cleanup(group.close)
	closeA()
	host := newGatewayTestHost(t, pair[1])
	fake := host.resolve(t, "only-wg.test", dnsmessage.TypeAAAA)
	if !fake.Is6() || !syntheticAddress(fake) {
		t.Fatal("expected fake IPv6", fake)
	}
	for _, network := range []string{"tcp", "udp"} {
		exchange(t, host.dial(t, network, fake, 8080), "wireguard:hello")
	}
	if group.gateway.selectedDNS.Load() != 1 || group.gateway.selectedFlows.Load() != 2 || group.gateway.directFlows.Load() != 0 {
		t.Fatal("route counters must distinguish selected DNS, selected flows and forwarded DNS")
	}
	if dnsQueries.Load() < 2 {
		t.Fatal("domain was not resolved inside WG")
	}
	var stats tunnelStats
	if err := group.devices[0].IpcGetOperation(&stats); err != nil {
		t.Fatal(err)
	}
	if stats.sent == 0 || stats.received == 0 || stats.handshake == 0 {
		t.Fatal("no encrypted roundtrip", stats)
	}
	direct, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer direct.Close()
	go echoListener(direct, "physical:")
	physical, err := group.gateway.manager.Dial(context.Background(), "", "tcp", direct.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	exchange(t, physical, "physical:hello")
	if _, err := group.gateway.target(netip.MustParseAddr("fd7e:746e::ffff")); err == nil {
		t.Fatal("expired fake address leaked to physical network")
	}
}
func echoListener(listener net.Listener, prefix string) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			buf := make([]byte, 512)
			for {
				n, err := conn.Read(buf)
				if err != nil {
					return
				}
				if _, err = conn.Write(append([]byte(prefix), buf[:n]...)); err != nil {
					return
				}
			}
		}()
	}
}
func exchange(t *testing.T, c net.Conn, want string) {
	t.Helper()
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	out := make([]byte, len(want))
	if _, err := io.ReadFull(c, out); err != nil {
		t.Fatal(err)
	}
	if string(out) != want {
		t.Fatalf("got %q want %q", out, want)
	}
}

type gatewayTestHost struct{ s *stack.Stack }

func newGatewayTestHost(t *testing.T, fd int) *gatewayTestHost {
	t.Helper()
	dup, err := unix.Dup(fd)
	if err != nil {
		t.Fatal(err)
	}
	peer := os.NewFile(uintptr(dup), "gateway-host")
	host := stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol}, TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	link := channel.New(64, 1280, "")
	if err := host.CreateNIC(1, link); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"192.0.2.2", "fd7e:746e::2"} {
		ip := netip.MustParseAddr(raw)
		proto := ipv4.ProtocolNumber
		if ip.Is6() {
			proto = ipv6.ProtocolNumber
		}
		if err := host.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: proto, AddressWithPrefix: tcpip.AddressWithPrefix{Address: tcpip.AddrFromSlice(ip.AsSlice()), PrefixLen: ip.BitLen()}}, stack.AddressProperties{}); err != nil {
			t.Fatal(err)
		}
	}
	host.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}, {Destination: header.IPv6EmptySubnet, NIC: 1}})
	ctx, cancel := context.WithCancel(context.Background())
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
			n, err := peer.Read(b)
			if err != nil {
				return
			}
			proto := ipv4.ProtocolNumber
			if b[0]>>4 == 6 {
				proto = ipv6.ProtocolNumber
			}
			p := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte{}, b[:n]...))})
			link.InjectInbound(proto, p)
			p.DecRef()
		}
	}()
	t.Cleanup(func() { cancel(); peer.Close(); host.Close(); link.Close(); host.Wait() })
	return &gatewayTestHost{host}
}
func (h *gatewayTestHost) dial(t *testing.T, network string, ip netip.Addr, port uint16) net.Conn {
	t.Helper()
	addr := tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(ip.AsSlice()), Port: port}
	proto := ipv4.ProtocolNumber
	if ip.Is6() {
		proto = ipv6.ProtocolNumber
	}
	if network == "tcp" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		c, err := gonet.DialContextTCP(ctx, h.s, addr, proto)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	c, err := gonet.DialUDP(h.s, nil, &addr, proto)
	if err != nil {
		t.Fatal(err)
	}
	return c
}
func (h *gatewayTestHost) resolve(t *testing.T, name string, kind dnsmessage.Type) netip.Addr {
	t.Helper()
	c := h.dial(t, "udp", netip.MustParseAddr("198.18.0.1"), 53)
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 10, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name + "."), Type: kind, Class: dnsmessage.ClassINET}}}
	raw, _ := q.Pack()
	if _, err := c.Write(raw); err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 4096)
	n, err := c.Read(b)
	if err != nil {
		t.Fatal(err)
	}
	var reply dnsmessage.Message
	if err := reply.Unpack(b[:n]); err != nil || len(reply.Answers) != 1 {
		t.Fatalf("DNS response %+v %v", reply, err)
	}
	switch record := reply.Answers[0].Body.(type) {
	case *dnsmessage.AResource:
		return netip.AddrFrom4(record.A)
	case *dnsmessage.AAAAResource:
		return netip.AddrFrom16(record.AAAA)
	}
	t.Fatal("unexpected DNS record")
	return netip.Addr{}
}

// A failed start must release its duplicates of the protected UDP sockets;
// checking that the same UDP port can be rebound catches leaks independently
// of unrelated Go runtime descriptors or garbage collection timing.
func TestRoutedStartFailureReleasesProtectedSockets(t *testing.T) {
	for _, phase := range []string{"invalid-uapi", "later-invalid-socket", "invalid-system-tun"} {
		t.Run(phase, func(t *testing.T) {
			for attempt := 0; attempt < 4; attempt++ {
				fd, port, closeOriginal := testSocket(t)
				pair := testTunPair(t)
				config := RoutedConfig{Profiles: []RoutedProfile{{ID: "first", Addresses: []string{"10.44.0.2"}}}}
				fds := []int{fd}
				confs := []string{fmt.Sprintf("private_key=%x\n", testKey(t).Bytes())}
				tunFD := pair[0]
				want := -4
				switch phase {
				case "invalid-uapi":
					confs[0] = "private_key=invalid\n"
				case "later-invalid-socket":
					want = -2
					fds = append(fds, -1)
					confs = append(confs, confs[0])
					config.Profiles = append(config.Profiles, RoutedProfile{ID: "second", Addresses: []string{"10.45.0.2"}})
				case "invalid-system-tun":
					want = -3
					tunFD = -1
				}
				group, result := startRoutedTunnels(tunFD, 1280, fds, confs, config)
				if group != nil {
					group.close()
					t.Fatal("unexpected successful start")
				}
				if result != want {
					t.Fatalf("failure = %d, want %d", result, want)
				}
				closeOriginal()
				rebound, err := net.ListenUDP("udp", &net.UDPAddr{Port: int(port)})
				if err != nil {
					t.Fatalf("protected socket leaked on %s: %v", phase, err)
				}
				rebound.Close()
			}
		})
	}
}

func TestPhysicalDNSUpdatesWithoutRestart(t *testing.T) {
	m := newRoutedManager(RoutedConfig{DNS: []string{"192.0.2.53"}})
	updated := []string{"2001:db8::53", "198.51.100.53"}
	if err := m.setDNS(updated); err != nil {
		t.Fatal(err)
	}
	updated[0] = "203.0.113.1"
	copyOfDNS := m.DNS()
	if len(copyOfDNS) != 2 || copyOfDNS[0] != "2001:db8::53" {
		t.Fatal("new network DNS was not retained independently")
	}
	copyOfDNS[0] = "203.0.113.2"
	if m.DNS()[0] != "2001:db8::53" {
		t.Fatal("returned DNS snapshot aliases runtime state")
	}
	for _, invalid := range [][]string{{"198.18.0.1"}, {"fd7e:746e::1"}, {"not-an-ip"}, {"0.0.0.0"}, {"224.0.0.1"}} {
		if err := m.setDNS(invalid); err == nil {
			t.Fatal("accepted invalid/recursive physical DNS", invalid)
		}
		if m.DNS()[0] != "2001:db8::53" {
			t.Fatal("invalid update discarded working DNS")
		}
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				if worker%2 == 0 {
					m.setDNS([]string{"192.0.2.53"})
				} else {
					dns := m.DNS()
					if len(dns) > 0 {
						dns[0] = "203.0.113.1"
					}
				}
			}
		}(i)
	}
	wg.Wait()
	if m.DNS()[0] != "192.0.2.53" {
		t.Fatal("concurrent DNS updates were corrupted")
	}
}
