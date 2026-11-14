package tailnet

import (
	"bytes"
	"errors"
	"golang.org/x/sys/unix"
	"os"
	"testing"
	"time"
)

func TestCloseUnblocksUnattachedRead(t *testing.T) {
	d := NewTunnel()
	done := make(chan error, 1)
	go func() { _, e := d.Read([][]byte{make([]byte, 1500)}, make([]int, 1), 0); done <- e }()
	d.Close()
	select {
	case e := <-done:
		if !errors.Is(e, os.ErrClosed) {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("read remained blocked")
	}
	if d.Attach(-1) == nil {
		t.Fatal("attach after close succeeded")
	}
	d.Close()
}
func TestInvalidDescriptor(t *testing.T) {
	d := NewTunnel()
	defer d.Close()
	if d.Attach(-1) == nil {
		t.Fatal("invalid descriptor accepted")
	}
}

func TestTunnelTransfersPackets(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	d := NewTunnel()
	defer d.Close()
	if err = d.Attach(fds[0]); err != nil {
		t.Fatal(err)
	}
	packet := []byte{0x45, 0, 0, 4}
	if _, err = unix.Write(fds[1], packet); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 1500)
	sizes := make([]int, 1)
	if n, err := d.Read([][]byte{buf}, sizes, 16); n != 1 || err != nil {
		t.Fatalf("read: %d %v", n, err)
	}
	if !bytes.Equal(buf[16:16+sizes[0]], packet) {
		t.Fatal("outbound packet changed")
	}
	if n, err := d.Write([][]byte{buf[:16+sizes[0]]}, 16); n != 1 || err != nil {
		t.Fatalf("write: %d %v", n, err)
	}
	sent, received := d.Stats()
	if sent != uint64(len(packet)) || received != uint64(len(packet)) {
		t.Fatalf("stats = %d/%d", sent, received)
	}
	readError, writeError := d.Errors()
	if readError != "" || writeError != "" {
		t.Fatalf("unexpected errors: %s/%s", readError, writeError)
	}
	n, err := unix.Read(fds[1], buf)
	if err != nil || !bytes.Equal(buf[:n], packet) {
		t.Fatalf("inbound packet: %v", err)
	}
}
