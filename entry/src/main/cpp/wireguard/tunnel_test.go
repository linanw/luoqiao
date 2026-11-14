package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net/netip"
	"testing"

	"golang.org/x/sys/unix"
)

func TestWireGuardRoundTrip(t *testing.T) {
	for _, outer := range []string{"127.0.0.1", "::1"} {
		t.Run(outer, func(t *testing.T) {
			testWireGuardRoundTrip(t, netip.MustParseAddr(outer))
		})
	}
}

func testWireGuardRoundTrip(t *testing.T, outer netip.Addr) {
	a, aPort, closeA := testSocket(t)
	b, bPort, closeB := testSocket(t)
	aTun := testTunPair(t)
	bTun := testTunPair(t)
	aKey, bKey := testKey(t), testKey(t)
	aIP, bIP := [4]byte{10, 0, 0, 1}, [4]byte{10, 0, 0, 2}

	config := func(local, peer *ecdh.PrivateKey, port uint16, dst [4]byte) string {
		return fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=%s\nallowed_ip=%s/32\n",
			local.Bytes(), peer.PublicKey().Bytes(), netip.AddrPortFrom(outer, port), netip.AddrFrom4(dst))
	}
	aGroup, result := startTunnels(aTun[0], 1420, []int{a}, []string{config(aKey, bKey, bPort, bIP)})
	if result != 0 {
		t.Fatalf("start first tunnel returned %d", result)
	}
	t.Cleanup(aGroup.close)
	bGroup, result := startTunnels(bTun[0], 1420, []int{b}, []string{config(bKey, aKey, aPort, aIP)})
	if result != 0 {
		t.Fatalf("start second tunnel returned %d", result)
	}
	t.Cleanup(bGroup.close)
	closeA()
	closeB()

	testPacket(t, aTun[1], bTun[1], aIP, bIP)
	testPacket(t, bTun[1], aTun[1], bIP, aIP)
	var stats tunnelStats
	if err := aGroup.devices[0].IpcGetOperation(&stats); err != nil {
		t.Fatal(err)
	}
	if stats.sent == 0 || stats.received == 0 || stats.handshake == 0 {
		t.Fatalf("missing statistics after bidirectional traffic: %+v", stats)
	}
}

// TestSharedTunDispatch starts two devices on one TUN descriptor and verifies
// each device claims its own allowed-ip prefixes in the shared table.
func TestSharedTunDispatch(t *testing.T) {
	a, aPort, closeA := testSocket(t)
	b, bPort, closeB := testSocket(t)
	shared := testTunPair(t)
	aKey, bKey := testKey(t), testKey(t)

	aConf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=10.1.0.0/24\n",
		aKey.Bytes(), bKey.PublicKey().Bytes(), bPort)
	bConf := fmt.Sprintf("private_key=%x\nreplace_peers=true\npublic_key=%x\nendpoint=127.0.0.1:%d\nallowed_ip=10.2.0.0/24\n",
		bKey.Bytes(), aKey.PublicKey().Bytes(), aPort)
	group, result := startTunnels(shared[0], 1420, []int{a, b}, []string{aConf, bConf})
	if result != 0 {
		t.Fatalf("startTunnels returned %d", result)
	}
	t.Cleanup(group.close)
	closeA()
	closeB()

	if owner := group.table.lookup(netip.MustParseAddr("10.1.0.7")); owner != 0 {
		t.Fatalf("first device should claim 10.1.0.7, owner %d", owner)
	}
	if owner := group.table.lookup(netip.MustParseAddr("10.2.0.7")); owner != 1 {
		t.Fatalf("second device should claim 10.2.0.7, owner %d", owner)
	}
	if owner := group.table.lookup(netip.MustParseAddr("10.3.0.7")); owner != -1 {
		t.Fatalf("unclaimed destination should have no owner, got %d", owner)
	}
}

