#!/usr/bin/env python3
"""Execute the actual OpenHarmony interface functions against host resources.

The subject is read from the installed toolchain, not reimplemented here. Only
its build tag, package name and syscall import change. The syscall adapter uses
real host Socket/Close; it supplies the unavailable OpenHarmony ioctl ABI. The
C getifaddrs adapter supplies IPv4/IPv6 lists and counts their explicit frees.
Socket failure is a real EMFILE from a temporarily lowered child-process limit.

The unpatched comparison comes from the toolchain's own git HEAD when present,
otherwise by reversing the checked-in patch in an isolated temporary copy.
No installed toolchain files are changed and no external network is contacted.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SUBJECT = Path("src/net/interface_table_openharmony.go")
PATCH = ROOT / "tools/patches/openharmony-go-interface-resources.patch"

PLATFORM = r'''
package platform

import (
    "sync"
    "syscall"
    "unsafe"
)

type RawSockaddrAny = syscall.RawSockaddrAny
type RawSockaddrInet4 = syscall.RawSockaddrInet4
type RawSockaddrInet6 = syscall.RawSockaddrInet6

const (
    AF_INET = syscall.AF_INET
    AF_INET6 = syscall.AF_INET6
    SOCK_DGRAM = syscall.SOCK_DGRAM
    SYS_IOCTL = syscall.SYS_IOCTL
    SIOCGIFINDEX = 1
    SIOCGIFMTU = 2
    SIOCGIFHWADDR = 3
)

var FailIoctl bool
var mu sync.Mutex
var opened = map[int]bool{}
var SocketCalls, SocketFailures int

func Socket(domain, kind, protocol int) (int, error) {
    fd, err := syscall.Socket(domain, kind, protocol)
    mu.Lock()
    defer mu.Unlock()
    SocketCalls++
    if err == nil { opened[fd] = true } else { SocketFailures++ }
    return fd, err
}

func Close(fd int) error {
    err := syscall.Close(fd)
    if err == nil {
        mu.Lock()
        delete(opened, fd)
        mu.Unlock()
    }
    return err
}

// Cleanup is called only after assertions, so an unfixed subject cannot exhaust
// the host while running the remaining independent negative-control cases.
func Cleanup() {
    mu.Lock()
    defer mu.Unlock()
    for fd := range opened { syscall.Close(fd); delete(opened, fd) }
    SocketCalls, SocketFailures = 0, 0
}

// This is the only simulated syscall. It implements the OpenHarmony ifreq ABI
// absent on macOS, first proving that the subject passed a live kernel socket.
//go:uintptrescapes
//go:nocheckptr
func Syscall(trap, fd, request, argument uintptr) (uintptr, uintptr, syscall.Errno) {
    var stat syscall.Stat_t
    if err := syscall.Fstat(int(fd), &stat); err != nil { return 0, 0, syscall.EBADF }
    if trap != SYS_IOCTL || FailIoctl { return 0, 0, syscall.EINVAL }
    ifr := (*struct { Name [16]byte; Data [24]byte })(unsafe.Pointer(argument))
    switch request {
    case SIOCGIFINDEX:
        *(*uint32)(unsafe.Pointer(&ifr.Data[0])) = 7
    case SIOCGIFMTU:
        *(*uint32)(unsafe.Pointer(&ifr.Data[0])) = 1500
    case SIOCGIFHWADDR:
        copy(ifr.Data[2:8], []byte{2, 0, 0, 0, 0, 7})
    default:
        return 0, 0, syscall.EINVAL
    }
    return 0, 0, 0
}
'''

FIXTURE = r'''
package interfacecheck

import (
    "fmt"
    "math/bits"
    "net"
    "syscall"
    "unsafe"
)

type Interface = net.Interface
type Addr = net.Addr
type IP = net.IP
type IPNet = net.IPNet
type Flags = net.Flags
const IPv4len = net.IPv4len
const IPv6len = net.IPv6len
var IPv4 = net.IPv4
var CIDRMask = net.CIDRMask

func linkFlags(v uint32) Flags { return Flags(v) }
func simpleMaskLength(mask []byte) int {
    n := 0
    for _, b := range mask { n += bits.OnesCount8(b) }
    return n
}

type _C_int = int
type _C_struct_sockaddr = syscall.RawSockaddrAny
type _C_struct_ifaddrs struct {
    next *_C_struct_ifaddrs
    addr, mask *_C_struct_sockaddr
    name string
    flags uint32
}

var fixtureMode string
var allocCalls, allocatedNodes, freeCalls, freedNodes int
var liveLists = map[*_C_struct_ifaddrs]int{}

func raw4(address [4]byte) *_C_struct_sockaddr {
    raw := new(_C_struct_sockaddr)
    sa := (*syscall.RawSockaddrInet4)(unsafe.Pointer(raw))
    sa.Family, sa.Addr = syscall.AF_INET, address
    return raw
}

func raw6(address [16]byte) *_C_struct_sockaddr {
    raw := new(_C_struct_sockaddr)
    sa := (*syscall.RawSockaddrInet6)(unsafe.Pointer(raw))
    sa.Family, sa.Addr = syscall.AF_INET6, address
    return raw
}

func _C_getifaddrs(out **_C_struct_ifaddrs) (int, error) {
    if fixtureMode == "getifaddrs_failure" { return -1, syscall.ENOMEM }
    allocCalls++
    if fixtureMode == "empty" { *out = nil; return 0, nil }
    head := &_C_struct_ifaddrs{name: "test0", flags: uint32(net.FlagUp)}
    nodes := 1
    if fixtureMode != "nil_address" {
        head.addr, head.mask = raw4([4]byte{192, 0, 2, 9}), raw4([4]byte{255, 255, 255, 0})
        var ip6, mask6 [16]byte
        copy(ip6[:], net.ParseIP("2001:db8::9").To16())
        for i := 0; i < 8; i++ { mask6[i] = 255 }
        head.next = &_C_struct_ifaddrs{name: "test0", flags: uint32(net.FlagUp),
            addr: raw6(ip6), mask: raw6(mask6), next: &_C_struct_ifaddrs{name: "no-address"}}
        nodes = 3
    }
    *out = head
    liveLists[head] = nodes
    allocatedNodes += nodes
    if fixtureMode == "stale_errno" { return 0, syscall.EINVAL }
    return 0, nil
}

func _C_freeifaddrs(head *_C_struct_ifaddrs) {
    freeCalls++
    if head == nil { return }
    expected, ok := liveLists[head]
    if !ok { panic("freeifaddrs received an unknown or already-freed head") }
    actual := 0
    for r := head; r != nil; r = r.next { actual++ }
    if actual != expected { panic(fmt.Sprintf("freeifaddrs list was truncated: %d != %d", actual, expected)) }
    freedNodes += actual
    delete(liveLists, head)
}

func _C_gai_strerror(_ _C_int) string { return "simulated getifaddrs failure" }
func _C_ifa_next(r *_C_struct_ifaddrs) **_C_struct_ifaddrs { return &r.next }
func _C_ifa_addr(r *_C_struct_ifaddrs) **_C_struct_sockaddr { return &r.addr }
func _C_ifa_mask(r *_C_struct_ifaddrs) **_C_struct_sockaddr { return &r.mask }
func _C_ifa_flags(r *_C_struct_ifaddrs) *uint32 { return &r.flags }
func _C_gifa_name(r *_C_struct_ifaddrs) string { return r.name }
'''

TEST = r'''
package interfacecheck

import (
    "errors"
    "os"
    "runtime"
    "strconv"
    "syscall"
    "testing"
    platform "interfacecheck/platform"
)

func fdCount(t *testing.T) int {
    t.Helper()
    path := "/proc/self/fd"
    if runtime.GOOS == "darwin" { path = "/dev/fd" }
    entries, err := os.ReadDir(path)
    if err != nil { t.Fatal(err) }
    return len(entries)
}

func TestInterfaceResources(t *testing.T) {
    iterations, err := strconv.Atoi(os.Getenv("INTERFACE_TEST_ITERATIONS"))
    if err != nil || iterations < 100 { t.Fatal("at least 100 iterations required") }
    // Make the unpatched negative control observable without exhausting its
    // own descriptor limit before every requested iteration has executed.
    var original syscall.Rlimit
    if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &original); err != nil { t.Fatal(err) }
    needed := uint64(iterations + 128)
    if original.Cur < needed {
        adjusted := original
        if adjusted.Max < needed { t.Fatalf("fd hard limit %d is below required %d", adjusted.Max, needed) }
        adjusted.Cur = needed
        if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &adjusted); err != nil { t.Fatal(err) }
        defer syscall.Setrlimit(syscall.RLIMIT_NOFILE, &original)
    }
    // Initialize lazy Go runtime poller descriptors before taking baselines.
    f, err := os.CreateTemp("", "interface-resource-warmup-")
    if err != nil { t.Fatal(err) }
    name := f.Name(); f.Close(); os.Remove(name)
    for _, function := range []string{"interfaceTable", "interfaceAddrTable"} {
        for _, scenario := range []string{"success", "empty", "stale_errno", "socket_failure",
            "filtered", "nil_address", "ioctl_failure", "getifaddrs_failure"} {
            t.Run(function+"/"+scenario, func(t *testing.T) {
                fixtureMode = scenario
                allocCalls, allocatedNodes, freeCalls, freedNodes = 0, 0, 0, 0
                liveLists = map[*_C_struct_ifaddrs]int{}
                platform.Cleanup()
                platform.FailIoctl = scenario == "ioctl_failure"
                defer platform.Cleanup()
                before := fdCount(t)
                returnedErrors, wrongResults := 0, 0
                for i := 0; i < iterations; i++ {
                    var saved syscall.Rlimit
                    if scenario == "socket_failure" {
                        if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &saved); err != nil { t.Fatal(err) }
                        lowered := saved; lowered.Cur = 0
                        if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &lowered); err != nil { t.Fatal(err) }
                    }
                    var callErr error
                    var valid bool
                    if function == "interfaceTable" {
                        index := 0
                        if scenario == "filtered" { index = 99 }
                        result, e := interfaceTable(index); callErr = e
                        expectEmpty := scenario == "empty" || scenario == "filtered" || scenario == "nil_address"
                        valid = expectEmpty && len(result) == 0 || !expectEmpty && len(result) == 1 &&
                            result[0].Index == 7 && result[0].MTU == 1500 && result[0].Name == "test0" && len(result[0].HardwareAddr) == 6
                        // The unchanged function intentionally retains unknown
                        // interfaces when index ioctl fails. Only cleanup is at
                        // issue in this compatibility scenario.
                        if scenario == "ioctl_failure" { valid = len(result) == 2 }
                    } else {
                        var ifi *Interface
                        if scenario == "filtered" { ifi = &Interface{Index: 99} }
                        result, e := interfaceAddrTable(ifi); callErr = e
                        expectEmpty := scenario == "empty" || scenario == "filtered" || scenario == "nil_address" || scenario == "ioctl_failure"
                        valid = expectEmpty && len(result) == 0 || !expectEmpty && len(result) == 2 &&
                            result[0].String() == "192.0.2.9/24" && result[1].String() == "2001:db8::9/64"
                    }
                    if scenario == "socket_failure" {
                        // Restore before reporting so testing/logging can open
                        // descriptors even when the function under test fails.
                        if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &saved); err != nil { panic(err) }
                        valid = errors.Is(callErr, syscall.EMFILE)
                    } else if scenario == "getifaddrs_failure" {
                        valid = errors.Is(callErr, syscall.ENOMEM)
                    } else if callErr != nil {
                        returnedErrors++
                    }
                    if !valid { wrongResults++ }
                }
                after := fdCount(t)
                t.Logf("iterations=%d fd_before=%d fd_after=%d getifaddrs=%d frees=%d allocated_nodes=%d freed_nodes=%d socket_calls=%d socket_failures=%d",
                    iterations, before, after, allocCalls, freeCalls, allocatedNodes, freedNodes, platform.SocketCalls, platform.SocketFailures)
                if after != before { t.Errorf("FD leak: before=%d after=%d delta=%d", before, after, after-before) }
                if allocCalls != freeCalls || allocatedNodes != freedNodes || len(liveLists) != 0 {
                    t.Errorf("getifaddrs leak: calls=%d frees=%d nodes=%d freed=%d live_lists=%d",
                        allocCalls, freeCalls, allocatedNodes, freedNodes, len(liveLists))
                }
                if returnedErrors != 0 || wrongResults != 0 {
                    t.Errorf("incorrect result: unexpected_errors=%d wrong_results=%d", returnedErrors, wrongResults)
                }
                expectedSockets := iterations
                if scenario == "getifaddrs_failure" { expectedSockets = 0 }
                if platform.SocketCalls != expectedSockets { t.Errorf("socket calls=%d expected=%d", platform.SocketCalls, expectedSockets) }
                if scenario == "socket_failure" && platform.SocketFailures != iterations { t.Errorf("actual kernel socket failure path was not exercised") }
            })
        }
    }
}
'''


def run(command, **kwargs):
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


def baseline_source(toolchain: Path, temporary: Path) -> tuple[str, str]:
    # Check for the toolchain's own metadata; git would otherwise walk upwards
    # and could return a parent application's unrelated HEAD.
    if (toolchain / ".git").exists():
        result = run(["git", "-C", str(toolchain), "show", f"HEAD:{SUBJECT}"])
        if result.returncode == 0:
            return result.stdout, "toolchain git show HEAD:src/net/interface_table_openharmony.go"
    copy = temporary / "unpatched"
    for relative in [SUBJECT, Path("src/net/cgo_unix_cgo.go")]:
        target = copy / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(toolchain / relative, target)
    result = run(["git", "apply", "--reverse", str(PATCH)], cwd=copy)
    if result.returncode:
        raise RuntimeError("Cannot recover the unpatched negative control:\n" + result.stderr)
    return (copy / SUBJECT).read_text(), "reverse of checked-in patch in isolated toolchain source copy (release has no git metadata)"


def write_harness(directory: Path, source: str):
    directory.mkdir()
    # Preserve function bodies exactly: only the surrounding host build/import
    # environment changes. The adapter never implements their ownership logic.
    source = "\n".join(line for line in source.splitlines() if not line.startswith("//go:build ")) + "\n"
    source = source.replace("package net\n", "package interfacecheck\n", 1)
    source = source.replace('"syscall"', 'syscall "interfacecheck/platform"', 1)
    (directory / "go.mod").write_text("module interfacecheck\n\ngo 1.20\n")
    (directory / "interface_subject.go").write_text(source)
    (directory / "fixture_test.go").write_text(FIXTURE)
    (directory / "resources_test.go").write_text(TEST)
    (directory / "platform").mkdir()
    (directory / "platform/platform.go").write_text(PLATFORM)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", type=Path, default=ROOT / ".toolchain/ohos-go")
    parser.add_argument("--go", type=Path, help="Host Go compiler, default: the toolchain's bin/go")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--race", action="store_true")
    args = parser.parse_args()
    if args.iterations < 100:
        parser.error("--iterations must be at least 100")
    toolchain = args.toolchain.resolve()
    compiler = (args.go or toolchain / "bin/go").resolve()
    env = os.environ.copy()
    for name in ["GOOS", "GOARCH", "GOROOT", "GOFLAGS", "GOWORK", "GOEXPERIMENT"]:
        env.pop(name, None)
    env.update(GOTOOLCHAIN="local", GOPROXY="off", GOWORK="off", INTERFACE_TEST_ITERATIONS=str(args.iterations))
    with tempfile.TemporaryDirectory(prefix="ohos-interface-resources-") as temporary:
        temporary = Path(temporary)
        baseline, provenance = baseline_source(toolchain, temporary)
        patched = (toolchain / SUBJECT).read_text()
        print("Negative-control source:", provenance, flush=True)
        for label, source in [("baseline", baseline), ("patched", patched)]:
            directory = temporary / label
            write_harness(directory, source)
            command = [str(compiler), "test", "-count=1", "-v", "-timeout=60s"]
            if args.race:
                command.append("-race")
            command.append("./...")
            result = run(command, cwd=directory, env=env)
            output = result.stdout + result.stderr
            print(f"\n=== {label} ===\n{output}", end="", flush=True)
            if label == "baseline":
                required = ["FD leak:", "getifaddrs leak:", "--- FAIL: TestInterfaceResources/interfaceTable/socket_failure",
                            "--- FAIL: TestInterfaceResources/interfaceAddrTable/socket_failure",
                            "--- FAIL: TestInterfaceResources/interfaceTable/stale_errno",
                            "--- FAIL: TestInterfaceResources/interfaceAddrTable/stale_errno"]
                if result.returncode == 0 or not all(marker in output for marker in required):
                    raise SystemExit("FAIL: baseline did not reproduce the expected actual-resource regressions")
            elif result.returncode:
                raise SystemExit("FAIL: patched toolchain did not pass resource regression tests")
        print(f"PASS: baseline reproduces leaks; patched functions pass 16 cases × {args.iterations} calls", flush=True)


if __name__ == "__main__":
    main()
