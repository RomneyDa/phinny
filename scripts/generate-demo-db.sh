#!/usr/bin/env bash
# Regenerate the bundled demo database (Resources/phinny-demo.sqlite).
#
# Builds the app, then runs it once in generate mode (PHINNY_GENERATE_DEMO),
# which writes the demo SQLite via the real DB code so its schema always matches.
# Commit the resulting Resources/phinny-demo.sqlite.
#
# Usage: scripts/generate-demo-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/opt/homebrew/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

OUT="$PWD/Resources/phinny-demo.sqlite"

./scripts/build-app.sh Debug
echo "Generating $OUT …"
PHINNY_GENERATE_DEMO="$OUT" dist/Phinny.app/Contents/MacOS/Phinny

echo "Done. Demo rows:"
sqlite3 "$OUT" "SELECT 'accounts', COUNT(*) FROM account UNION ALL SELECT 'transactions', COUNT(*) FROM transaction_row;"
