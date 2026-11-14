package multinet

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func bytesField(num byte, b []byte) []byte {
	out := []byte{num<<3 | 2}
	out = binary.AppendUvarint(out, uint64(len(b)))
	return append(out, b...)
}
func databaseFixture(name string, rules []string) []byte {
	site := bytesField(1, []byte(name))
	for _, rule := range rules {
		parts := strings.SplitN(rule, ":", 2)
		typ := map[string]byte{"keyword": 0, "regexp": 1, "domain": 2, "full": 3}[parts[0]]
		d := append([]byte{8, typ}, bytesField(2, []byte(parts[1]))...)
		site = append(site, bytesField(2, d)...)
	}
	return bytesField(1, site)
}
func TestDatabaseValidation(t *testing.T) {
	data := databaseFixture("google", []string{"domain:google.com", "full:example.com", "regexp:^A\\D+$"})
	db, e := parseDatabase(data)
	if e != nil || len(db["google"]) != 3 {
		t.Fatal(db, e)
	}
	for n := 0; n < len(data); n++ {
		if _, e := parseDatabase(data[:n]); e == nil {
			t.Fatalf("accepted truncated data at %d", n)
		}
	}
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dlc.dat.download"), data, 0600)
	os.WriteFile(filepath.Join(dir, "dlc.dat.sha256.download"), []byte("wrong"), 0600)
	if InstallDatabase(dir) == nil {
		t.Fatal("accepted invalid checksum")
	}
	sum := sha256.Sum256(data)
	os.WriteFile(filepath.Join(dir, "dlc.dat.sha256.download"), []byte(fmt.Sprintf("%x dlc.dat", sum)), 0600)
	if e := InstallDatabase(dir); e != nil {
		t.Fatal(e)
	}
	if source := os.Getenv("GEOSITE_TEST_DATABASE"); source != "" {
		b, e := os.ReadFile(source)
		if e != nil {
			t.Fatal(e)
		}
		db, e := parseDatabase(b)
		if e != nil || len(db) < 1000 {
			t.Fatal(len(db), e)
		}
		t.Logf("validated %d upstream lists", len(db))
	}
}

func TestSessionDatabasePathFreezesRulesAcrossAutomaticRecovery(t *testing.T) {
	dir := t.TempDir()
	snapshot := filepath.Join(t.TempDir(), "dlc.dat")
	old := databaseFixture("site", []string{"domain:old.example"})
	if err := os.WriteFile(snapshot, old, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dlc.dat"), old, 0600); err != nil {
		t.Fatal(err)
	}
	config := Config{Directory: dir, DatabasePath: snapshot, Profiles: []Profile{{ID: "aaaaaaaa", Lists: []string{"site"}}}}
	first, err := Compile(config)
	if err != nil {
		t.Fatal(err)
	}
	if first.Domain("old.example") != "aaaaaaaa" || !strings.Contains(first.DescribeDomain("old.example"), "域名库 site") {
		t.Fatal("snapshot rule or description missing")
	}
	if err := os.WriteFile(filepath.Join(dir, "dlc.dat"), databaseFixture("site", []string{"domain:new.example"}), 0600); err != nil {
		t.Fatal(err)
	}
	recovered, err := Compile(config)
	if err != nil {
		t.Fatal(err)
	}
	if recovered.Domain("old.example") != "aaaaaaaa" || recovered.Domain("new.example") != "" {
		t.Fatal("automatic recovery loaded edited live rules")
	}
	config.DatabasePath = ""
	nextSession, err := Compile(config)
	if err != nil || nextSession.Domain("new.example") != "aaaaaaaa" {
		t.Fatal("new manual session did not load current catalog", err)
	}
	for _, path := range []string{"relative/dlc.dat", filepath.Join(dir, "missing.dat")} {
		config.DatabasePath = path
		if _, err := Compile(config); err == nil {
			t.Fatal("bad snapshot silently fell back to live catalog")
		}
	}
}
