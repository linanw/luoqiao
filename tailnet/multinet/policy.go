// Package multinet routes flows through independently authenticated tailnets.
package multinet

import (
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

type Profile struct {
	ID          string
	Name        string
	ControlURL  string
	Hostname    string
	ExitNodeIP  string
	LegacyState bool
	Domains     []string
	CIDRs       []string
	Lists       []string
}
type Config struct {
	Directory    string
	DatabasePath string
	DNS          []string
	Profiles     []Profile
}
type domainRule struct {
	value   string
	exact   bool
	keyword bool
	re      *regexp.Regexp
	owner   string
	source  string
}
type ipRule struct {
	prefix netip.Prefix
	owner  string
}
type Policy struct {
	seen    map[string]string
	domains []domainRule
	ips     []ipRule
}

var validID = regexp.MustCompile(`^[a-fA-F0-9-]{8,64}$`)
var validList = regexp.MustCompile(`^[a-z0-9][a-z0-9_.@!-]{0,99}$`)

func validProfileID(p Profile) bool {
	return validID.MatchString(p.ID) && !p.LegacyState || p.ID == "legacy" && p.LegacyState
}

func Compile(c Config) (*Policy, error) {
	p := &Policy{seen: map[string]string{}}
	// This index is only needed for build-time duplicate/conflict detection.
	// Keeping it on the immutable policy retains a second map of every domain
	// rule for the entire VPN session, including large selected domain lists.
	defer func() { p.seen = nil }()
	var db map[string][]string
	for _, profile := range c.Profiles {
		if len(profile.Lists) > 0 {
			var err error
			db, err = readConfiguredDatabase(c)
			if err != nil {
				return nil, fmt.Errorf("download domain database before connecting: %w", err)
			}
			break
		}
	}
	seen := map[string]bool{}
	for _, profile := range c.Profiles {
		if !validProfileID(profile) || seen[profile.ID] {
			return nil, fmt.Errorf("invalid or duplicate profile ID")
		}
		seen[profile.ID] = true
		for _, d := range profile.Domains {
			if err := p.add(d, profile.ID); err != nil {
				return nil, err
			}
		}
		for _, cidr := range profile.CIDRs {
			prefix, err := netip.ParsePrefix(cidr)
			if err != nil {
				ip, e := netip.ParseAddr(cidr)
				if e != nil {
					return nil, fmt.Errorf("invalid IP rule %q", cidr)
				}
				prefix = netip.PrefixFrom(ip, ip.BitLen())
			}
			if prefix.Bits() == 0 {
				return nil, fmt.Errorf("default IP routes are not permitted in selected-sites mode")
			}
			for _, old := range p.ips {
				if old.prefix == prefix.Masked() && old.owner != profile.ID {
					return nil, fmt.Errorf("IP rule %s belongs to multiple networks", prefix)
				}
			}
			p.ips = append(p.ips, ipRule{prefix.Masked(), profile.ID})
		}
		for _, list := range profile.Lists {
			rules, ok := db[list]
			if !ok {
				return nil, fmt.Errorf("unknown domain list %s", list)
			}
			source := "域名库 " + list
			for _, rule := range rules {
				if err := p.addSource(rule, profile.ID, source); err != nil {
					return nil, err
				}
			}
		}

	}
	return p, nil
}
func (p *Policy) add(token, owner string) error {
	return p.addSource(token, owner, "手动域名")
}
func (p *Policy) addSource(token, owner, source string) error {
	token = strings.TrimSpace(token)
	if !strings.HasPrefix(token, "regexp:") {
		token = strings.ToLower(token)
	}
	if token == "" {
		return fmt.Errorf("empty domain rule")
	}
	r := domainRule{owner: owner, source: source}
	switch {
	case strings.HasPrefix(token, "full:"):
		r.exact = true
		token = strings.TrimPrefix(token, "full:")
	case strings.HasPrefix(token, "domain:"):
		token = strings.TrimPrefix(token, "domain:")
	case strings.HasPrefix(token, "keyword:"):
		r.keyword = true
		token = strings.TrimPrefix(token, "keyword:")
	case strings.HasPrefix(token, "regexp:"):
		// Preserve regexp syntax/case; matching DNS names are normalized separately.
		re, err := regexp.Compile(strings.TrimPrefix(token, "regexp:"))
		if err != nil {
			return err
		}
		r.re = re
	}
	r.value = strings.TrimSuffix(token, ".")
	key := fmt.Sprintf("%t|%t|%s", r.exact, r.keyword, r.value)
	if old, ok := p.seen[key]; ok {
		if old != owner {
			return fmt.Errorf("domain rule %s belongs to multiple networks", token)
		}
		return nil
	}
	p.seen[key] = owner

	p.domains = append(p.domains, r)
	return nil
}

func (p *Policy) Domain(name string) string { owner, _ := p.DomainMatch(name); return owner }

func (p *Policy) DomainMatch(name string) (string, int) {
	owner, score, _ := p.domainMatchDetail(name)
	return owner, score
}
func (p *Policy) domainMatchDetail(name string) (string, int, string) {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	best := ""
	score := -1
	description := ""
	for _, r := range p.domains {
		hit := false
		s := len(r.value)
		switch {
		case r.re != nil:
			hit = r.re.MatchString(name)
			s = 0
		case r.keyword:
			hit = strings.Contains(name, r.value)
			s = 0
		case r.exact:
			hit = name == r.value
			s += 10000
		default:
			hit = name == r.value || strings.HasSuffix(name, "."+r.value)
		}
		if hit && s > score {
			best = r.owner
			score = s
			kind := "domain:"
			switch {
			case r.re != nil:
				kind = "regexp:"
			case r.keyword:
				kind = "keyword:"
			case r.exact:
				kind = "full:"
			}
			description = r.source + " · " + kind + r.value
		} else if hit && s == score && best != r.owner {
			best = "!ambiguous"
		}
	}
	return best, score, description
}

func (p *Policy) DescribeDomain(name string) string {
	_, _, rule := p.domainMatchDetail(name)
	return rule
}
func (p *Policy) DescribeIP(ip netip.Addr) string {
	best, bits := "", -1
	for _, rule := range p.ips {
		if rule.prefix.Contains(ip) && rule.prefix.Bits() > bits {
			best, bits = rule.prefix.String(), rule.prefix.Bits()
		}
	}
	return best
}
func (p *Policy) IP(ip netip.Addr) string { owner, _ := p.IPMatch(ip); return owner }

func (p *Policy) IPMatch(ip netip.Addr) (string, int) {
	best := ""
	bits := -1
	for _, r := range p.ips {
		if r.prefix.Contains(ip) && r.prefix.Bits() > bits {
			best = r.owner
			bits = r.prefix.Bits()
		}
	}
	return best, bits
}
