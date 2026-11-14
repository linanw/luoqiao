package tailnet

import (
	"encoding/binary"
	"golang.org/x/net/dns/dnsmessage"
	"testing"
)

func TestObserveMagicDNS(t *testing.T) {
	name := dnsmessage.MustNewName("node.example.ts.net.")
	msg := dnsmessage.Message{Header: dnsmessage.Header{Response: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}, Answers: []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: [4]byte{100, 90, 175, 126}}}}}
	payload, err := msg.Pack()
	if err != nil {
		t.Fatal(err)
	}
	packet := make([]byte, 28+len(payload))
	packet[0] = 0x45
	packet[9] = 17
	binary.BigEndian.PutUint16(packet[20:22], 53)
	binary.BigEndian.PutUint16(packet[24:26], uint16(8+len(payload)))
	copy(packet[28:], payload)
	observation, ok := observeMagicDNS(packet)
	if !ok || len(observation.Answers) != 1 || observation.Answers[0] != "100.90.175.126" {
		t.Fatal(observation, ok)
	}
	for n := 0; n < len(packet); n++ {
		if _, ok := observeMagicDNS(packet[:n]); ok {
			t.Fatalf("accepted truncated packet: %d", n)
		}
	}
}
