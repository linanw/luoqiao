package diagnostics

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func writeFixture(t *testing.T, dir, name, contents string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestProcessCountersAndUnavailableValues(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "fd"), 0700); err != nil {
		t.Fatal(err)
	}
	writeFixture(t, filepath.Join(dir, "fd"), "70000", "secret descriptor target must not be read")
	writeFixture(t, filepath.Join(dir, "fd"), "70001", "another secret")
	writeFixture(t, filepath.Join(dir, "fd"), "not-a-descriptor", "ignored")
	writeFixture(t, dir, "status", "Name:\tsecret-name\nVmRSS:\t1234 kB\nVmHWM:\t5678 kB\nVmSize:\t9012 kB\nVmSwap:\t0 kB\nThreads:\t19\n")
	// Starttime is field 22, after a comm value that itself contains ')'.
	writeFixture(t, dir, "stat", "42 (process with ) spaces) R "+strings.Repeat("0 ", 18)+"1234567 0 0\n")
	writeFixture(t, dir, "oom_score_adj", "-800\n")
	p := sampleProcess(dir)
	want := map[string]struct {
		got   Counter
		value uint64
	}{
		"fd": {p.FDCount, 2}, "rss": {p.RSSBytes, 1234 * 1024}, "peak": {p.PeakRSSBytes, 5678 * 1024},
		"virtual": {p.VirtualBytes, 9012 * 1024}, "swap": {p.SwapBytes, 0}, "threads": {p.Threads, 19},
		"start": {p.StartTimeTicks, 1234567},
	}
	for name, c := range want {
		if !c.got.Valid || c.got.Value != c.value {
			t.Errorf("%s = %+v, want %d", name, c.got, c.value)
		}
	}
	if !p.OOMScoreAdj.Valid || p.OOMScoreAdj.Value != -800 {
		t.Fatalf("oom adj: %+v", p.OOMScoreAdj)
	}
	b, err := json.Marshal(p)
	if err != nil || strings.Contains(string(b), "secret") {
		t.Fatalf("not a numeric-only snapshot: %s %v", b, err)
	}
	missing := sampleProcess(filepath.Join(dir, "missing"))
	if missing.FDCount.Valid || missing.RSSBytes.Valid || missing.Threads.Valid || missing.StartTimeTicks.Valid || missing.OOMScoreAdj.Valid {
		t.Fatalf("missing proc incorrectly reported as measured zeros: %+v", missing)
	}
}

func TestMalformedCountersDoNotBecomeMeasurements(t *testing.T) {
	for _, line := range []string{"VmRSS: -1 kB", "VmRSS: 1 MB", "VmRSS: 18446744073709551615 kB", "VmRSS: +1 kB", "VmRSS: one kB", "VmRSS: 1 kB trailing"} {
		var p Process
		parseStatus(strings.NewReader(line), &p)
		if p.RSSBytes.Valid {
			t.Errorf("accepted %q: %+v", line, p.RSSBytes)
		}
	}
	dir := t.TempDir()
	writeFixture(t, dir, "fd", "regular file cannot be enumerated")
	writeFixture(t, dir, "status", "Threads: -5\nVmSwap: not-a-number kB\n")
	writeFixture(t, dir, "stat", "truncated (process) R 1 2")
	for _, adj := range []string{"-1001", "1001", "bad", strings.Repeat("0", 64)} {
		writeFixture(t, dir, "oom_score_adj", adj)
		p := sampleProcess(dir)
		if p.FDCount.Valid || p.Threads.Valid || p.SwapBytes.Valid || p.StartTimeTicks.Valid || p.OOMScoreAdj.Valid {
			t.Fatalf("malformed values accepted: %+v", p)
		}
	}
}

func TestSamplingDoesNotLeakDescriptors(t *testing.T) {
	fdPath := "/proc/self/fd"
	if runtime.GOOS == "darwin" {
		fdPath = "/dev/fd"
	}
	before := countFDs(fdPath)
	if !before.Valid {
		t.Skip("host does not expose own descriptor directory")
	}
	dir := t.TempDir()
	writeFixture(t, dir, "status", "VmRSS: 100 kB\nThreads: 10\n")
	writeFixture(t, dir, "stat", "bad stat exercises a partial sample")
	writeFixture(t, dir, "oom_score_adj", "500\n")
	for i := 0; i < 2048; i++ {
		if !countFDs(fdPath).Valid {
			t.Fatal("descriptor sampling failed")
		}
		sampleProcess(dir)
	}
	after := countFDs(fdPath)
	if !after.Valid || after.Value > before.Value+2 {
		t.Fatalf("descriptor count grew: before=%+v after=%+v", before, after)
	}
}

func TestFDCountExcludesItsOwnSamplingDescriptor(t *testing.T) {
	fdPath := "/proc/self/fd"
	if runtime.GOOS == "darwin" {
		fdPath = "/dev/fd"
	}
	before := countFDs(fdPath)
	if !before.Valid {
		t.Skip("host does not expose own descriptor directory")
	}
	f, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	during := countFDs(fdPath)
	f.Close()
	after := countFDs(fdPath)
	if !during.Valid || !after.Valid || during.Value != before.Value+1 || after.Value != before.Value {
		t.Fatalf("descriptor counts do not track open/close: before=%+v during=%+v after=%+v", before, during, after)
	}
}

func TestRuntimeSnapshotIsScopedAndValid(t *testing.T) {
	before := time.Now().UnixMilli()
	s := Sample("wireguard", Activity{Groups: 1, WireGuardDevices: 2, TailnetNodes: 3, DNSAliases: 4})
	if s.Version != 1 || s.Engine != "wireguard" || s.PID != os.Getpid() || s.SampledAt < before || s.EngineUptimeMS < 0 {
		t.Fatalf("invalid sample metadata: %+v", s)
	}
	for name, counter := range map[string]Counter{"objects": s.Go.HeapObjectBytes, "reserved": s.Go.HeapReservedBytes, "released": s.Go.HeapReleasedBytes,
		"total": s.Go.TotalBytes, "stacks": s.Go.StackBytes, "goroutines": s.Go.Goroutines, "gc": s.Go.GCCycles} {
		if !counter.Valid {
			t.Errorf("runtime counter unavailable on test toolchain: %s", name)
		}
	}
	if s.Go.Goroutines.Value == 0 || s.Go.HeapReservedBytes.Value < s.Go.HeapObjectBytes.Value || s.Activity.TailnetNodes != 3 {
		t.Fatalf("inconsistent runtime snapshot: %+v", s)
	}
	if runtime.GOOS == "linux" && (!s.Process.FDCount.Valid || !s.Process.RSSBytes.Valid || !s.Process.StartTimeTicks.Valid) {
		t.Fatalf("native Linux proc fields unavailable: %+v", s.Process)
	}
}

func BenchmarkResourceSample(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		Sample("wireguard", Activity{})
	}
}
