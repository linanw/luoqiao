// Package diagnostics samples numeric resource counters without disclosing
// descriptors, domains, account data, or tunnel configuration.
package diagnostics

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"runtime/metrics"
	"strconv"
	"strings"
	"time"
)

// Counter distinguishes an unavailable counter from a measured zero. Callers
// must check Valid before plotting Value or using it in comparisons.
type Counter struct {
	Value uint64 `json:"value"`
	Valid bool   `json:"valid"`
}

type SignedCounter struct {
	Value int64 `json:"value"`
	Valid bool  `json:"valid"`
}

type Process struct {
	FDCount        Counter       `json:"fdCount"`
	RSSBytes       Counter       `json:"rssBytes"`
	PeakRSSBytes   Counter       `json:"peakRssBytes"`
	VirtualBytes   Counter       `json:"virtualBytes"`
	SwapBytes      Counter       `json:"swapBytes"`
	Threads        Counter       `json:"threads"`
	StartTimeTicks Counter       `json:"startTimeTicks"`
	OOMScoreAdj    SignedCounter `json:"oomScoreAdj"`
}

// Go describes only the calling archive's Go runtime, not the whole process.
// TotalBytes is runtime-accounted memory; HeapReleasedBytes has been returned
// to the OS, so neither TotalBytes nor HeapReservedBytes is process RSS.
type Go struct {
	HeapObjectBytes   Counter `json:"heapObjectBytes"`
	HeapReservedBytes Counter `json:"heapReservedBytes"`
	HeapReleasedBytes Counter `json:"heapReleasedBytes"`
	TotalBytes        Counter `json:"totalBytes"`
	StackBytes        Counter `json:"stackBytes"`
	Goroutines        Counter `json:"goroutines"`
	GCCycles          Counter `json:"gcCycles"`
}

// Activity reports aggregate sizes only. It never enumerates a connection,
// domain, address, profile identifier, or descriptor target.
type Activity struct {
	Groups             int `json:"groups"`
	WireGuardDevices   int `json:"wireguardDevices"`
	TailnetNodes       int `json:"tailnetNodes"`
	Gateways           int `json:"gateways"`
	ActiveFlows        int `json:"activeFlows"`
	TrackedConnections int `json:"trackedConnections"`
	DirectFlows        int `json:"directFlows"`
	DNSAliases         int `json:"dnsAliases"`
}

type Snapshot struct {
	Version        int      `json:"version"`
	SampledAt      int64    `json:"sampledAt"`
	PID            int      `json:"pid"`
	Engine         string   `json:"engine"`
	EngineUptimeMS int64    `json:"engineUptimeMs"`
	Process        Process  `json:"process"`
	Go             Go       `json:"go"`
	Activity       Activity `json:"activity"`
}

var startedAt = time.Now()

// Sample performs no network I/O, GC, heap walk, or descriptor-target lookup.
// /proc reads are bounded and all sampling descriptors are closed on every path.
// FDCount is a point-in-time count and can vary while other threads open files.
func Sample(engine string, activity Activity) Snapshot {
	return Snapshot{Version: 1, SampledAt: time.Now().UnixMilli(), PID: os.Getpid(),
		Engine: engine, EngineUptimeMS: time.Since(startedAt).Milliseconds(),
		Process: sampleProcess("/proc/self"), Go: sampleGo(), Activity: activity}
}

