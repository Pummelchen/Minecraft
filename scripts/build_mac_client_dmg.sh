#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"
APP_NAME="Pummelchen Installer.app"
DMG_NAME="Pummelchen-Client-Installer.dmg"
PUBLIC_URL="${PUMMELCHEN_PUBLIC_URL:-http://91.99.176.243:7788}"
CLIENT_ZIP_NAME="minecraft_26.1.2_client_macos_apple_silicon.zip"

command -v hdiutil >/dev/null 2>&1 || {
  echo "hdiutil is required; build this DMG on macOS." >&2
  exit 1
}

rm -rf "$OUTPUT_DIR/build"
mkdir -p "$OUTPUT_DIR/build/$APP_NAME/Contents/MacOS" "$OUTPUT_DIR/build/$APP_NAME/Contents/Resources"

cat > "$OUTPUT_DIR/build/$APP_NAME/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Pummelchen Installer</string>
  <key>CFBundleIdentifier</key>
  <string>server.pummelchen.client-installer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Pummelchen Installer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$OUTPUT_DIR/build/$APP_NAME/Contents/MacOS/Pummelchen Installer" <<APP
#!/bin/bash
set -euo pipefail

BASE_URL="\${PUMMELCHEN_BASE_URL:-$PUBLIC_URL}"
ZIP_NAME="$CLIENT_ZIP_NAME"
MC_DIR="\${MINECRAFT_DIR:-\$HOME/Library/Application Support/minecraft}"
SERVER_ADDRESS="91.99.176.243:25565"
STAMP="\$(date +%Y%m%d-%H%M%S)"
LOG_DIR="\$HOME/Library/Logs/Pummelchen"
CACHE_DIR="\$HOME/Library/Caches/Pummelchen"
WORK_DIR="\$(mktemp -d "\${TMPDIR:-/tmp}/pummelchen-installer.XXXXXX")"
LOG_FILE="\$LOG_DIR/dmg-installer-\$STAMP.log"

mkdir -p "\$LOG_DIR" "\$CACHE_DIR"
exec > >(tee -a "\$LOG_FILE") 2>&1

cleanup() {
  rm -rf "\$WORK_DIR"
}
trap cleanup EXIT

dialog() {
  if [ "\${PUMMELCHEN_SKIP_DIALOGS:-0}" = "1" ]; then
    return 0
  fi
  /usr/bin/osascript -e "display dialog \$1 buttons {\\\"OK\\\"} default button \\\"OK\\\" with title \\\"Pummelchen Server\\\"" >/dev/null 2>&1 || true
}

fail() {
  echo "PUMMELCHEN_DMG_INSTALL_FAILED: \$*"
  echo "Log file: \$LOG_FILE"
  dialog "\"Setup could not complete. The log is saved at:\\n\$LOG_FILE\""
  exit 1
}

echo "Pummelchen DMG installer"
echo "Base URL: \$BASE_URL"
echo "Minecraft folder: \$MC_DIR"
echo "Log file: \$LOG_FILE"

[ "\$(uname -m)" = "arm64" ] || fail "This installer is for Apple Silicon Macs."
command -v curl >/dev/null 2>&1 || fail "curl is missing."
command -v unzip >/dev/null 2>&1 || fail "unzip is missing."
command -v shasum >/dev/null 2>&1 || fail "shasum is missing."

SHA_URL="\$BASE_URL/downloads/\$ZIP_NAME.sha256"
ZIP_URL="\$BASE_URL/downloads/\$ZIP_NAME"
SHA_PATH="\$CACHE_DIR/\$ZIP_NAME.sha256"
ZIP_PATH="\$CACHE_DIR/\$ZIP_NAME"

echo "Reading current client checksum..."
curl --silent --show-error --fail --location --retry 3 --retry-delay 2 "\$SHA_URL" -o "\$SHA_PATH" || fail "Could not download checksum."
EXPECTED_SHA="\$(awk '{ print \$1; exit }' "\$SHA_PATH")"
[ -n "\$EXPECTED_SHA" ] || fail "Checksum file is empty."

if [ -f "\$ZIP_PATH" ]; then
  CURRENT_SHA="\$(shasum -a 256 "\$ZIP_PATH" | awk '{ print \$1 }')"
else
  CURRENT_SHA=""
fi

if [ "\$CURRENT_SHA" != "\$EXPECTED_SHA" ]; then
  echo "Downloading current client pack..."
  rm -f "\$ZIP_PATH"
  curl --silent --show-error --fail --location --retry 3 --retry-delay 2 "\$ZIP_URL" -o "\$ZIP_PATH" || fail "Could not download client pack."
fi

echo "\$EXPECTED_SHA  \$ZIP_PATH" | shasum -a 256 -c - || fail "Downloaded client pack checksum mismatch."

echo "Unpacking client pack..."
unzip -q "\$ZIP_PATH" -d "\$WORK_DIR" || fail "Could not unpack client pack."
INSTALLER="\$WORK_DIR/client-package/Install Mods.command"
[ -x "\$INSTALLER" ] || chmod +x "\$INSTALLER" || fail "Client installer is not executable."

echo "Running managed client installer..."
PUMMELCHEN_NONINTERACTIVE=1 \\
PUMMELCHEN_REQUIRE_LOCAL_JAVA="\${PUMMELCHEN_REQUIRE_LOCAL_JAVA:-1}" \\
PUMMELCHEN_OPEN_LAUNCHER="\${PUMMELCHEN_OPEN_LAUNCHER:-1}" \\
PUMMELCHEN_LOG_FILE="\$LOG_FILE" \\
"\$INSTALLER" "\$MC_DIR" || fail "Managed client installer failed."

dialog "\"Ready to play Pummelchen Server.\\n\\nMinecraft Launcher is opening. Use the NeoForge 26.1.2 profile and join \$SERVER_ADDRESS.\""
exit 0
APP

chmod +x "$OUTPUT_DIR/build/$APP_NAME/Contents/MacOS/Pummelchen Installer"

cat > "$OUTPUT_DIR/build/README.txt" <<README
Pummelchen Server Mac Installer

Open "Pummelchen Installer.app".

The installer runs in your user account only. It downloads the current client
pack, verifies SHA256, installs a user-local Java 25 runtime if needed, syncs
the Pummelchen mods/resource packs/shader packs, installs the NeoForge profile,
adds Pummelchen Server to Minecraft's server list, installs the background
auto-updater and Client Doctor log uploader, and opens Minecraft. Future pack
changes sync from the VPS without downloading this DMG again. Crash reports can
be uploaded with "Pummelchen Send Logs.command" in your Applications folder.

Server: 91.99.176.243:25565
README

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$OUTPUT_DIR/build/$APP_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$DMG_NAME"
hdiutil create -volname "Pummelchen Client Installer" -srcfolder "$OUTPUT_DIR/build" -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
echo "$OUTPUT_DIR/$DMG_NAME"
