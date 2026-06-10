#!/bin/bash
# Pummelchen Client Updater — syncs mods, resource packs, and shader packs
# to the latest server release. Designed for launchd (every 5 min). No signing needed.
#
# Usage: pummelchen-updater.sh [--force] [--dry-run]

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
MC_DIR="${MINECRAFT_DIR:-$HOME/Library/Application Support/minecraft}"
PUBLIC_URL="${PUMMELCHEN_BASE_URL:-http://91.99.176.243:7788}"
STATE_DIR="$MC_DIR/.pummelchen"
STATE_FILE="$STATE_DIR/sync-state.json"
LOCK_FILE="$STATE_DIR/updater.lock"
LOG_DIR="$HOME/Library/Logs/Pummelchen"
LOG_FILE="$LOG_DIR/updater.log"
LOG_MAX=1048576   # 1 MB rotation threshold
COOLDOWN=120      # seconds between syncs when up-to-date

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────
mkdir -p "$STATE_DIR" "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

notify() {
  osascript -e "display notification \"$1\" with title \"Pummelchen\" subtitle \"$2\"" 2>/dev/null || true
}

# MSDOS-style progress bar: [##########----------] 45/263 (17%) filename
progress_bar() {
  local current="$1" total="$2" label="$3" bar_width=30
  # Guard against division by zero (e.g. 0 downloads planned)
  if [ "$total" -eq 0 ]; then
    if [ "$current" -eq 0 ]; then echo; fi
    return 0
  fi
  local pct=$((current * 100 / total))
  local filled=$((current * bar_width / total))
  local empty=$((bar_width - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="#"; done
  for ((i=0; i<empty; i++)); do bar+="-"; done
  printf '\r  [%s] %d/%d (%d%%) %s' "$bar" "$current" "$total" "$pct" "$label"
  if [ "$current" -eq "$total" ]; then echo; fi
}

mc_running() {
  pgrep -f "Minecraft.app" >/dev/null 2>&1 ||
  pgrep -f "net.minecraft.client" >/dev/null 2>&1
}

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
    if kill -0 "$lock_pid" 2>/dev/null; then
      log "Another instance (PID $lock_pid) running — exiting"
      exit 0
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE"; }
trap release_lock EXIT

rotate_log() {
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

# ── Main sync ──────────────────────────────────────────────────
sync_client() {
  acquire_lock
  rotate_log
  exec > >(tee -a "$LOG_FILE") 2>&1

  log "=== Pummelchen updater starting ==="

  # Skip if Minecraft is running
  if [ "$FORCE" -ne 1 ] && mc_running; then
    log "Minecraft is running — skipping to avoid file conflicts"
    return 0
  fi

  # Cooldown check
  if [ "$FORCE" -ne 1 ] && [ -f "$STATE_FILE" ]; then
    local age
    age="$(python3 -c "
import json, time
try:
    from datetime import datetime, timezone
    d = json.load(open('$STATE_FILE'))
    if d.get('was_uptodate'):
        t = datetime.fromisoformat(d['synced_at'].replace('Z','+00:00'))
        print(int(time.time() - t.timestamp()))
    else:
        print(9999)
except Exception:
    print(9999)
" 2>/dev/null || echo 9999)"
    if [ "$age" -lt "$COOLDOWN" ]; then
      log "Cooldown (${age}s < ${COOLDOWN}s) — skipping"
      return 0
    fi
  fi

  # 1. Fetch current release
  local release_json
  release_json="$(curl -fsS --connect-timeout 10 --max-time 20 \
    "$PUBLIC_URL/downloads/current-release.json" 2>/dev/null)" || {
    log "ERROR: Cannot reach server at $PUBLIC_URL"
    return 1
  }

  local release_id manifest_url
  release_id="$(echo "$release_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['release_id'])")"
  manifest_url="$(echo "$release_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['manifest_url'])")"
  log "Server release: $release_id"

  # Quick check: same release?
  local prev_release=""
  [ -f "$STATE_FILE" ] && prev_release="$(python3 -c "
import json
try: print(json.load(open('$STATE_FILE')).get('release_id',''))
except: print('')
" 2>/dev/null || echo "")"

  if [ "$release_id" = "$prev_release" ] && [ "$FORCE" -ne 1 ]; then
    log "Already on $release_id — up-to-date"
    python3 -c "
import json
d = json.load(open('$STATE_FILE')); d['was_uptodate'] = True
json.dump(d, open('$STATE_FILE','w'), indent=2)
" 2>/dev/null || true
    return 0
  fi

  # 2. Fetch sync manifest
  local manifest_text
  manifest_text="$(curl -fsS --connect-timeout 10 --max-time 60 \
    "${PUBLIC_URL%/}/$manifest_url" 2>/dev/null)" || {
    log "ERROR: Cannot fetch manifest"
    return 1
  }

  # 3. Compute plan (download/remove/unchanged) via Python
  export MC_DIR PUBLIC_URL MANIFEST_TEXT="$manifest_text"
  export PREV_FILES_JSON="$(python3 -c "
import json
try: print(json.dumps(json.load(open('$STATE_FILE')).get('files', {})))
except: print('{}')
" 2>/dev/null || echo '{}')"

  local plan_json
  plan_json="$(python3 << 'PYEOF'
import json, os
from urllib.parse import quote

PUBLIC_URL = os.environ["PUBLIC_URL"]
prev_files = json.loads(os.environ.get("PREV_FILES_JSON", "{}"))
manifest_text = os.environ.get("MANIFEST_TEXT", "")

remote = {}
for line in manifest_text.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("\t")
    if len(parts) < 5:
        continue
    section, name, size_s, sha_field, url_path = parts[0], parts[1], parts[2], parts[3], parts[4]
    sha = sha_field.replace("sha256:", "")
    # URL-encode the path (spaces→%20, brackets→%5B/%5D, etc.)
    encoded_path = quote(url_path, safe="/")
    key = section + "/" + name
    remote[key] = {
        "section": section, "name": name, "size": int(size_s),
        "sha256": sha, "url": PUBLIC_URL + "/" + encoded_path
    }

downloads = []
removals = []
unchanged = 0

for key, info in remote.items():
    if key in prev_files and prev_files[key].get("sha256") == info["sha256"]:
        unchanged += 1
    else:
        downloads.append(info)

for key, info in prev_files.items():
    if key not in remote:
        removals.append({"section": info["section"], "name": info["name"]})

print(json.dumps({
    "downloads": downloads, "removals": removals,
    "unchanged": unchanged, "total": len(remote),
    "remote_files": remote
}))
PYEOF
  )"

  local dl_count rm_count unch_count
  dl_count="$(echo "$plan_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['downloads']))")"
  rm_count="$(echo "$plan_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['removals']))")"
  unch_count="$(echo "$plan_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['unchanged'])")"

  log "Plan: $dl_count to download, $rm_count to remove, $unch_count unchanged"

  if [ "$dl_count" -eq 0 ] && [ "$rm_count" -eq 0 ]; then
    log "Everything up-to-date on $release_id"
    python3 -c "
