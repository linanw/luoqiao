package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"harmony/tailnet/multinet"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type independentTailnets struct {
	policy  *multinet.Policy
	closed  atomic.Int32
	changed atomic.Int32
	calls   atomic.Int32
	fail    atomic.Bool
}

func newIndependentTailnets(t *testing.T) *independentTailnets {
	t.Helper()
	policy, err := multinet.Compile(multinet.Config{Profiles: []multinet.Profile{
		{ID: "aaaaaaaa", Domains: []string{"tn-a.test", "specific.shared.test", "same.test"}, CIDRs: []string{"10.4.0.0/16"}},
		{ID: "bbbbbbbb", Domains: []string{"tn-b.test"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	return &independentTailnets{policy: policy}
}
func (m *independentTailnets) PolicyDomain(name string) (string, int) {
	return m.policy.DomainMatch(name)
}
func (m *independentTailnets) PolicyIP(ip netip.Addr) (string, int) { return m.policy.IPMatch(ip) }
func (*independentTailnets) AutomaticDomain(name string) string {
	if name == "host.tailnet.test" {
		return "aaaaaaaa"
	}
	return ""
}
func (*independentTailnets) AutomaticIP(ip netip.Addr) string {
	if ip == netip.MustParseAddr("100.64.1.2") || ip == netip.MustParseAddr("192.168.72.60") {
		return "aaaaaaaa"
	}
	return ""
}
func (m *independentTailnets) Dial(_ context.Context, owner, network, _ string) (net.Conn, error) {
	m.calls.Add(1)
	if m.fail.Load() || owner != "aaaaaaaa" && owner != "bbbbbbbb" {
		return nil, errors.New("selected tailnet unavailable")
	}
	local, remote := net.Pipe()
	go func() {
		defer remote.Close()
		buf := make([]byte, 512)
		for {
			n, err := remote.Read(buf)
			if err != nil {
				return
			}
			if _, err = remote.Write(append([]byte(owner+":"+network+":"), buf[:n]...)); err != nil {
				return
			}
		}
	}()
	return local, nil
}
func (m *independentTailnets) NetworkChanged([]string) error { m.changed.Add(1); return nil }
func (*independentTailnets) Status() []multinet.NodeStatus {
	return []multinet.NodeStatus{{ID: "aaaaaaaa", BackendState: "Running"}, {ID: "bbbbbbbb", BackendState: "NeedsLogin"}}
}
func (m *independentTailnets) Close() { m.closed.Add(1) }

func TestMixedPolicySpecificityAndFailureIsolation(t *testing.T) {
	m := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{
		{ID: "main", Default: true, CIDRs: []string{"0.0.0.0/0", "10.0.0.0/8"}, Domains: []string{"shared.test", "same.test"}},
		{ID: "aaaaaaaa", Exacts: []string{"exact.specific.shared.test"}, CIDRs: []string{"10.4.1.0/24"}},
	}})
	tn := newIndependentTailnets(t)
	m.tailnets = tn
	for name, want := range map[string]string{"public.test": "wg:main", "specific.shared.test": "aaaaaaaa", "x.shared.test": "wg:main", "exact.specific.shared.test": "wg:aaaaaaaa", "host.tailnet.test": "aaaaaaaa", "same.test": "!ambiguous"} {
		if got := m.Domain(name); got != want {
			t.Fatalf("%s => %s, want %s", name, got, want)
		}
	}
	for address, want := range map[string]string{"10.4.1.9": "wg:aaaaaaaa", "10.4.2.9": "aaaaaaaa", "100.64.1.2": "aaaaaaaa", "192.168.72.60": "aaaaaaaa", "1.1.1.1": "wg:main"} {
		if got := m.IP(netip.MustParseAddr(address)); got != want {
			t.Fatalf("%s => %s, want %s", address, got, want)
		}
	}
	direct := &recordingDialer{err: errors.New("must not use physical network")}
	m.direct = direct
	wg := &recordingDialer{err: errors.New("wg failed")}
	m.dialers["aaaaaaaa"] = wg
	tn.fail.Store(true)
	for _, owner := range []string{"aaaaaaaa", "wg:aaaaaaaa", "!ambiguous", "unknown"} {
		if _, err := m.Dial(context.Background(), owner, "tcp", "private.test:443"); err == nil {
			t.Fatal("failure expected")
		}
	}
	if direct.calls.Load() != 0 || wg.calls.Load() != 1 {
		t.Fatal("a selected or ambiguous flow escaped its owner")
	}
	if err := m.setDNS([]string{"8.8.8.8"}); err != nil || tn.changed.Load() != 1 {
		t.Fatal("network change not delivered")
	}
	configured := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{{ID: "subnet", CIDRs: []string{"192.168.0.0/16"}, RoutesFallback: true}}})
	configured.tailnets = tn
	if configured.IP(netip.MustParseAddr("192.168.72.60")) != "aaaaaaaa" || configured.IP(netip.MustParseAddr("192.168.1.1")) != "wg:subnet" {
		t.Fatal("configured WireGuard AllowedIPs swallowed a discovered Tailnet subnet")
	}
}

// Each server uses its own key pair and may even use the same private addresses.
// The shared system gateway must select the right encrypted device by DNS owner.
func mixedWireGuardServer(t *testing.T, domain, label string) (int, string, func()) {
	t.Helper()
	a, aPort, closeA := testSocket(t)
	b, bPort, closeB := testSocket(t)
	aKey, bKey := testKey(t), testKey(t)
	aIP, bIP := netip.MustParseAddr("10.44.0.2"), netip.MustParseAddr("10.44.0.1")
	tun, stack, err := netstack.CreateNetTUN([]netip.Addr{bIP}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	bind, err := newProtectedBind(b)
	if err != nil {
		t.Fatal(err)
	}
	server := device.NewDevice(tun, bind, device.NewLogger(device.LogLevelSilent, ""))
	t.Cleanup(server.Close)
	conf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=%s/32\n", bKey.Bytes(), aKey.PublicKey().Bytes(), aPort, aIP)
	if err := server.IpcSet(conf); err != nil {
		t.Fatal(err)
	}
	if err := server.Up(); err != nil {
		t.Fatal(err)
	}
	closeB()
	dns, err := stack.ListenUDPAddrPort(netip.AddrPortFrom(bIP, 53))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dns.Close() })
	go func() {
		buf := make([]byte, 4096)
		for {
			n, addr, err := dns.ReadFrom(buf)
			if err != nil {
				return
			}
			var q dnsmessage.Message
			if q.Unpack(buf[:n]) != nil || len(q.Questions) != 1 {
				continue
			}
			q.Header.Response = true
			q.Header.RecursionAvailable = true
			q.Answers = nil
			if normalizeName(q.Questions[0].Name.String()) == domain && q.Questions[0].Type == dnsmessage.TypeA {
				q.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: q.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: bIP.As4()}}}
			}
			reply, _ := q.Pack()
			dns.WriteTo(reply, addr)
		}
	}()
	tcp, err := stack.ListenTCPAddrPort(netip.AddrPortFrom(bIP, 8080))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tcp.Close() })
	go echoListener(tcp, label+":")
	udp, err := stack.ListenUDPAddrPort(netip.AddrPortFrom(bIP, 8080))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { udp.Close() })
	go func() {
		b := make([]byte, 512)
		for {
			n, a, e := udp.ReadFrom(b)
			if e != nil {
				return
			}
			udp.WriteTo(append([]byte(label+":"), b[:n]...), a)
		}
	}()
	client := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=0.0.0.0/0\n", aKey.Bytes(), bKey.PublicKey().Bytes(), bPort)
	return a, client, closeA
}

