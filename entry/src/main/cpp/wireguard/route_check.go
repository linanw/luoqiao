package main

/*
#include <stddef.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"harmony/tailnet/multinet"
	"net"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type routeCheckRequest struct {
	Target     string
	ResolveDNS bool
}
type routeDecision struct {
	Kind, Owner, NetworkID, NetworkName string
	ReasonCode, Reason, Rule            string
	DeviceIndex                         int
	RawIPMayBypassVPN, SyntheticDNS     bool
}
type routeAddress struct {
	IP       string
	Decision routeDecision
}
type routeDNS struct{ Status, Source, Error string }
type routeCheckResult struct {
	Input, Host, InputKind string
	Decision               routeDecision
	Addresses              []routeAddress
	DNS                    routeDNS
	Warnings               []string
	Error                  string
}
type routeCheckContext struct {
	group    *tunnelGroup
	manager  *routedManager
	statuses []multinet.NodeStatus
}

func normalizeCheckTarget(input string) (string, netip.Addr, error) {
	value := strings.TrimSpace(input)
	if len(value) == 0 || len(value) > 2048 || strings.ContainsAny(value, "\x00\r\n\t\\") {
		return "", netip.Addr{}, errors.New("请输入有效的域名或 IP 地址")
	}
	if strings.Contains(value, "://") {
		u, err := url.Parse(value)
		if err != nil || u.Scheme != "http" && u.Scheme != "https" || u.User != nil || u.Hostname() == "" {
			return "", netip.Addr{}, errors.New("仅支持域名、IP 或 HTTP/HTTPS 地址")
		}
		value = u.Hostname()
	} else if host, port, err := net.SplitHostPort(value); err == nil {
		if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
			return "", netip.Addr{}, errors.New("端口无效")
		}
		value = host
	} else if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
		value = value[1 : len(value)-1]
	}
	if ip, err := netip.ParseAddr(value); err == nil {
		if ip.Zone() != "" || ip.IsUnspecified() || ip.IsMulticast() {
			return "", netip.Addr{}, errors.New("请输入可路由的单个 IP 地址")
		}
		ip = ip.Unmap()
		return ip.String(), ip, nil
	}
	value = normalizeName(value)
	if !validRoutingDomain(value) {
		return "", netip.Addr{}, errors.New("请输入域名或 IP，不能包含路径或网段长度")
	}
	return value, netip.Addr{}, nil
}

func (c *routeCheckContext) decision(owner, code, rule, reason string) routeDecision {
	d := routeDecision{Owner: owner, ReasonCode: code, Reason: reason, Rule: rule, DeviceIndex: -1}
	switch {
	case owner == "":
		d.Kind = "direct"
		d.NetworkName = "正常网络"
	case owner == "!ambiguous":
		d.Kind = "ambiguous"
		d.Reason = "多个连接同样匹配，已阻止流量以避免选错网络"
	case owner == unavailableSubnetOwner:
		d.Kind = "unavailable"
		d.Reason = "指定的 Tailnet 没有可用子网路由，已阻止回退到本地网络"
	case strings.HasPrefix(owner, "!"):
		d.Kind = "unavailable"
	case strings.HasPrefix(owner, "wg:"):
		d.Kind, d.NetworkID = "wireguard", strings.TrimPrefix(owner, "wg:")
		d.NetworkName = d.NetworkID
		for i, profile := range c.manager.config.Profiles {
			if profile.ID == d.NetworkID {
				d.DeviceIndex = i
				break
			}
		}
		if c.manager.dialers[d.NetworkID] == nil {
			d.Kind = "unavailable"
			d.Reason += "；该 WireGuard 尚未就绪"
		}
		if d.DeviceIndex >= 0 && d.DeviceIndex < len(c.group.devices) && c.group.devices[d.DeviceIndex] != nil {
			select {
			case <-c.group.devices[d.DeviceIndex].Wait():
				d.Kind = "unavailable"
				d.Reason += "；该 WireGuard 已停止"
			default:
			}
		}
	default:
		d.Kind, d.NetworkID, d.NetworkName = "tailnet", owner, owner
		found := false
		for _, status := range c.statuses {
			if status.ID == owner {
				found = true
				if status.Name != "" {
					d.NetworkName = status.Name
				}
				if status.BackendState != "Running" || status.Error != "" {
					d.Kind = "unavailable"
					d.Reason += "；该 Tailnet 尚未就绪，禁止直连回退"
				}
				break
			}
		}
		if !found {
			d.Kind = "unavailable"
			d.Reason += "；该 Tailnet 未启用，禁止直连回退"
		}
	}
	if len(d.Rule) > 2048 {
		d.Rule = d.Rule[:2048]
	}
	return d
}

func chooseExplanation(owner string, score int, code, rule string, other string, otherScore int, otherCode, otherRule string) (string, int, string, string) {
	chosen, selectedScore := chooseRoute(owner, score, other, otherScore)
	if other != "" && otherScore > score {
		return chosen, selectedScore, otherCode, otherRule
	}
	if chosen == "!ambiguous" && owner != "!ambiguous" {
		return chosen, selectedScore, "ambiguous", rule + " / " + otherRule
	}
	return chosen, selectedScore, code, rule
}

func (c *routeCheckContext) domain(name string) routeDecision {
	m := c.manager
	owner, score, code, rule := "", -1, "", ""
	if id := m.exacts[name]; id != "" {
		owner, score, code, rule = wgOwner(id), 10000+len(name), "domain_exact", "full:"+name
	}
	for suffix := name; suffix != ""; {
		if id := m.domains[suffix]; id != "" {
			owner, score, code, rule = chooseExplanation(owner, score, code, rule, wgOwner(id), len(suffix), "domain_suffix", "domain:"+suffix)
		}
		_, next, found := strings.Cut(suffix, ".")
		if !found {
			break
		}
		suffix = next
	}
	if m.tailnets != nil {
		other, n := m.tailnets.PolicyDomain(name)
		description := "Tailnet 域名规则"
		if explainer, ok := m.tailnets.(interface{ DescribeDomain(string) string }); ok {
			description = explainer.DescribeDomain(name)
		}
		owner, score, code, rule = chooseExplanation(owner, score, code, rule, other, n, "tailnet_domain", description)
	}
	if owner != "" {
		return c.decision(owner, code, rule, "命中当前会话的域名规则")
	}
	if m.tailnets != nil {
		if owner := m.tailnets.AutomaticDomain(name); owner != "" {
			return c.decision(owner, "magic_dns", name, "命中 Tailnet 的 MagicDNS 名称")
		}
	}
	if m.defaultOwner != "" {
		return c.decision(wgOwner(m.defaultOwner), "default_wireguard", "默认 WireGuard", "由默认 WireGuard 接管域名；其域名归属优先于网段偏好")
	}
	d := c.decision("", "dns_required", "", "域名未指定连接，需要先解析地址，再逐 IP 判断")
	d.Kind = "dns_required"
	return d
}

func (c *routeCheckContext) ip(ip netip.Addr, synthetic bool) routeDecision {
	m := c.manager
	var d routeDecision
	if owner, applies := m.subnetPreference(ip); applies {
		var match *compiledSubnetPreference
		for i := range m.subnetPreferences {
			p := &m.subnetPreferences[i]
			if p.prefix.Contains(ip) && (match == nil || p.prefix.Bits() > match.prefix.Bits()) {
				match = p
			}
		}
		rule, reason := "", "命中当前物理网络的重叠网段偏好"
		if match != nil {
			rule = match.CIDR
			if match.Priority == "local" {
				reason += "：本地网络优先"
			} else {
				reason += "：Tailnet 优先"
			}
		}
		d = c.decision(owner, "subnet_preference", rule, reason)
	} else {
		owner, score, code, rule := "", -1, "", ""
		fallback, fallbackScore, fallbackCode, fallbackRule := "", -1, "", ""
		for _, profile := range m.config.Profiles {
			for _, raw := range profile.CIDRs {
				prefix, err := netip.ParsePrefix(raw)
				if err != nil || !prefix.Contains(ip) {
					continue
				}
				if profile.RoutesFallback || prefix.Bits() == 0 {
					fallback, fallbackScore, fallbackCode, fallbackRule = chooseExplanation(fallback, fallbackScore, fallbackCode, fallbackRule, wgOwner(profile.ID), prefix.Bits(), "wireguard_allowed_ips", prefix.Masked().String())
				} else {
					owner, score, code, rule = chooseExplanation(owner, score, code, rule, wgOwner(profile.ID), prefix.Bits(), "ip_rule", prefix.Masked().String())
				}
			}
		}
		if m.tailnets != nil {
			other, bits := m.tailnets.PolicyIP(ip)
			description := "Tailnet IP 规则"
			if explainer, ok := m.tailnets.(interface{ DescribeIP(netip.Addr) string }); ok {
				description = explainer.DescribeIP(ip)
			}
			owner, score, code, rule = chooseExplanation(owner, score, code, rule, other, bits, "ip_rule", description)
		}
		if owner != "" {
			d = c.decision(owner, code, rule, "命中当前会话的 IP 网段规则")
		} else {
			if m.tailnets != nil {
				owner = m.tailnets.AutomaticIP(ip)
			}
			if owner != "" {
				code, rule, score = "tailnet_subnet", "Tailnet 公布的子网", -1
				for _, s := range c.statuses {
					for _, raw := range append(append([]string{}, s.PeerIPs...), s.SubnetRoutes...) {
						p, err := netip.ParsePrefix(raw)
						kind := "tailnet_subnet"
						if err != nil {
							if addr, e := netip.ParseAddr(raw); e == nil {
								p = netip.PrefixFrom(addr, addr.BitLen())
								kind = "tailnet_peer"
							}
						}
						if p.IsValid() && p.Bits() > 0 && p.Contains(ip) && p.Bits() > score {
							score, code, rule = p.Bits(), kind, raw
						}
					}
				}
				d = c.decision(owner, code, rule, "命中 Tailnet 节点或其公布的子网，优先于 WireGuard 兜底路由")
			} else if fallback != "" {
				d = c.decision(fallback, fallbackCode, fallbackRule, "命中 WireGuard 配置的 AllowedIPs 兜底路由")
			} else {
				d = c.decision("", "direct", "", "未命中连接规则，使用正常网络")
			}
		}
	}
	d.SyntheticDNS = synthetic
	if !synthetic && d.Kind != "direct" {
		d.RawIPMayBypassVPN = ip.IsLoopback() || ip.IsLinkLocalUnicast()
		m.dnsMu.RLock()
		for _, local := range m.localPrefixes {
			if local.Contains(ip) {
				d.RawIPMayBypassVPN = true
				break
			}
		}
		m.dnsMu.RUnlock()
	}
	return d
}

func (c *routeCheckContext) address(ip netip.Addr) routeDecision {
	g := c.group.gateway
	g.mu.Lock()
	saved, exists := g.fake[ip]
	g.mu.Unlock()
	if exists {
		if saved.literal.IsValid() {
			d := c.ip(saved.literal, true)
			if d.Rule == "" {
				d.Rule = saved.literal.String()
			} else {
				d.Rule = saved.literal.String() + " → " + d.Rule
			}
			return d
		}
		d := c.decision(saved.owner, "synthetic_dns_domain", saved.host, "这是当前会话已分配的域名地址，保留该域名的连接归属")
		d.SyntheticDNS = true
		return d
	}
	if syntheticAddress(ip) {
		return c.decision("!expired", "expired_dns_alias", ip.String(), "该合成 DNS 地址不属于当前会话，请重新解析域名")
	}
	return c.ip(ip, false)
}

func lookupCurrentDNS(ctx context.Context, host string, servers []string) ([]netip.Addr, error) {
	if len(servers) == 0 {
		return nil, errors.New("当前物理网络没有可用 DNS")
	}
	endpoints := make([]string, len(servers))
	for i, server := range servers {
		endpoints[i] = net.JoinHostPort(server, "53")
	}
	return lookupRouteDNS(ctx, host, endpoints)
}

func checkRoute(group *tunnelGroup, request routeCheckRequest) routeCheckResult {
	result := routeCheckResult{Input: request.Target, Addresses: []routeAddress{}, Warnings: []string{}, DNS: routeDNS{Status: "not_needed"}, Decision: routeDecision{Kind: "unavailable", DeviceIndex: -1}}
	host, ip, err := normalizeCheckTarget(request.Target)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Host, result.InputKind = host, "domain"
	if ip.IsValid() {
		result.InputKind = "ip"
	}
	if group == nil {
		result.Error = "当前没有可检查的 VPN 会话"
		return result
	}
	group.transportMu.Lock()
	closed := group.closed
	group.transportMu.Unlock()
	if closed {
		result.Error = "当前 VPN 会话已经结束"
		return result
	}
	if group.routed == nil || group.gateway == nil {
		result.Decision = routeDecision{Kind: "unsupported", DeviceIndex: -1, ReasonCode: "raw_mode", Reason: "原配置模式不执行域名分流；请使用 IP 检查其 AllowedIPs"}
		if ip.IsValid() && group.table != nil {
			index, prefix := group.table.lookupMatch(ip)
			if index >= 0 {
				result.Decision = routeDecision{Kind: "wireguard", Owner: "wg:index:" + strconv.Itoa(index), NetworkID: "index:" + strconv.Itoa(index), NetworkName: "WireGuard " + strconv.Itoa(index+1), DeviceIndex: index, ReasonCode: "raw_allowed_ips", Reason: "原配置模式按 AllowedIPs 最长前缀选择该连接；相同前缀由先加入的连接持有", Rule: prefix}
				if index < len(group.devices) && group.devices[index] != nil {
					select {
					case <-group.devices[index].Wait():
						result.Decision.Kind = "unavailable"
						result.Decision.Reason += "；该 WireGuard 已停止"
					default:
					}
				}
			} else {
				result.Decision.Reason = "当前 WireGuard AllowedIPs 未覆盖此 IP；是否直连取决于系统路由，无法在此模式确认"
			}
		}
		result.Warnings = append(result.Warnings, "原始 IP 还受系统路由优先级影响，此结果只解释 VPN 内部规则")
		return result
	}
	c := &routeCheckContext{group: group, manager: group.routed}
	if c.manager.tailnets != nil {
		c.statuses = c.manager.tailnets.Status()
	}
	if ip.IsValid() {
		result.Decision = c.address(ip)
	} else {
		result.Decision = c.domain(host)
		if result.Decision.Kind != "dns_required" {
			result.Decision.SyntheticDNS = result.Decision.Owner != "" && !strings.HasPrefix(result.Decision.Owner, "!")
			result.DNS.Source = "selected_network"
			result.Warnings = append(result.Warnings, "已按域名确定连接，不向物理网络额外查询该域名，也不检测业务连通性")
		} else if !request.ResolveDNS {
			result.DNS.Status = "skipped"
		} else {
			result.DNS.Source = "physical"
			ctx, cancel := context.WithTimeout(group.gateway.ctx, 5*time.Second)
			addresses, err := lookupCurrentDNS(ctx, host, c.manager.DNS())
			cancel()
			if err != nil {
				result.DNS.Status, result.DNS.Error = "failed", "当前网络 DNS 未能解析该域名，请检查网络或稍后重试"
			} else {
				result.DNS.Status = "resolved"
				seen := map[netip.Addr]bool{}
				for _, address := range addresses {
					address = address.Unmap()
					if seen[address] || len(result.Addresses) >= 64 {
						continue
					}
					seen[address] = true
					decision := c.ip(address, c.manager.subnetDNSAddress(address))
					result.Addresses = append(result.Addresses, routeAddress{IP: address.String(), Decision: decision})
				}
				if len(result.Addresses) > 0 {
					result.Decision = result.Addresses[0].Decision
					for _, address := range result.Addresses[1:] {
						if address.Decision.Owner != result.Decision.Owner || address.Decision.Kind != result.Decision.Kind {
							result.Decision = routeDecision{Kind: "dns_required", DeviceIndex: -1, ReasonCode: "per_address", Reason: "解析结果使用不同路径，请查看各 IP 的选路结果"}
							break
						}
					}
				}
			}
		}
	}
	if result.Decision.RawIPMayBypassVPN {
		result.Warnings = append(result.Warnings, "目标同时位于当前本地网段；原始 IP 可能先被系统送到本地网络，不能保证进入 VPN")
	}
	for _, address := range result.Addresses {
		if address.Decision.RawIPMayBypassVPN {
			result.Warnings = append(result.Warnings, "部分解析地址属于当前本地网段，真实 IP 可能被系统路由优先送到本地网络")
			break
		}
	}
	return result
}

func routeCheckJSON(handle int32, raw string) string {
	var request routeCheckRequest
	var result routeCheckResult
	if len(raw) == 0 || len(raw) > 8192 || json.Unmarshal([]byte(raw), &request) != nil {
		result = checkRoute(nil, routeCheckRequest{})
		result.Error = "路由检查请求格式无效"
	} else {
		groups.Lock()
		group := groups.entries[handle]
		groups.Unlock()
		result = checkRoute(group, request)
	}
	data, _ := json.Marshal(result)
	return string(data)
}

//export wg_check_route
func wg_check_route(handle C.int, requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(routeCheckJSON(int32(handle), ""))
	}
	return C.CString(routeCheckJSON(int32(handle), C.GoString(requestJSON)))
}
