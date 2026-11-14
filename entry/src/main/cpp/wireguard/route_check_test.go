package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"harmony/tailnet/multinet"
)

func routeCheckerFixture(t *testing.T, config RoutedConfig) (*tunnelGroup, *recordingDialer, *subnetTestTailnets) {
	t.Helper()
	m := newRoutedManager(config)
	dialer := &recordingDialer{err: errors.New("checker must not dial a business connection")}
	m.direct = dialer
	for _, profile := range config.Profiles {
		m.dialers[profile.ID] = dialer
	}
	tn := &subnetTestTailnets{independentTailnets: newIndependentTailnets(t), statuses: []multinet.NodeStatus{{ID: "aaaaaaaa", Name: "家庭Tailnet", BackendState: "Running", DNSSuffix: "tailnet.test", PeerNames: []string{"host.tailnet.test"}, PeerIPs: []string{"100.64.1.2"}, SubnetRoutes: []string{"192.168.72.0/24"}}, {ID: "bbbbbbbb", BackendState: "Running"}}}
	m.tailnets = tn
	g, err := NewGateway(m)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(g.Close)
	return &tunnelGroup{gateway: g, routed: m}, dialer, tn
}

func TestRouteCheckerCurrentDomainRulesAndNoSideEffects(t *testing.T) {
	group, dialer, tn := routeCheckerFixture(t, RoutedConfig{Profiles: []RoutedProfile{
		{ID: "one", Domains: []string{"example.com", "same.test"}},
		{ID: "two", Exacts: []string{"api.example.com"}},
		{ID: "default", Default: true},
	}})
	for target, want := range map[string]string{"api.example.com": "wg:two", "a.example.com": "wg:one", "tn-a.test": "aaaaaaaa", "host.tailnet.test": "aaaaaaaa", "elsewhere.test": "wg:default", "same.test": "!ambiguous"} {
		result := checkRoute(group, routeCheckRequest{Target: target, ResolveDNS: true})
		if result.Error != "" || result.Decision.Owner != want || result.DNS.Status != "not_needed" || len(result.Addresses) != 0 {
			t.Fatalf("%s: %+v", target, result)
		}
		if result.Decision.Reason == "" || result.Decision.Rule == "" {
			t.Fatal("missing explanation", result)
		}
		if result.Decision.Owner != group.routed.Domain(target) {
			t.Fatal("checker disagrees with actual domain owner")
		}
	}
	if dialer.calls.Load() != 0 || tn.calls.Load() != 0 || group.gateway.selectedDNS.Load() != 0 || len(group.gateway.fake) != 0 || len(group.gateway.RouteEvents()) != 0 {
		t.Fatal("read-only checker mutated routing or dialed a business flow")
	}
	tn.statuses[0].BackendState = "NeedsLogin"
	result := checkRoute(group, routeCheckRequest{Target: "host.tailnet.test"})
	if result.Decision.Kind != "unavailable" || result.Decision.Owner != "aaaaaaaa" {
		t.Fatal("unavailable Tailnet lost its fail-closed owner", result)
	}
}

func TestRouteCheckerSubnetAliasesAndSystemOverlapWarning(t *testing.T) {
	group, dialer, _ := routeCheckerFixture(t, RoutedConfig{LocalPrefixes: []string{"192.168.72.0/24"}, SubnetPreferences: []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "tailnet", TailnetID: "aaaaaaaa"}}, Profiles: []RoutedProfile{{ID: "fallback", CIDRs: []string{"0.0.0.0/0"}, RoutesFallback: true}}})
	for _, address := range []string{"192.168.72.60", "203.0.113.60", "100.64.1.2"} {
		result := checkRoute(group, routeCheckRequest{Target: address})
		if result.Decision.Owner != group.routed.IP(netip.MustParseAddr(address)) {
			t.Fatal("checker disagrees with IP policy", result)
		}
	}
	raw := checkRoute(group, routeCheckRequest{Target: "192.168.72.60"})
	if raw.Decision.Kind != "tailnet" || !raw.Decision.RawIPMayBypassVPN || raw.Decision.ReasonCode != "subnet_preference" || len(raw.Warnings) == 0 {
		t.Fatal("raw IP system overlap not explained", raw)
	}
	real := netip.MustParseAddr("192.168.72.60")
	fake, err := group.gateway.allocateTarget(real.String(), "!subnet", false, destination{host: real.String(), literal: real})
	if err != nil {
		t.Fatal(err)
	}
	alias := checkRoute(group, routeCheckRequest{Target: fake.String()})
	if !alias.Decision.SyntheticDNS || alias.Decision.RawIPMayBypassVPN || alias.Decision.Owner != "aaaaaaaa" {
		t.Fatal("synthetic DNS path not explained", alias)
	}
	group.routed.tailnets = nil
	unavailable := checkRoute(group, routeCheckRequest{Target: fake.String()})
	if unavailable.Decision.Kind != "unavailable" || unavailable.Decision.Owner != unavailableSubnetOwner {
		t.Fatal("disabled preferred Tailnet was reported as direct", unavailable)
	}
	if err := group.routed.setNetwork(routedNetwork{DNS: []string{"8.8.8.8"}, LocalPrefixes: []string{}}); err != nil {
		t.Fatal(err)
	}
	cellular := checkRoute(group, routeCheckRequest{Target: fake.String()})
	if cellular.Decision.Owner != "wg:fallback" || !cellular.Decision.SyntheticDNS {
		t.Fatal("checker cached alias's old owner", cellular)
	}
	expired := checkRoute(group, routeCheckRequest{Target: "198.18.255.254"})
	if expired.Decision.Kind != "unavailable" || expired.Decision.ReasonCode != "expired_dns_alias" {
		t.Fatal("expired alias was treated as normal IP", expired)
	}
	if dialer.calls.Load() != 0 {
		t.Fatal("checker invoked business dialer")
	}
}

