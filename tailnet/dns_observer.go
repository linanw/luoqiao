package tailnet

import (
	"encoding/binary"
	"golang.org/x/net/dns/dnsmessage"
	"net/netip"
	"strings"
)

// DNSObservation records only tailnet DNS diagnostics, never application payloads.
type DNSObservation struct {
	Question string
	Response bool
	RCode    int
	Answers  []string
}

func observeMagicDNS(packet []byte) (DNSObservation, bool) {
	var out DNSObservation
	if len(packet) < 20 {
		return out, false
	}
	offset := 0
	switch packet[0] >> 4 {
	case 4:
		offset = int(packet[0]&15) * 4
		if offset < 20 || packet[9] != 17 || binary.BigEndian.Uint16(packet[6:8])&0x3fff != 0 {
			return out, false
		}
	case 6:
		offset = 40
		if packet[6] != 17 {
			return out, false
		}
	default:
		return out, false
	}
	if len(packet) < offset+8 {
		return out, false
	}
	udp := packet[offset:]
	if binary.BigEndian.Uint16(udp[:2]) != 53 && binary.BigEndian.Uint16(udp[2:4]) != 53 {
		return out, false
	}
	length := int(binary.BigEndian.Uint16(udp[4:6]))
	if length < 8 || length > len(udp) {
		return out, false
	}
	var msg dnsmessage.Message
	if msg.Unpack(udp[8:length]) != nil || len(msg.Questions) != 1 {
		return out, false
	}
	name := strings.ToLower(msg.Questions[0].Name.String())
	if !strings.HasSuffix(name, ".ts.net.") && strings.Contains(strings.TrimSuffix(name, "."), ".") {
		return out, false
	}
	out = DNSObservation{Question: name, Response: msg.Response, RCode: int(msg.RCode), Answers: []string{}}
	for _, a := range msg.Answers {
		switch body := a.Body.(type) {
		case *dnsmessage.AResource:
			out.Answers = append(out.Answers, netip.AddrFrom4(body.A).String())
		case *dnsmessage.AAAAResource:
			out.Answers = append(out.Answers, netip.AddrFrom16(body.AAAA).String())
		}
	}
	return out, true
}
