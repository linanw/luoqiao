package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"harmony/tailnet/multinet"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

type subnetTestTailnets struct {
	*independentTailnets
	statuses []multinet.NodeStatus
	mu       sync.Mutex
	address  string
}

func (s *subnetTestTailnets) Status() []multinet.NodeStatus { return s.statuses }
func (s *subnetTestTailnets) AutomaticIP(ip netip.Addr) string {
	owner, bits := "", -1
	for _, status := range s.statuses {
		for _, raw := range status.SubnetRoutes {
			prefix := netip.MustParsePrefix(raw)
			if prefix.Contains(ip) {
				owner, bits = chooseRoute(owner, bits, status.ID, prefix.Bits())
			}
		}
	}
	return owner
}
func (s *subnetTestTailnets) Dial(ctx context.Context, owner, network, address string) (net.Conn, error) {
	s.mu.Lock()
	s.address = address
	s.mu.Unlock()
	return s.independentTailnets.Dial(ctx, owner, network, address)
}
func subnetTestManager(t *testing.T, preferences []SubnetPreference, local []string) (*routedManager, *subnetTestTailnets) {
	t.Helper()
	m := newRoutedManager(RoutedConfig{DNS: []string{"192.0.2.53"}, LocalPrefixes: local, SubnetPreferences: preferences})
	tn := &subnetTestTailnets{independentTailnets: newIndependentTailnets(t), statuses: []multinet.NodeStatus{
		{ID: "aaaaaaaa", BackendState: "Running", SubnetRoutes: []string{"192.168.72.0/24", "fd12:3456::/48"}},
	}}
	m.tailnets = tn
	return m, tn
}

func TestSubnetPreferenceOverlapSpecificityAndIsolation(t *testing.T) {
	m, _ := subnetTestManager(t, []SubnetPreference{
		{CIDR: "192.168.0.0/16", Priority: "local"},
		{CIDR: "192.168.72.128/25", Priority: "tailnet", TailnetID: "aaaaaaaa"},
		{CIDR: "fd12:3456::/48", Priority: "local"},
		{CIDR: "fd12:3456:0:1::/64", Priority: "tailnet"},
	}, []string{"192.168.72.61/24", "fd12:3456::123/48"})
	for address, want := range map[string]string{
		"192.168.72.60": "", "192.168.72.200": "aaaaaaaa", "192.168.73.60": "",
		"fd12:3456:0:2::1": "", "fd12:3456:0:1::1": "aaaaaaaa", "2001:db8::1": "",
	} {
		if got := m.IP(netip.MustParseAddr(address)); got != want {
			t.Fatalf("%s => %q, want %q", address, got, want)
		}
	}
	// Existing explicit domains and MagicDNS bypass IP preference decisions.
	if m.Domain("host.tailnet.test") != "aaaaaaaa" {
		t.Fatal("MagicDNS owner changed")
	}
	if err := m.setNetwork(routedNetwork{DNS: []string{"8.8.8.8"}, LocalPrefixes: []string{}}); err != nil {
		t.Fatal(err)
	}
	if m.IP(netip.MustParseAddr("192.168.72.60")) != "aaaaaaaa" || m.IP(netip.MustParseAddr("fd12:3456:0:2::1")) != "aaaaaaaa" {
		t.Fatal("LAN preference was applied without physical overlap")
	}
}

