// Package service is Phinny's orchestration layer: the Go equivalent of
// AppState.swift. It owns the config + database, chooses the mode (demo /
// connected / import-only), runs syncs and imports, and exposes every mutation
// and query the CLI and daemon surface. Views (Swift) and agents (CLI) are
// read-only/RPC consumers of this layer; all mutable logic lives here.
package service

import (
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/config"
	"github.com/RomneyDa/phinny/cli/internal/keychain"
	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/store"
)

const lastSyncKey = "last_sync_at"

// Mode is the data mode, mirroring AppState's phases.
type Mode string

const (
	ModeDemo       Mode = "demo"        // bundled sample data, no network
	ModeConnected  Mode = "connected"   // a SimpleFIN access URL is in the Keychain
	ModeImportOnly Mode = "import-only" // real DB from an Apple Card import, nothing to sync
	ModeEmpty      Mode = "empty"       // no data and no demo source (pure CLI, not connected)
)

// Options configure how the service opens.
type Options struct {
	// DBPath overrides the database file (default ~/.phinny/phinny.sqlite).
	DBPath string
	// DemoSource is the bundled demo .sqlite the app provides; enables demo mode
	// when nothing is connected. Empty for pure CLI use.
	DemoSource string
	// ForceDemo opens demo data regardless of any connected account.
	ForceDemo bool
}

// Service is the live orchestration object.
type Service struct {
	paths config.Paths
	cfg   config.Config
	db    *store.DB
	mode  Mode
	opts  Options
}

// Open builds a Service and selects the mode (mirrors AppState.bootstrap).
func Open(opts Options) (*Service, error) {
	paths := config.DefaultPaths()
	if opts.DBPath != "" {
		paths.Database = opts.DBPath
	}
	s := &Service{paths: paths, cfg: config.Load(paths), opts: opts}
	if err := s.bootstrap(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Service) bootstrap() error {
	// Materialize config.yaml on first run so settings are discoverable.
	if _, err := os.Stat(s.paths.Config); os.IsNotExist(err) {
		_ = config.Save(s.paths, s.cfg)
	}

	if s.opts.ForceDemo {
		return s.enterDemo()
	}
	if keychain.HasAccessURL() {
		return s.enterConnected(ModeConnected)
	}
	// No token but a real DB exists with an Apple Card import -> import-only.
	if fileExists(s.paths.Database) {
		if db, err := store.Open(s.paths.Database); err == nil {
			if db.AccountExists(model.StatementAccountID) {
				s.db = db
				s.mode = ModeImportOnly
				return nil
			}
			db.Close()
		}
	}
	if s.opts.DemoSource != "" {
		return s.enterDemo()
	}
	// Pure CLI with nothing connected: open the real DB if present, else empty.
	if fileExists(s.paths.Database) {
		return s.enterConnected(ModeImportOnly)
	}
	db, err := store.Open(s.paths.Database)
	if err != nil {
		return err
	}
	s.db = db
	s.mode = ModeEmpty
	return nil
}

func (s *Service) enterConnected(mode Mode) error {
	db, err := store.Open(s.paths.Database)
	if err != nil {
		return err
	}
	s.db = db
	s.mode = mode
	return nil
}

func (s *Service) enterDemo() error {
	if err := s.prepareDemoCopy(); err != nil {
		return err
	}
	db, err := store.Open(s.paths.DemoCopy)
	if err != nil {
		return err
	}
	s.db = db
	s.mode = ModeDemo
	return nil
}

// prepareDemoCopy copies the bundled demo DB to a writable location, overwriting
// any previous copy so it stays fresh.
func (s *Service) prepareDemoCopy() error {
	if err := s.paths.EnsureDir(); err != nil {
		return err
	}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		_ = os.Remove(s.paths.DemoCopy + suffix)
	}
	return copyFile(s.opts.DemoSource, s.paths.DemoCopy)
}

// Close releases the database.
func (s *Service) Close() error {
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// Mode returns the current data mode.
func (s *Service) Mode() Mode { return s.mode }

// Connected reports whether a SimpleFIN access URL is stored.
func (s *Service) Connected() bool { return keychain.HasAccessURL() }

// IsImportOnly reports a real DB with imported data but no connected account.
func (s *Service) IsImportOnly() bool { return s.mode == ModeImportOnly }

// Writable reports whether mutations persist (everything except the demo copy
// is the real DB; demo writes are allowed but live only in the throwaway copy).
func (s *Service) Writable() bool { return s.db != nil }

// LastSync returns the recorded last sync time, or nil.
func (s *Service) LastSync() *time.Time {
	raw, ok, err := s.db.Meta(lastSyncKey)
	if err != nil || !ok {
		return nil
	}
	secs, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return nil
	}
	t := time.Unix(int64(secs), 0)
	return &t
}

// Config returns the loaded config.
func (s *Service) Config() config.Config { return s.cfg }

// SetConfig updates and persists the config.
func (s *Service) SetConfig(cfg config.Config) error {
	if cfg.Sync.MinIntervalHours <= 0 {
		cfg.Sync.MinIntervalHours = s.cfg.Sync.MinIntervalHours
	}
	if cfg.Sync.HistoryDays <= 0 {
		cfg.Sync.HistoryDays = s.cfg.Sync.HistoryDays
	}
	s.cfg = cfg
	return config.Save(s.paths, cfg)
}

// DB exposes the underlying store for read commands.
func (s *Service) DB() *store.DB { return s.db }

// ---- small helpers ------------------------------------------------------

func (s *Service) now() time.Time   { return time.Now() }
func (s *Service) epoch() int64     { return time.Now().Unix() }
func newID() string                 { return uuidV4() }

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("bundled demo database is missing: %w", err)
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

// uuidV4 generates a random RFC-4122 v4 UUID (uppercase, matching Swift's
// UUID().uuidString style) without an external dependency.
func uuidV4() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	const hex = "0123456789ABCDEF"
	buf := make([]byte, 36)
	j := 0
	for i := 0; i < 16; i++ {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			buf[j] = '-'
			j++
		}
		buf[j] = hex[b[i]>>4]
		buf[j+1] = hex[b[i]&0x0f]
		j += 2
	}
	return string(buf)
}
