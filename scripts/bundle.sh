#!/usr/bin/env bash
# Build the SwiftPM executable and assemble it into a proper .app bundle.
# A real bundle (with Info.plist + bundle id) is required for the status-bar
# accessory behavior and for Now Playing / media-key registration to work.
#
# Signing:
#   - If SIGN_IDENTITY is set (e.g. "Developer ID Application: Name (TEAMID)"),
#     the app is signed with that identity + hardened runtime + secure timestamp,
#     which is what notarization requires.
#   - Otherwise it falls back to an ad-hoc signature so local builds still run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Reed.app"
BUNDLE_ID="co.kobylinski.reed"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/Reed"

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reed"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Reed</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Reed</string>
    <key>CFBundleDisplayName</key><string>Reed</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}.oauth</string>
            <key>CFBundleURLSchemes</key>
            <array><string>reed</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> codesign (Developer ID + hardened runtime)"
    echo "    identity: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP/Contents/MacOS/Reed"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP"
    echo "==> verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    echo "==> ad-hoc codesign (no SIGN_IDENTITY set — local build)"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || \
        echo "   (codesign skipped/failed — local run still works)"
fi

echo "==> done: $APP"
echo "    run with: open \"$APP\"   (or)   \"$APP/Contents/MacOS/Reed\""