func TestSubnetTailnetPreferenceFailsClosedForMissingAmbiguousAndFailedOwners(t *testing.T) {
	for _, id := range []string{"", "aaaaaaaa", "cccccccc"} {
		t.Run("owner="+id, func(t *testing.T) {
			m, tn := subnetTestManager(t, []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "tailnet", TailnetID: id}}, []string{"192.168.72.0/24"})
			tn.statuses = append(tn.statuses, multinet.NodeStatus{ID: "bbbbbbbb", BackendState: "Running", SubnetRoutes: []string{"192.168.72.0/24"}})
			direct := &recordingDialer{err: errors.New("physical network must not run")}
			m.direct = direct
			owner := m.IP(netip.MustParseAddr("192.168.72.60"))
			want := map[string]string{"": "!ambiguous", "aaaaaaaa": "aaaaaaaa", "cccccccc": unavailableSubnetOwner}[id]
			if owner != want {
				t.Fatalf("owner %q, want %q", owner, want)
			}
			tn.fail.Store(true)
			if _, err := m.Dial(context.Background(), owner, "tcp", "192.168.72.60:443"); err == nil || direct.calls.Load() != 0 {
				t.Fatal("unavailable or ambiguous Tailnet leaked to LAN")
			}
			// The saved preference continues to reserve the LAN range if no
			// selected network is enabled or none currently advertises its route.
			m.tailnets = nil
			owner = m.IP(netip.MustParseAddr("192.168.72.60"))
			if owner != unavailableSubnetOwner {
				t.Fatalf("disabled Tailnet became %q", owner)
			}
			if _, err := m.Dial(context.Background(), owner, "tcp", "192.168.72.60:443"); err == nil || direct.calls.Load() != 0 {
				t.Fatal("disabled Tailnet leaked to LAN")
			}
		})
	}
	// A local preference does not override unrelated WG routing when no
	// Tailnet advertises that subnet at all.
	m := newRoutedManager(RoutedConfig{LocalPrefixes: []string{"192.168.72.0/24"}, SubnetPreferences: []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "local"}}, Profiles: []RoutedProfile{{ID: "wg", CIDRs: []string{"0.0.0.0/0"}, RoutesFallback: true}}})
	if got := m.IP(netip.MustParseAddr("192.168.72.60")); got != "wg:wg" {
		t.Fatal("local preference without a Tailnet subnet changed routing", got)
	}
}

func TestSubnetConfigurationValidationAndAtomicNetworkUpdates(t *testing.T) {
	for _, preferences := range [][]SubnetPreference{
		{{CIDR: "192.168.72.1/24", Priority: "local"}, {CIDR: "192.168.72.0/24", Priority: "tailnet"}},
		{{CIDR: "0.0.0.0/0", Priority: "local"}}, {{CIDR: "::/0", Priority: "tailnet"}},
		{{CIDR: "192.168.72.0", Priority: "tailnet"}}, {{CIDR: "192.168.72.0/24", Priority: "invalid"}},
		{{CIDR: "192.168.72.0/24", Priority: "local", TailnetID: "aaaaaaaa"}},
		{{CIDR: "192.168.72.0/24", Priority: "tailnet", TailnetID: "not-an-id"}},
	} {
		if _, err := compileSubnetPreferences(preferences); err == nil {
			t.Fatal("invalid subnet preferences accepted")
		}
		config := RoutedConfig{Profiles: []RoutedProfile{{ID: "wg", Addresses: []string{"10.1.1.2"}}}, SubnetPreferences: preferences}
		raw, _ := json.Marshal(config)
		if _, err := parseRoutedConfig(string(raw), 1); err == nil {
			t.Fatal("start validation ignored invalid subnet preferences")
		}
	}
	for _, raw := range []string{`{}`, `{"DNS":[],"LocalPrefixes":null}`, `{"DNS":null,"LocalPrefixes":[]}`, `{"DNS":["198.18.0.1"],"LocalPrefixes":[]}`, `{"DNS":["8.8.8.8"],"LocalPrefixes":["0.0.0.0/0"]}`} {
		if _, err := parseRoutedNetwork(raw); err == nil {
			t.Fatal("invalid network JSON accepted")
		}
	}
	m, tn := subnetTestManager(t, []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "local"}}, []string{"192.168.72.61/24", "192.168.72.0/24"})
	if len(m.localPrefixes) != 1 {
		t.Fatal("physical prefixes were not canonicalized and deduplicated")
	}
	if err := m.setNetwork(routedNetwork{DNS: []string{"8.8.8.8"}, LocalPrefixes: []string{"bad"}}); err == nil {
		t.Fatal("invalid update accepted")
	}
	if err := m.setNetwork(routedNetwork{DNS: []string{}, LocalPrefixes: []string{}}); err == nil {
		t.Fatal("empty DNS update accepted for active Tailnets")
	}
	if m.DNS()[0] != "192.0.2.53" || m.IP(netip.MustParseAddr("192.168.72.60")) != "" || tn.changed.Load() != 0 {
		t.Fatal("invalid network update partially applied")
	}
	if err := m.setDNS([]string{"9.9.9.9"}); err != nil || m.IP(netip.MustParseAddr("192.168.72.60")) != "" {
		t.Fatal("legacy DNS update discarded physical prefixes")
	}
	var workers sync.WaitGroup
	for i := 0; i < 4; i++ {
		workers.Add(1)
		go func(i int) {
			defer workers.Done()
			for j := 0; j < 200; j++ {
				if i%2 == 0 {
					m.setNetwork(routedNetwork{DNS: []string{"8.8.8.8"}, LocalPrefixes: []string{"192.168.72.0/24"}})
				} else {
					m.IP(netip.MustParseAddr("192.168.72.60"))
					m.DNS()
				}
			}
		}(i)
	}
	workers.Wait()
}

