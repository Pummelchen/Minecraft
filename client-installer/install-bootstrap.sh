#!/bin/bash
set -euo pipefail

TOTAL_STEPS=10
DEFAULT_BASE_URL="http://91.99.176.243:7788"
DEFAULT_ZIP_NAME="minecraft_26.1.2_client_macos_apple_silicon.zip"

BASE_URL="${PUMMELCHEN_BASE_URL:-$DEFAULT_BASE_URL}"
ZIP_NAME="${PUMMELCHEN_CLIENT_ZIP_NAME:-$DEFAULT_ZIP_NAME}"
MC_DIR="${MINECRAFT_DIR:-$HOME/Library/Application Support/minecraft}"
SERVER_ADDRESS="${PUMMELCHEN_SERVER_ADDRESS:-91.99.176.243:25565}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HOME/Library/Logs/Pummelchen"
CACHE_DIR="$HOME/Library/Caches/Pummelchen"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-installer.XXXXXX")"
LOG_FILE="$LOG_DIR/dmg-installer-$STAMP.log"

mkdir -p "$LOG_DIR" "$CACHE_DIR"
printf 'PUMMELCHEN_LOG\t%s\n' "$LOG_FILE"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

progress() {
  local current="$1"
  local message="$2"
  printf 'PUMMELCHEN_PROGRESS\t%s\t%s\t%s\n' "$current" "$TOTAL_STEPS" "$message"
  log "[$current/$TOTAL_STEPS] $message"
}

detail() {
  printf 'PUMMELCHEN_DETAIL\t%s\n' "$*"
  log "$*"
}

fail() {
  printf 'PUMMELCHEN_FAIL\t%s\n' "$*"
  log "PUMMELCHEN_DMG_INSTALL_FAILED: $*"
  exit 1
}

download_url() {
  local url="$1"
  local output="$2"
  curl --silent --show-error --fail --location --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 1800 "$url" -o "$output"
}

json_string_value() {
  local key="$1"
  local path="$2"
  sed -nE "s/.*\\\"$key\\\"[[:space:]]*:[[:space:]]*\\\"([^\\\"]*)\\\".*/\\1/p" "$path" | head -n 1
}

human_bytes() {
  awk -v bytes="${1:-0}" '
    BEGIN {
      split("B KB MB GB TB", units, " ")
      value = bytes + 0
      unit = 1
      while (value >= 1024 && unit < 5) {
        value = value / 1024
        unit++
      }
      if (unit == 1) printf "%d %s", value, units[unit]
      else printf "%.1f %s", value, units[unit]
    }'
}

count_section() {
  local section="$1"
  local manifest="$2"
  awk -F '\t' -v section="$section" '$1 == section { count++ } END { print count + 0 }' "$manifest"
}

sum_manifest_bytes() {
  local manifest="$1"
  awk -F '\t' 'NF >= 3 && $1 !~ /^#/ { total += $3 } END { print total + 0 }' "$manifest"
}

progress 1 "Checking Mac and required tools"
log "Pummelchen DMG installer"
log "Base URL: $BASE_URL"
log "Minecraft folder: $MC_DIR"
log "Log file: $LOG_FILE"

[ "$(uname -m)" = "arm64" ] || fail "This installer is for Apple Silicon Macs."
command -v curl >/dev/null 2>&1 || fail "curl is missing."
command -v unzip >/dev/null 2>&1 || fail "unzip is missing."
command -v shasum >/dev/null 2>&1 || fail "shasum is missing."

progress 2 "Resolving the current tested release"
RELEASE_POINTER_URL="$BASE_URL/downloads/current-release.json"
RELEASE_JSON="$WORK_DIR/current-release.json"
SYNC_MANIFEST="$WORK_DIR/client-sync-manifest.tsv"
RELEASE_ID="legacy"
ZIP_URL="$BASE_URL/downloads/$ZIP_NAME"
EXPECTED_SHA=""
MANIFEST_URL="$BASE_URL/downloads/client-sync-manifest.tsv"

if download_url "$RELEASE_POINTER_URL" "$RELEASE_JSON"; then
  RELEASE_ID="$(json_string_value release_id "$RELEASE_JSON" || true)"
  POINTER_ZIP="$(json_string_value client_zip_url "$RELEASE_JSON" || true)"
  POINTER_SHA="$(json_string_value client_zip_sha256 "$RELEASE_JSON" || true)"
  POINTER_MANIFEST="$(json_string_value manifest_url "$RELEASE_JSON" || true)"
  if [ -n "$POINTER_ZIP" ]; then
    case "$POINTER_ZIP" in
      http://*|https://*) ZIP_URL="$POINTER_ZIP" ;;
      *) ZIP_URL="${BASE_URL%/}/${POINTER_ZIP#/}" ;;
    esac
  fi
  if [ -n "$POINTER_MANIFEST" ]; then
    case "$POINTER_MANIFEST" in
      http://*|https://*) MANIFEST_URL="$POINTER_MANIFEST" ;;
      *) MANIFEST_URL="${BASE_URL%/}/${POINTER_MANIFEST#/}" ;;
    esac
  fi
  if [ -n "$POINTER_SHA" ]; then
    EXPECTED_SHA="$POINTER_SHA"
  fi
