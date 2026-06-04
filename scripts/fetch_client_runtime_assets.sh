#!/bin/bash
set -euo pipefail

SERVER_DIR="${1:-/var/minecraft_26.1.2}"
NEOFORGE_VERSION="${NEOFORGE_VERSION:-26.1.2.71}"
CLIENT_PACKAGE_DIR="$SERVER_DIR/client-package"
INSTALLER_NAME="neoforge-${NEOFORGE_VERSION}-installer.jar"
INSTALLER_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/${INSTALLER_NAME}"

mkdir -p "$CLIENT_PACKAGE_DIR"

if [ -f "$CLIENT_PACKAGE_DIR/$INSTALLER_NAME" ]; then
  echo "exists=$CLIENT_PACKAGE_DIR/$INSTALLER_NAME"
  exit 0
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/neoforge-installer.XXXXXX.jar")"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
  "$INSTALLER_URL" \
  --output "$tmp"

if [ ! -s "$tmp" ]; then
  echo "Downloaded NeoForge installer is empty." >&2
  exit 1
fi

mv "$tmp" "$CLIENT_PACKAGE_DIR/$INSTALLER_NAME"
chmod 0644 "$CLIENT_PACKAGE_DIR/$INSTALLER_NAME"
echo "installed=$CLIENT_PACKAGE_DIR/$INSTALLER_NAME"
