#!/bin/bash
set -uo pipefail

MODE="upload"
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --collect-only) MODE="collect" ;;
    --upload) MODE="upload" ;;
    --upload-if-new-crash) MODE="upload-if-new-crash" ;;
    --quiet) QUIET=1 ;;
    --help)
      cat <<'HELP'
Pummelchen Client Doctor

Usage:
  pummelchen-client-doctor.sh --upload
  pummelchen-client-doctor.sh --collect-only
  pummelchen-client-doctor.sh --upload-if-new-crash --quiet
HELP
      exit 0
      ;;
  esac
done

DEFAULT_BASE_URL="http://91.99.176.243:7788"
CONFIG_PATH="${PUMMELCHEN_CONFIG_PATH:-$HOME/Library/Application Support/Pummelchen/client.conf}"

if [ -f "$CONFIG_PATH" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_PATH"
fi

BASE_URL="${PUMMELCHEN_BASE_URL:-${BASE_URL:-$DEFAULT_BASE_URL}}"
UPLOAD_URL="${PUMMELCHEN_LOG_UPLOAD_URL:-${BASE_URL%/}/client-logs/upload}"
UPLOAD_TOKEN="${PUMMELCHEN_LOG_UPLOAD_TOKEN:-${LOG_UPLOAD_TOKEN:-}}"
MC_DIR="${MINECRAFT_DIR:-${MC_DIR:-$HOME/Library/Application Support/minecraft}}"
PUMMELCHEN_HOME="${PUMMELCHEN_HOME:-$HOME/Library/Application Support/Pummelchen}"
LOG_DIR="${PUMMELCHEN_LOG_DIR:-$HOME/Library/Logs/Pummelchen}"
CACHE_DIR="${PUMMELCHEN_CACHE_DIR:-$HOME/Library/Caches/Pummelchen}"
STATE_DIR="$MC_DIR/.pummelchen"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CLIENT_ID_FILE="$PUMMELCHEN_HOME/client-id"
LAST_CRASH_FILE="$STATE_DIR/last-uploaded-crash.txt"
MAX_UPLOAD_MB="${PUMMELCHEN_MAX_LOG_UPLOAD_MB:-25}"

mkdir -p "$PUMMELCHEN_HOME" "$LOG_DIR" "$CACHE_DIR" "$STATE_DIR"

log() {
  if [ "$QUIET" != "1" ]; then
    printf '%s\n' "$*"
  fi
}

fail() {
  printf 'PUMMELCHEN_CLIENT_DOCTOR_FAILED: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is missing."
}

client_id() {
  if [ ! -s "$CLIENT_ID_FILE" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      uuidgen | tr '[:upper:]' '[:lower:]' > "$CLIENT_ID_FILE"
    else
      printf '%s-%s\n' "$(hostname | tr -cd 'A-Za-z0-9_.-')" "$(date +%s)" > "$CLIENT_ID_FILE"
    fi
    chmod 600 "$CLIENT_ID_FILE"
  fi
  tr -cd 'A-Za-z0-9_.-' < "$CLIENT_ID_FILE" | cut -c1-80
}

newest_crash_report() {
  local folder="$MC_DIR/crash-reports"
  [ -d "$folder" ] || return 0
  local files
  shopt -s nullglob
  files=("$folder"/*.txt)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || return 0
  ls -t "${files[@]}" 2>/dev/null | head -n 1
}

should_upload_for_crash() {
  local newest previous
  newest="$(newest_crash_report || true)"
  [ -n "$newest" ] || return 1
  previous="$(cat "$LAST_CRASH_FILE" 2>/dev/null || true)"
  [ "$newest" != "$previous" ]
}

redact_text_file() {
  local src="$1"
  local dst="$2"
  [ -f "$src" ] || return 0
  /usr/bin/sed -E \
    -e "s#${HOME//\\/\\\\}#~#g" \
    -e 's#/Users/[^/[:space:]]+#~/REDACTED_USER#g' \
    -e 's#(accessToken|clientToken|session|authorization|Authorization|Bearer)[^[:space:],}"]+#\1=REDACTED#g' \
    -e 's#([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+)\.[A-Za-z]{2,}#REDACTED_EMAIL#g' \
    "$src" > "$dst" 2>/dev/null || true
}

copy_latest_files() {
  local src_dir="$1"
  local dst_dir="$2"
  local pattern="$3"
  local limit="$4"
  [ -d "$src_dir" ] || return 0
  mkdir -p "$dst_dir"
  local files path count
  shopt -s nullglob
  files=("$src_dir"/$pattern)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || return 0
  count=0
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    redact_text_file "$path" "$dst_dir/$(basename "$path")"
    count=$((count + 1))
    [ "$count" -ge "$limit" ] && break
  done < <(ls -t "${files[@]}" 2>/dev/null)
}

hash_section() {
  local section="$1"
  local folder="$MC_DIR/$section"
  local output="$2"
  mkdir -p "$(dirname "$output")"
  {
    printf 'section\tname\tsize\tsha256\n'
    if [ -d "$folder" ]; then
      find "$folder" -maxdepth 1 -type f \( -name '*.jar' -o -name '*.zip' \) -print 2>/dev/null \
        | sort \
        | while IFS= read -r path; do
            local name size digest
            name="$(basename "$path")"
            size="$(wc -c < "$path" | tr -d '[:space:]')"
            digest="$(shasum -a 256 "$path" | awk '{ print $1 }')"
            printf '%s\t%s\t%s\tsha256:%s\n' "$section" "$name" "$size" "$digest"
          done
    fi
  } > "$output"
}

pack_sha256() {
  local status="$STATE_DIR/auto-update-status.txt"
  local sha_file="$CACHE_DIR/minecraft_26.1.2_client_macos_apple_silicon.zip.sha256"
  if [ -f "$sha_file" ]; then
    awk '{ print $1; exit }' "$sha_file"
    return 0
  fi
  awk -F '=' '$1 == "pack_sha256" { print $2; exit }' "$status" 2>/dev/null || true
}

crash_headline() {
  local newest="$1"
  [ -f "$newest" ] || return 0
  awk '
    /Description:/ { print; exit }
    /Exception|Error|Caused by:/ { print; exit }
  ' "$newest" | head -n 1
}

collect_bundle() {
  local cid="$1"
  local work_dir="$2"
  local bundle_root="$work_dir/pummelchen-client-logs-$STAMP"
  local diagnostics="$bundle_root/diagnostics"
  mkdir -p "$diagnostics" "$bundle_root/minecraft-logs" "$bundle_root/crash-reports" "$bundle_root/pummelchen"

  local newest_crash
  newest_crash="$(newest_crash_report || true)"
  local headline
  headline="$(crash_headline "$newest_crash" || true)"

  {
    printf 'created_at=%s\n' "$STAMP"
    printf 'client_id=%s\n' "$cid"
    printf 'minecraft_version=26.1.2\n'
    printf 'base_url=%s\n' "$BASE_URL"
    printf 'minecraft_dir=~/Library/Application Support/minecraft\n'
    printf 'os=%s %s\n' "$(sw_vers -productName 2>/dev/null || printf macOS)" "$(sw_vers -productVersion 2>/dev/null || true)"
    printf 'arch=%s\n' "$(uname -m)"
    printf 'java=%s\n' "$(java -version 2>&1 | sed -n '1p' || true)"
    printf 'pack_sha256=%s\n' "$(pack_sha256)"
    printf 'newest_crash=%s\n' "$(basename "$newest_crash")"
    printf 'notes=Collected by Pummelchen Client Doctor\n'
  } > "$bundle_root/summary.txt"

  printf '%s\n' "${headline:-No crash headline found}" > "$bundle_root/crash-headline.txt"

  copy_latest_files "$MC_DIR/logs" "$bundle_root/minecraft-logs" "latest.log" 1
  copy_latest_files "$MC_DIR/logs" "$bundle_root/minecraft-logs" "debug.log" 1
  copy_latest_files "$MC_DIR/crash-reports" "$bundle_root/crash-reports" "*.txt" 5
  copy_latest_files "$LOG_DIR" "$bundle_root/pummelchen" "*.log" 8
  copy_latest_files "$STATE_DIR" "$bundle_root/pummelchen" "*.txt" 8
  copy_latest_files "$STATE_DIR" "$bundle_root/pummelchen" "*.tsv" 4

  hash_section "mods" "$diagnostics/mods.tsv"
  hash_section "resourcepacks" "$diagnostics/resourcepacks.tsv"
  hash_section "shaderpacks" "$diagnostics/shaderpacks.tsv"

  {
    printf 'Disk usage for Minecraft folder:\n'
    du -sh "$MC_DIR" 2>/dev/null || true
    printf '\nRecent crash reports:\n'
    find "$MC_DIR/crash-reports" -maxdepth 1 -type f -name '*.txt' -print 2>/dev/null | xargs ls -lt 2>/dev/null | head -n 10 || true
  } > "$diagnostics/filesystem.txt"

  printf '%s\n' "$bundle_root"
}

zip_bundle() {
  local bundle_root="$1"
  local zip_path="$2"
  if command -v zip >/dev/null 2>&1; then
    (cd "$(dirname "$bundle_root")" && zip -qry "$zip_path" "$(basename "$bundle_root")")
  elif command -v ditto >/dev/null 2>&1; then
    (cd "$(dirname "$bundle_root")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$bundle_root")" "$zip_path")
  else
    fail "zip or ditto is required to create a diagnostic bundle."
  fi
}

upload_bundle() {
  local zip_path="$1"
  local cid="$2"
  [ -n "$UPLOAD_TOKEN" ] || fail "Upload token is missing. Re-run the Pummelchen installer."
  local size max_bytes
  size="$(wc -c < "$zip_path" | tr -d '[:space:]')"
  max_bytes=$((MAX_UPLOAD_MB * 1024 * 1024))
  [ "$size" -le "$max_bytes" ] || fail "Diagnostic bundle is too large: $size bytes."

  curl --silent --show-error --fail --location --retry 2 --retry-delay 2 \
    -X POST \
    -H "Content-Type: application/zip" \
    -H "X-Pummelchen-Upload-Token: $UPLOAD_TOKEN" \
    -H "X-Pummelchen-Client-Id: $cid" \
    -H "X-Pummelchen-Filename: $(basename "$zip_path")" \
    -H "X-Pummelchen-Pack-Sha: $(pack_sha256)" \
    --data-binary "@$zip_path" \
    "$UPLOAD_URL"
}

if [ "$MODE" = "upload-if-new-crash" ] && ! should_upload_for_crash; then
  log "No new Minecraft crash report to upload."
  exit 0
fi

require_command curl
require_command shasum

CLIENT_ID="$(client_id)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-client-doctor.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

log "Collecting Pummelchen client diagnostics..."
BUNDLE_ROOT="$(collect_bundle "$CLIENT_ID" "$WORK_DIR")"
ZIP_PATH="$CACHE_DIR/pummelchen-client-logs-$STAMP.zip"
rm -f "$ZIP_PATH"
zip_bundle "$BUNDLE_ROOT" "$ZIP_PATH" || fail "Could not create diagnostic ZIP."

if [ "$MODE" = "collect" ]; then
  printf '%s\n' "$ZIP_PATH"
  exit 0
fi

log "Uploading diagnostic bundle..."
UPLOAD_RESPONSE="$(upload_bundle "$ZIP_PATH" "$CLIENT_ID")" || fail "Upload failed."
printf '%s\n' "$UPLOAD_RESPONSE"

NEWEST_CRASH="$(newest_crash_report || true)"
if [ -n "$NEWEST_CRASH" ]; then
  printf '%s\n' "$NEWEST_CRASH" > "$LAST_CRASH_FILE"
fi

log "Pummelchen diagnostic upload complete."
