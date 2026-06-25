#!/usr/bin/env bash
# Build the SwiftPM executable and assemble it into a proper .app bundle.
# A real bundle (with Info.plist + bundle id) is required for the status-bar
# accessory behavior and for Now Playing / media-key registration to work.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SoundCloudPlayer.app"
BUNDLE_ID="co.kobylinski.soundcloudplayer"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/SoundCloudPlayer"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SoundCloudPlayer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SoundCloudPlayer</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>SoundCloudPlayer</string>
    <key>CFBundleDisplayName</key><string>SoundCloud Player</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}.oauth</string>
            <key>CFBundleURLSchemes</key>
            <array><string>soundcloudplayer</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped/failed — local run still works)"

echo "==> done: $APP"
echo "    run with: open \"$APP\"   (or)   \"$APP/Contents/MacOS/SoundCloudPlayer\""
