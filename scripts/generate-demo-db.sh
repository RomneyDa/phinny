#!/usr/bin/env bash
# Inspect / validate the bundled demo database (Resources/phinny-demo.sqlite).
#
# NOTE: demo generation moved when the engine was rewritten in Go. The old
# in-app generator (DemoData.swift, PHINNY_GENERATE_DEMO) is preserved under
# archive/ for reference. The committed Resources/phinny-demo.sqlite is a
# GRDB-created database that the Go engine opens directly (its migrations are
# GRDB-compatible), so it is used as-is. Porting the synthesizer to a
# `phinny gen-demo` command is a tracked follow-up (see AGENTS.md).
#
# This script validates that the committed demo DB opens with the Go engine and
# reports its row counts, which is what you usually want after touching schema.
#
# Usage: scripts/generate-demo-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$PWD/Resources/phinny-demo.sqlite"
if [ ! -f "$OUT" ]; then
    echo "Missing $OUT" >&2
    exit 1
fi

echo "Validating $OUT with the Go engine ..."
( cd cli && go build -o /tmp/phinny-validate ./cmd/phinny )
HOME_TMP="$(mktemp -d)"
HOME="$HOME_TMP" /tmp/phinny-validate --demo --demo-source "$OUT" status
rm -rf "$HOME_TMP"

echo "Demo rows:"
sqlite3 "$OUT" "SELECT 'accounts', COUNT(*) FROM account UNION ALL SELECT 'transactions', COUNT(*) FROM transaction_row UNION ALL SELECT 'mortgages', COUNT(*) FROM mortgage;"