func TestTwoEncryptedWireGuardsAndIndependentTailnetsShareGateway(t *testing.T) {
	a, confA, closeA := mixedWireGuardServer(t, "wg-a.test", "wireguard-a")
	b, confB, closeB := mixedWireGuardServer(t, "wg-b.test", "wireguard-b")
	pair := testTunPair(t)
	config := RoutedConfig{Profiles: []RoutedProfile{
		{ID: "main", Addresses: []string{"10.44.0.2"}, DNS: []string{"10.44.0.1"}, Domains: []string{"wg-a.test"}},
		{ID: "second", Addresses: []string{"10.44.0.2"}, DNS: []string{"10.44.0.1"}, Domains: []string{"wg-b.test"}},
	}}
	group, result := startRoutedTunnels(pair[0], 1280, []int{a, b}, []string{confA, confB}, config)
	if result != 0 {
		t.Fatalf("start %d", result)
	}
	t.Cleanup(group.close)
	closeA()
	closeB()
	tn := newIndependentTailnets(t)
	group.routed.tailnets = tn
	host := newGatewayTestHost(t, pair[1])
	t.Cleanup(func() {
		if t.Failed() {
			t.Log("flow error:", group.gateway.FlowError())
			for i, dev := range group.devices {
				var s tunnelStats
				dev.IpcGetOperation(&s)
				t.Log("device", i, "stats", s)
			}
		}
	})
	for domain, label := range map[string]string{"wg-a.test": "wireguard-a", "wg-b.test": "wireguard-b", "tn-a.test": "aaaaaaaa", "tn-b.test": "bbbbbbbb", "host.tailnet.test": "aaaaaaaa"} {
		fake := host.resolve(t, domain, dnsmessage.TypeAAAA)
		for _, network := range []string{"tcp", "udp"} {
			t.Log(domain, network)
			want := label + ":hello"
			if label == "aaaaaaaa" || label == "bbbbbbbb" {
				want = label + ":" + network + ":hello"
			}
			mixedExchange(t, host.dial(t, network, fake, 8080), want)
		}
	}
	for _, addr := range []string{"100.64.1.2", "192.168.72.60"} {
		mixedExchange(t, host.dial(t, "tcp", netip.MustParseAddr(addr), 8080), "aaaaaaaa:tcp:hello")
	}
	// Bind to a real interface: gVisor intentionally rejects loopback destination
	// packets arriving through the synthetic system TUN.
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		t.Fatal(err)
	}
	var physical netip.Addr
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err == nil && prefix.Addr().Is4() && !prefix.Addr().IsLoopback() {
			physical = prefix.Addr()
			break
		}
	}
	if !physical.IsValid() {
		t.Fatal("test needs a local non-loopback IPv4 interface")
	}
	direct, err := net.Listen("tcp4", net.JoinHostPort(physical.String(), "0"))
	if err != nil {
		t.Fatal(err)
	}
	defer direct.Close()
	go echoListener(direct, "physical:")
	mixedExchange(t, host.dial(t, "tcp", physical, uint16(direct.Addr().(*net.TCPAddr).Port)), "physical:hello")
	if group.gateway.directFlows.Load() != 1 {
		t.Fatal("unselected traffic did not use the physical network")
	}
	handle := registerGroup(group)
	var detail groupDetails
	if err := json.Unmarshal([]byte(groupDetailJSON(handle)), &detail); err != nil {
		t.Fatal(err)
	}
	if len(detail.WireGuard) != 2 || len(detail.Tailnets) != 2 {
		t.Fatal("lost per-connection status")
	}
	for _, s := range detail.WireGuard {
		if s.LastHandshake == 0 || s.SentBytes == 0 || s.ReceivedBytes == 0 || !s.Running {
			t.Fatal("no encrypted roundtrip", s)
		}
	}
	// An open selected flow must be released before the Tailnet manager is closed.
	open := host.dial(t, "tcp", netip.MustParseAddr("100.64.1.2"), 8080)
	if _, err := open.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	out := make([]byte, len("aaaaaaaa:tcp:hello"))
	if _, err := io.ReadFull(open, out); err != nil {
		t.Fatal(err)
	}
	group.close()
	open.Close()
	group.close()
	groups.Lock()
	delete(groups.entries, handle)
	groups.Unlock()
	if tn.closed.Load() != 1 {
		t.Fatal("tailnet lifecycle not closed exactly once")
	}
}

