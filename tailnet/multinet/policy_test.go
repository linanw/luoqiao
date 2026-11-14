package multinet

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func TestPolicy(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dlc.dat"), databaseFixture("site", []string{"domain:example.com", "full:only.example.net", "regexp:^video[0-9]+\\.example.net$"}), 0600)
	p, e := Compile(Config{Directory: dir, Profiles: []Profile{{ID: "aaaaaaaa", Lists: []string{"site"}, CIDRs: []string{"10.0.0.0/8"}}, {ID: "bbbbbbbb", Domains: []string{"specific.example.com"}, CIDRs: []string{"10.1.0.0/16"}}}})
	if e != nil {
		t.Fatal(e)
	}
	for name, want := range map[string]string{"www.example.com": "aaaaaaaa", "example.com.evil.net": "", "CHINA.COM.": "", "plain.com": "", "only.example.net": "aaaaaaaa", "sub.only.example.net": "", "video9.example.net": "aaaaaaaa", "specific.example.com": "bbbbbbbb"} {
		if got := p.Domain(name); got != want {
			t.Fatalf("%s: got %s want %s", name, got, want)
		}
	}
	if p.IP(netip.MustParseAddr("10.1.2.3")) != "bbbbbbbb" {
		t.Fatal("longest prefix")
	}
	if _, e := Compile(Config{Directory: dir, Profiles: []Profile{{ID: "aaaaaaaa", Lists: []string{"missing"}}}}); e == nil {
		t.Fatal("missing list accepted")
	}
	if _, e := Compile(Config{Profiles: []Profile{{ID: "aaaaaaaa", Domains: []string{"a.com"}}, {ID: "bbbbbbbb", Domains: []string{"a.com"}}}}); e == nil {
		t.Fatal("ambiguous rule accepted")
	}
}