func subnetDNSFixture(t *testing.T, kind dnsmessage.Type, address string) (dnsmessage.Message, dnsmessage.Message) {
	t.Helper()
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: 123, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("home.example."), Type: kind, Class: dnsmessage.ClassINET}}}
	reply := query
	reply.Header.Response, reply.Header.AuthenticData = true, true
	reply.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: dnsmessage.TypeCNAME, Class: dnsmessage.ClassINET, TTL: 3600}, Body: &dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("nas.example.")}}}
	header := dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName("nas.example."), Type: kind, Class: dnsmessage.ClassINET, TTL: 3600}
	ip := netip.MustParseAddr(address)
	if kind == dnsmessage.TypeA {
		reply.Answers = append(reply.Answers, dnsmessage.Resource{Header: header, Body: &dnsmessage.AResource{A: ip.As4()}})
	} else {
		reply.Answers = append(reply.Answers, dnsmessage.Resource{Header: header, Body: &dnsmessage.AAAAResource{AAAA: ip.As16()}})
	}
	return query, reply
}

func subnetDNSFake(t *testing.T, g *Gateway, query, reply dnsmessage.Message) netip.Addr {
	t.Helper()
	raw, _ := reply.Pack()
	out, err := g.prepareSubnetDNSReply(raw, query)
	if err != nil {
		t.Fatal(err)
	}
	var got dnsmessage.Message
	if err := got.Unpack(out); err != nil {
		t.Fatal(err)
	}
	if got.Header.AuthenticData || got.Answers[1].Header.TTL != 60 {
		t.Fatal("synthetic answer retained DNSSEC authentication or excessive TTL")
	}
	switch body := got.Answers[1].Body.(type) {
	case *dnsmessage.AResource:
		return netip.AddrFrom4(body.A)
	case *dnsmessage.AAAAResource:
		return netip.AddrFrom16(body.AAAA)
	}
	t.Fatal("missing synthetic address")
	return netip.Addr{}
}

