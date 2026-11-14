package multinet

import (
	"context"
	"harmony/tailnet"
	"net/netip"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestLegacyStateDirectoryKeepsExistingIdentity(t *testing.T) {
	dir := t.TempDir()
	for control, suffix := range map[string]string{"": "tailscale", "https://headscale.example:443/path?a=b": "https%3A%2F%2Fheadscale.example%3A443%2Fpath%3Fa%3Db", "https://headscale.example/a!()'*": "https%3A%2F%2Fheadscale.example%2Fa!()'*"} {
		if got := profileStateDir(dir, Profile{ID: "legacy", LegacyState: true, ControlURL: control}); got != filepath.Join(dir, "tailnet", suffix) {
			t.Fatalf("wrong legacy identity path: %s", got)
		}
	}
	if got := profileStateDir(dir, Profile{ID: "aaaaaaaa"}); got != filepath.Join(dir, "networks", "aaaaaaaa") {
		t.Fatal("changed independent profile identity")
	}
	if _, err := Compile(Config{Profiles: []Profile{{ID: "legacy", LegacyState: true}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := Compile(Config{Profiles: []Profile{{ID: "legacy"}}}); err == nil {
		t.Fatal("legacy path must require explicit opt-in")
	}
	if _, err := Compile(Config{Profiles: []Profile{{ID: "aaaaaaaa", LegacyState: true}}}); err == nil {
		t.Fatal("a normal profile must not reuse legacy identity")
	}
}

type migrationClient struct {
	namingClient
	changes atomic.Int32
}

func (c *migrationClient) NetworkChanged() { c.changes.Add(1) }

func TestPhysicalNetworkChangeKeepsOverlappingSubnetOwnership(t *testing.T) {
	profile := Profile{ID: "aaaaaaaa"}
	policy, err := Compile(Config{Profiles: []Profile{profile}})
	if err != nil {
		t.Fatal(err)
	}
	client := &migrationClient{}
	m := &Manager{policy: policy, config: Config{DNS: []string{"8.8.8.8"}, Profiles: []Profile{profile}}, nodes: map[string]*node{
		"aaaaaaaa": {client: client, status: NodeStatus{ID: "aaaaaaaa", SubnetRoutes: []string{"192.168.72.0/24"}, DNSSuffix: "a.tail.test", PeerNames: []string{"disk-station.a.tail.test"}}},
	}}
	for _, dns := range [][]string{{"192.168.72.1"}, {"192.168.72.1"}, {"8.8.8.8"}} {
		if err := m.NetworkChanged(dns); err != nil {
			t.Fatal(err)
		}
		if m.DNS()[0] != dns[0] || m.IP(netip.MustParseAddr("192.168.72.60")) != "aaaaaaaa" || m.Domain("disk-station") != "aaaaaaaa" {
			t.Fatal("underlay migration changed selected tailnet ownership")
		}
	}
	if client.changes.Load() != 3 {
		t.Fatal("same DNS on a different physical network suppressed migration")
	}
	if err := m.NetworkChanged([]string{"invalid"}); err == nil {
		t.Fatal("invalid DNS accepted")
	}
	if m.DNS()[0] != "8.8.8.8" || client.changes.Load() != 3 {
		t.Fatal("invalid update changed working transport state")
	}
}

func TestDiscoveredRoutesMagicDNSAndAmbiguity(t *testing.T) {
	p, err := Compile(Config{Profiles: []Profile{{ID: "aaaaaaaa", CIDRs: []string{"192.168.72.0/24"}}, {ID: "bbbbbbbb", CIDRs: []string{"10.0.0.0/8"}}}})
	if err != nil {
		t.Fatal(err)
	}
	m := &Manager{policy: p, config: Config{Profiles: []Profile{{ID: "aaaaaaaa"}, {ID: "bbbbbbbb"}}}, nodes: map[string]*node{
		"aaaaaaaa": {status: NodeStatus{ID: "aaaaaaaa", DNSSuffix: "a.tail.test", PeerIPs: []string{"100.64.0.1"}, SubnetRoutes: []string{"192.168.72.0/24", "172.16.0.0/16", "0.0.0.0/0"}}},
		"bbbbbbbb": {status: NodeStatus{ID: "bbbbbbbb", DNSSuffix: "b.tail.test", PeerIPs: []string{"100.64.0.1", "100.64.0.2"}, SubnetRoutes: []string{"172.16.0.0/16", "192.168.72.0/25"}}},
	}}
	for addr, want := range map[string]string{"100.64.0.1": "!ambiguous", "100.64.0.2": "bbbbbbbb", "172.16.1.1": "!ambiguous", "192.168.72.60": "bbbbbbbb", "192.168.72.200": "aaaaaaaa", "8.8.8.8": ""} {
		if got := m.AutomaticIP(netip.MustParseAddr(addr)); got != want {
			t.Fatalf("%s => %s want %s", addr, got, want)
		}
	}
	if m.IP(netip.MustParseAddr("192.168.72.60")) != "aaaaaaaa" {
		t.Fatal("explicit rule must override automatic routes")
	}
	if m.AutomaticDomain("HOST.A.TAIL.TEST.") != "aaaaaaaa" || m.AutomaticDomain("host.b.tail.test") != "bbbbbbbb" || m.AutomaticDomain("a.tail.test.evil") != "" {
		t.Fatal("MagicDNS suffix dispatch failed")
	}
	m.nodes["bbbbbbbb"].status.DNSSuffix = "a.tail.test"
	if m.AutomaticDomain("host.a.tail.test") != "!ambiguous" {
		t.Fatal("overlapping MagicDNS must fail closed")
	}
}

func TestDialRequiresSuccessfulExitConfiguration(t *testing.T) {
	n := &node{client: &tailnet.Client{}, status: NodeStatus{ID: "aaaaaaaa", BackendState: "Running"}}
	m := &Manager{nodes: map[string]*node{"aaaaaaaa": n}}
	// A non-nil client and Running backend are insufficient before SetExitNode succeeds.
	if _, err := m.Dial(context.Background(), "aaaaaaaa", "tcp", "1.1.1.1:443"); err == nil {
		t.Fatal("dialed before exit configuration")
	}
	n.exitReady = true
	n.status.Error = "exit configuration failed"
	if _, err := m.Dial(context.Background(), "aaaaaaaa", "tcp", "1.1.1.1:443"); err == nil {
		t.Fatal("dialed with failed exit configuration")
	}
}
