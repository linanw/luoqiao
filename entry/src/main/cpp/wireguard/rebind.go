package main

/*
#include <stddef.h>
*/
import "C"

import (
	"bufio"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.zx2c4.com/wireguard/device"
)

const maxEndpointUpdate = 128 * 1024

func configuredPeerKeys(config string) map[string]bool {
	keys := map[string]bool{}
	scan := bufio.NewScanner(strings.NewReader(config))
	for scan.Scan() {
		if key, value, ok := strings.Cut(scan.Text(), "="); ok && key == "public_key" {
			keys[strings.ToLower(value)] = true
		}
	}
	return keys
}

// Network migration may change only endpoints of already configured peers.
// Credentials, routes, and device options are never accepted through this API.
func validateEndpointUpdate(update string, known map[string]bool) error {
	if len(update) > maxEndpointUpdate || strings.ContainsRune(update, 0) {
		return errors.New("invalid endpoint update")
	}
	if update == "" {
		return nil
	}
	expectingKey := true
	seen := map[string]bool{}
	scan := bufio.NewScanner(strings.NewReader(update))
	for scan.Scan() {
		key, value, ok := strings.Cut(scan.Text(), "=")
		if !ok {
			return errors.New("invalid endpoint update")
		}
		if expectingKey {
			decoded, err := hex.DecodeString(value)
			canonical := strings.ToLower(value)
			if key != "public_key" || err != nil || len(decoded) != 32 || !known[canonical] || seen[canonical] {
				return errors.New("unknown or duplicate endpoint peer")
			}
			seen[canonical] = true
		} else {
			address, err := netip.ParseAddrPort(value)
			if key != "endpoint" || err != nil || address.Port() == 0 || address.Addr().IsUnspecified() || address.Addr().IsMulticast() {
				return errors.New("endpoint must be a numeric unicast address")
			}
		}
		expectingKey = !expectingKey
	}
	if scan.Err() != nil || !expectingKey || len(seen) == 0 {
		return errors.New("incomplete endpoint update")
	}
	return nil
}

func rebindGroup(group *tunnelGroup, fds []int, updates []string) error {
	group.transportMu.Lock()
	defer group.transportMu.Unlock()
	if group.closed || len(fds) != len(group.devices) || len(updates) != len(fds) || len(group.binds) != len(fds) || len(group.peerKeys) != len(fds) {
		return errors.New("invalid transport replacement")
	}
	prepared := make([]*net.UDPConn, len(fds))
	defer func() {
		for _, udp := range prepared {
			if udp != nil {
				udp.Close()
			}
		}
	}()
	seenFD := map[int]bool{}
	for index, fd := range fds {
		if fd < 0 || seenFD[fd] {
			return errors.New("invalid replacement socket")
		}
		seenFD[fd] = true
		if err := validateEndpointUpdate(updates[index], group.peerKeys[index]); err != nil {
			return err
		}
		udp, err := duplicateProtectedUDP(fd)
		if err != nil {
			return errors.New("replacement socket is unavailable")
		}
		prepared[index] = udp
		if udp.LocalAddr().(*net.UDPAddr).Port == 0 {
			return errors.New("replacement socket is unbound")
		}
		select {
		case <-group.devices[index].Wait():
			return errors.New("WireGuard device stopped")
		default:
		}
	}
	for index, dev := range group.devices {
		udp := prepared[index]
		port := udp.LocalAddr().(*net.UDPAddr).Port
		group.binds[index].queueReplacement(udp)
		prepared[index] = nil // The bind now owns this duplicate.
		// This makes WireGuard stop its old receiver, close the old descriptor,
		// and open the prepared replacement with the correct new source port.
		if err := dev.IpcSet("listen_port=" + strconv.Itoa(port) + "\n" + updates[index]); err != nil {
			group.binds[index].discardPrepared()
			return errors.New("WireGuard transport replacement failed")
		}
		// Re-establish NAT/peer endpoint state promptly; neither operation changes keys.
		dev.SendKeepalivesToPeersWithCurrentKeypair()
		for raw := range group.peerKeys[index] {
			var key device.NoisePublicKey
			if key.FromHex(raw) == nil {
				if peer := dev.LookupPeer(key); peer != nil {
					_ = peer.SendHandshakeInitiation(false)
				}
			}
		}
	}
	group.rebinds++
	group.lastRebind = time.Now().UnixMilli()
	return nil
}

//export wg_rebind_transport
func wg_rebind_transport(handle C.int, udpFds *C.int, updates **C.char, count C.int) C.int {
	if count < 0 || count > maxTunnels || count > 0 && (udpFds == nil || updates == nil) {
		return -1
	}
	groups.Lock()
	group := groups.entries[int32(handle)]
	groups.Unlock()
	if group == nil {
		return -1
	}
	rawFds := unsafe.Slice(udpFds, int(count))
	rawUpdates := unsafe.Slice(updates, int(count))
	fds := make([]int, int(count))
	parsed := make([]string, int(count))
	for i := range fds {
		if rawUpdates[i] == nil {
			return -1
		}
		fds[i] = int(rawFds[i])
		parsed[i] = C.GoString(rawUpdates[i])
		if len(parsed[i]) > maxEndpointUpdate {
			return -1
		}
	}
	if rebindGroup(group, fds, parsed) != nil {
		return -2
	}
	return 0
}
