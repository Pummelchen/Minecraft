#!/bin/sh
set -eu

PROJECT_DIR="${PROJECT_DIR:-/var/minecraft_mods}"
SERVER_DIR="${SERVER_DIR:-/var/minecraft_26.1.2}"

/usr/bin/python3 "$PROJECT_DIR/scripts/daily_release_pipeline.py" \
  --db "$PROJECT_DIR/data/minecraft_mods.sqlite" \
  --server-dir "$SERVER_DIR" \
  --project-root "$PROJECT_DIR" \
  --release-root "$PROJECT_DIR/releases" \
  --public-downloads "$PROJECT_DIR/site/public/downloads" \
  --site-output "$PROJECT_DIR/site/public" \
  --release-backup-dir "$PROJECT_DIR/release_backups" \
  --trigger cron \
  --scan-limit 200 \
  --apply-limit 5

if command -v hdiutil >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
  echo "Starting installer DMG rebuild..."
  "$PROJECT_DIR/scripts/build_mac_client_dmg.sh" "$SERVER_DIR" || {
    echo "DMG build failed. Failing the update cycle so this release does not get published without an installer artifact." >&2
    exit 1
  }
else
  echo "Skipping DMG rebuild; hdiutil and swiftc are required on macOS builders." >&2
fi
