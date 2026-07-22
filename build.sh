#!/usr/bin/env bash
# Build JumpBack.app — a native macOS menu-bar app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/JumpBack.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
BIN="$MACOS/JumpBack"

CONFIG="${1:-debug}" # debug | release

echo "==> Cleaning bundle"
rm -rf "$APP"
mkdir -p "$MACOS"

echo "==> Compiling ($CONFIG)"
SWIFT_FLAGS=(-o "$BIN" -framework Cocoa -framework ApplicationServices -framework Carbon)
if [[ "$CONFIG" == "release" ]]; then
	SWIFT_FLAGS+=(-O)
else
	SWIFT_FLAGS+=(-g -Onone)
fi

swiftc "${SWIFT_FLAGS[@]}" "$ROOT/Sources/main.swift"

# Keep debug symbols in build/ rather than inside the .app bundle.
if [[ -d "$BIN.dSYM" ]]; then
	rm -rf "$BUILD_DIR/JumpBack.dSYM"
	mv "$BIN.dSYM" "$BUILD_DIR/JumpBack.dSYM"
fi

echo "==> Assembling bundle"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

# Bundle icons: .icns for the app icon, template PNGs for the menu-bar glyph.
RESOURCES="$CONTENTS/Resources"
mkdir -p "$RESOURCES"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/Resources/menubarTemplate.png" "$RESOURCES/menubarTemplate.png"
cp "$ROOT/Resources/menubarTemplate@2x.png" "$RESOURCES/menubarTemplate@2x.png"

# Ad-hoc code sign so the Accessibility permission grant sticks across rebuilds
# with a stable bundle identity.
echo "==> Code signing (ad-hoc)"
codesign --force --sign - --identifier "com.theleadershipthread.jumpback" "$APP"

echo "==> Built: $APP"
