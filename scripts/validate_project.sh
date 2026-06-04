#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-validate.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_line() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    sha256sum "$1"
  fi
}

sha256_value() {
  sha256_line "$1" | awk '{ print $1 }'
}

log "Python compile"
mapfile -t PY_FILES < <(find "$ROOT_DIR/scripts" -name '*.py' -type f | sort)
"$PYTHON_BIN" -m py_compile "${PY_FILES[@]}"

log "Shell syntax"
while IFS= read -r path; do
  bash -n "$path"
done < <(find "$ROOT_DIR/scripts" "$ROOT_DIR/client-package" -type f \( -name '*.sh' -o -name '*.command' \) | sort)

log "Tracked secret guard"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT_DIR" ls-files | grep -Eq '(^|/)upload-token\.txt$|(^|/)secrets/'; then
    fail "runtime secret file is tracked by git"
  fi
  if git -C "$ROOT_DIR" grep -nE '^[[:space:]]*(password|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_./+-]{24,}' -- ':!*.example' ':!README.md' >/tmp/pummelchen-secret-grep.$$ 2>/dev/null; then
    cat /tmp/pummelchen-secret-grep.$$ >&2
    rm -f /tmp/pummelchen-secret-grep.$$
    fail "possible hard-coded secret in tracked files"
  fi
fi
rm -f /tmp/pummelchen-secret-grep.$$

log "Database migrations"
DB="$TMP_DIR/minecraft_mods.sqlite"
"$PYTHON_BIN" "$ROOT_DIR/scripts/moddb.py" --db "$DB" init
"$PYTHON_BIN" "$ROOT_DIR/scripts/gameplay_load_lab.py" --db "$DB" init

log "Release-manager fixture"
SERVER="$TMP_DIR/server"
RELEASES="$TMP_DIR/releases"
PUBLIC="$TMP_DIR/public/downloads"
mkdir -p "$SERVER/mods" "$SERVER/server-datapacks" "$SERVER/client-package/mods" \
  "$SERVER/client-package/resourcepacks" "$SERVER/client-package/shaderpacks" \
  "$SERVER/client-package/tools" "$SERVER/libraries/net/neoforged/neoforge/26.1.2.71"
printf 'mod-a\n' > "$SERVER/mods/mod-a.jar"
printf 'pack-a\n' > "$SERVER/server-datapacks/pack-a.zip"
printf 'client-mod-a\n' > "$SERVER/client-package/mods/client-mod-a.jar"
printf 'resource-a\n' > "$SERVER/client-package/resourcepacks/resource-a.zip"
printf 'shader-a\n' > "$SERVER/client-package/shaderpacks/shader-a.zip"
printf 'do-not-publish\n' > "$SERVER/client-package/tools/upload-token.txt"
printf 'client zip\n' > "$SERVER/minecraft_26.1.2_client_macos_apple_silicon.zip"
sha256_line "$SERVER/minecraft_26.1.2_client_macos_apple_silicon.zip" > "$SERVER/minecraft_26.1.2_client_macos_apple_silicon.zip.sha256"
printf 'mrpack\n' > "$SERVER/pummelchen-server-26.1.2.mrpack"
printf 'dmg\n' > "$SERVER/Pummelchen-Client-Installer.dmg"
sha256_line "$SERVER/Pummelchen-Client-Installer.dmg" > "$SERVER/Pummelchen-Client-Installer.dmg.sha256"

"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  create --release-id qa_release_1 --activate --notes "quality gate release"
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  validate qa_release_1
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  current-json >/dev/null
[ -f "$PUBLIC/current-release.json" ] || fail "current-release.json was not published"
[ -f "$PUBLIC/releases/qa_release_1/client-sync-manifest.tsv" ] || fail "release client manifest was not published"
[ ! -e "$PUBLIC/releases/qa_release_1/client-files/tools/upload-token.txt" ] || fail "upload token leaked into public release"

log "Rollback fixture"
printf 'mod-b\n' > "$SERVER/mods/mod-b.jar"
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  create --release-id qa_release_2 --activate --notes "second quality gate release" >/dev/null
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  rollback --notes "quality gate rollback" >/dev/null
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  validate qa_release_1
[ ! -f "$SERVER/mods/mod-b.jar" ] || fail "rollback did not remove newer mod"

log "Client manifest checker"
MANIFEST_PACKAGE="$TMP_DIR/manifest-package"
mkdir -p "$MANIFEST_PACKAGE/mods" "$MANIFEST_PACKAGE/resourcepacks" "$MANIFEST_PACKAGE/shaderpacks"
printf 'fixture\n' > "$MANIFEST_PACKAGE/mods/fixture.jar"
SIZE="$(wc -c < "$MANIFEST_PACKAGE/mods/fixture.jar" | tr -d '[:space:]')"
HASH="$(sha256_value "$MANIFEST_PACKAGE/mods/fixture.jar")"
printf '[mods]\nfixture.jar\t%s\tsha256:%s\n' "$SIZE" "$HASH" > "$MANIFEST_PACKAGE/manifest.txt"
"$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_manifest.py" "$MANIFEST_PACKAGE" --strict
"$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_manifest.py" "$ROOT_DIR/client-package"

log "Generated status site"
SITE_OUT="$TMP_DIR/site"
"$PYTHON_BIN" "$ROOT_DIR/scripts/generate_status_site.py" --db "$DB" --server-dir "$SERVER" --output-dir "$SITE_OUT" --public-url "http://127.0.0.1:7788"
[ -f "$SITE_OUT/index.html" ] || fail "status site was not generated"
grep -q "Pummelchen Server" "$SITE_OUT/index.html" || fail "status site title missing"

log "Live stats and exporter"
"$PYTHON_BIN" "$ROOT_DIR/scripts/live_stats_feed.py" --db "$DB" --server-dir "$SERVER" --output "$TMP_DIR/live-stats.json" --state "$TMP_DIR/live-state.json"
grep -q "Active release" "$TMP_DIR/live-stats.json" || fail "live stats missing release data"
"$PYTHON_BIN" "$ROOT_DIR/scripts/minecraft_metrics_exporter.py" --db "$DB" --server-dir "$SERVER" --state "$TMP_DIR/metrics-state.json" --once | grep -q "pummelchen_minecraft_up"

log "Load-lab dry run"
"$PYTHON_BIN" "$ROOT_DIR/scripts/gameplay_load_lab.py" --db "$DB" --server-dir "$SERVER" run fresh_world_idle --dry-run

log "Monitoring JSON"
"$PYTHON_BIN" -m json.tool "$ROOT_DIR/monitoring/grafana/dashboards/pummelchen-overview.json" >/dev/null

if command -v nginx >/dev/null 2>&1; then
  log "Nginx syntax"
  NGINX_MAIN="$TMP_DIR/nginx.conf"
  {
    printf 'events {}\n'
    printf 'http { include "%s/nginx/pummelchen-server.conf"; }\n' "$ROOT_DIR"
  } > "$NGINX_MAIN"
  nginx -t -c "$NGINX_MAIN" -p "$TMP_DIR" >/dev/null
fi

log "Quality gate passed"
