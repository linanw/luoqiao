package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Use exactly the VPN's current DNS endpoints, bypassing the host process's
// /etc/hosts, search domains and global resolver. These are DNS datagrams only.
func lookupRouteDNS(ctx context.Context, host string, endpoints []string) ([]netip.Addr, error) {
	type familyResult struct {
		addresses []netip.Addr
		err       error
	}
	results := make(chan familyResult, 2)
	for _, kind := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		go func(kind dnsmessage.Type) {
			addresses, err := lookupRouteDNSFamily(ctx, host, kind, endpoints)
			results <- familyResult{addresses, err}
		}(kind)
	}
	addresses := []netip.Addr{}
	for i := 0; i < 2; i++ {
		result := <-results
		if result.err == nil {
			addresses = append(addresses, result.addresses...)
		}
	}
	if len(addresses) == 0 {
		return nil, errors.New("DNS returned no usable address")
	}
	return addresses, nil
}

func lookupRouteDNSFamily(ctx context.Context, host string, kind dnsmessage.Type, endpoints []string) ([]netip.Addr, error) {
	seen := map[string]bool{}
	for hop := 0; hop < 16; hop++ {
		if seen[host] {
			break
		}
		seen[host] = true
		name, err := dnsmessage.NewName(host + ".")
		if err != nil {
			return nil, err
		}
		var nonce [2]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			return nil, err
		}
		query := dnsmessage.Message{Header: dnsmessage.Header{ID: binary.BigEndian.Uint16(nonce[:]), RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: kind, Class: dnsmessage.ClassINET}}}
		var reply dnsmessage.Message
		ok := false
		for _, endpoint := range endpoints {
			r, err := queryRouteDNS(ctx, query, endpoint)
			if err == nil {
				reply, ok = r, true
				break
			}
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
		}
		if !ok {
			return nil, errors.New("DNS response unavailable")
		}
		if reply.Header.RCode != dnsmessage.RCodeSuccess {
			return nil, errors.New("DNS name unavailable")
		}
		canonical, err := dnsCanonicalName(reply, host)
		if err != nil {
			return nil, err
		}
		addresses := []netip.Addr{}
		for _, answer := range reply.Answers {
			if answer.Header.Class != dnsmessage.ClassINET || answer.Header.Type != kind || normalizeName(answer.Header.Name.String()) != canonical {
				continue
			}
			switch value := answer.Body.(type) {
			case *dnsmessage.AResource:
				addresses = append(addresses, netip.AddrFrom4(value.A))
			case *dnsmessage.AAAAResource:
				addresses = append(addresses, netip.AddrFrom16(value.AAAA))
			}
		}
		if len(addresses) > 0 || canonical == host {
			return addresses, nil
		}
		host = canonical
	}
	return nil, errors.New("DNS alias chain invalid")
}

func queryRouteDNS(ctx context.Context, query dnsmessage.Message, endpoint string) (dnsmessage.Message, error) {
	var reply dnsmessage.Message
	conn, err := (&net.Dialer{}).DialContext(ctx, "udp", endpoint)
	if err != nil {
		return reply, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	deadline := time.Now().Add(2 * time.Second)
	if limit, ok := ctx.Deadline(); ok && limit.Before(deadline) {
		deadline = limit
	}
	conn.SetDeadline(deadline)
	raw, err := query.Pack()
	if err != nil {
		return reply, err
	}
	if _, err = conn.Write(raw); err != nil {
		return reply, err
	}
	buffer := make([]byte, 65535)
	n, err := conn.Read(buffer)
	if err != nil {
		return reply, err
	}
	if err := reply.Unpack(buffer[:n]); err != nil {
		return reply, err
	}
	if !reply.Header.Response || reply.Header.Truncated || reply.Header.ID != query.Header.ID || reply.Header.OpCode != query.Header.OpCode || len(reply.Questions) != 1 || reply.Questions[0].Type != query.Questions[0].Type || reply.Questions[0].Class != query.Questions[0].Class || normalizeName(reply.Questions[0].Name.String()) != normalizeName(query.Questions[0].Name.String()) {
		return reply, errors.New("invalid DNS response")
	}
	return reply, nil
}
