#!/bin/bash
set -euo pipefail

TOTAL_STEPS=10
DEFAULT_BASE_URL="http://91.99.176.243:7788"
DEFAULT_ZIP_NAME="minecraft_26.1.2_client_macos_apple_silicon.zip"
INSTALLER_VERSION="${PUMMELCHEN_INSTALLER_VERSION:-1.2}"

BASE_URL="${PUMMELCHEN_BASE_URL:-$DEFAULT_BASE_URL}"
ZIP_NAME="${PUMMELCHEN_CLIENT_ZIP_NAME:-$DEFAULT_ZIP_NAME}"
MC_DIR="${MINECRAFT_DIR:-$HOME/Library/Application Support/minecraft}"
SERVER_ADDRESS="${PUMMELCHEN_SERVER_ADDRESS:-91.99.176.243:25565}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PUMMELCHEN_HOME="$HOME/Library/Application Support/Pummelchen"
LOG_DIR="$HOME/Library/Logs/Pummelchen"
CACHE_DIR="$HOME/Library/Caches/Pummelchen"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-installer.XXXXXX")"
LOG_FILE="${PUMMELCHEN_INSTALLER_LOG_FILE:-$LOG_DIR/dmg-installer-$STAMP.log}"
SESSION_ID="${PUMMELCHEN_INSTALLER_SESSION_ID:-}"
INSTALLER_EVENT_URL="${PUMMELCHEN_INSTALLER_EVENT_URL:-${BASE_URL%/}/client-logs/installer-event}"
CLIENT_ID_FILE="$PUMMELCHEN_HOME/client-id"
CURRENT_STEP=0
RELEASE_ID=""

mkdir -p "$LOG_DIR" "$CACHE_DIR" "$PUMMELCHEN_HOME"
printf 'PUMMELCHEN_LOG\t%s\n' "$LOG_FILE"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

new_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    printf 'installer-%s-%s\n' "$(hostname | tr -cd 'A-Za-z0-9_.-')" "$(date +%s)"
  fi
}

client_id() {
  if [ ! -s "$CLIENT_ID_FILE" ]; then
    new_session_id > "$CLIENT_ID_FILE"
    chmod 600 "$CLIENT_ID_FILE" 2>/dev/null || true
  fi
  tr -cd 'A-Za-z0-9_.-' < "$CLIENT_ID_FILE" | cut -c1-80
}

redact_file_to() {
  local src="$1"
  local dst="$2"
  if [ "$src" != "/dev/stdin" ] && [ ! -f "$src" ]; then
    : > "$dst"
    return 0
  fi
  sed -E \
    -e "s#${HOME//\\/\\\\}#~#g" \
    -e 's#/Users/[^/[:space:]]+#~/REDACTED_USER#g' \
    -e 's#(accessToken|clientToken|session|authorization|Authorization|Bearer)[^[:space:],}"]+#\1=REDACTED#g' \
    -e 's#([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+)\.[A-Za-z]{2,}#REDACTED_EMAIL#g' \
    "$src" > "$dst" 2>/dev/null || true
}

