package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func TestEndpointRefreshAcceptsOnlyKnownPublicKeysAndNumericEndpoints(t *testing.T) {
	key := strings.Repeat("ab", 32)
	known := map[string]bool{key: true}
	valid := "public_key=" + key + "\nendpoint=192.0.2.1:51820\n"
	for _, update := range []string{"", valid, "public_key=" + key + "\nendpoint=[2001:db8::1]:51820\n"} {
		if err := validateEndpointUpdate(update, known); err != nil {
			t.Fatal(err)
		}
	}
	for _, update := range []string{valid + valid, "private_key=" + key + "\n", "public_key=" + key + "\n", strings.Replace(valid, key, strings.Repeat("cd", 32), 1), strings.Replace(valid, "192.0.2.1", "vpn.example", 1), strings.Replace(valid, ":51820", ":0", 1), strings.Replace(valid, "192.0.2.1", "0.0.0.0", 1), valid + "replace_peers=true\n", valid + "allowed_ip=0.0.0.0/0\n", valid + "\x00"} {
		if validateEndpointUpdate(update, known) == nil {
			t.Fatal("unsafe endpoint update accepted")
		}
	}
}

func TestRebindPreservesEncryptedTCPAndSyntheticDNS(t *testing.T) {
	for _, routed := range []bool{false, true} {
		t.Run(fmt.Sprintf("routed=%t", routed), func(t *testing.T) {
			a, aPort, closeA := testSocket(t)
			b, bPort, closeB := testSocket(t)
			aKey, bKey := testKey(t), testKey(t)
			aIP, bIP := netip.MustParseAddr("192.0.2.2"), netip.MustParseAddr("10.44.0.1")
			serverTun, serverNet, err := netstack.CreateNetTUN([]netip.Addr{bIP}, nil, 1280)
			if err != nil {
				t.Fatal(err)
			}
			serverBind, err := newProtectedBind(b)
			if err != nil {
				t.Fatal(err)
			}
			server := device.NewDevice(serverTun, serverBind, device.NewLogger(device.LogLevelSilent, ""))
			serverConf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=%s/32\n", bKey.Bytes(), aKey.PublicKey().Bytes(), aPort, aIP)
			serverGroup := &tunnelGroup{devices: []*device.Device{server}, binds: []*protectedBind{serverBind}, peerKeys: []map[string]bool{configuredPeerKeys(serverConf)}}
			t.Cleanup(serverGroup.close)
			if err := server.IpcSet(serverConf); err != nil {
				t.Fatal(err)
			}
			if err := server.Up(); err != nil {
				t.Fatal(err)
			}
			closeB()
			listener, err := serverNet.ListenTCPAddrPort(netip.AddrPortFrom(bIP, 8080))
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			go echoListener(listener, "stable:")
			packets, err := serverNet.ListenUDPAddrPort(netip.AddrPortFrom(bIP, 8080))
			if err != nil {
				t.Fatal(err)
			}
			defer packets.Close()
			go func() {
				buf := make([]byte, 512)
				for {
					n, addr, err := packets.ReadFrom(buf)
					if err != nil {
						return
					}
					packets.WriteTo(append([]byte("stable:"), buf[:n]...), addr)
				}
			}()
			dns, err := serverNet.ListenUDPAddrPort(netip.AddrPortFrom(bIP, 53))
			if err != nil {
				t.Fatal(err)
			}
			defer dns.Close()
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
					if q.Questions[0].Type == dnsmessage.TypeA {
						q.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: q.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: bIP.As4()}}}
					}
					raw, _ := q.Pack()
					dns.WriteTo(raw, addr)
				}
			}()
			pair := testTunPair(t)
			clientConf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=%s/32\n", aKey.Bytes(), bKey.PublicKey().Bytes(), bPort, bIP)
			var group *tunnelGroup
			var result int
			if routed {
				group, result = startRoutedTunnels(pair[0], 1280, []int{a}, []string{clientConf}, RoutedConfig{Profiles: []RoutedProfile{{ID: "migration", Addresses: []string{aIP.String()}, DNS: []string{bIP.String()}, Domains: []string{"server.test"}, CIDRs: []string{bIP.String() + "/32"}}}})
			} else {
				group, result = startTunnels(pair[0], 1280, []int{a}, []string{clientConf})
			}
			if result != 0 {
				t.Fatalf("start %d", result)
			}
			t.Cleanup(group.close)
			closeA()
			host := newGatewayTestHost(t, pair[1])
			target := bIP
			if routed {
				target = host.resolve(t, "server.test", dnsmessage.TypeAAAA)
			}
			conn := host.dial(t, "tcp", target, 8080)
			defer conn.Close()
			checkOpen := func() {
				t.Helper()
				conn.SetDeadline(time.Now().Add(25 * time.Second))
				if _, err := conn.Write([]byte("hello")); err != nil {
					t.Fatal(err)
				}
				buf := make([]byte, len("stable:hello"))
				if _, err := io.ReadFull(conn, buf); err != nil {
					t.Fatal(err)
				}
				if string(buf) != "stable:hello" {
					t.Fatal(string(buf))
				}
			}
			checkOpen()
			oldClient := group.binds[0].active
			oldServer := serverBind.active
			// Invalid updates are rejected before disturbing the existing transport.
			unused, _, closeUnused := testSocket(t)
			if rebindGroup(group, []int{unused}, []string{"private_key=invalid\n"}) == nil {
				t.Fatal("credential mutation accepted")
			}
			closeUnused()
			checkOpen()
			// Both server endpoint and client source port change, like DNS and network migration.
			newServer, newServerPort, closeNewServer := testSocket(t)
			if err := rebindGroup(serverGroup, []int{newServer}, []string{""}); err != nil {
				t.Fatal(err)
			}
			closeNewServer()
			if routed {
				if err := group.setRouteDNS([]string{"192.168.72.1"}); err != nil {
					t.Fatal(err)
				}
			}
			newClient, _, closeNewClient := testSocket(t)
			update := fmt.Sprintf("public_key=%x\nendpoint=127.0.0.1:%d\n", bKey.PublicKey().Bytes(), newServerPort)
			if err := rebindGroup(group, []int{newClient}, []string{update}); err != nil {
				t.Fatal(err)
			}
			closeNewClient()
			checkOpen() // The same inner TCP connection must survive the outer socket swap.
			mixedExchange(t, host.dial(t, "udp", target, 8080), "stable:hello")
			if _, err := oldClient.WriteToUDPAddrPort([]byte{0}, netip.MustParseAddrPort("127.0.0.1:9")); err == nil {
				t.Fatal("old client socket leaked")
			}
			if _, err := oldServer.WriteToUDPAddrPort([]byte{0}, netip.MustParseAddrPort("127.0.0.1:9")); err == nil {
				t.Fatal("old server socket leaked")
			}
			if routed {
				if again := host.resolve(t, "server.test", dnsmessage.TypeAAAA); again != target {
					t.Fatal("migration invalidated synthetic DNS mapping")
				}
			}
			handle := registerGroup(group)
			defer func() { groups.Lock(); delete(groups.entries, handle); groups.Unlock() }()
			var details groupDetails
			if err := json.Unmarshal([]byte(groupDetailJSON(handle)), &details); err != nil {
				t.Fatal(err)
			}
			if details.Rebinds != 1 || details.LastRebind <= 0 {
				t.Fatal("missing transport migration diagnostics")
			}
			group.close()
			if err := rebindGroup(group, nil, nil); err == nil {
				t.Fatal("closed group rebound")
			}
		})
	}
}