func TestRouteCheckerRawModeLongestPrefixAndUnsupportedDomains(t *testing.T) {
	table := newRouteTable()
	table.insert(netip.MustParsePrefix("0.0.0.0/0"), 0)
	table.insert(netip.MustParsePrefix("10.0.0.0/8"), 1)
	table.insert(netip.MustParsePrefix("10.0.0.0/8"), 2)
	group := &tunnelGroup{table: table}
	result := checkRoute(group, routeCheckRequest{Target: "10.3.4.5"})
	if result.Decision.Kind != "wireguard" || result.Decision.DeviceIndex != 1 || result.Decision.Rule != "10.0.0.0/8" {
		t.Fatal(result)
	}
	for _, target := range []string{"public.example", "2001:db8::1"} {
		result = checkRoute(group, routeCheckRequest{Target: target, ResolveDNS: true})
		if result.Decision.Kind != "unsupported" {
			t.Fatal("unknown raw route was guessed", result)
		}
	}
}

func TestRouteCheckerInputAndConcurrentNetworkSnapshots(t *testing.T) {
	for input, want := range map[string]string{"https://Home.Example/path?query=1": "home.example", "home.example:443": "home.example", "[2001:db8::1]:443": "2001:db8::1", "HOME.EXAMPLE.": "home.example"} {
		host, _, err := normalizeCheckTarget(input)
		if err != nil || host != want {
			t.Fatal(input, host, err)
		}
	}
	for _, input := range []string{"", "http://name:password@example.test", "file:///etc/passwd", "name/path", "192.168.1.0/24", "name\\.test", "0.0.0.0", "name:99999"} {
		if _, _, err := normalizeCheckTarget(input); err == nil {
			t.Fatal("invalid target accepted", input)
		}
	}
	group, _, _ := routeCheckerFixture(t, RoutedConfig{SubnetPreferences: []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "local"}}})
	var workers sync.WaitGroup
	for i := 0; i < 4; i++ {
		workers.Add(1)
		go func(i int) {
			defer workers.Done()
			for n := 0; n < 100; n++ {
				if i%2 == 0 {
					group.routed.setNetwork(routedNetwork{DNS: []string{"192.168.72.1"}, LocalPrefixes: []string{"192.168.72.0/24"}})
				} else {
					result := checkRoute(group, routeCheckRequest{Target: "192.168.72.60"})
					if result.Error != "" {
						t.Error(result.Error)
					}
				}
			}
		}(i)
	}
	workers.Wait()
	group.closed = true
	if result := checkRoute(group, routeCheckRequest{Target: "example.test"}); result.Error == "" {
		t.Fatal("closed session accepted")
	}
}

func TestRouteCheckerDNSUsesOnlySpecifiedServerAndValidatesAnswers(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	var queries atomic.Int32
	var wrong atomic.Bool
	go func() {
		buffer := make([]byte, 4096)
		for {
			n, peer, err := server.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			var q dnsmessage.Message
			if q.Unpack(buffer[:n]) != nil || len(q.Questions) != 1 {
				continue
			}
			queries.Add(1)
			if q.Questions[0].Name.String() != "localhost." {
				wrong.Store(true)
			}
			q.Header.Response = true
			q.Answers = nil
			if q.Questions[0].Type == dnsmessage.TypeA {
				q.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: q.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: [4]byte{192, 168, 72, 60}}}}
			}
			raw, _ := q.Pack()
			server.WriteToUDP(raw, peer)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	addresses, err := lookupRouteDNS(ctx, "localhost", []string{server.LocalAddr().String()})
	if err != nil || len(addresses) != 1 || addresses[0].String() != "192.168.72.60" || queries.Load() != 2 || wrong.Load() {
		t.Fatal("resolver used host files, unrelated DNS or a business request", addresses, err, queries.Load())
	}
	bad, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer bad.Close()
	go func() {
		buffer := make([]byte, 4096)
		n, peer, e := bad.ReadFromUDP(buffer)
		if e != nil {
			return
		}
		var q dnsmessage.Message
		q.Unpack(buffer[:n])
		q.Header.Response = true
		q.Header.ID++
		raw, _ := q.Pack()
		bad.WriteToUDP(raw, peer)
	}()
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: 12}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("example.test."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	if _, err := queryRouteDNS(ctx, query, bad.LocalAddr().String()); err == nil {
		t.Fatal("wrong DNS response ID accepted")
	}
}

func TestRouteCheckerDNSCancellationDoesNotWaitForNetworkTimeout(t *testing.T) {
	blackhole, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer blackhole.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := lookupRouteDNS(ctx, "example.test", []string{blackhole.LocalAddr().String()})
		done <- err
	}()
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled DNS unexpectedly succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("VPN stop could not cancel checker DNS")
	}
}