func TestSubnetDNSAliasesPreserveLiteralAndReevaluateCachedFlowsAcrossNetworks(t *testing.T) {
	for _, priority := range []string{"local", "tailnet"} {
		t.Run(priority, func(t *testing.T) {
			m, tn := subnetTestManager(t, []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: priority}}, nil)
			g, err := NewGateway(m)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(g.Close)
			query, reply := subnetDNSFixture(t, dnsmessage.TypeA, "192.168.72.60")
			fake := subnetDNSFake(t, g, query, reply)
			if !syntheticAddress(fake) || g.selectedDNS.Load() != 1 {
				t.Fatal("cellular DNS was not pre-aliased")
			}
			before, _ := g.target(fake)
			if before.host != "192.168.72.60" || before.owner != "aaaaaaaa" {
				t.Fatal("cellular alias did not use original IP policy", before)
			}
			if err := m.setNetwork(routedNetwork{DNS: []string{"192.168.72.1"}, LocalPrefixes: []string{"192.168.72.0/24"}}); err != nil {
				t.Fatal(err)
			}
			want := "aaaaaaaa"
			if priority == "local" {
				want = ""
			}
			after, _ := g.target(fake)
			if after.host != before.host || after.owner != want {
				t.Fatal("cached alias retained a stale network owner", after)
			}
			if priority == "tailnet" {
				app, _ := startForwardedTestFlow(t, g, fake, 5001, "tcp")
				checkForwardedEcho(t, app, "aaaaaaaa:tcp:hello")
				tn.mu.Lock()
				address := tn.address
				tn.mu.Unlock()
				if address != "192.168.72.60:5001" {
					t.Fatal("Tailnet was asked to resolve the public domain", address)
				}
				g.Close()
			}
			if again := subnetDNSFake(t, g, query, reply); again != fake {
				t.Fatal("cached literal alias changed within the VPN session")
			}
			m.setNetwork(routedNetwork{DNS: []string{"8.8.8.8"}, LocalPrefixes: []string{}})
			cellular, _ := g.target(fake)
			if cellular.owner != "aaaaaaaa" {
				t.Fatal("local preference leaked into cellular routing")
			}
		})
	}
}

func TestSubnetDNSIPv6AndExplicitDomainsKeepTheirOriginalOwners(t *testing.T) {
	m, _ := subnetTestManager(t, []SubnetPreference{{CIDR: "fd12:3456::/48", Priority: "local"}}, []string{"fd12:3456::/48"})
	g, _ := NewGateway(m)
	defer g.Close()
	query, reply := subnetDNSFixture(t, dnsmessage.TypeAAAA, "fd12:3456::60")
	fake := subnetDNSFake(t, g, query, reply)
	dst, _ := g.target(fake)
	if !fake.Is6() || !syntheticAddress(fake) || dst.host != "fd12:3456::60" || dst.owner != "" {
		t.Fatal("IPv6 subnet alias did not preserve address or local owner")
	}
	for _, owner := range []string{"wg:explicit", "aaaaaaaa"} {
		fixed, _ := g.allocate("selected.example", owner, true)
		dst, _ := g.target(fixed)
		if dst.host != "selected.example" || dst.owner != owner {
			t.Fatal("subnet preference overrode an explicitly selected domain")
		}
	}
	// A default WG already owns its domain DNS. Do not leak DNS to the physical
	// network to discover a LAN override; preserve that existing contract.
	defaultWG := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{{ID: "default", Default: true}}, SubnetPreferences: []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "local"}}})
	defaultGateway, _ := NewGateway(defaultWG)
	defer defaultGateway.Close()
	q, _ := subnetDNSFixture(t, dnsmessage.TypeA, "192.168.72.60")
	raw, _ := q.Pack()
	var answer dnsmessage.Message
	if err := answer.Unpack(defaultGateway.dns(raw)); err != nil || len(answer.Answers) != 1 {
		t.Fatal("default WG domain no longer receives its synthetic DNS answer")
	}
	address := netip.AddrFrom4(answer.Answers[0].Body.(*dnsmessage.AResource).A)
	owned, _ := defaultGateway.target(address)
	if owned.owner != "wg:default" || owned.host != "home.example" {
		t.Fatal("default WG DNS ownership changed", owned)
	}
}

