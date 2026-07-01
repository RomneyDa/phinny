#!/usr/bin/env bash
# Build, Developer ID-sign, notarize, and staple Phinny for distribution.
# Produces a drag-to-Applications Phinny.dmg (primary) plus Phinny.zip.
#
# Credentials come from .env.signing.local (gitignored) locally, or from the
# environment (GitHub Actions secrets) in CI. Mirrors the sibling Spurkle app.
#
# Usage: scripts/build-signed-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/opt/homebrew/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ENV_FILE=".env.signing.local"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION (.env.signing.local or env)}"
: "${APPLE_ID:?Set APPLE_ID}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Set APPLE_APP_SPECIFIC_PASSWORD}"

xcodegen generate
xcodebuild \
    -project Phinny.xcodeproj \
    -scheme Phinny \
    -configuration Release \
    -derivedDataPath .build \
    -skipMacroValidation \
    build

mkdir -p dist
rm -rf dist/Phinny.app
cp -R ".build/Build/Products/Release/Phinny.app" dist/Phinny.app
APP="dist/Phinny.app"

# Build + bundle the phinny Go engine (universal, pure Go / no cgo). The app
# launches it as `phinny serve --stdio`. It must be signed with the hardened
# runtime + a secure timestamp for notarization to pass.
echo "Building phinny engine ..."
ENGINE_DIR=".build/engine"
mkdir -p "$ENGINE_DIR"
( cd cli
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "../$ENGINE_DIR/phinny-arm64" ./cmd/phinny
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -o "../$ENGINE_DIR/phinny-amd64" ./cmd/phinny
)
lipo -create -output "$ENGINE_DIR/phinny" "$ENGINE_DIR/phinny-arm64" "$ENGINE_DIR/phinny-amd64"
mkdir -p "$APP/Contents/Resources"
cp "$ENGINE_DIR/phinny" "$APP/Contents/Resources/phinny"
chmod +x "$APP/Contents/Resources/phinny"
codesign --force --options runtime --timestamp \
    -s "$DEVELOPER_ID_APPLICATION" "$APP/Contents/Resources/phinny"

# Sign embedded frameworks/dylibs first (SPM links statically, so usually a
# no-op), then the app bundle with the hardened runtime.
if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 \
        | while IFS= read -r -d '' item; do
            codesign --force --options runtime --timestamp -s "$DEVELOPER_ID_APPLICATION" "$item"
        done
fi

codesign --force --deep --options runtime --timestamp \
    --entitlements "Resources/Phinny.dmg.entitlements" \
    -s "$DEVELOPER_ID_APPLICATION" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Build the DMG (drag-to-Applications) ---
DMG="dist/Phinny.dmg"
STAGE="dist/dmg-stage"
rm -f "$DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Phinny.app"

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "Phinny" \
        --window-size 500 340 \
        --icon-size 110 \
        --icon "Phinny.app" 130 165 \
        --app-drop-link 370 165 \
        --hide-extension "Phinny.app" \
        --no-internet-enable \
        "$DMG" "$STAGE" || true
fi
if [ ! -f "$DMG" ]; then
    echo "create-dmg unavailable or failed - falling back to hdiutil."
    hdiutil create -volname "Phinny" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
rm -rf "$STAGE"

codesign --force --timestamp -s "$DEVELOPER_ID_APPLICATION" "$DMG"

echo "Submitting DMG to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

# Staple the DMG and the app (works offline after drag-out).
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

ZIP="dist/Phinny.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl -a -vvv --type exec "$APP" || true
spctl -a -t open --context context:primary-signature -vvv "$DMG" || true
echo "Done: $DMG (+ $APP, $ZIP)"
