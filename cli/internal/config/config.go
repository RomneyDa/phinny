// Package config owns Phinny's ~/.phinny paths and the non-sensitive config.yaml
// (mirrors Config.swift). Credentials never live here; they go in the Keychain.
package config

import (
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Paths under ~/.phinny.
type Paths struct {
	Dir      string
	Config   string
	Database string
	DemoCopy string
}

// DefaultPaths resolves ~/.phinny locations for the current user.
func DefaultPaths() Paths {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	dir := filepath.Join(home, ".phinny")
	return Paths{
		Dir:      dir,
		Config:   filepath.Join(dir, "config.yaml"),
		Database: filepath.Join(dir, "phinny.sqlite"),
		DemoCopy: filepath.Join(dir, "phinny-demo.sqlite"),
	}
}

// EnsureDir creates ~/.phinny (0700) if needed.
func (p Paths) EnsureDir() error {
	if _, err := os.Stat(p.Dir); os.IsNotExist(err) {
		return os.MkdirAll(p.Dir, 0o700)
	}
	return nil
}

// Sync settings (the on-disk YAML). snake_case keys match config.yaml.
type Sync struct {
	MinIntervalHours int `yaml:"min_interval_hours" json:"min_interval_hours"`
	HistoryDays      int `yaml:"history_days" json:"history_days"`
}

// Config is the on-disk config.yaml.
type Config struct {
	Sync Sync `yaml:"sync" json:"sync"`
}

// Default returns the built-in defaults.
func Default() Config {
	return Config{Sync: Sync{MinIntervalHours: 6, HistoryDays: 365}}
}

// Load reads config.yaml, falling back to defaults on any error (first run).
func Load(p Paths) Config {
	data, err := os.ReadFile(p.Config)
	if err != nil {
		return Default()
	}
	cfg := Default()
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Default()
	}
	if cfg.Sync.MinIntervalHours == 0 {
		cfg.Sync.MinIntervalHours = 6
	}
	if cfg.Sync.HistoryDays == 0 {
		cfg.Sync.HistoryDays = 365
	}
	return cfg
}

// Save writes config.yaml with 0600 permissions.
func Save(p Paths, cfg Config) error {
	if err := p.EnsureDir(); err != nil {
		return err
	}
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	if err := os.WriteFile(p.Config, data, 0o600); err != nil {
		return err
	}
	return os.Chmod(p.Config, 0o600)
}
