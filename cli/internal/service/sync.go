package service

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/importer"
	"github.com/RomneyDa/phinny/cli/internal/keychain"
	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/simplefin"
	"github.com/RomneyDa/phinny/cli/internal/store"
)

// Connect claims a setup token, stores the access URL, switches to the real DB,
// and runs a first (forced) sync.
func (s *Service) Connect(setupToken string) error {
	url, err := simplefin.Claim(setupToken)
	if err != nil {
		return err
	}
	if err := keychain.SetAccessURL(url); err != nil {
		return fmt.Errorf("could not save credentials to the Keychain: %w", err)
	}
	if err := s.switchToRealDB(ModeConnected); err != nil {
		return err
	}
	return s.Sync(true)
}

// Disconnect forgets the SimpleFIN connection. Keeps imported data (import-only)
// or falls back to demo/empty.
func (s *Service) Disconnect() error {
	if err := keychain.DeleteAccessURL(); err != nil {
		return err
	}
	if fileExists(s.paths.Database) && s.db != nil && s.mode != ModeDemo && s.db.AccountExists(model.StatementAccountID) {
		s.mode = ModeImportOnly
		return nil
	}
	// Re-evaluate from scratch (demo if a source is available, else empty).
	if s.db != nil {
		s.db.Close()
		s.db = nil
	}
	return s.bootstrap()
}

// switchToRealDB closes any open (e.g. demo) DB and opens the real one.
func (s *Service) switchToRealDB(mode Mode) error {
	if s.db != nil && s.mode == ModeDemo {
		s.db.Close()
		s.db = nil
	}
	if s.db == nil {
		db, err := store.Open(s.paths.Database)
		if err != nil {
			return err
		}
		s.db = db
	}
	s.mode = mode
	return nil
}

// Sync pulls accounts + transactions from SimpleFIN and writes them through the
// upsert path, then records the sync time and re-runs transfer detection.
// RATE-LIMITED: callers must respect the provider's ~24 requests/day budget.
func (s *Service) Sync(force bool) error {
	accessURL := keychain.AccessURL()
	if accessURL == "" {
		return fmt.Errorf("not connected: no SimpleFIN access URL stored (run `phinny connect <token>`)")
	}
	if err := s.switchToRealDB(ModeConnected); err != nil {
		return err
	}
	since := time.Now().AddDate(0, 0, -s.cfg.Sync.HistoryDays)
	res, err := simplefin.Fetch(accessURL, since)
	if err != nil {
		return err
	}
	if err := s.db.Replace(res.Accounts, res.Transactions); err != nil {
		return err
	}
	if err := s.db.SetMeta(lastSyncKey, strconv.FormatInt(time.Now().Unix(), 10)); err != nil {
		return err
	}
	_, _ = s.AutoDetectTransfers()
	return nil
}

// ShouldAutoSync reports whether a launch-time auto-sync is due (stale-only),
// guarding the provider's request budget.
func (s *Service) ShouldAutoSync() (bool, error) {
	n, err := s.db.TransactionCount()
	if err != nil {
		return false, err
	}
	if n == 0 {
		return true, nil
	}
	last := s.LastSync()
	if last == nil {
		return true, nil
	}
	interval := time.Duration(s.cfg.Sync.MinIntervalHours) * time.Hour
	return time.Since(*last) > interval, nil
}

// ImportResult reports an Apple Card import.
type ImportResult struct {
	Imported int    `json:"imported"`
	Message  string `json:"message"`
}

// ImportStatementFile reads and imports an Apple Card statement file.
func (s *Service) ImportStatementFile(path string) (ImportResult, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return ImportResult{}, err
	}
	return s.ImportStatement(data, baseName(path))
}

// ImportStatement parses statement bytes and writes them through the same upsert
// path as a sync. Switches out of demo mode into the real DB on first import.
func (s *Service) ImportStatement(data []byte, filename string) (ImportResult, error) {
	res, err := importer.Parse(data, filename)
	if err != nil {
		return ImportResult{}, err
	}
	mode := s.mode
	if mode == ModeDemo || mode == ModeEmpty {
		mode = ModeImportOnly
	}
	if err := s.switchToRealDB(mode); err != nil {
		return ImportResult{}, err
	}
	if err := s.db.Replace(res.Accounts, res.Transactions); err != nil {
		return ImportResult{}, err
	}
	_, _ = s.AutoDetectTransfers()
	n := len(res.Transactions)
	plural := "s"
	if n == 1 {
		plural = ""
	}
	return ImportResult{Imported: n, Message: fmt.Sprintf("Imported %d Apple Card transaction%s.", n, plural)}, nil
}

func baseName(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[i+1:]
		}
	}
	return p
}

// SetAccountHidden hides or shows an account on the dashboard.
func (s *Service) SetAccountHidden(id string, hidden bool) error {
	return s.db.SetAccountHidden(id, hidden)
}