func TestSubnetDNSChecksResponseIdentityAndCNAMEChain(t *testing.T) {
	m, _ := subnetTestManager(t, []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "tailnet"}}, nil)
	g, _ := NewGateway(m)
	defer g.Close()
	for name, mutate := range map[string]func(*dnsmessage.Message){
		"id":               func(r *dnsmessage.Message) { r.Header.ID++ },
		"response":         func(r *dnsmessage.Message) { r.Header.Response = false },
		"question-name":    func(r *dnsmessage.Message) { r.Questions[0].Name = dnsmessage.MustNewName("other.example.") },
		"question-type":    func(r *dnsmessage.Message) { r.Questions[0].Type = dnsmessage.TypeAAAA },
		"question-class":   func(r *dnsmessage.Message) { r.Questions[0].Class = dnsmessage.ClassCHAOS },
		"missing-question": func(r *dnsmessage.Message) { r.Questions = nil },
		"loop": func(r *dnsmessage.Message) {
			r.Answers = append(r.Answers[:1], dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName("nas.example."), Type: dnsmessage.TypeCNAME, Class: dnsmessage.ClassINET}, Body: &dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("home.example.")}})
		},
		"conflicting-cname": func(r *dnsmessage.Message) {
			r.Answers = append(r.Answers, dnsmessage.Resource{Header: r.Answers[0].Header, Body: &dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("other.example.")}})
		},
		"cname-and-address": func(r *dnsmessage.Message) { r.Answers[1].Header.Name = r.Questions[0].Name },
	} {
		t.Run(name, func(t *testing.T) {
			query, reply := subnetDNSFixture(t, dnsmessage.TypeA, "192.168.72.60")
			reply.Questions = append([]dnsmessage.Question{}, query.Questions...)
			mutate(&reply)
			raw, _ := reply.Pack()
			if _, err := g.prepareSubnetDNSReply(raw, query); err == nil {
				t.Fatal("invalid reply gained a synthetic subnet alias")
			}
		})
	}
	if len(g.fake) != 0 {
		t.Fatal("rejected reply allocated DNS state")
	}
}

func TestSubnetDNSRewritesOnlyRelatedAnswersAndRemovesBypassHints(t *testing.T) {
	m, _ := subnetTestManager(t, []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "tailnet"}}, nil)
	g, _ := NewGateway(m)
	defer g.Close()
	query, reply := subnetDNSFixture(t, dnsmessage.TypeA, "192.168.72.60")
	address := func(name, ip string) dnsmessage.Resource {
		return dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 300}, Body: &dnsmessage.AResource{A: netip.MustParseAddr(ip).As4()}}
	}
	reply.Answers = append(reply.Answers, address("nas.example.", "192.168.72.61"), address("nas.example.", "203.0.113.10"), address("unrelated.example.", "192.168.72.99"))
	reply.Additionals = []dnsmessage.Resource{address("nas.example.", "192.168.72.60"), address("other.example.", "192.168.72.98")}
	raw, _ := reply.Pack()
	out, err := g.prepareSubnetDNSReply(raw, query)
	if err != nil {
		t.Fatal(err)
	}
	var got dnsmessage.Message
	if err := got.Unpack(out); err != nil {
		t.Fatal(err)
	}
	if len(got.Answers) != 5 || len(got.Additionals) != 0 || got.Header.AuthenticData {
		t.Fatal("unexpected synthesized response shape")
	}
	for _, i := range []int{1, 2} {
		ip := netip.AddrFrom4(got.Answers[i].Body.(*dnsmessage.AResource).A)
		if !syntheticAddress(ip) {
			t.Fatal("related A record could bypass the VPN")
		}
	}
	if netip.AddrFrom4(got.Answers[3].Body.(*dnsmessage.AResource).A).String() != "203.0.113.10" || netip.AddrFrom4(got.Answers[4].Body.(*dnsmessage.AResource).A).String() != "192.168.72.99" || len(g.fake) != 2 || g.selectedDNS.Load() != 1 {
		t.Fatal("unrelated addresses acquired a subnet route, or per-query accounting was wrong")
	}
	// An unrelated record alone cannot trigger rewriting or change a valid
	// public answer, including its existing DNSSEC authentication flag.
	publicQuery, publicReply := subnetDNSFixture(t, dnsmessage.TypeA, "203.0.113.10")
	publicReply.Additionals = []dnsmessage.Resource{address("other.example.", "192.168.72.97")}
	publicRaw, _ := publicReply.Pack()
	unchanged, err := g.prepareSubnetDNSReply(publicRaw, publicQuery)
	if err != nil || !bytes.Equal(unchanged, publicRaw) || len(g.fake) != 2 {
		t.Fatal("unrelated Additional changed a public response")
	}
	for _, kind := range []dnsmessage.Type{64, 65} {
		q := query
		q.Questions = append([]dnsmessage.Question{}, query.Questions...)
		q.Questions[0].Type = kind
		q.Header.AuthenticData = true
		raw, _ := q.Pack()
		var answer dnsmessage.Message
		if err := answer.Unpack(g.dns(raw)); err != nil || answer.Header.RCode != dnsmessage.RCodeSuccess || answer.Header.AuthenticData || len(answer.Answers) != 0 {
			t.Fatal("saved subnet preferences did not suppress cached address hints")
		}
	}
	plain, _ := NewGateway(newRoutedManager(RoutedConfig{}))
	defer plain.Close()
	if plain.suppressSubnetDNSHints(65) {
		t.Fatal("HTTPS records were suppressed with no subnet preferences")
	}
}

