#!/usr/bin/env bash
# Build Phinny.app for local development.
#
# Signs with a stable Developer ID identity when one is configured (keeps macOS
# file-access prompts consistent across rebuilds), otherwise falls back to
# ad-hoc ("-"), which always launches locally.
#
# Usage: scripts/build-app.sh [Debug|Release]   (default: Debug)
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/opt/homebrew/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${1:-Debug}"

# Optional signing identity from the gitignored env file.
ENV_FILE=".env.signing.local"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

xcodegen generate
xcodebuild \
    -project Phinny.xcodeproj \
    -scheme Phinny \
    -configuration "$CONFIG" \
    -derivedDataPath .build \
    -skipMacroValidation \
    build

BUILT=".build/Build/Products/$CONFIG/Phinny.app"
mkdir -p dist
rm -rf dist/Phinny.app
cp -R "$BUILT" dist/Phinny.app

# Build the phinny Go engine (universal arm64+x86_64, pure Go / no cgo) and
# bundle it into the app. The app launches it as `phinny serve --stdio` and does
# all of its real work (SQLite, sync, import, categorization, mortgage, Zillow)
# through it. codesign --deep below signs this nested binary as well.
echo "Building phinny engine ..."
ENGINE_DIR=".build/engine"
mkdir -p "$ENGINE_DIR"
( cd cli
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "../$ENGINE_DIR/phinny-arm64" ./cmd/phinny
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -o "../$ENGINE_DIR/phinny-amd64" ./cmd/phinny
)
lipo -create -output "$ENGINE_DIR/phinny" "$ENGINE_DIR/phinny-arm64" "$ENGINE_DIR/phinny-amd64"
mkdir -p dist/Phinny.app/Contents/Resources
cp "$ENGINE_DIR/phinny" dist/Phinny.app/Contents/Resources/phinny
chmod +x dist/Phinny.app/Contents/Resources/phinny

SIGN_IDENTITY="${DEV_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:--}}"
codesign --force --deep --options runtime \
    --entitlements Resources/Phinny.dev.entitlements \
    --sign "$SIGN_IDENTITY" dist/Phinny.app

echo "Built dist/Phinny.app ($CONFIG, signed: $SIGN_IDENTITY)"
echo "Run it with:  open dist/Phinny.app"
