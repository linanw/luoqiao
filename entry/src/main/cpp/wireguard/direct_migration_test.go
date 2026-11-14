package main

import (
	"context"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

func startForwardedTestFlow(t *testing.T, g *Gateway, ip netip.Addr, port uint16, network string) (net.Conn, <-chan struct{}) {
	t.Helper()
	app, inner := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		g.forward(inner, stack.TransportEndpointID{LocalAddress: tcpip.AddrFromSlice(ip.AsSlice()), LocalPort: port}, network)
	}()
	t.Cleanup(func() {
		app.Close()
		inner.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("forwarded flow did not stop")
		}
	})
	return app, done
}

func checkForwardedEcho(t *testing.T, c net.Conn, want string) {
	t.Helper()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, len(want))
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != want {
		t.Fatalf("echo %q, error %v", buf, err)
	}
}

func TestNetworkChangeClosesPhysicalTCPButPreservesSelectedFlowsAndDNS(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	closed := make(chan int, 8)
	go func() {
		for n := 1; ; n++ {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn, n int) {
				defer c.Close()
				defer func() { closed <- n }()
				io.Copy(c, c)
			}(c, n)
		}
	}()
	_, rawPort, _ := net.SplitHostPort(listener.Addr().String())
	port, _ := strconv.Atoi(rawPort)
	m := newRoutedManager(RoutedConfig{Profiles: []RoutedProfile{{ID: "keep"}}})
	m.dialers["keep"] = &net.Dialer{}
	m.tailnets = newIndependentTailnets(t)
	g, err := NewGateway(m)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(g.Close)
	group := &tunnelGroup{gateway: g}
	fake, err := g.allocate("127.0.0.1", "wg:keep", false)
	if err != nil {
		t.Fatal(err)
	}
	peer, err := g.allocate("tn-a.test", "aaaaaaaa", false)
	if err != nil {
		t.Fatal(err)
	}
	direct, directDone := startForwardedTestFlow(t, g, netip.MustParseAddr("127.0.0.1"), uint16(port), "tcp")
	checkForwardedEcho(t, direct, "hello")
	wg, _ := startForwardedTestFlow(t, g, fake, uint16(port), "tcp")
	checkForwardedEcho(t, wg, "hello")
	tn, _ := startForwardedTestFlow(t, g, peer, 8080, "tcp")
	checkForwardedEcho(t, tn, "aaaaaaaa:tcp:hello")
	if group.setRouteDNS([]string{"invalid"}) == nil {
		t.Fatal("invalid network update accepted")
	}
	checkForwardedEcho(t, direct, "hello")
	if err := group.setRouteDNS([]string{"192.168.72.1"}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-directDone:
	case <-time.After(3 * time.Second):
		t.Fatal("old direct flow was left waiting for TCP timeout")
	}
	if _, err := direct.Write([]byte("old")); err == nil {
		t.Fatal("old inner direct flow remained usable")
	}
	select {
	case n := <-closed:
		if n != 1 {
			t.Fatal("selected physical transport unexpectedly closed")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("old physical TCP was not closed")
	}
	checkForwardedEcho(t, wg, "hello")
	checkForwardedEcho(t, tn, "aaaaaaaa:tcp:hello")
	if unchanged, _ := g.allocate("127.0.0.1", "wg:keep", false); unchanged != fake {
		t.Fatal("network change discarded synthetic DNS mapping")
	}
	fresh, _ := startForwardedTestFlow(t, g, netip.MustParseAddr("127.0.0.1"), uint16(port), "tcp")
	checkForwardedEcho(t, fresh, "hello")
	// The mock Tailnet uses net.Pipe without TCP CloseWrite; close its other end
	// before waiting for forwarded goroutines during cleanup.
	g.Close()
}

type lateDirectDialer struct {
	started, release, canceled chan struct{}
	remote                     net.Conn
	once                       sync.Once
}

func (d *lateDirectDialer) DialContext(ctx context.Context, _, _ string) (net.Conn, error) {
	d.once.Do(func() { close(d.started) })
	<-ctx.Done()
	close(d.canceled)
	<-d.release // Deliberately ignore cancellation and return an old-network socket.
	return d.remote, nil
}

func TestNetworkChangeRejectsLateDirectDialResult(t *testing.T) {
	for _, network := range []string{"tcp", "udp"} {
		t.Run(network, func(t *testing.T) {
			remote, peer := net.Pipe()
			defer peer.Close()
			d := &lateDirectDialer{started: make(chan struct{}), release: make(chan struct{}), canceled: make(chan struct{}), remote: remote}
			m := newRoutedManager(RoutedConfig{})
			m.direct = d
			g, err := NewGateway(m)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(g.Close)
			app, done := startForwardedTestFlow(t, g, netip.MustParseAddr("192.0.2.10"), 80, network)
			select {
			case <-d.started:
			case <-time.After(3 * time.Second):
				t.Fatal("direct dial did not start")
			}
			g.ResetDirectFlows()
			select {
			case <-d.canceled:
			case <-time.After(3 * time.Second):
				t.Fatal("in-progress direct dial was not canceled")
			}
			if _, err := app.Write([]byte("old")); err == nil {
				t.Fatal("in-progress inner flow not closed")
			}
			close(d.release)
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("late direct dial resumed forwarding")
			}
			peer.SetDeadline(time.Now().Add(time.Second))
			if _, err := peer.Write([]byte("old")); err != io.ErrClosedPipe {
				t.Fatalf("late physical socket not closed: %v", err)
			}
		})
	}
}