report_event() {
  local event_type="$1"
  local severity="$2"
  local status="$3"
  local step_current="${4:-}"
  local step_total="${5:-}"
  local message="${6:-}"
  local include_tail="${7:-0}"
  [ "${PUMMELCHEN_DISABLE_INSTALLER_EVENTS:-0}" = "1" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  [ -n "$INSTALLER_EVENT_URL" ] || return 0

  local cid os_summary arch redacted_log event_at tail_file
  cid="$(client_id || true)"
  os_summary="$(sw_vers -productName 2>/dev/null || printf macOS) $(sw_vers -productVersion 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"
  redacted_log="${LOG_FILE/#$HOME/~}"
  event_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tail_file=""

  local curl_args=(
    --silent --show-error --fail --location
    --retry 1 --retry-delay 1
    --connect-timeout 3 --max-time 8
    -X POST
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8"
    -H "User-Agent: PummelchenInstallerBootstrap/$INSTALLER_VERSION"
    --data-urlencode "session_id=$SESSION_ID"
    --data-urlencode "client_id=$cid"
    --data-urlencode "event_type=$event_type"
    --data-urlencode "severity=$severity"
    --data-urlencode "status=$status"
    --data-urlencode "event_at=$event_at"
    --data-urlencode "installer_version=$INSTALLER_VERSION"
    --data-urlencode "release_id=$RELEASE_ID"
    --data-urlencode "minecraft_version=26.1.2"
    --data-urlencode "os=$os_summary"
    --data-urlencode "arch=$arch"
    --data-urlencode "local_log_path=$redacted_log"
    --data-urlencode "step_current=$step_current"
    --data-urlencode "step_total=$step_total"
    --data-urlencode "message=$message"
  )
  if [ "$include_tail" = "1" ]; then
    tail_file="$WORK_DIR/installer-event-tail.txt"
    { tail -n 120 "$LOG_FILE" 2>/dev/null || true; } | redact_file_to /dev/stdin "$tail_file"
    curl_args+=(--data-urlencode "log_excerpt@$tail_file")
  fi

  if ! curl "${curl_args[@]}" "$INSTALLER_EVENT_URL" >/dev/null 2>> "$LOG_FILE"; then
    printf 'Installer event upload failed: %s %s\n' "$event_type" "$message" >> "$LOG_FILE"
  fi
}

if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(new_session_id)"
fi

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

progress() {
  local current="$1"
  local message="$2"
  CURRENT_STEP="$current"
  printf 'PUMMELCHEN_PROGRESS\t%s\t%s\t%s\n' "$current" "$TOTAL_STEPS" "$message"
  log "[$current/$TOTAL_STEPS] $message"
  report_event "progress" "info" "running" "$current" "$TOTAL_STEPS" "$message" 0
}

detail() {
  printf 'PUMMELCHEN_DETAIL\t%s\n' "$*"
  log "$*"
  report_event "detail" "info" "running" "$CURRENT_STEP" "$TOTAL_STEPS" "$*" 0
}

fail() {
  printf 'PUMMELCHEN_FAIL\t%s\n' "$*"
  log "PUMMELCHEN_DMG_INSTALL_FAILED: $*"
  report_event "failed" "error" "failed" "$CURRENT_STEP" "$TOTAL_STEPS" "$*" 1
  exit 1
}

on_unhandled_error() {
  local status="$1"
  local line="$2"
  trap - ERR
  log "PUMMELCHEN_DMG_INSTALL_FAILED: unexpected exit code $status at line $line"
  report_event "failed" "error" "failed" "$CURRENT_STEP" "$TOTAL_STEPS" "Unexpected installer error at line $line with exit code $status." 1
  exit "$status"
}

trap 'on_unhandled_error "$?" "$LINENO"' ERR

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

count_installed_mods() {
  local dir="$1"
  [ -d "$dir" ] || {
    printf '0\n'
    return 0
  }
  find "$dir" -maxdepth 1 -type f -name '*.jar' 2>/dev/null | wc -l | tr -d '[:space:]'
}

count_installed_packs() {
  local dir="$1"
  [ -d "$dir" ] || {
    printf '0\n'
    return 0
  }
  find "$dir" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.jar' \) 2>/dev/null | wc -l | tr -d '[:space:]'
}

progress 1 "Checking Mac and required tools"
log "Pummelchen DMG installer"
log "Session ID: $SESSION_ID"
log "Base URL: $BASE_URL"
log "Minecraft folder: $MC_DIR"
log "Log file: $LOG_FILE"
report_event "bootstrap_started" "info" "running" "$CURRENT_STEP" "$TOTAL_STEPS" "Installer bootstrap initialized." 0

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
INSTALLED_MODS="$(count_installed_mods "$MC_DIR/mods")"
INSTALLED_RESOURCES="$(count_installed_packs "$MC_DIR/resourcepacks")"
INSTALLED_SHADERS="$(count_installed_packs "$MC_DIR/shaderpacks")"
detail "Installed $INSTALLED_MODS mods, $INSTALLED_RESOURCES resource packs, and $INSTALLED_SHADERS shader packs."

progress 10 "Ready to play Pummelchen Server"
printf 'PUMMELCHEN_DONE\tReady to play Pummelchen Server. Use the NeoForge 26.1.2 profile and join %s.\n' "$SERVER_ADDRESS"
log "Ready to play Pummelchen Server."
report_event "completed" "info" "ok" "$TOTAL_STEPS" "$TOTAL_STEPS" "Ready to play Pummelchen Server. Setup completed without errors." 1