type pausedSubnetTarget struct {
	*routedManager
	selected, resume chan struct{}
	calls            atomic.Int32
}

func (p *pausedSubnetTarget) IP(ip netip.Addr) string {
	owner := p.routedManager.IP(ip)
	if p.calls.Add(1) == 1 {
		close(p.selected)
		<-p.resume
	}
	return owner
}

func TestSubnetNetworkChangeBetweenTargetAndDirectRegistrationCannotLeakToLAN(t *testing.T) {
	// Cellular DNS has already cached a literal alias. With no active Tailnet,
	// the old non-overlapping physical network would use normal direct routing.
	m := newRoutedManager(RoutedConfig{SubnetPreferences: []SubnetPreference{{CIDR: "192.168.72.0/24", Priority: "tailnet"}}})
	direct := &recordingDialer{err: errors.New("must not dial LAN")}
	m.direct = direct
	paused := &pausedSubnetTarget{routedManager: m, selected: make(chan struct{}), resume: make(chan struct{})}
	g, err := NewGateway(paused)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(g.Close)
	real := netip.MustParseAddr("192.168.72.60")
	fake, err := g.allocateTarget(real.String(), "!subnet", false, destination{host: real.String(), literal: real})
	if err != nil {
		t.Fatal(err)
	}
	app, done := startForwardedTestFlow(t, g, fake, 443, "tcp")
	select {
	case <-paused.selected:
	case <-time.After(3 * time.Second):
		t.Fatal("flow never selected its old direct target")
	}
	// Complete the exact setRouteNetwork sequence while the flow has selected
	// direct but has not registered in Gateway.direct yet.
	if err := m.setNetwork(routedNetwork{DNS: []string{"192.168.72.1"}, LocalPrefixes: []string{"192.168.72.0/24"}}); err != nil {
		t.Fatal(err)
	}
	g.ResetDirectFlows()
	close(paused.resume)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("stale direct selection was not closed")
	}
	if direct.calls.Load() != 0 {
		t.Fatal("stale selection invoked the physical dialer after Tailnet became required")
	}
	if _, err := app.Write([]byte("private")); err == nil {
		t.Fatal("stale inner connection remained open")
	}
	events := g.RouteEvents()
	if len(events) != 1 || events[0].Owner != unavailableSubnetOwner || events[0].Success {
		t.Fatal("missing fail-closed route diagnostic", events)
	}
}