import json
d = json.load(open('$STATE_FILE')); d['was_uptodate'] = True
json.dump(d, open('$STATE_FILE','w'), indent=2)
" 2>/dev/null || true
    return 0
  fi

  # Dry-run: just report
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN:"
    echo "$plan_json" | python3 -c "
import json,sys
p = json.load(sys.stdin)
for d in p['downloads']: print(f\"  + {d['section']}/{d['name']} ({d['size']}B)\")
for r in p['removals']:  print(f\"  - {r['section']}/{r['name']}\")
"
    return 0
  fi

  # 4. Download new/changed files
  local dl_list
  dl_list="$(echo "$plan_json" | python3 -c "
import json,sys
for d in json.load(sys.stdin)['downloads']:
    print(d['section'] + '\t' + d['name'] + '\t' + d['url'] + '\t' + d['sha256'])
")"

  local ok=0 fail=0 retries=0 current=0
  while IFS=$'\t' read -r section name url sha; do
    [ -n "$name" ] || continue
    current=$((current + 1))
    local short_name="${name:0:40}"
    [ ${#name} -gt 40 ] && short_name="${name:0:37}..."
    progress_bar "$current" "$dl_count" "$short_name"
    local dir="$MC_DIR/$section"
    mkdir -p "$dir"
    local target="$dir/$name"
    local tmp="$dir/.pummelchen-dl-$$"
    local attempt=0 max_attempts=3 success=0
    while [ "$attempt" -lt "$max_attempts" ]; do
      attempt=$((attempt + 1))
      if curl -gfsS --retry 3 --retry-delay 2 --retry-all-errors \
           --connect-timeout 15 --max-time 300 \
           -o "$tmp" "$url" 2>/dev/null; then
        local actual
        actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
        if [ "$actual" = "$sha" ]; then
          mv -f "$tmp" "$target"
          ok=$((ok + 1))
          success=1
          break
        else
          log "  SHA256 mismatch for $name (attempt $attempt/$max_attempts)"
          rm -f "$tmp"
        fi
      else
        if [ "$attempt" -lt "$max_attempts" ]; then
          log "  Download failed: $name (attempt $attempt/$max_attempts, retrying...)"
          sleep 2
        else
          log "  Download failed: $name (gave up after $max_attempts attempts)"
        fi
        rm -f "$tmp"
      fi
    done
    if [ "$success" -eq 0 ]; then
      fail=$((fail + 1))
    fi
    if [ "$attempt" -gt 1 ] && [ "$success" -eq 1 ]; then
      retries=$((retries + 1))
    fi
  done <<< "$dl_list"
  progress_bar "$dl_count" "$dl_count" "done"
  log "Downloads: $ok ok, $fail failed, $retries retried"

  # 5. Remove managed files no longer in release
  local rm_list
  rm_list="$(echo "$plan_json" | python3 -c "
import json,sys
for r in json.load(sys.stdin)['removals']:
    print(r['section'] + '\t' + r['name'])
")"

  local rm_ok=0 rm_current=0
  while IFS=$'\t' read -r section name; do
    [ -n "$name" ] || continue
    rm_current=$((rm_current + 1))
    local short_name="${name:0:40}"
    [ ${#name} -gt 40 ] && short_name="${name:0:37}..."
    progress_bar "$rm_current" "$rm_count" "rm: $short_name"
    local target="$MC_DIR/$section/$name"
    if [ -f "$target" ]; then
      log "  - $section/$name"
      rm -f "$target"
      rm_ok=$((rm_ok + 1))
    fi
  done <<< "$rm_list"

  # 6. Save state
  local new_files_json
  new_files_json="$(echo "$plan_json" | python3 -c "
import json,sys
p = json.load(sys.stdin)
files = {}
for k,v in p['remote_files'].items():
    files[k] = {'section':v['section'],'name':v['name'],'sha256':v['sha256']}
print(json.dumps(files))
")"

  python3 -c "
import json
state = {
    'release_id': '$release_id',
    'synced_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'was_uptodate': False,
    'files': json.loads('''$new_files_json''')
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null

  # 7. Notify
  notify "Synced $ok files, removed $rm_ok — release $release_id" "Pummelchen Updated"
  log "Sync complete: $ok downloaded ($fail failed, $retries retried), $rm_ok removed"
}

# ── Entry point ────────────────────────────────────────────────
sync_client
