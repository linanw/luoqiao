package tailnet

import (
	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"sync"
	"sync/atomic"
)

// Tunnel waits for the VPN descriptor while the control plane authenticates.
// The duplicate belongs to this object; the original belongs to HarmonyOS.
type Tunnel struct {
	dnsResponse atomic.Value
	dnsQuery    atomic.Value
	readError   atomic.Value
	writeError  atomic.Value
	sent        atomic.Uint64
	received    atomic.Uint64
	mu          sync.Mutex
	file        *os.File
	ready       chan struct{}
	done        chan struct{}
	events      chan tun.Event
	once        sync.Once
}

func NewTunnel() *Tunnel {
	return &Tunnel{ready: make(chan struct{}), done: make(chan struct{}), events: make(chan tun.Event, 1)}
}
func (t *Tunnel) Attach(fd int) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	select {
	case <-t.done:
		return os.ErrClosed
	default:
	}
	if t.file != nil {
		return os.ErrExist
	}
	n, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return err
	}
	if err = unix.SetNonblock(n, true); err != nil {
		unix.Close(n)
		return err
	}
	t.file = os.NewFile(uintptr(n), "tailnet-tun")
	close(t.ready)
	t.events <- tun.EventUp
	return nil
}
func (t *Tunnel) wait() (*os.File, error) {
	select {
	case <-t.done:
		return nil, os.ErrClosed
	case <-t.ready:
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.file, nil
}
func (t *Tunnel) File() *os.File           { t.mu.Lock(); defer t.mu.Unlock(); return t.file }
func (t *Tunnel) Name() (string, error)    { return "tailnet", nil }
func (t *Tunnel) MTU() (int, error)        { return 1280, nil }
func (t *Tunnel) BatchSize() int           { return 1 }
func (t *Tunnel) Events() <-chan tun.Event { return t.events }
func (t *Tunnel) Read(b [][]byte, s []int, o int) (int, error) {
	f, e := t.wait()
	if e != nil {
		return 0, e
	}
	n, e := f.Read(b[0][o:])
	if e != nil {
		t.readError.Store(e.Error())
		return 0, e
	}
	if observation, ok := observeMagicDNS(b[0][o : o+n]); ok && !observation.Response {
		t.dnsQuery.Store(observation)
	}
	t.sent.Add(uint64(n))
	s[0] = n
	return 1, nil
}
func (t *Tunnel) Write(b [][]byte, o int) (int, error) {
	f, e := t.wait()
	if e != nil {
		return 0, e
	}
	for i, p := range b {
		n, e := f.Write(p[o:])
		if e != nil {
			t.writeError.Store(e.Error())
			return i, e
		}
		if observation, ok := observeMagicDNS(p[o:]); ok && observation.Response {
			t.dnsResponse.Store(observation)
		}
		t.received.Add(uint64(n))
		if n != len(p)-o {
			return i, io.ErrShortWrite
		}
	}
	return len(b), nil
}
func (t *Tunnel) Close() error {
	t.once.Do(func() {
		t.mu.Lock()
		defer t.mu.Unlock()
		close(t.done)
		if t.file != nil {
			t.file.Close()
		}
		close(t.events)
	})
	return nil
}

func (t *Tunnel) Stats() (uint64, uint64) { return t.sent.Load(), t.received.Load() }

func (t *Tunnel) Errors() (string, string) {
	r, w := "", ""
	if v := t.readError.Load(); v != nil {
		r = v.(string)
	}
	if v := t.writeError.Load(); v != nil {
		w = v.(string)
	}
	return r, w
}

func (t *Tunnel) DNSResponse() DNSObservation {
	if v := t.dnsResponse.Load(); v != nil {
		return v.(DNSObservation)
	}
	return DNSObservation{}
}

func (t *Tunnel) DNSQuery() DNSObservation {
	if v := t.dnsQuery.Load(); v != nil {
		return v.(DNSObservation)
	}
	return DNSObservation{}
}
