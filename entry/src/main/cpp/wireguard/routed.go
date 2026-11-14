package main

/*
#include <stddef.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"harmony/tailnet/multinet"
	"net"
	"net/netip"
	"strings"
	"sync"
	"unsafe"

	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// RoutedConfig is aligned by index with the supplied WireGuard UAPI configs.
// Addresses are inner interface addresses, not the system VPN's fake-DNS addresses.
type RoutedConfig struct {
	DNS               []string
	Profiles          []RoutedProfile
	Tailnets          multinet.Config
	SubnetPreferences []SubnetPreference
	LocalPrefixes     []string
}

type RoutedProfile struct {
	ID             string
	Addresses      []string
	DNS            []string
	Domains        []string
	Exacts         []string
	CIDRs          []string
	Default        bool
	RoutesFallback bool
}

type contextDialer interface {
	DialContext(context.Context, string, string) (net.Conn, error)
}

type tailnetRouter interface {
	PolicyDomain(string) (string, int)
	PolicyIP(netip.Addr) (string, int)
	AutomaticDomain(string) string
	AutomaticIP(netip.Addr) string
	Dial(context.Context, string, string, string) (net.Conn, error)
	NetworkChanged([]string) error
	Status() []multinet.NodeStatus
	Close()
}
type routedManager struct {
	tailnets          tailnetRouter
	config            RoutedConfig
	dialers           map[string]contextDialer
	direct            contextDialer
	exacts            map[string]string
	domains           map[string]string
	prefixes          *routeTable
	defaultOwner      string
	dnsMu             sync.RWMutex
	physicalDNS       []string
	networkMu         sync.Mutex
	localPrefixes     []netip.Prefix
	subnetPreferences []compiledSubnetPreference
}

func parseRoutedConfig(raw string, count int) (RoutedConfig, error) {
	var config RoutedConfig
	if len(raw) == 0 || len(raw) > 4*maxConfigSize {
		return config, errors.New("invalid routing document size")
	}
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return config, err
	}
	if count < 0 || count > maxTunnels || len(config.Profiles) != count || count+len(config.Tailnets.Profiles) == 0 || len(config.Tailnets.Profiles) > maxTunnels {
		return config, errors.New("routing profile count does not match devices")
	}
	seen := make(map[string]bool)
	defaults := 0
	for _, profile := range config.Profiles {
		if profile.ID == "" || profile.ID == "!ambiguous" || seen[profile.ID] || len(profile.ID) > 128 {
			return config, errors.New("invalid or duplicated routing profile ID")
		}
		seen[profile.ID] = true
		if len(profile.Addresses) == 0 || len(profile.Addresses) > 32 {
			return config, errors.New("routing profile requires an inner address")
		}
		for _, address := range profile.Addresses {
			ip, err := netip.ParseAddr(address)
			if err != nil || ip.IsUnspecified() || ip.IsMulticast() || ip.Zone() != "" {
				return config, errors.New("invalid inner address")
			}
		}
		if len(profile.DNS) > 32 || len(profile.Domains)+len(profile.Exacts) > 250000 || len(profile.CIDRs) > 10000 {
			return config, errors.New("routing profile exceeds limits")
		}
		for _, address := range profile.DNS {
			if _, err := netip.ParseAddr(address); err != nil {
				return config, errors.New("invalid tunnel DNS address")
			}
		}
		for _, domain := range append(append([]string{}, profile.Domains...), profile.Exacts...) {
			if !validRoutingDomain(domain) {
				return config, errors.New("invalid routing domain")
			}
		}
		for _, raw := range profile.CIDRs {
			if _, err := netip.ParsePrefix(raw); err != nil {
				return config, errors.New("invalid routing prefix")
			}
		}
		if profile.Default {
			defaults++
		}
	}
	if defaults > 1 {
		return config, errors.New("multiple default routing profiles")
	}
	if len(config.Tailnets.Profiles) > 0 {
		config.Tailnets.DNS = append([]string{}, config.DNS...)
		if _, err := multinet.Compile(config.Tailnets); err != nil {
			return config, errors.New("invalid tailnet routing configuration")
		}
	}
	if err := validatePhysicalDNS(config.DNS); err != nil {
		return config, err
	}
	if _, err := compileSubnetPreferences(config.SubnetPreferences); err != nil {
		return config, err
	}
	if _, err := parseLocalPrefixes(config.LocalPrefixes); err != nil {
		return config, err
	}
	return config, nil
}

func validatePhysicalDNS(addresses []string) error {
	if len(addresses) > 32 {
		return errors.New("too many physical-network DNS servers")
	}
	for _, address := range addresses {
		ip, err := netip.ParseAddr(address)
		if err != nil || ip.IsUnspecified() || ip.IsMulticast() || syntheticAddress(ip) {
			return errors.New("invalid physical-network DNS server")
		}
	}
	return nil
}

func validRoutingDomain(raw string) bool {
	domain := normalizeName(raw)
	if len(domain) == 0 || len(domain) > 253 || strings.ContainsAny(domain, ":/ \\@*\t\r\n") {
		return false
	}
	for _, label := range strings.Split(domain, ".") {
		if len(label) == 0 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return false
			}
		}
	}
	return true
}

func newRoutedManager(config RoutedConfig) *routedManager {
	m := &routedManager{config: config, physicalDNS: append([]string(nil), config.DNS...), dialers: map[string]contextDialer{}, direct: &net.Dialer{},
		exacts: map[string]string{}, domains: map[string]string{}, prefixes: newRouteTable()}
	m.localPrefixes, _ = parseLocalPrefixes(config.LocalPrefixes)
	m.subnetPreferences, _ = compileSubnetPreferences(config.SubnetPreferences)
	insert := func(entries map[string]string, name, id string) {
		name = normalizeName(name)
		if prior := entries[name]; prior != "" && prior != id {
			entries[name] = "!ambiguous"
		} else {
			entries[name] = id
		}
	}
	for index, profile := range config.Profiles {
		for _, name := range profile.Domains {
			insert(m.domains, name, profile.ID)
		}
		for _, name := range profile.Exacts {
			insert(m.exacts, name, profile.ID)
		}
		for _, prefix := range profile.CIDRs {
			p, err := netip.ParsePrefix(prefix)
			if err == nil {
				m.prefixes.insert(p.Masked(), index)
			}
		}
		if profile.Default {
			m.defaultOwner = profile.ID
		}
	}
	return m
}

func chooseRoute(owner string, score int, other string, otherScore int) (string, int) {
	if other == "" {
		return owner, score
	}
	if otherScore > score {
		return other, otherScore
	}
	if otherScore == score && owner != "" && owner != other {
		return "!ambiguous", score
	}
	return owner, score
}
func wgOwner(id string) string {
	if id == "" || id == "!ambiguous" {
		return id
	}
	return "wg:" + id
}
func (m *routedManager) Domain(name string) string {
	name = normalizeName(name)
	owner, score := "", -1
	if id := m.exacts[name]; id != "" {
		owner, score = wgOwner(id), 10000+len(name)
	}
	for suffix := name; suffix != ""; {
		if id := m.domains[suffix]; id != "" {
			owner, score = chooseRoute(owner, score, wgOwner(id), len(suffix))
		}
		_, next, found := strings.Cut(suffix, ".")
		if !found {
			break
		}
		suffix = next
	}
	if m.tailnets != nil {
		other, otherScore := m.tailnets.PolicyDomain(name)
		owner, score = chooseRoute(owner, score, other, otherScore)
	}
	if owner != "" {
		return owner
	}
	if m.tailnets != nil {
		if owner := m.tailnets.AutomaticDomain(name); owner != "" {
			return owner
		}
	}
	return wgOwner(m.defaultOwner)
}
func (m *routedManager) IP(ip netip.Addr) string {
	if owner, applies := m.subnetPreference(ip); applies {
		return owner
	}
	owner, score := "", -1
	fallback, fallbackScore := "", -1
	for _, p := range m.config.Profiles {
		for _, raw := range p.CIDRs {
			prefix, err := netip.ParsePrefix(raw)
			if err != nil || !prefix.Contains(ip) {
				continue
			}
			if p.RoutesFallback || prefix.Bits() == 0 {
				fallback, fallbackScore = chooseRoute(fallback, fallbackScore, wgOwner(p.ID), prefix.Bits())
				continue
			}
			owner, score = chooseRoute(owner, score, wgOwner(p.ID), prefix.Bits())
		}
	}
	if m.tailnets != nil {
		other, bits := m.tailnets.PolicyIP(ip)
		owner, score = chooseRoute(owner, score, other, bits)
	}
	if owner != "" {
		return owner
	}
	if m.tailnets != nil {
		if owner := m.tailnets.AutomaticIP(ip); owner != "" {
			return owner
		}
	}
	return fallback
}

func (m *routedManager) DNS() []string {
	m.dnsMu.RLock()
	defer m.dnsMu.RUnlock()
	return append([]string(nil), m.physicalDNS...)
}

func (m *routedManager) setDNS(addresses []string) error {
	m.networkMu.Lock()
	defer m.networkMu.Unlock()
	if m.tailnets != nil && len(addresses) == 0 {
		return errors.New("physical network DNS is unavailable")
	}
	if err := validatePhysicalDNS(addresses); err != nil {
		return err
	}
	m.dnsMu.Lock()
	m.physicalDNS = append([]string(nil), addresses...)
	m.dnsMu.Unlock()
	if m.tailnets != nil {
		return m.tailnets.NetworkChanged(addresses)
	}
	return nil
}

// Dial makes exactly one routing decision. A selected network failure must not
// disclose the flow to the physical connection by trying the direct dialer.
func (m *routedManager) Dial(ctx context.Context, owner, network, address string) (net.Conn, error) {
	if strings.HasPrefix(owner, "!") {
		return nil, errors.New("selected network is ambiguous or unavailable")
	}
	if owner == "" {
		return m.direct.DialContext(ctx, network, address)
	}
	if !strings.HasPrefix(owner, "wg:") && m.tailnets != nil {
		return m.tailnets.Dial(ctx, owner, network, address)
	}
	dialer := m.dialers[strings.TrimPrefix(owner, "wg:")]
	if dialer == nil {
		return nil, errors.New("selected WireGuard network is unavailable")
	}
	return dialer.DialContext(ctx, network, address)
}

func tunnelAddresses(profile RoutedProfile) ([]netip.Addr, []netip.Addr) {
	addresses := make([]netip.Addr, 0, len(profile.Addresses))
	v4, v6 := false, false
	for _, raw := range profile.Addresses {
		ip := netip.MustParseAddr(raw).Unmap()
		addresses = append(addresses, ip)
		v4 = v4 || ip.Is4()
		v6 = v6 || ip.Is6()
	}
	dns := make([]netip.Addr, 0, len(profile.DNS))
	for _, raw := range profile.DNS {
		ip := netip.MustParseAddr(raw).Unmap()
		if ip.Is4() && v4 || ip.Is6() && v6 {
			dns = append(dns, ip)
		}
	}
	// These queries are sent through this WireGuard device, never net.DefaultResolver.
	if len(dns) == 0 {
		if v4 {
			dns = append(dns, netip.MustParseAddr("1.1.1.1"))
		} else if v6 {
			dns = append(dns, netip.MustParseAddr("2606:4700:4700::1111"))
		}
	}
	return addresses, dns
}

func startRoutedTunnels(tunFD, mtu int, udpFds []int, confs []string, config RoutedConfig) (*tunnelGroup, int) {
	if len(udpFds) != len(confs) || len(confs)+len(config.Tailnets.Profiles) == 0 || len(confs) > maxTunnels || len(config.Profiles) != len(confs) {
		return nil, -1
	}
	manager := newRoutedManager(config)
	group := &tunnelGroup{routed: manager}
	if len(config.Tailnets.Profiles) > 0 {
		config.Tailnets.DNS = append([]string{}, config.DNS...)
		var err error
		manager.tailnets, err = multinet.New(config.Tailnets)
		if err != nil {
			return nil, -7
		}
	}
	binds := make([]*protectedBind, 0, len(confs))
	fail := func(code int) (*tunnelGroup, int) {
		group.close()
		for _, bind := range binds {
			bind.dispose()
		}
		return nil, code
	}
	for index, conf := range confs {
		bind, err := newProtectedBind(udpFds[index])
		if err != nil {
			return fail(-2)
		}
		binds = append(binds, bind)
		group.binds = append(group.binds, bind)
		group.peerKeys = append(group.peerKeys, configuredPeerKeys(conf))
		addresses, dns := tunnelAddresses(config.Profiles[index])
		virtual, network, err := netstack.CreateNetTUN(addresses, dns, mtu)
		if err != nil {
			return fail(-3)
		}
		dev := device.NewDevice(virtual, bind, device.NewLogger(device.LogLevelSilent, ""))
		group.devices = append(group.devices, dev)
		if err := dev.IpcSet(conf); err != nil {
			return fail(-4)
		}
		manager.dialers[config.Profiles[index].ID] = network
	}
	for _, dev := range group.devices {
		if err := dev.Up(); err != nil {
			return fail(-5)
		}
	}
	gateway, err := NewGateway(manager)
	if err != nil {
		return fail(-6)
	}
	group.gateway = gateway
	if err := gateway.Tun.Attach(tunFD); err != nil {
		return fail(-3)
	}
	return group, 0
}

//export wg_start_routed
func wg_start_routed(tunFD, mtu C.int, udpFds *C.int, confs **C.char, count C.int, routing *C.char) C.int {
	if tunFD < 0 || mtu < 1280 || mtu > 9000 || (count > 0 && (udpFds == nil || confs == nil)) || routing == nil || count < 0 || count > maxTunnels {
		return -1
	}
	config, err := parseRoutedConfig(C.GoString(routing), int(count))
	if err != nil {
		return -7
	}
	fds := unsafe.Slice((*C.int)(unsafe.Pointer(udpFds)), int(count))
	rawConfs := unsafe.Slice(confs, int(count))
	parsedFds := make([]int, int(count))
	parsedConfs := make([]string, int(count))
	for index := range parsedFds {
		if fds[index] < 0 || fds[index] == tunFD || rawConfs[index] == nil {
			return -1
		}
		parsedFds[index] = int(fds[index])
		parsedConfs[index] = C.GoString(rawConfs[index])
		if len(parsedConfs[index]) == 0 || len(parsedConfs[index]) > maxConfigSize {
			return -1
		}
	}
	group, result := startRoutedTunnels(int(tunFD), int(mtu), parsedFds, parsedConfs, config)
	if result != 0 {
		return C.int(result)
	}
	return C.int(registerGroup(group))
}

//export wg_route_counts
func wg_route_counts(handle C.int, selectedDNS, selectedFlows, directFlows *C.double) {
	if selectedDNS != nil {
		*selectedDNS = 0
	}
	if selectedFlows != nil {
		*selectedFlows = 0
	}
	if directFlows != nil {
		*directFlows = 0
	}
	groups.Lock()
	group := groups.entries[int32(handle)]
	groups.Unlock()
	if group == nil || group.gateway == nil {
		return
	}
	if selectedDNS != nil {
		*selectedDNS = C.double(group.gateway.selectedDNS.Load())
	}
	if selectedFlows != nil {
		*selectedFlows = C.double(group.gateway.selectedFlows.Load())
	}
	if directFlows != nil {
		*directFlows = C.double(group.gateway.directFlows.Load())
	}
}

//export wg_set_route_dns
func wg_set_route_dns(handle C.int, dnsJSON *C.char) C.int {
	if dnsJSON == nil {
		return -1
	}
	raw := C.GoString(dnsJSON)
	if len(raw) == 0 || len(raw) > 4096 {
		return -1
	}
	var addresses []string
	if err := json.Unmarshal([]byte(raw), &addresses); err != nil || addresses == nil {
		return -1
	}
	groups.Lock()
	group := groups.entries[int32(handle)]
	groups.Unlock()
	if group == nil || group.gateway == nil {
		return -1
	}
	if group.setRouteDNS(addresses) != nil {
		return -1
	}
	return 0
}

func (group *tunnelGroup) setRouteDNS(addresses []string) error {
	manager, ok := group.gateway.manager.(*routedManager)
	if !ok {
		return errors.New("routed gateway unavailable")
	}
	if err := manager.setDNS(addresses); err != nil {
		return err
	}
	group.gateway.ResetDirectFlows()
	return nil
}

//export wg_detail_status
func wg_detail_status(handle C.int) *C.char {
	return C.CString(groupDetailJSON(int32(handle)))
}

//export wg_free_string
func wg_free_string(value *C.char) { C.free(unsafe.Pointer(value)) }

type wireGuardDetail struct {
	ID                                      string
	SentBytes, ReceivedBytes, LastHandshake uint64
	Running                                 bool
}
type groupDetails struct {
	FlowError   string
	RouteEvents []RouteEvent
	Rebinds     uint64
	LastRebind  int64
	WireGuard   []wireGuardDetail
	Tailnets    []multinet.NodeStatus
}

func groupDetailJSON(handle int32) string {
	details := groupDetails{RouteEvents: []RouteEvent{}, WireGuard: []wireGuardDetail{}, Tailnets: []multinet.NodeStatus{}}
	groups.Lock()
	group := groups.entries[handle]
	groups.Unlock()
	if group != nil {
		group.transportMu.Lock()
		details.Rebinds, details.LastRebind = group.rebinds, group.lastRebind
		group.transportMu.Unlock()
		if group.gateway != nil {
			details.FlowError = group.gateway.FlowError()
			details.RouteEvents = group.gateway.RouteEvents()
		}
		for i, dev := range group.devices {
			s := wireGuardDetail{Running: true}
			if group.routed != nil && i < len(group.routed.config.Profiles) {
				s.ID = group.routed.config.Profiles[i].ID
			}
			select {
			case <-dev.Wait():
				s.Running = false
			default:
			}
			var stats tunnelStats
			if err := dev.IpcGetOperation(&stats); err != nil {
				s.Running = false
			}
			s.SentBytes, s.ReceivedBytes, s.LastHandshake = stats.sent, stats.received, stats.handshake
			details.WireGuard = append(details.WireGuard, s)
		}
		if group.routed != nil && group.routed.tailnets != nil {
			details.Tailnets = group.routed.tailnets.Status()
		}
	}
	raw, _ := json.Marshal(details)
	return string(raw)
}
