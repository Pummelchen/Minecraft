#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/swift/PummelchenSwift"
BUILD_DIR="$ROOT_DIR/build/macos-client"
APP_DIR="$BUILD_DIR/PummelchenClient.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

swift build --package-path "$PACKAGE_DIR" -c release --product PummelchenClient
cp "$PACKAGE_DIR/.build/release/PummelchenClient" "$MACOS_DIR/PummelchenClient"
chmod 755 "$MACOS_DIR/PummelchenClient"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>PummelchenClient</string>
  <key>CFBundleIdentifier</key>
  <string>de.pummelchen.client</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Pummelchen Client</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.4.0</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign -s - --force "$APP_DIR"
codesign -dv "$APP_DIR" >/dev/null
printf 'pummelchen_client_app=%s\n' "$APP_DIR"