func TestRebindRejectsBadDescriptorsWithoutReplacingOthers(t *testing.T) {
	a, _, closeA := testSocket(t)
	b, _, closeB := testSocket(t)
	defer closeA()
	defer closeB()
	group := &tunnelGroup{devices: []*device.Device{nil, nil}, binds: []*protectedBind{{}, {}}, peerKeys: []map[string]bool{{}, {}}}
	// Invalid input is rejected before dereferencing devices or adopting sockets.
	if err := rebindGroup(group, []int{a, b}, []string{"private_key=x\n", ""}); err == nil {
		t.Fatal("bad update accepted")
	}
	if _, err := unix.FcntlInt(uintptr(a), unix.F_GETFD, 0); err != nil {
		t.Fatal("caller descriptor closed")
	}
	closeA()
	if err := rebindGroup(group, []int{a, b}, []string{"", ""}); err == nil {
		t.Fatal("closed replacement descriptor accepted")
	}
	if _, err := unix.FcntlInt(uintptr(b), unix.F_GETFD, 0); err != nil {
		t.Fatal("unadopted caller descriptor closed")
	}
}

func TestRouteEventsBoundedSnapshot(t *testing.T) {
	g := &Gateway{}
	for i := 0; i < 20; i++ {
		g.recordRoute("legacy", fmt.Sprintf("192.168.72.%d", i), "tcp", i%2 == 0)
	}
	events := g.RouteEvents()
	if len(events) != 16 || events[0].Target != "192.168.72.4" || events[15].Time <= 0 || events[0].Owner != "legacy" {
		t.Fatal("invalid routing diagnostic")
	}
	events[0].Target = "modified"
	if g.RouteEvents()[0].Target == "modified" {
		t.Fatal("diagnostic snapshot aliases live state")
	}
}
