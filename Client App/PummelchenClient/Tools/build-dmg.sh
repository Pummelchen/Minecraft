#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DMG_DIR="$BUILD_DIR/pummelchen-dmg"
STAGE_DIR="$DMG_DIR/stage"
APP_NAME="Pummelchen Client.app"
APP_DIR="$STAGE_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DMG_NAME="Pummelchen-Client-Installer.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"
VERSION="${PUMMELCHEN_CLIENT_VERSION:-0.8.0}"

cd "$ROOT_DIR"

swift build -c release --product PummelchenClient
swift build -c release --product pummelchen-client-sync

rm -rf "$STAGE_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

install -m 755 "$BUILD_DIR/arm64-apple-macosx/release/PummelchenClient" "$MACOS_DIR/PummelchenClient"
install -m 755 "$BUILD_DIR/arm64-apple-macosx/release/pummelchen-client-sync" "$MACOS_DIR/pummelchen-client-sync"

DUCKDB_BIN="${PUMMELCHEN_DUCKDB_BIN:-$(command -v duckdb || true)}"
if [[ -z "$DUCKDB_BIN" || ! -x "$DUCKDB_BIN" ]]; then
    echo "duckdb executable not found; install DuckDB or set PUMMELCHEN_DUCKDB_BIN" >&2
    exit 1
fi
DUCKDB_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DUCKDB_BIN")"
install -m 755 "$DUCKDB_REAL" "$RESOURCES_DIR/duckdb"
DUCKDB_PREFIX="$(cd "$(dirname "$DUCKDB_REAL")/.." && pwd)"
if [[ -f "$DUCKDB_PREFIX/LICENSE" ]]; then
    install -m 644 "$DUCKDB_PREFIX/LICENSE" "$RESOURCES_DIR/duckdb-LICENSE.txt"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Pummelchen Client</string>
    <key>CFBundleExecutable</key>
    <string>PummelchenClient</string>
    <key>CFBundleIdentifier</key>
    <string>de.pummelchen.minecraft.client</string>
    <key>CFBundleName</key>
    <string>Pummelchen Client</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$RESOURCES_DIR/duckdb"
codesign --force --sign - "$MACOS_DIR/pummelchen-client-sync"
codesign --force --sign - "$MACOS_DIR/PummelchenClient"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

hdiutil create \
    -volname "Pummelchen Client" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

(
    cd "$DMG_DIR"
    shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256"
)
echo "$DMG_PATH"
