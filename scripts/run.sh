#!/usr/bin/env bash
# Build and run Phinny for local development.
#
# Runs the binary directly (not via `open`) so environment variables from .env -
# notably SIMPLEFIN_TOKEN - reach the app. With a token set, a Debug build
# auto-connects to your real account; otherwise it shows bundled demo data.
#
# Usage: scripts/run.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

# Load dev env (SIMPLEFIN_TOKEN) if present.
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1090
    source .env
    set +a
fi

./scripts/build-app.sh "${1:-Debug}"
echo "Launching dist/Phinny.app/Contents/MacOS/Phinny …"
exec dist/Phinny.app/Contents/MacOS/Phinny
