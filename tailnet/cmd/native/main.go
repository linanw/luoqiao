package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"encoding/json"
	"harmony/tailnet"
	"harmony/tailnet/diagnostics"
	"harmony/tailnet/multinet"
	"os"
	"sync"
	"time"
	"unsafe"
)

var mu sync.Mutex
var client *tailnet.Client
var device *tailnet.Tunnel
var manager *multinet.Manager
var gateway *multinet.Gateway

func result(err error) *C.char {
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString("")
}

//export tn_free
func tn_free(p *C.char) { C.free(unsafe.Pointer(p)) }

//export tn_start
func tn_start(dir, host, control *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if client != nil || manager != nil {
		return C.CString("already started")
	}
	device = tailnet.NewTunnel()
	var e error
	client, e = tailnet.New(tailnet.Config{StateDir: C.GoString(dir), Hostname: C.GoString(host), ControlURL: C.GoString(control), Tun: device})
	if e != nil {
		device.Close()
	}
	return result(e)
}

//export tn_attach
func tn_attach(fd C.int) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if client == nil && gateway == nil {
		return C.CString("not started")
	}
	if gateway != nil {
		return result(gateway.Tun.Attach(int(fd)))
	}
	return result(device.Attach(int(fd)))
}

//export tn_status
func tn_status() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if manager != nil {
		sent, received := gateway.Tun.Stats()
		r, w := gateway.Tun.Errors()
		b, _ := json.Marshal(map[string]any{"Nodes": manager.Status(), "error": gateway.FlowError(), "SentBytes": sent, "ReceivedBytes": received, "ReadError": r, "WriteError": w})
		return C.CString(string(b))
	}
	if client == nil {
		return C.CString(`{}`)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	s, e := client.Status(ctx)
	if e != nil {
		b, _ := json.Marshal(map[string]string{"error": e.Error()})
		return C.CString(string(b))
	}
	type peer struct {
		DNSName      string
		HostName     string
		TailscaleIPs []string
		Online       bool
	}
	peers := make([]peer, 0, len(s.Peer))
	routes := make([]string, 0)
	for _, p := range s.Peer {
		if p == nil {
			continue
		}
		if p.PrimaryRoutes != nil {
			for _, prefix := range p.PrimaryRoutes.All() {
				if prefix.Bits() > 0 {
					routes = append(routes, prefix.String())
				}
			}
		}
		ips := make([]string, 0, len(p.TailscaleIPs))
		for _, ip := range p.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		peers = append(peers, peer{p.DNSName, p.HostName, ips, p.Online})
	}
	suffix := ""
	if s.CurrentTailnet != nil {
		suffix = s.CurrentTailnet.MagicDNSSuffix
	}
	sent, received := device.Stats()
	readError, writeError := device.Errors()
	b, _ := json.Marshal(map[string]any{"DNSQuery": device.DNSQuery(), "DNSResponse": device.DNSResponse(), "SubnetRoutes": routes, "ReadError": readError, "WriteError": writeError, "DNSSuffix": suffix, "SentBytes": sent, "ReceivedBytes": received, "Health": s.Health, "BackendState": s.BackendState, "AuthURL": s.AuthURL, "TailscaleIPs": s.TailscaleIPs, "PeerList": peers})
	return C.CString(string(b))
}

//export tn_resources
func tn_resources() *C.char {
	mu.Lock()
	a := diagnostics.Activity{}
	if client != nil {
		a.TailnetNodes = 1
	}
	if manager != nil {
		a.TailnetNodes += manager.NodeCount()
	}
	if gateway != nil {
		a.Gateways = 1
		a.ActiveFlows, a.TrackedConnections, a.DNSAliases = gateway.ResourceCounts()
	}
	if client != nil || manager != nil {
		a.Groups = 1
	}
	mu.Unlock()
	b, _ := json.Marshal(diagnostics.Sample("tailnet", a))
	return C.CString(string(b))
}

//export tn_stop
func tn_stop() {
	mu.Lock()
	defer mu.Unlock()
	if gateway != nil {
		gateway.Close()
		gateway = nil
	}
	if manager != nil {
		manager.Close()
		manager = nil
	}
	if device != nil {
		device.Close()
	}
	if client != nil {
		client.Close()
		client = nil
	}
}
func main() {}

//export tn_multi
func tn_multi(path *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if client != nil || manager != nil {
		return C.CString("already started")
	}
	b, err := os.ReadFile(C.GoString(path))
	if err != nil {
		return result(err)
	}
	var cfg multinet.Config
	if err = json.Unmarshal(b, &cfg); err != nil {
		return result(err)
	}
	manager, err = multinet.New(cfg)
	if err != nil {
		return result(err)
	}
	gateway, err = multinet.NewGateway(manager)
	if err != nil {
		manager.Close()
		manager = nil
	}
	return result(err)
}

//export tn_network
func tn_network(dns *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if manager != nil {
		var servers []string
		if err := json.Unmarshal([]byte(C.GoString(dns)), &servers); err != nil {
			return result(err)
		}
		return result(manager.NetworkChanged(servers))
	}
	if client != nil {
		client.NetworkChanged()
	}
	return C.CString("")
}

//export tn_database
func tn_database(dir *C.char) *C.char { return result(multinet.InstallDatabase(C.GoString(dir))) }

//export tn_catalog
func tn_catalog(dir *C.char) *C.char {
	names, err := multinet.DatabaseCatalog(C.GoString(dir))
	if err != nil {
		b, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(b))
	}
	b, _ := json.Marshal(names)
	return C.CString(string(b))
}
