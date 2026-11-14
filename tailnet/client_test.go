package tailnet

import "testing"

func TestConfigValidation(t *testing.T) {
	for _, endpoint := range []string{"", "https://controlplane.tailscale.com", "https://headscale.example.com"} {
		if err := (Config{StateDir: "/private/node", Hostname: "harmony", ControlURL: endpoint}).Validate(); err != nil {
			t.Fatal(err)
		}
	}
	for _, endpoint := range []string{"http://headscale.example.com", "https://user:secret@example.com", "https://example.com?token=secret", "https://", "ftp://example.com"} {
		if err := (Config{StateDir: "/private/node", Hostname: "harmony", ControlURL: endpoint}).Validate(); err == nil {
			t.Errorf("accepted %q", endpoint)
		}
	}
	for _, c := range []Config{{StateDir: "relative", Hostname: "harmony"}, {StateDir: "/private/node"}} {
		if c.Validate() == nil {
			t.Fatal("accepted invalid configuration")
		}
	}
}