func TestRouteTable(t *testing.T) {
	table := newRouteTable()

	mustInsert := func(prefix string, owner int) {
		t.Helper()
		if !table.insert(netip.MustParsePrefix(prefix), owner) {
			t.Fatalf("insert %s for %d failed", prefix, owner)
		}
	}
	mustInsert("10.0.0.0/8", 0)
	mustInsert("10.1.0.0/16", 1)
	mustInsert("2001:db8::/32", 2)

	if table.insert(netip.MustParsePrefix("10.0.0.0/8"), 3) {
		t.Fatal("duplicate exact prefix must not be claimed twice")
	}
	if table.insert(netip.MustParsePrefix("10.0.0.0/8"), 0) {
		t.Fatal("re-insert by the same owner must also be rejected")
	}

	lookup := func(addr string) int {
		t.Helper()
		return table.lookup(netip.MustParseAddr(addr))
	}
	if owner := lookup("10.0.5.1"); owner != 0 {
		t.Fatalf("10.0.5.1 owner = %d, want 0", owner)
	}
	if owner := lookup("10.1.5.1"); owner != 1 {
		t.Fatalf("10.1.5.1 owner = %d, want 1", owner)
	}
	if owner := lookup("10.2.5.1"); owner != 0 {
		t.Fatalf("10.2.5.1 owner = %d, want 0", owner)
	}
	if owner := lookup("11.0.0.1"); owner != -1 {
		t.Fatalf("11.0.0.1 owner = %d, want -1", owner)
	}
	if owner := lookup("2001:db8::1"); owner != 2 {
		t.Fatalf("2001:db8::1 owner = %d, want 2", owner)
	}
	if owner := lookup("2001:db9::1"); owner != -1 {
		t.Fatalf("2001:db9::1 owner = %d, want -1", owner)
	}

	v4Mapped := netip.MustParseAddr("::ffff:10.1.5.1")
	if owner := table.lookup(v4Mapped); owner != 1 {
		t.Fatalf("v4-mapped lookup owner = %d, want 1", owner)
	}
}

func TestDestinationAddress(t *testing.T) {
	packet := make([]byte, 20)
	packet[0] = 0x45
	copy(packet[16:20], []byte{192, 0, 2, 9})
	dst, ok := destinationAddress(packet)
	if !ok || dst != netip.MustParseAddr("192.0.2.9") {
		t.Fatalf("v4 destination = %v, ok %v", dst, ok)
	}
	six := make([]byte, 40)
	six[0] = 0x60
	sixAddr := netip.MustParseAddr("2001:db8::5").As16()
	copy(six[24:40], sixAddr[:])
	dst, ok = destinationAddress(six)
	if !ok || dst != netip.MustParseAddr("2001:db8::5") {
		t.Fatalf("v6 destination = %v, ok %v", dst, ok)
	}
	if _, ok = destinationAddress([]byte{0x45, 0}); ok {
		t.Fatal("truncated v4 packet must be rejected")
	}
}

func testSocket(t *testing.T) (int, uint16, func()) {
	t.Helper()
	fd, err := openSocket(0)
	if err != nil {
		t.Fatal(err)
	}
	closeSocket := func() {
		if fd >= 0 {
			unix.Close(fd)
			fd = -1
		}
	}
	t.Cleanup(closeSocket)
	addr, err := unix.Getsockname(fd)
	if err != nil {
		t.Fatal(err)
	}
	switch addr := addr.(type) {
	case *unix.SockaddrInet4:
		return fd, uint16(addr.Port), closeSocket
	case *unix.SockaddrInet6:
		return fd, uint16(addr.Port), closeSocket
	default:
		t.Fatalf("unexpected UDP address: %T", addr)
		return 0, 0, nil
	}
}

func testTunPair(t *testing.T) [2]int {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		unix.Close(fds[0])
		unix.Close(fds[1])
	})
	return fds
}

func testKey(t *testing.T) *ecdh.PrivateKey {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func testPacket(t *testing.T, sender, receiver int, src, dst [4]byte) {
	t.Helper()
	payload := []byte("WireGuard integration test")
	packet := make([]byte, 20+len(payload))
	packet[0] = 0x45
	packet[8] = 64
	packet[9] = 253
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	copy(packet[12:16], src[:])
	copy(packet[16:20], dst[:])
	copy(packet[20:], payload)
	if n, err := unix.Write(sender, packet); err != nil || n != len(packet) {
		t.Fatalf("failed to send inner IP packet: wrote %d bytes, error %v", n, err)
	}
	fds := []unix.PollFd{{Fd: int32(receiver), Events: unix.POLLIN}}
	if n, err := unix.Poll(fds, 5000); err != nil || n != 1 || fds[0].Revents&unix.POLLIN == 0 {
		t.Fatalf("timed out waiting for the decrypted packet: events %#v, error %v", fds, err)
	}
	buf := make([]byte, 2048)
	n, err := unix.Read(receiver, buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf[:n], packet) {
		t.Fatalf("decrypted IP packet differs: got %x, want %x", buf[:n], packet)
	}
}
