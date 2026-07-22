#!/usr/bin/env bash
# Build script: compiles the SwiftPM executable and assembles JumpBack.app.
# Usage: ./build.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="JumpBack"
BUNDLE_ID="arabinda.me.jumpback"
APP="$ROOT/build/$APP_NAME.app"

echo "==> Building ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN" ]; then
	echo "Build failed: binary not found at $BIN" >&2
	exit 1
fi

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Icons: .icns for the app icon, template PNGs (with @2x) for the menu-bar glyph.
[ -f "$ROOT/Resources/AppIcon.icns" ]            && cp "$ROOT/Resources/AppIcon.icns"            "$APP/Contents/Resources/"
[ -f "$ROOT/Resources/menubarTemplate.png" ]     && cp "$ROOT/Resources/menubarTemplate.png"     "$APP/Contents/Resources/"
[ -f "$ROOT/Resources/menubarTemplate@2x.png" ]  && cp "$ROOT/Resources/menubarTemplate@2x.png"  "$APP/Contents/Resources/"

# Ad-hoc code sign with a stable identity so the Accessibility permission
# grant persists across rebuilds.
echo "==> Ad-hoc code signing…"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> Done: $APP"