func TestTailnetOnlyRoutingDocument(t *testing.T) {
	raw := fmt.Sprintf(`{"DNS":["8.8.8.8"],"Profiles":[],"Tailnets":{"Directory":%q,"Profiles":[{"ID":"legacy","Hostname":"harmony","LegacyState":true}]}}`, t.TempDir())
	if _, err := parseRoutedConfig(raw, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := parseRoutedConfig(`{"Profiles":[]}`, 0); err == nil {
		t.Fatal("empty gateway accepted")
	}
}

func TestMixedDetailExposesFlowFailureWithoutConfiguration(t *testing.T) {
	gateway := &Gateway{}
	gateway.lastError.Store("selected network has no route")
	group := &tunnelGroup{gateway: gateway}
	handle := registerGroup(group)
	defer func() { groups.Lock(); delete(groups.entries, handle); groups.Unlock() }()
	var details groupDetails
	if err := json.Unmarshal([]byte(groupDetailJSON(handle)), &details); err != nil {
		t.Fatal(err)
	}
	if details.FlowError != "selected network has no route" {
		t.Fatal("flow diagnostic not propagated")
	}
}

// Under the race detector, two independent WireGuard handshakes may need a
// retransmission. Match the gateway dial timeout rather than a five-second echo deadline.
func mixedExchange(t *testing.T, conn net.Conn, want string) {
	t.Helper()
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(25 * time.Second))
	if _, err := conn.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(want))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
