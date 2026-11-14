package main

/*
#include <stddef.h>
*/
import "C"

import (
	"bufio"
	"bytes"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"golang.zx2c4.com/wireguard/device"
)

const (
	maxConfigSize = 1024 * 1024
	maxTunnels    = 16
)

// tunnelGroup bundles the WireGuard devices that share one system TUN. The
// router dispatches inner packets by destination through the shared route
// table where each device claims its allowed-ip prefixes.
type tunnelGroup struct {
	closeOnce   sync.Once
	transportMu sync.Mutex
	closed      bool
	binds       []*protectedBind
	peerKeys    []map[string]bool
	rebinds     uint64
	lastRebind  int64
	router      *tunRouter
	table       *routeTable
	devices     []*device.Device
	gateway     *Gateway
	routed      *routedManager
}

func (g *tunnelGroup) close() {
	g.closeOnce.Do(func() {
		g.transportMu.Lock()
		defer g.transportMu.Unlock()
		g.closed = true
		if g.gateway != nil {
			g.gateway.Close()
		}
		for _, dev := range g.devices {
			dev.Close()
		}
		for _, bind := range g.binds {
			bind.dispose()
		}
		if g.routed != nil && g.routed.tailnets != nil {
			g.routed.tailnets.Close()
		}
		if g.router != nil {
			g.router.close()
		}
	})
}

var groups = struct {
	sync.Mutex
	next    int32
	entries map[int32]*tunnelGroup
}{entries: make(map[int32]*tunnelGroup)}

//export wg_open_socket
func wg_open_socket(port C.int) C.int {
	if port < 0 || port > 65535 {
		return -1
	}
	fd, err := openSocket(int(port))
	if err != nil {
		return -1
	}
	return C.int(fd)
}

//export wg_start
func wg_start(tunFD, udpFD, mtu C.int, conf *C.char, size C.size_t) C.int {
	if tunFD < 0 || udpFD < 0 || tunFD == udpFD || mtu < 576 || mtu > 9000 ||
		conf == nil || size == 0 || size > maxConfigSize {
		return -1
	}
	config := C.GoStringN(conf, C.int(size))
	udpFds := []int{int(udpFD)}
	confs := []string{config}
	group, result := startTunnels(int(tunFD), int(mtu), udpFds, confs)
	if result != 0 {
		return C.int(result)
	}
	return C.int(registerGroup(group))
}

//export wg_start_many
func wg_start_many(tunFD, mtu C.int, udpFds *C.int, confs **C.char, count C.int) C.int {
	if tunFD < 0 || mtu < 576 || mtu > 9000 || udpFds == nil || confs == nil ||
		count <= 0 || count > maxTunnels {
		return -1
	}
	fds := unsafe.Slice((*int32)(unsafe.Pointer(udpFds)), int(count))
	rawConfs := unsafe.Slice(confs, int(count))
	parsedFds := make([]int, int(count))
	parsedConfs := make([]string, int(count))
	for index := 0; index < int(count); index++ {
		fd := int(fds[index])
		if fd < 0 || fd == int(tunFD) {
			return -1
		}
		config := C.GoString(rawConfs[index])
		if len(config) == 0 || len(config) > maxConfigSize {
			return -1
		}
		parsedFds[index] = fd
		parsedConfs[index] = config
	}
	group, result := startTunnels(int(tunFD), int(mtu), parsedFds, parsedConfs)
	if result != 0 {
		return C.int(result)
	}
	return C.int(registerGroup(group))
}

func registerGroup(group *tunnelGroup) int32 {
	groups.Lock()
	defer groups.Unlock()
	for {
		groups.next++
		if groups.next <= 0 {
			groups.next = 1
		}
		if _, exists := groups.entries[groups.next]; !exists {
			groups.entries[groups.next] = group
			return groups.next
		}
	}
}