fi
detail "Release: ${RELEASE_ID:-legacy}"

progress 3 "Reading mod list and download plan"
download_url "$MANIFEST_URL" "$SYNC_MANIFEST" || fail "Could not download client sync manifest."
MOD_COUNT="$(count_section mods "$SYNC_MANIFEST")"
RESOURCE_COUNT="$(count_section resourcepacks "$SYNC_MANIFEST")"
SHADER_COUNT="$(count_section shaderpacks "$SYNC_MANIFEST")"
TOTAL_BYTES="$(sum_manifest_bytes "$SYNC_MANIFEST")"
detail "Client pack contains $MOD_COUNT mods, $RESOURCE_COUNT resource packs, $SHADER_COUNT shader packs. First install downloads about $(human_bytes "$TOTAL_BYTES")."

progress 4 "Checking local cache"
SHA_URL="$BASE_URL/downloads/$ZIP_NAME.sha256"
SHA_PATH="$CACHE_DIR/${RELEASE_ID:-legacy}-$ZIP_NAME.sha256"
ZIP_PATH="$CACHE_DIR/${RELEASE_ID:-legacy}-$ZIP_NAME"
if [ -z "$EXPECTED_SHA" ]; then
  download_url "$SHA_URL" "$SHA_PATH" || fail "Could not download checksum."
  EXPECTED_SHA="$(awk '{ print $1; exit }' "$SHA_PATH")"
else
  printf '%s  %s\n' "$EXPECTED_SHA" "$ZIP_NAME" > "$SHA_PATH"
fi
[ -n "$EXPECTED_SHA" ] || fail "Checksum file is empty."

if [ -f "$ZIP_PATH" ]; then
  CURRENT_SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')"
else
  CURRENT_SHA=""
fi

if [ "$CURRENT_SHA" != "$EXPECTED_SHA" ]; then
  progress 5 "Downloading current client pack"
  detail "Downloading about $(human_bytes "$TOTAL_BYTES") from the VPS. This is the long step on first install."
  rm -f "$ZIP_PATH"
  download_url "$ZIP_URL" "$ZIP_PATH" || fail "Could not download client pack."
else
  progress 5 "Using cached client pack"
  detail "Cached pack already matches the current release checksum."
fi

progress 6 "Verifying client pack checksum"
echo "$EXPECTED_SHA  $ZIP_PATH" | shasum -a 256 -c - >> "$LOG_FILE" 2>&1 || fail "Downloaded client pack checksum mismatch."

progress 7 "Unpacking client pack"
unzip -q "$ZIP_PATH" -d "$WORK_DIR" || fail "Could not unpack client pack."
INSTALLER="$WORK_DIR/client-package/Install Mods.command"
[ -x "$INSTALLER" ] || chmod +x "$INSTALLER" || fail "Client installer is not executable."

progress 8 "Installing Java, NeoForge, mods, resource packs, and updater"
PUMMELCHEN_NONINTERACTIVE=1 \
PUMMELCHEN_REQUIRE_LOCAL_JAVA="${PUMMELCHEN_REQUIRE_LOCAL_JAVA:-1}" \
PUMMELCHEN_OPEN_LAUNCHER="${PUMMELCHEN_OPEN_LAUNCHER:-1}" \
PUMMELCHEN_LOG_FILE="$LOG_FILE" \
"$INSTALLER" "$MC_DIR" >> "$LOG_FILE" 2>&1 || fail "Managed client installer failed."

progress 9 "Verifying installed client files"
INSTALLED_MODS="$(find "$MC_DIR/mods" -maxdepth 1 -type f -name '*.jar' 2>/dev/null | wc -l | tr -d '[:space:]')"
INSTALLED_RESOURCES="$(find "$MC_DIR/resourcepacks" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.jar' \) 2>/dev/null | wc -l | tr -d '[:space:]')"
INSTALLED_SHADERS="$(find "$MC_DIR/shaderpacks" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.jar' \) 2>/dev/null | wc -l | tr -d '[:space:]')"
detail "Installed $INSTALLED_MODS mods, $INSTALLED_RESOURCES resource packs, and $INSTALLED_SHADERS shader packs."

progress 10 "Ready to play Pummelchen Server"
printf 'PUMMELCHEN_DONE\tReady to play Pummelchen Server. Use the NeoForge 26.1.2 profile and join %s.\n' "$SERVER_ADDRESS"
log "Ready to play Pummelchen Server."
