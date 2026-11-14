package multinet

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Decode the small GeoSite protobuf schema without introducing a second protobuf runtime.
type wireField struct {
	num     uint64
	value   []byte
	integer uint64
}

func fields(b []byte) ([]wireField, error) {
	out := []wireField{}
	for len(b) > 0 {
		tag, n := binary.Uvarint(b)
		if n <= 0 || tag>>3 == 0 {
			return nil, errors.New("invalid geosite protobuf")
		}
		b = b[n:]
		f := wireField{num: tag >> 3}
		switch tag & 7 {
		case 0:
			v, n := binary.Uvarint(b)
			if n <= 0 {
				return nil, errors.New("invalid varint")
			}
			f.integer = v
			b = b[n:]
		case 2:
			size, n := binary.Uvarint(b)
			if n <= 0 || size > uint64(len(b)-n) {
				return nil, errors.New("truncated geosite field")
			}
			b = b[n:]
			f.value = b[:int(size)]
			b = b[int(size):]
		case 1:
			if len(b) < 8 {
				return nil, errors.New("truncated fixed64")
			}
			b = b[8:]
		case 5:
			if len(b) < 4 {
				return nil, errors.New("truncated fixed32")
			}
			b = b[4:]
		default:
			return nil, errors.New("unsupported protobuf wire type")
		}
		out = append(out, f)
	}
	return out, nil
}
func parseDatabase(b []byte) (map[string][]string, error) {
	if len(b) == 0 || len(b) > 16*1024*1024 {
		return nil, errors.New("geosite database size invalid")
	}
	root, e := fields(b)
	if e != nil {
		return nil, e
	}
	out := map[string][]string{}
	for _, site := range root {
		if site.num != 1 {
			continue
		}
		sf, e := fields(site.value)
		if e != nil {
			return nil, e
		}
		name := ""
		rules := []string{}
		for _, f := range sf {
			switch f.num {
			case 1:
				name = strings.ToLower(string(f.value))
			case 2:
				df, e := fields(f.value)
				if e != nil {
					return nil, e
				}
				typ := uint64(0)
				value := ""
				for _, d := range df {
					if d.num == 1 {
						typ = d.integer
					}
					if d.num == 2 {
						value = string(d.value)
					}
				}
				prefixes := []string{"keyword:", "regexp:", "domain:", "full:"}
				if typ > 3 || value == "" {
					return nil, errors.New("invalid domain record")
				}
				rules = append(rules, prefixes[typ]+value)
			}
		}
		if !validList.MatchString(name) {
			return nil, fmt.Errorf("invalid list name %q", name)
		}
		out[name] = rules
	}
	if len(out) == 0 {
		return nil, errors.New("empty geosite database")
	}
	return out, nil
}
func readDatabase(dir string) (map[string][]string, error) {
	return readDatabaseFile(filepath.Join(dir, "dlc.dat"))
}
func readConfiguredDatabase(config Config) (map[string][]string, error) {
	if config.DatabasePath == "" {
		return readDatabase(config.Directory)
	}
	if !filepath.IsAbs(config.DatabasePath) {
		return nil, errors.New("session domain database path must be absolute")
	}
	// Never fall back to the live catalog: automatic recovery must use the
	// immutable database selected at the start of this VPN session.
	return readDatabaseFile(config.DatabasePath)
}
func readDatabaseFile(path string) (map[string][]string, error) {
	info, e := os.Stat(path)
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 16*1024*1024 {
		return nil, errors.New("geosite database size invalid")
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	return parseDatabase(b)
}
func DatabaseCatalog(dir string) ([]string, error) {
	db, e := readDatabase(dir)
	if e != nil {
		return nil, e
	}
	names := make([]string, 0, len(db))
	for name := range db {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, nil
}
func InstallDatabase(dir string) error {
	path := filepath.Join(dir, "dlc.dat.download")
	b, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	sum, e := os.ReadFile(filepath.Join(dir, "dlc.dat.sha256.download"))
	if e != nil {
		return e
	}
	parts := strings.Fields(string(sum))
	if len(parts) == 0 {
		return errors.New("missing checksum")
	}
	actual := sha256.Sum256(b)
	if !strings.EqualFold(parts[0], hex.EncodeToString(actual[:])) {
		return errors.New("geosite SHA256 mismatch; retry download")
	}
	if _, e = parseDatabase(b); e != nil {
		return e
	}
	return os.Rename(path, filepath.Join(dir, "dlc.dat"))
}
