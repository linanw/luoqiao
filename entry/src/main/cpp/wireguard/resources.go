package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"harmony/tailnet/diagnostics"
)

func resourceActivity() diagnostics.Activity {
	groups.Lock()
	current := make([]*tunnelGroup, 0, len(groups.entries))
	for _, group := range groups.entries {
		current = append(current, group)
	}
	groups.Unlock()
	a := diagnostics.Activity{Groups: len(current)}
	for _, group := range current {
		// These slice headers/pointers and the configured node list are immutable
		// after registerGroup publishes the completed group under groups.Lock.
		// stop removes it before close; close/rebind never replace these fields.
		// Dynamic gateway contents below are separately protected by g.mu.
		a.WireGuardDevices += len(group.devices)
		if group.routed != nil {
			a.TailnetNodes += len(group.routed.config.Tailnets.Profiles)
		}
		if g := group.gateway; g != nil {
			g.mu.Lock()
			a.Gateways++
			a.ActiveFlows += len(g.slots)
			a.TrackedConnections += len(g.conns)
			a.DirectFlows += len(g.direct)
			a.DNSAliases += len(g.fake)
			g.mu.Unlock()
		}
	}
	return a
}

//export wg_resource_usage
func wg_resource_usage() *C.char {
	b, _ := json.Marshal(diagnostics.Sample("wireguard", resourceActivity()))
	return C.CString(string(b))
}
