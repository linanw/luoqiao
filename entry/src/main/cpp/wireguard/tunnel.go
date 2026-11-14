package main

import (
	"io"
	"net/netip"
	"os"
	"sync"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/tun"
)

// tunRouter owns the system TUN descriptor. It reads inner packets, looks up
// the claiming device in the shared route table and hands the packet to that
// device. Writes from every device are serialized onto the same descriptor.
type tunRouter struct {
	file       *os.File
	fd         int
	wakeReader *os.File
	wakeWriter *os.File
	wakeFD     int
	table      *routeTable
	writeMu    sync.Mutex
	closeOnce  sync.Once
	closed     chan struct{}
}

func newTunRouter(fd int, table *routeTable) (*tunRouter, error) {
	duplicate, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(duplicate), "harmony-vpn-tun")
	reader, writer, err := os.Pipe()
	if err != nil {
		file.Close()
		return nil, err
	}
	if err = unix.SetNonblock(duplicate, true); err != nil {
		file.Close()
		reader.Close()
		writer.Close()
		return nil, err
	}
	return &tunRouter{
		file: file, fd: duplicate, table: table,
		wakeReader: reader, wakeWriter: writer, wakeFD: int(reader.Fd()),
		closed: make(chan struct{}),
	}, nil
}

// newTun creates the per-device TUN endpoint that the WireGuard engine reads
// from and writes to.
func (r *tunRouter) newTun(index int, mtu int) *virtualTun {
	return &virtualTun{
		router:  r,
		index:   index,
		mtu:     mtu,
		packets: make(chan []byte, 1024),
		events:  make(chan tun.Event),
		closed:  make(chan struct{}),
	}
}

// start begins dispatching packets to the per-device channels.
func (r *tunRouter) start(targets []chan []byte) {
	go r.run(targets)
}

func (r *tunRouter) run(targets []chan []byte) {
	buffer := make([]byte, 65536)
	fds := []unix.PollFd{
		{Fd: int32(r.fd), Events: unix.POLLIN},
		{Fd: int32(r.wakeFD), Events: unix.POLLIN},
	}
	for {
		_, err := unix.Poll(fds, -1)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			return
		}
		if fds[1].Revents != 0 {
			return
		}
		if fds[0].Revents&unix.POLLIN == 0 {
			continue
		}
		for {
			n, err := unix.Read(r.fd, buffer)
			if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
				break
			}
			if err == unix.EINTR {
				continue
			}
			if err != nil {
				return
			}
			if n == 0 {
				return
			}
			r.dispatch(buffer[:n], targets)
		}
	}
}

func (r *tunRouter) dispatch(packet []byte, targets []chan []byte) {
	destination, ok := destinationAddress(packet)
	if !ok {
		return
	}
	owner := r.table.lookup(destination)
	if owner < 0 || owner >= len(targets) {
		return
	}
	owned := make([]byte, len(packet))
	copy(owned, packet)
	select {
	case targets[owner] <- owned:
	default:
		// The claiming device is saturated; dropping is safe for UDP traffic.
	}
}

// write sends decrypted packets from a device to the system TUN.
func (r *tunRouter) write(bufs [][]byte, offset int) (int, error) {
	r.writeMu.Lock()
	defer r.writeMu.Unlock()
	for index, buf := range bufs {
		packet := buf[offset:]
		n, err := unix.Write(r.fd, packet)
		for err == unix.EINTR {
			n, err = unix.Write(r.fd, packet)
		}
		if err != nil {
			return index, err
		}
		if n != len(packet) {
			return index, io.ErrShortWrite
		}
	}
	return len(bufs), nil
}

func (r *tunRouter) close() {
	r.closeOnce.Do(func() {
		// Closing the writer wakes Poll before the closed channel broadcast.
		r.wakeWriter.Close()
		close(r.closed)
		r.file.Close()
		r.wakeReader.Close()
	})
}

// virtualTun is the tun.Device each WireGuard engine is bound to.
type virtualTun struct {
	router    *tunRouter
	index     int
	mtu       int
	packets   chan []byte
	events    chan tun.Event
	closed    chan struct{}
	closeOnce sync.Once
}

var _ tun.Device = (*virtualTun)(nil)

func (t *virtualTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	select {
	case packet := <-t.packets:
		sizes[0] = copy(bufs[0][offset:], packet)
		return 1, nil
	case <-t.closed:
		return 0, os.ErrClosed
	case <-t.router.closed:
		return 0, os.ErrClosed
	}
}

func (t *virtualTun) Write(bufs [][]byte, offset int) (int, error) {
	select {
	case <-t.closed:
		return 0, os.ErrClosed
	case <-t.router.closed:
		return 0, os.ErrClosed
	default:
	}
	return t.router.write(bufs, offset)
}

func (t *virtualTun) Close() error {
	t.closeOnce.Do(func() {
		close(t.closed)
		close(t.events)
	})
	return nil
}

func (t *virtualTun) File() *os.File           { return t.router.file }
func (t *virtualTun) MTU() (int, error)        { return t.mtu, nil }
func (*virtualTun) Name() (string, error)      { return "harmony-vpn-tun", nil }
func (t *virtualTun) Events() <-chan tun.Event { return t.events }
func (*virtualTun) BatchSize() int             { return 1 }

// routeTableOwner is retained for tests to inspect dispatch decisions.
func routeTableOwner(table *routeTable, destination netip.Addr) int {
	return table.lookup(destination)
}
