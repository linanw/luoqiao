package multinet

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

var errRecordedDial = errors.New("recorded selected-network dial")

type namingClient struct {
	status           *ipnstate.Status
	mu               sync.Mutex
	address, network string
}

func (c *namingClient) Status(context.Context) (*ipnstate.Status, error) { return c.status, nil }
func (*namingClient) SetExitNode(context.Context, string) error          { return nil }
func (*namingClient) NetworkChanged()                                    {}
func (*namingClient) Close() error                                       { return nil }
func (c *namingClient) DialTunnel(_ context.Context, network, address string) (net.Conn, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.address, c.network = address, network
	return nil, errRecordedDial
}

func TestShortMagicDNSUsesReportedDNSNameAndSelectedNetwork(t *testing.T) {
	p := Profile{ID: "aaaaaaaa", Name: "A"}
	policy, err := Compile(Config{Profiles: []Profile{p}})
	if err != nil {
		t.Fatal(err)
	}
	fake := &namingClient{status: &ipnstate.Status{
		BackendState: "Running", CurrentTailnet: &ipnstate.TailnetStatus{MagicDNSSuffix: "a.tail.test"},
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{{}: {HostName: "svc-subnet-72", DNSName: "SVC-SUBNET-72-1.A.TAIL.TEST.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.1")}}},
	}}
	ctx, cancel := context.WithCancel(context.Background())
	m := &Manager{ctx: ctx, cancel: cancel, policy: policy, config: Config{Profiles: []Profile{p}}, nodes: map[string]*node{"aaaaaaaa": {client: fake}}}
	m.wg.Add(1)
	go m.run(m.nodes[p.ID], p)
	defer m.Close()
	deadline := time.After(2 * time.Second)
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for len(m.Status()[0].PeerNames) == 0 {
		select {
		case <-deadline:
			t.Fatal("node did not report peer names")
		case <-tick.C:
		}
	}
	if got := m.Status()[0].PeerNames; len(got) != 1 || got[0] != "svc-subnet-72-1.a.tail.test" {
		t.Fatal("did not preserve canonical DNSName", got)
	}
	for _, name := range []string{"svc-subnet-72-1", "SVC-SUBNET-72-1.", "svc-subnet-72-1.a.tail.test."} {
		if m.Domain(name) != "aaaaaaaa" {
			t.Fatalf("no automatic owner for %s", name)
		}
	}
	for _, name := range []string{"svc-subnet-72", "prefix-svc-subnet-72-1", "svc-subnet-72-1.evil.test"} {
		if m.AutomaticDomain(name) != "" {
			t.Fatalf("invented alias for %s", name)
		}
	}
	if _, err := m.Dial(context.Background(), "aaaaaaaa", "tcp", "SVC-SUBNET-72-1.:5001"); !errors.Is(err, errRecordedDial) {
		t.Fatal(err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.address != "svc-subnet-72-1.a.tail.test:5001" || fake.network != "tcp" {
		t.Fatalf("wrong selected dial: %s %s", fake.network, fake.address)
	}
}

func TestShortMagicDNSCrossNetworkConflictAndExplicitOverride(t *testing.T) {
	profiles := []Profile{{ID: "aaaaaaaa"}, {ID: "bbbbbbbb", Domains: []string{"full:disk-station"}}}
	policy, err := Compile(Config{Profiles: profiles})
	if err != nil {
		t.Fatal(err)
	}
	a, b := &namingClient{}, &namingClient{}
	m := &Manager{policy: policy, config: Config{Profiles: profiles}, nodes: map[string]*node{
		"aaaaaaaa": {client: a, exitReady: true, status: NodeStatus{ID: "aaaaaaaa", BackendState: "Running", DNSSuffix: "a.tail.test", PeerNames: []string{"disk-station.a.tail.test"}}},
		"bbbbbbbb": {client: b, exitReady: true, status: NodeStatus{ID: "bbbbbbbb", BackendState: "Running", DNSSuffix: "b.tail.test", PeerNames: []string{"disk-station.b.tail.test"}}},
	}}
	if m.AutomaticDomain("disk-station") != "!ambiguous" {
		t.Fatal("duplicate short name did not fail closed")
	}
	if m.Domain("disk-station") != "bbbbbbbb" {
		t.Fatal("explicit selected network lost priority")
	}
	if _, err := m.Dial(context.Background(), "!ambiguous", "tcp", "disk-station:5001"); err == nil {
		t.Fatal("ambiguous owner dialed")
	}
	if _, err := m.Dial(context.Background(), m.Domain("disk-station"), "tcp", "disk-station:5001"); !errors.Is(err, errRecordedDial) {
		t.Fatal(err)
	}
	if b.address != "disk-station.b.tail.test:5001" || a.address != "" {
		t.Fatal("explicit rule dialed the wrong same-named peer")
	}
	// Fully-qualified names remain usable independently even when short names overlap.
	if m.AutomaticDomain("disk-station.a.tail.test") != "aaaaaaaa" || m.AutomaticDomain("disk-station.b.tail.test") != "bbbbbbbb" {
		t.Fatal("FQDN ownership became ambiguous")
	}
	for _, address := range []string{"disk-station.a.tail.test:5001", "other:443", "100.64.0.1:443", "[fd7a:115c:a1e0::1]:443"} {
		if got := canonicalPeerAddress(m.nodes["aaaaaaaa"].status, address); got != address {
			t.Fatalf("rewrote unrelated address %s", address)
		}
	}
	if shortPeerCanonical(NodeStatus{PeerNames: []string{"disk-station.a.tail.test"}}, "disk-station") != "" {
		t.Fatal("guessed a suffix when none is available")
	}
	if shortPeerCanonical(NodeStatus{DNSSuffix: "a.tail.test", PeerNames: []string{"disk-station.a.tail.test.evil"}}, "disk-station") != "" {
		t.Fatal("suffix boundary was ignored")
	}
}
