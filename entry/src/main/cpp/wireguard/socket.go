package main

import (
	"errors"
	"net"
	"net/netip"
	"os"
	"sync"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
)

// The VPN extension protects the bound socket before start. Reusing a duplicate
// of that descriptor preserves the platform's VPN exclusion on outgoing packets.
func openSocket(port int) (int, error) {
	udp, err := net.ListenUDP("udp", &net.UDPAddr{Port: port})
	if err != nil {
		return -1, err
	}
	defer udp.Close()

	raw, err := udp.SyscallConn()
	if err != nil {
		return -1, err
	}
	var fd int
	var dupErr error
	if err := raw.Control(func(original uintptr) {
		fd, dupErr = unix.FcntlInt(original, unix.F_DUPFD_CLOEXEC, 0)
	}); err != nil {
		return -1, err
	}
	return fd, dupErr
}

func duplicateProtectedUDP(fd int) (*net.UDPConn, error) {
	duplicate, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(duplicate), "protected-wireguard-socket")
	defer file.Close()
	packet, err := net.FilePacketConn(file)
	if err != nil {
		return nil, err
	}
	udp, ok := packet.(*net.UDPConn)
	if !ok {
		packet.Close()
		return nil, errors.New("expected UDP socket")
	}
	return udp, nil
}
func newProtectedBind(fd int) (*protectedBind, error) {
	udp, err := duplicateProtectedUDP(fd)
	if err != nil {
		return nil, err
	}
	return &protectedBind{prepared: udp}, nil
}

// queueReplacement transfers ownership to the bind. BindUpdate closes the old
// reader before Open consumes this already-protected descriptor.
func (b *protectedBind) queueReplacement(udp *net.UDPConn) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.prepared != nil {
		b.prepared.Close()
	}
	b.prepared = udp
}
func (b *protectedBind) discardPrepared() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.prepared != nil {
		b.prepared.Close()
		b.prepared = nil
	}
}

type protectedBind struct {
	mu       sync.Mutex
	prepared *net.UDPConn
	active   *net.UDPConn
}

var _ conn.Bind = (*protectedBind)(nil)

func (b *protectedBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.active != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	udp := b.prepared
	if udp == nil {
		return nil, 0, net.ErrClosed
	}
	actual := uint16(udp.LocalAddr().(*net.UDPAddr).Port)
	if port != 0 && port != actual {
		return nil, 0, errors.New("listen port differs from the protected socket")
	}
	b.active, b.prepared = udp, nil
	return []conn.ReceiveFunc{func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		n, from, err := udp.ReadFromUDPAddrPort(packets[0])
		if err != nil {
			return 0, err
		}
		sizes[0] = n
		eps[0] = &conn.StdNetEndpoint{AddrPort: netip.AddrPortFrom(from.Addr().Unmap(), from.Port())}
		return 1, nil
	}}, actual, nil
}

func (b *protectedBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.active == nil {
		return nil
	}
	udp := b.active
	b.active = nil
	return udp.Close()
}

func (b *protectedBind) dispose() {
	_ = b.Close()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.prepared != nil {
		_ = b.prepared.Close()
		b.prepared = nil
	}
}

func (*protectedBind) SetMark(mark uint32) error {
	if mark != 0 {
		return errors.New("the VPN extension manages socket routing")
	}
	return nil
}

func (b *protectedBind) Send(bufs [][]byte, endpoint conn.Endpoint) error {
	ep, ok := endpoint.(*conn.StdNetEndpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	b.mu.Lock()
	udp := b.active
	b.mu.Unlock()
	if udp == nil {
		return net.ErrClosed
	}
	for _, buf := range bufs {
		if _, err := udp.WriteToUDPAddrPort(buf, ep.AddrPort); err != nil {
			return err
		}
	}
	return nil
}

func (*protectedBind) ParseEndpoint(value string) (conn.Endpoint, error) {
	address, err := netip.ParseAddrPort(value)
	if err != nil {
		return nil, err
	}
	return &conn.StdNetEndpoint{AddrPort: address}, nil
}

func (*protectedBind) BatchSize() int { return 1 }