func sampleProcess(root string) Process {
	p := Process{FDCount: countFDs(filepath.Join(root, "fd"))}
	if f, err := os.Open(filepath.Join(root, "oom_score_adj")); err == nil {
		b, err := io.ReadAll(io.LimitReader(f, 64))
		f.Close()
		if err == nil && len(b) < 64 {
			value, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
			if err == nil && value >= -1000 && value <= 1000 {
				p.OOMScoreAdj = SignedCounter{value, true}
			}
		}
	}
	if f, err := os.Open(filepath.Join(root, "status")); err == nil {
		parseStatus(io.LimitReader(f, 128*1024), &p)
		f.Close()
	}
	if f, err := os.Open(filepath.Join(root, "stat")); err == nil {
		b, err := io.ReadAll(io.LimitReader(f, 16*1024))
		f.Close()
		if err == nil && len(b) < 16*1024 {
			// comm can include spaces and parentheses; field 3 starts after its
			// final ')'. Only field 22 (starttime) is retained.
			if end := strings.LastIndexByte(string(b), ')'); end >= 0 {
				fields := strings.Fields(string(b[end+1:]))
				if len(fields) > 19 {
					p.StartTimeTicks = parseUnsigned(fields[19], 1)
				}
			}
		}
	}
	return p
}

func countFDs(path string) Counter {
	dir, err := os.Open(path)
	if err != nil {
		return Counter{}
	}
	defer dir.Close()
	self := strconv.FormatUint(uint64(dir.Fd()), 10)
	var count uint64
	for {
		names, err := dir.Readdirnames(128)
		for _, name := range names {
			if name != self && parseUnsigned(name, 1).Valid {
				count++
			}
		}
		if err == io.EOF {
			return Counter{count, true}
		}
		if err != nil {
			return Counter{}
		}
	}
}

func parseUnsigned(value string, multiplier uint64) Counter {
	if value == "" || strings.IndexFunc(value, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return Counter{}
	}
	n, err := strconv.ParseUint(value, 10, 64)
	if err != nil || n > ^uint64(0)/multiplier {
		return Counter{}
	}
	return Counter{n * multiplier, true}
}

func parseStatus(r io.Reader, p *Process) {
	s := bufio.NewScanner(r)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) < 2 {
			continue
		}
		var target *Counter
		switch fields[0] {
		case "VmRSS:":
			target = &p.RSSBytes
		case "VmHWM:":
			target = &p.PeakRSSBytes
		case "VmSize:":
			target = &p.VirtualBytes
		case "VmSwap:":
			target = &p.SwapBytes
		case "Threads:":
			if len(fields) == 2 {
				p.Threads = parseUnsigned(fields[1], 1)
			}
		}
		if target != nil && len(fields) == 3 && fields[2] == "kB" {
			*target = parseUnsigned(fields[1], 1024)
		}
	}
}

func metricValue(s metrics.Sample) Counter {
	if s.Value.Kind() != metrics.KindUint64 {
		return Counter{}
	}
	return Counter{s.Value.Uint64(), true}
}

func sum(values ...Counter) Counter {
	var total uint64
	for _, value := range values {
		if !value.Valid || ^uint64(0)-total < value.Value {
			return Counter{}
		}
		total += value.Value
	}
	return Counter{total, true}
}

func sampleGo() Go {
	// Read lightweight runtime counters rather than stopping the world with
	// ReadMemStats. Unsupported counters remain explicitly unavailable.
	samples := []metrics.Sample{
		{Name: "/memory/classes/heap/objects:bytes"},
		{Name: "/memory/classes/heap/free:bytes"},
		{Name: "/memory/classes/heap/unused:bytes"},
		{Name: "/memory/classes/heap/released:bytes"},
		{Name: "/memory/classes/total:bytes"},
		{Name: "/memory/classes/heap/stacks:bytes"},
		{Name: "/memory/classes/os-stacks:bytes"},
		{Name: "/sched/goroutines:goroutines"},
		{Name: "/gc/cycles/total:gc-cycles"},
	}
	metrics.Read(samples)
	object, free, unused, released := metricValue(samples[0]), metricValue(samples[1]), metricValue(samples[2]), metricValue(samples[3])
	return Go{HeapObjectBytes: object, HeapReservedBytes: sum(object, free, unused, released),
		HeapReleasedBytes: released, TotalBytes: metricValue(samples[4]),
		StackBytes: sum(metricValue(samples[5]), metricValue(samples[6])),
		Goroutines: metricValue(samples[7]), GCCycles: metricValue(samples[8])}
}
