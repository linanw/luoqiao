package main

/*
#include <stddef.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"net/netip"
	"regexp"
)

type SubnetPreference struct {
	CIDR      string
	Priority  string
	TailnetID string
}
type compiledSubnetPreference struct {
	SubnetPreference
	prefix netip.Prefix
}
type routedNetwork struct {
	DNS           []string
	LocalPrefixes []string
}

const unavailableSubnetOwner = "!unavailable"

var subnetTailnetID = regexp.MustCompile(`^(legacy|[a-fA-F0-9-]{8,64})$`)

func subnetPrefix(raw string) (netip.Prefix, error) {
	prefix, err := netip.ParsePrefix(raw)
	if err != nil || prefix.Bits() == 0 {
		return netip.Prefix{}, errors.New("invalid subnet prefix")
	}
	return prefix.Masked(), nil
}

func compileSubnetPreferences(preferences []SubnetPreference) ([]compiledSubnetPreference, error) {
	if len(preferences) > 128 {
		return nil, errors.New("too many subnet preferences")
	}
	seen := map[netip.Prefix]bool{}
	result := make([]compiledSubnetPreference, 0, len(preferences))
	for _, preference := range preferences {
		prefix, err := subnetPrefix(preference.CIDR)
		if err != nil || seen[prefix] {
			return nil, errors.New("invalid or duplicate subnet preference")
		}
		if preference.Priority != "local" && preference.Priority != "tailnet" {
			return nil, errors.New("invalid subnet priority")
		}
		if preference.TailnetID != "" && (preference.Priority != "tailnet" || !subnetTailnetID.MatchString(preference.TailnetID)) {
			return nil, errors.New("invalid preferred tailnet")
		}
		seen[prefix] = true
		preference.CIDR = prefix.String()
		result = append(result, compiledSubnetPreference{preference, prefix})
	}
	return result, nil
}

func parseLocalPrefixes(raw []string) ([]netip.Prefix, error) {
	if len(raw) > 256 {
		return nil, errors.New("too many physical network prefixes")
	}
	seen := map[netip.Prefix]bool{}
	result := make([]netip.Prefix, 0, len(raw))
	for _, value := range raw {
		prefix, err := subnetPrefix(value)
		if err != nil {
			return nil, errors.New("invalid physical network prefix")
		}
		if !seen[prefix] {
			seen[prefix] = true
			result = append(result, prefix)
		}
	}
	return result, nil
}

// A saved Tailnet preference reserves its overlapping LAN range even while its
// selected network is disabled, reconnecting, or no longer advertises the route.
// This prevents loss of the preferred route from silently disclosing data to LAN.
// With no on-link physical overlap, normal routing remains unchanged.
func (m *routedManager) subnetPreference(ip netip.Addr) (string, bool) {
	m.dnsMu.RLock()
	onLink := false
	for _, prefix := range m.localPrefixes {
		if prefix.Contains(ip) {
			onLink = true
			break
		}
	}
	m.dnsMu.RUnlock()
	if !onLink {
		return "", false
	}
	var selected *compiledSubnetPreference
	for i := range m.subnetPreferences {
		p := &m.subnetPreferences[i]
		if p.prefix.Contains(ip) && (selected == nil || p.prefix.Bits() > selected.prefix.Bits()) {
			selected = p
		}
	}
	if selected == nil {
		return "", false
	}
	owner, bits := "", -1
	if m.tailnets != nil {
		for _, status := range m.tailnets.Status() {
			if selected.TailnetID != "" && selected.TailnetID != status.ID {
				continue
			}
			for _, raw := range status.SubnetRoutes {
				prefix, err := subnetPrefix(raw)
				if err == nil && prefix.Contains(ip) {
					owner, bits = chooseRoute(owner, bits, status.ID, prefix.Bits())
				}
			}
		}
	}
	if selected.Priority == "local" {
		return "", owner != ""
	}
	if owner == "" {
		return unavailableSubnetOwner, true
	}
	return owner, true
}

func (m *routedManager) hasSubnetDNSPreferences() bool { return len(m.subnetPreferences) > 0 }

// Alias saved ranges before an overlap starts, too: an application may cache its
// cellular DNS response and then move onto a conflicting LAN without resolving.
func (m *routedManager) subnetDNSAddress(ip netip.Addr) bool {
	for _, p := range m.subnetPreferences {
		if p.prefix.Contains(ip) {
			return true
		}
	}
	return false
}

func (m *routedManager) setNetwork(network routedNetwork) error {
	m.networkMu.Lock()
	defer m.networkMu.Unlock()
	if m.tailnets != nil && len(network.DNS) == 0 {
		return errors.New("physical network DNS is unavailable")
	}
	if err := validatePhysicalDNS(network.DNS); err != nil {
		return err
	}
	prefixes, err := parseLocalPrefixes(network.LocalPrefixes)
	if err != nil {
		return err
	}
	m.dnsMu.Lock()
	m.physicalDNS = append([]string(nil), network.DNS...)
	m.localPrefixes = prefixes
	m.dnsMu.Unlock()
	if m.tailnets != nil {
		return m.tailnets.NetworkChanged(network.DNS)
	}
	return nil
}

func parseRoutedNetwork(raw string) (routedNetwork, error) {
	var network routedNetwork
	if len(raw) == 0 || len(raw) > 65536 {
		return network, errors.New("invalid physical network document")
	}
	if err := json.Unmarshal([]byte(raw), &network); err != nil || network.DNS == nil || network.LocalPrefixes == nil {
		return network, errors.New("invalid physical network document")
	}
	if err := validatePhysicalDNS(network.DNS); err != nil {
		return network, err
	}
	_, err := parseLocalPrefixes(network.LocalPrefixes)
	return network, err
}

func (group *tunnelGroup) setRouteNetwork(network routedNetwork) error {
	manager, ok := group.gateway.manager.(*routedManager)
	if !ok {
		return errors.New("routed gateway unavailable")
	}
	if err := manager.setNetwork(network); err != nil {
		return err
	}
	group.gateway.ResetDirectFlows()
	return nil
}

//export wg_set_route_network
func wg_set_route_network(handle C.int, networkJSON *C.char) C.int {
	if networkJSON == nil {
		return -1
	}
	network, err := parseRoutedNetwork(C.GoString(networkJSON))
	if err != nil {
		return -1
	}
	groups.Lock()
	group := groups.entries[int32(handle)]
	groups.Unlock()
	if group == nil || group.gateway == nil || group.setRouteNetwork(network) != nil {
		return -1
	}
	return 0
}
