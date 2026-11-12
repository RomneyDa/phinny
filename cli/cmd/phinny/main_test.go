package main

import (
	"reflect"
	"testing"
)

// The regression this guards: the app launches the engine as
// `serve --stdio --demo-source <path> --demo`, so global flags arrive after the
// command. Dropping them made the daemon open the real database instead of the
// demo one, and left a first run with no account on an empty dashboard.
func TestParseGlobalsAfterCommand(t *testing.T) {
	opts, rest, help := parseGlobals([]string{
		"serve", "--stdio", "--demo-source", "/tmp/demo.sqlite", "--demo",
	})

	if help {
		t.Fatal("wantHelp = true, want false")
	}
	if !opts.ForceDemo {
		t.Error("ForceDemo = false, want true")
	}
	if opts.DemoSource != "/tmp/demo.sqlite" {
		t.Errorf("DemoSource = %q, want /tmp/demo.sqlite", opts.DemoSource)
	}
	if want := []string{"serve", "--stdio"}; !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %v, want %v", rest, want)
	}
}

func TestParseGlobalsBeforeCommand(t *testing.T) {
	opts, rest, _ := parseGlobals([]string{
		"--db", "/tmp/x.sqlite", "--demo", "status",
	})

	if opts.DBPath != "/tmp/x.sqlite" {
		t.Errorf("DBPath = %q, want /tmp/x.sqlite", opts.DBPath)
	}
	if !opts.ForceDemo {
		t.Error("ForceDemo = false, want true")
	}
	if want := []string{"status"}; !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %v, want %v", rest, want)
	}
}

// Both spellings have to produce the same options, since the docs show one and
// the app sends the other.
func TestParseGlobalsOrderIndependent(t *testing.T) {
	before, restBefore, _ := parseGlobals([]string{"--db", "/tmp/x.sqlite", "dashboard"})
	after, restAfter, _ := parseGlobals([]string{"dashboard", "--db", "/tmp/x.sqlite"})

	if before != after {
		t.Errorf("options differ by flag position: %+v vs %+v", before, after)
	}
	if !reflect.DeepEqual(restBefore, restAfter) {
		t.Errorf("rest differs: %v vs %v", restBefore, restAfter)
	}
}

// Subcommand flags must survive; only the global ones get consumed.
func TestParseGlobalsLeavesCommandFlags(t *testing.T) {
	opts, rest, _ := parseGlobals([]string{
		"transactions", "--limit", "20", "--account", "acct-1", "--db", "/tmp/x.sqlite",
	})

	if opts.DBPath != "/tmp/x.sqlite" {
		t.Errorf("DBPath = %q, want /tmp/x.sqlite", opts.DBPath)
	}
	want := []string{"transactions", "--limit", "20", "--account", "acct-1"}
	if !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %v, want %v", rest, want)
	}
}

// serve looks for --http in what it is handed, so that must still be there.
func TestParseGlobalsKeepsServeFlags(t *testing.T) {
	_, rest, _ := parseGlobals([]string{"serve", "--http", "127.0.0.1:8765"})
	want := []string{"serve", "--http", "127.0.0.1:8765"}
	if !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %v, want %v", rest, want)
	}
}

func TestParseGlobalsHelp(t *testing.T) {
	for _, arg := range []string{"-h", "--help", "help"} {
		if _, _, help := parseGlobals([]string{arg}); !help {
			t.Errorf("parseGlobals(%q) wantHelp = false, want true", arg)
		}
	}
	// -h and --help are global anywhere.
	if _, _, help := parseGlobals([]string{"mortgage", "--help"}); !help {
		t.Error("`mortgage --help` wantHelp = false, want true")
	}
	// A bare "help" after a command is an ordinary argument, so a category can
	// legitimately be named "help".
	_, rest, help := parseGlobals([]string{"categories", "add", "help"})
	if help {
		t.Error("`categories add help` was treated as the help flag")
	}
	if want := []string{"categories", "add", "help"}; !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %v, want %v", rest, want)
	}
}

// A trailing flag with no value must not be silently swallowed.
func TestParseGlobalsDanglingValueFlag(t *testing.T) {
	opts, rest, _ := parseGlobals([]string{"status", "--db"})
	if opts.DBPath != "" {
		t.Errorf("DBPath = %q, want empty", opts.DBPath)
	}
	if want := []string{"status", "--db"}; !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %v, want %v", rest, want)
	}
}
