package main

import (
	"fmt"
	"harmony/tailnet/multinet"
	"sync"
	"testing"
)

func TestResourceActivityDuringActualRebindAndStop(t *testing.T) {
	before := resourceActivity()
	fd, _, closeOriginal := testSocket(t)
	key := testKey(t)
	config := fmt.Sprintf("private_key=%x\nreplace_peers=true\n", key.Bytes())
	pair := testTunPair(t)
	group, result := startTunnels(pair[0], 1420, []int{fd}, []string{config})
	if result != 0 {
		t.Fatalf("startTunnels returned %d", result)
	}
	closeOriginal()
	id := registerGroup(group)
	defer func() {
		groups.Lock()
		delete(groups.entries, id)
		groups.Unlock()
		group.close()
	}()
	ready, stop, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		resourceActivity()
		close(ready)
		for {
			select {
			case <-stop:
				return
			default:
				resourceActivity()
			}
		}
	}()
	var stopOnce sync.Once
	stopSampler := func() { stopOnce.Do(func() { close(stop) }); <-done }
	defer stopSampler()
	<-ready
	for i := 0; i < 12; i++ {
		fd, _, closeSocket := testSocket(t)
		err := rebindGroup(group, []int{fd}, []string{""})
		closeSocket()
		if err != nil {
			t.Fatal(err)
		}
	}
	groups.Lock()
	delete(groups.entries, id)
	groups.Unlock()
	group.close()
	stopSampler()
	if after := resourceActivity(); after != before {
		t.Fatalf("closed device remains in sample: before=%+v after=%+v", before, after)
	}
}

func TestResourceActivityConcurrentWithGatewayUpdatesAndShutdown(t *testing.T) {
	before := resourceActivity()
	g, err := NewGateway(newRoutedManager(RoutedConfig{}))
	if err != nil {
		t.Fatal(err)
	}
	group := &tunnelGroup{gateway: g, routed: &routedManager{config: RoutedConfig{Tailnets: multinet.Config{Profiles: []multinet.Profile{{ID: "legacy"}}}}}}
	id := registerGroup(group)
	defer func() {
		groups.Lock()
		delete(groups.entries, id)
		groups.Unlock()
		group.close()
	}()
	if _, err := g.allocate("private.example", "private-owner", false); err != nil {
		t.Fatal(err)
	}
	a := resourceActivity()
	if a.Groups != before.Groups+1 || a.Gateways != before.Gateways+1 || a.TailnetNodes != before.TailnetNodes+1 || a.DNSAliases != before.DNSAliases+1 {
		t.Fatalf("wrong aggregate activity: before=%+v during=%+v", before, a)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 2000; i++ {
			resourceActivity()
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 2000; i++ {
			if g.acquire() {
				g.free()
				g.wg.Done()
			}
		}
	}()
	wg.Wait()
	groups.Lock()
	delete(groups.entries, id)
	groups.Unlock()
	group.close()
	after := resourceActivity()
	if after != before {
		t.Fatalf("closed group remains active: before=%+v after=%+v", before, after)
	}
}
