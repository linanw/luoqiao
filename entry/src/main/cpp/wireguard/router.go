package main

import (
	"net/netip"
	"sync"
)

// routeTable routes inner packets to the device claiming the destination
// address through the longest matching allowed-ip prefix. An exact prefix is
// claimed by the first device that inserts it; later inserts are ignored.
type routeTable struct {
	mu    sync.RWMutex
	roots [2]*routeNode // 0: IPv4, 1: IPv6
}

type routeNode struct {
	children [2]*routeNode
	owner    int // -1 marks an intermediate node
}

func newRouteTable() *routeTable {
	return &routeTable{roots: [2]*routeNode{{owner: -1}, {owner: -1}}}
}

func familyIndex(addr netip.Addr) int {
	if addr.Is4() {
		return 0
	}
	return 1
}

func addressBit(addr netip.Addr, index int) int {
	if addr.Is4() {
		octets := addr.As4()
		return int(octets[index/8] >> (7 - uint(index%8)) & 1)
	}
	groups := addr.As16()
	return int(groups[index/8] >> (7 - uint(index%8)) & 1)
}

// insert claims the prefix for the owner device. It reports false when the
// exact prefix was already claimed by another device.
func (t *routeTable) insert(prefix netip.Prefix, owner int) bool {
	addr := prefix.Addr().Unmap()
	bits := prefix.Bits()
	if addr.Is4() && bits >= 96 {
		bits -= 96
	}
	total := 32
	if !addr.Is4() {
		total = 128
	} else if bits > 32 {
		return false
	}
	if bits < 0 || bits > total || owner < 0 {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	node := t.roots[familyIndex(addr)]
	for index := 0; index < bits; index++ {
		bit := addressBit(addr, index)
		if node.children[bit] == nil {
			node.children[bit] = &routeNode{owner: -1}
		}
		node = node.children[bit]
	}
	if node.owner >= 0 {
		return false
	}
	node.owner = owner
	return true
}

// lookup returns the owner of the longest matching prefix, or -1.
func (t *routeTable) lookup(addr netip.Addr) int {
	owner, _ := t.lookupMatch(addr)
	return owner
}
func (t *routeTable) lookupMatch(addr netip.Addr) (int, string) {
	addr = addr.Unmap()
	total := 32
	if !addr.Is4() {
		total = 128
	}
	t.mu.RLock()
	defer t.mu.RUnlock()
	node := t.roots[familyIndex(addr)]
	owner := -1
	matchedBits := -1
	for index := 0; index <= total; index++ {
		if node.owner >= 0 {
			owner = node.owner
			matchedBits = index
		}
		if index == total {
			break
		}
		next := node.children[addressBit(addr, index)]
		if next == nil {
			break
		}
		node = next
	}
	if matchedBits < 0 {
		return owner, ""
	}
	return owner, netip.PrefixFrom(addr, matchedBits).Masked().String()
}

// destinationAddress extracts the destination IP of a raw IP packet.
func destinationAddress(packet []byte) (netip.Addr, bool) {
	if len(packet) < 1 {
		return netip.Addr{}, false
	}
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 {
			return netip.Addr{}, false
		}
		var address [4]byte
		copy(address[:], packet[16:20])
		return netip.AddrFrom4(address), true
	case 6:
		if len(packet) < 40 {
			return netip.Addr{}, false
		}
		var address [16]byte
		copy(address[:], packet[24:40])
		return netip.AddrFrom16(address), true
	}
	return netip.Addr{}, false
}
