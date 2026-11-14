package main

import (
	"errors"
	"net/netip"

	"golang.org/x/net/dns/dnsmessage"
)

type subnetDNSPolicy interface {
	subnetDNSAddress(netip.Addr) bool
	hasSubnetDNSPreferences() bool
}

func (g *Gateway) suppressSubnetDNSHints(kind dnsmessage.Type) bool {
	policy, ok := g.manager.(subnetDNSPolicy)
	return ok && (kind == 64 || kind == 65) && policy.hasSubnetDNSPreferences()
}

// Only addresses belonging to the queried CNAME chain can gain a subnet alias.
// Unrelated Additional records must never influence the destination or owner.
func dnsCanonicalName(message dnsmessage.Message, name string) (string, error) {
	seen := map[string]bool{}
	for i := 0; i < 16; i++ {
		if seen[name] {
			return "", errors.New("cyclic DNS alias")
		}
		seen[name] = true
		next := ""
		address := false
		for _, answer := range message.Answers {
			if normalizeName(answer.Header.Name.String()) != name || answer.Header.Class != dnsmessage.ClassINET {
				continue
			}
			if cname, ok := answer.Body.(*dnsmessage.CNAMEResource); ok {
				value := normalizeName(cname.CNAME.String())
				if next != "" && next != value {
					return "", errors.New("conflicting DNS aliases")
				}
				next = value
			}
			address = address || answer.Header.Type == dnsmessage.TypeA || answer.Header.Type == dnsmessage.TypeAAAA
		}
		if next == "" {
			return name, nil
		}
		if address {
			return "", errors.New("conflicting DNS address and alias")
		}
		name = next
	}
	return "", errors.New("DNS alias chain too long")
}

func (g *Gateway) prepareSubnetDNSReply(raw []byte, query dnsmessage.Message) ([]byte, error) {
	var reply dnsmessage.Message
	if reply.Unpack(raw) != nil || !reply.Header.Response || reply.Header.ID != query.Header.ID || reply.Header.OpCode != query.Header.OpCode || len(query.Questions) != 1 || len(reply.Questions) != 1 {
		return nil, errors.New("invalid DNS response")
	}
	want, got := query.Questions[0], reply.Questions[0]
	if normalizeName(want.Name.String()) != normalizeName(got.Name.String()) || want.Type != got.Type || want.Class != got.Class {
		return nil, errors.New("DNS question mismatch")
	}
	policy, ok := g.manager.(subnetDNSPolicy)
	if !ok || !policy.hasSubnetDNSPreferences() || reply.Header.RCode != dnsmessage.RCodeSuccess || want.Class != dnsmessage.ClassINET || want.Type != dnsmessage.TypeA && want.Type != dnsmessage.TypeAAAA {
		return raw, nil
	}
	canonical, err := dnsCanonicalName(reply, normalizeName(want.Name.String()))
	if err != nil {
		return nil, err
	}
	changed := false
	for i := range reply.Answers {
		answer := &reply.Answers[i]
		if normalizeName(answer.Header.Name.String()) != canonical || answer.Header.Class != dnsmessage.ClassINET || answer.Header.Type != want.Type {
			continue
		}
		var real netip.Addr
		switch body := answer.Body.(type) {
		case *dnsmessage.AResource:
			real = netip.AddrFrom4(body.A)
		case *dnsmessage.AAAAResource:
			real = netip.AddrFrom16(body.AAAA)
		default:
			continue
		}
		if !policy.subnetDNSAddress(real) {
			continue
		}
		fake, err := g.allocateTarget(real.String(), "!subnet", real.Is6(), destination{host: real.String(), literal: real})
		if err != nil {
			return nil, err
		}
		if real.Is4() {
			answer.Body = &dnsmessage.AResource{A: fake.As4()}
		} else {
			answer.Body = &dnsmessage.AAAAResource{AAAA: fake.As16()}
		}
		if answer.Header.TTL > 60 {
			answer.Header.TTL = 60
		}
		changed = true
	}
	if !changed {
		return raw, nil
	}
	// Signatures no longer authenticate our synthesized answer. Retain only OPT
	// in Additional so an address hint cannot bypass the synthetic destination.
	reply.Header.AuthenticData = false
	reply.Authorities = nil
	answers := reply.Answers[:0]
	for _, record := range reply.Answers {
		if record.Header.Type != 46 { // A modified RRset cannot retain its RRSIG.
			answers = append(answers, record)
		}
	}
	reply.Answers = answers
	extra := reply.Additionals[:0]
	for _, record := range reply.Additionals {
		if record.Header.Type == dnsmessage.TypeOPT {
			extra = append(extra, record)
		}
	}
	reply.Additionals = extra
	result, err := reply.Pack()
	if err == nil {
		g.selectedDNS.Add(1)
	}
	return result, err
}
