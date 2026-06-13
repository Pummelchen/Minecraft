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
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DMG_NAME="Pummelchen-Client-Installer.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"
VERSION="${PUMMELCHEN_CLIENT_VERSION:-0.8.0}"

cd "$ROOT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

swift build -c release --product PummelchenClient
swift build -c release --product pummelchen-client-sync

rm -rf "$STAGE_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

install -m 755 "$BUILD_DIR/arm64-apple-macosx/release/PummelchenClient" "$MACOS_DIR/PummelchenClient"
install -m 755 "$BUILD_DIR/arm64-apple-macosx/release/pummelchen-client-sync" "$MACOS_DIR/pummelchen-client-sync"

DUCKDB_LIB="${PUMMELCHEN_DUCKDB_DYLIB:-/opt/homebrew/lib/libduckdb.dylib}"
if [[ ! -f "$DUCKDB_LIB" ]]; then
    echo "libduckdb.dylib not found; install DuckDB or set PUMMELCHEN_DUCKDB_DYLIB" >&2
    exit 1
fi
DUCKDB_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DUCKDB_LIB")"
DUCKDB_INSTALL_NAME="$(otool -D "$DUCKDB_REAL" | tail -n 1)"
install -m 755 "$DUCKDB_REAL" "$FRAMEWORKS_DIR/libduckdb.dylib"
install_name_tool -id "@rpath/libduckdb.dylib" "$FRAMEWORKS_DIR/libduckdb.dylib"
install_name_tool -change "$DUCKDB_INSTALL_NAME" "@rpath/libduckdb.dylib" "$MACOS_DIR/PummelchenClient"
install_name_tool -change "$DUCKDB_INSTALL_NAME" "@rpath/libduckdb.dylib" "$MACOS_DIR/pummelchen-client-sync"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/PummelchenClient"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/pummelchen-client-sync"
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
    <string>$MACOSX_DEPLOYMENT_TARGET</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$FRAMEWORKS_DIR/libduckdb.dylib"
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
