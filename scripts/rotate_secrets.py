#!/usr/bin/env python3
"""Rotate secrets for Pummelchen services.

This script generates new secrets and updates the credential files used by systemd LoadCredential.
After rotation, affected services must be restarted to pick up the new credentials.
"""

from __future__ import annotations

import argparse
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

SECRETS_DIR = Path("/var/minecraft_mods/secrets")

CREDENTIALS = {
    "client-log-upload-token": {
        "description": "Token for client diagnostic log uploads",
        "length": 64,
        "services": ["pummelchen-client-log-receiver.service"],
    },
    "rcon-password": {
        "description": "RCON password for Minecraft server",
        "length": 32,
        "services": ["pummelchen-minecraft.service"],
    },
}


def generate_token(length: int) -> str:
    """Generate a cryptographically secure random token."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def rotate_credential(name: str, length: int, dry_run: bool = False) -> str:
    """Rotate a single credential."""
    token = generate_token(length)
    cred_path = SECRETS_DIR / name

    if dry_run:
        print(f"DRY-RUN: Would write new {name} ({len(token)} chars)")
        return token

    # Backup existing credential
    if cred_path.exists():
        backup = SECRETS_DIR / f"{name}.bak.{int(os.path.getmtime(cred_path))}"
        shutil.copy2(cred_path, backup)
        print(f"Backed up {name} to {backup}")

    # Write new credential
    cred_path.parent.mkdir(parents=True, exist_ok=True)
    cred_path.write_text(token + "\n", encoding="utf-8")
    cred_path.chmod(0o600)
    print(f"Rotated {name}")

    return token


def restart_services(services: list[str], dry_run: bool = False) -> None:
    """Restart systemd services."""
    for service in services:
        if dry_run:
            print(f"DRY-RUN: Would restart {service}")
            continue
        try:
            subprocess.run(["systemctl", "reload-or-restart", service], check=True)
            print(f"Restarted {service}")
        except subprocess.CalledProcessError as e:
            print(f"Failed to restart {service}: {e}", file=sys.stderr)


def update_client_package_token(token: str, dry_run: bool = False) -> None:
    """Update the upload token in the client package for rebuild."""
    token_file = Path("/var/minecraft_26.1.2/client-package/tools/upload-token.txt")
    if dry_run:
        print(f"DRY-RUN: Would update {token_file}")
        return
    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.write_text(token + "\n", encoding="utf-8")
    token_file.chmod(0o600)
    print(f"Updated client package token at {token_file}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Rotate Pummelchen secrets")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done without making changes")
    parser.add_argument("--only", choices=list(CREDENTIALS.keys()), help="Rotate only a specific credential")
    parser.add_argument("--no-restart", action="store_true", help="Don't restart services after rotation")
    parser.add_argument("--rebuild-client", action="store_true", help="Rebuild client package after token rotation")
    args = parser.parse_args()

    if args.dry_run:
        print("=== DRY RUN MODE ===")

    targets = {args.only: CREDENTIALS[args.only]} if args.only else CREDENTIALS

    for name, info in targets.items():
        print(f"\nRotating {name} ({info['description']})...")
        token = rotate_credential(name, info["length"], dry_run=args.dry_run)

        if name == "client-log-upload-token":
            update_client_package_token(token, dry_run=args.dry_run)

        if not args.no_restart:
            restart_services(info["services"], dry_run=args.dry_run)

    if args.rebuild_client and not args.dry_run:
        print("\nRebuilding client package with new token...")
        try:
            subprocess.run([
                "python3", "/var/minecraft_mods/scripts/daily_update.py",
                "--db", "/var/minecraft_mods/data/minecraft_mods.sqlite",
                "--server-dir", "/var/minecraft_26.1.2",
                "rebuild-client"
            ], check=True)
            print("Client package rebuilt")
        except subprocess.CalledProcessError as e:
            print(f"Client rebuild failed: {e}", file=sys.stderr)
            return 1

    if args.dry_run:
        print("\n=== DRY RUN COMPLETE ===")
    else:
        print("\n=== ROTATION COMPLETE ===")

    return 0


if __name__ == "__main__":
    sys.exit(main())