// startTunnels builds one WireGuard device per configuration, all sharing the
// system TUN through the router and route table.
func startTunnels(tunFD, mtu int, udpFds []int, confs []string) (*tunnelGroup, int) {
	if len(udpFds) != len(confs) || len(confs) == 0 || len(confs) > maxTunnels {
		return nil, -1
	}
	table := newRouteTable()
	router, err := newTunRouter(tunFD, table)
	if err != nil {
		return nil, -3
	}
	group := &tunnelGroup{router: router, table: table}
	group.devices = make([]*device.Device, 0, len(confs))
	binds := make([]*protectedBind, 0, len(confs))
	targets := make([]chan []byte, 0, len(confs))
	fail := func(result int) (*tunnelGroup, int) {
		for _, dev := range group.devices {
			dev.Close()
		}
		for _, bind := range binds {
			bind.dispose()
		}
		router.close()
		return nil, result
	}
	for index, conf := range confs {
		bind, err := newProtectedBind(udpFds[index])
		if err != nil {
			return fail(-2)
		}
		binds = append(binds, bind)
		group.binds = append(group.binds, bind)
		group.peerKeys = append(group.peerKeys, configuredPeerKeys(conf))
		virtual := router.newTun(index, mtu)
		dev := device.NewDevice(virtual, bind, device.NewLogger(device.LogLevelSilent, ""))
		group.devices = append(group.devices, dev)
		if err := dev.IpcSet(conf); err != nil {
			return fail(-4)
		}
		claimRoutes(conf, table, index)
		targets = append(targets, virtual.packets)
	}
	for _, dev := range group.devices {
		if err := dev.Up(); err != nil {
			return fail(-5)
		}
	}
	router.start(targets)
	return group, 0
}

// claimRoutes inserts every allowed_ip prefix of a configuration into the
// shared table. Prefixes claimed by an earlier device win.
func claimRoutes(conf string, table *routeTable, owner int) {
	scanner := bufio.NewScanner(strings.NewReader(conf))
	for scanner.Scan() {
		key, value, found := strings.Cut(scanner.Text(), "=")
		if !found || key != "allowed_ip" {
			continue
		}
		prefix, err := netip.ParsePrefix(strings.TrimSpace(value))
		if err != nil {
			continue
		}
		table.insert(prefix, owner)
	}
}

//export wg_stop
func wg_stop(handle C.int) {
	groups.Lock()
	group := groups.entries[int32(handle)]
	delete(groups.entries, int32(handle))
	groups.Unlock()
	if group != nil {
		group.close()
	}
}

type tunnelStats struct {
	sent, received, handshake uint64
}

func (s *tunnelStats) Write(data []byte) (int, error) {
	// Ignore credential lines from the internal UAPI snapshot.
	scanner := bufio.NewScanner(bytes.NewReader(data))
	var seconds uint64
	for scanner.Scan() {
		key, value, found := strings.Cut(scanner.Text(), "=")
		if !found {
			continue
		}
		switch key {
		case "tx_bytes":
			n, _ := strconv.ParseUint(value, 10, 64)
			s.sent += n
		case "rx_bytes":
			n, _ := strconv.ParseUint(value, 10, 64)
			s.received += n
		case "last_handshake_time_sec":
			seconds, _ = strconv.ParseUint(value, 10, 64)
		case "last_handshake_time_nsec":
			nanos, _ := strconv.ParseUint(value, 10, 64)
			handshake := seconds*1000 + nanos/1_000_000
			if handshake > s.handshake {
				s.handshake = handshake
			}
		}
	}
	return len(data), scanner.Err()
}

//export wg_status
func wg_status(handle C.int, sent, received, handshake *C.double) C.int {
	groups.Lock()
	group := groups.entries[int32(handle)]
	groups.Unlock()
	if group == nil {
		return 0
	}
	if group.gateway != nil {
		readError, writeError := group.gateway.Tun.Errors()
		if readError != "" || writeError != "" {
			return 0
		}
	}
	var stats tunnelStats
	for _, dev := range group.devices {
		select {
		case <-dev.Wait():
			return 0
		default:
		}
		if err := dev.IpcGetOperation(&stats); err != nil {
			return 0
		}
	}
	*sent = C.double(stats.sent)
	*received = C.double(stats.received)
	*handshake = C.double(stats.handshake)
	return 1
}

func main() {}
