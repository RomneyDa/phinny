// Package keychain stores the SimpleFIN access URL (which embeds read-only bank
// credentials) in the macOS login Keychain, never on disk in plaintext (mirrors
// Keychain.swift). It shells out to /usr/bin/security so it interoperates with
// the generic-password item the Swift app used: same service + account.
//
// An item the CLI writes is created by the `security` tool, so subsequent CLI
// reads round-trip without a prompt. An item the legacy Swift app created is
// owned by Phinny.app, so the first CLI read of it may prompt once; re-saving
// through the CLI clears that.
package keychain

import (
	"os"
	"os/exec"
	"strings"
)

const (
	service = "com.dallinromney.phinny"
	account = "simplefin-access-url"
)

// AccessURL returns the stored access URL, or "" if none is saved. An env
// override (PHINNY_ACCESS_URL) wins, for headless/testing without the Keychain.
func AccessURL() string {
	if v := strings.TrimSpace(os.Getenv("PHINNY_ACCESS_URL")); v != "" {
		return v
	}
	out, err := exec.Command("security", "find-generic-password",
		"-s", service, "-a", account, "-w").Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\r\n")
}

// HasAccessURL reports whether an access URL is stored.
func HasAccessURL() bool { return AccessURL() != "" }

// SetAccessURL stores (replacing) the access URL.
func SetAccessURL(value string) error {
	// Delete any existing item first so the new one is cleanly owned by the
	// security tool (clears a legacy app-owned ACL that would otherwise prompt).
	_ = exec.Command("security", "delete-generic-password",
		"-s", service, "-a", account).Run()
	return exec.Command("security", "add-generic-password",
		"-U", "-s", service, "-a", account,
		"-D", "Phinny SimpleFIN access URL",
		"-w", value).Run()
}

// DeleteAccessURL removes the stored access URL (used by "disconnect").
func DeleteAccessURL() error {
	err := exec.Command("security", "delete-generic-password",
		"-s", service, "-a", account).Run()
	if err != nil {
		// Treat "not found" as success.
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 44 {
			return nil
		}
	}
	return err
}
