#!/usr/bin/env python3
"""Shared utility functions for the Pummelchen Minecraft control plane.

All scripts in this package import from here to avoid duplicating common
helpers.  Every function in this module is pure-stdlib (no pip dependencies).

**Dependency policy**: the entire Pummelchen control plane runs on the Python
standard library only.  Do not add ``pip install`` requirements; if an external
library is ever needed it must be vendored or wrapped via subprocess.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from pathlib import Path
from typing import Any

try:
    import fcntl  # type: ignore[import-not-found]
except ImportError:
    fcntl = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# Server connection constants
# ---------------------------------------------------------------------------
# These are the canonical defaults for the Pummelchen VPS.  Scripts use them
# as argparse defaults so that operators can override via CLI flags.

SERVER_PUBLIC_URL = "http://91.99.176.243:7788"
SERVER_HOST = "91.99.176.243"
SERVER_MC_PORT = 25565
MRPACK_NAME = "pummelchen-server-26.1.2.mrpack"


# ---------------------------------------------------------------------------
# File hashing
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    """Return the hex-encoded SHA-256 digest of *path*."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# Atomic JSON writer
# ---------------------------------------------------------------------------

def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    """Write *payload* as pretty-printed JSON using a temp-file + rename.

    Uses an advisory file lock when ``fcntl`` is available (Linux / macOS)
    to coordinate with concurrent readers.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        if fcntl is not None:
            fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


# ---------------------------------------------------------------------------
# SQLite helpers
# ---------------------------------------------------------------------------

def table_exists(conn: sqlite3.Connection, table_name: str) -> bool:
    """Return ``True`` if *table_name* exists as a table or view."""
    if hasattr(conn, "has_table"):
        return bool(conn.has_table(table_name))
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
        (table_name,),
    ).fetchone()
    return bool(row)


# ---------------------------------------------------------------------------
# Properties file parser
# ---------------------------------------------------------------------------

def read_properties(path: Path) -> dict[str, str]:
    """Parse a Java-style ``key=value`` properties file into a dict.

    Blank lines and lines starting with ``#`` are ignored.  This is the
    simple variant that returns a flat dict; scripts that need to preserve
    line order for in-place editing should keep their own specialised reader.
    """
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def human_bytes(value: float) -> str:
    """Format *value* bytes into a human-readable string (B/KB/MB/GB/TB)."""
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TB"


def display_release_version(release_id: str) -> str:
    """Convert a release identifier to a human-friendly version string.

    ``release_20260607_V9_daily`` → ``2026-06-07_V9``
    """
    value = (release_id or "").strip()
    match = re.fullmatch(r"release_(\d{4})(\d{2})(\d{2})_([^_]+)(?:_.*)?", value)
    if match:
        year, month, day, version = match.groups()
        if version_match := re.match(r"(V\d+)", version, re.IGNORECASE):
            version = version_match.group(1).upper()
        return f"{year}-{month}-{day}_{version}"
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})_([^_]+)(?:_.*)?", value)
    if match:
        year, month, day, version = match.groups()
        if version_match := re.match(r"(V\d+)", version, re.IGNORECASE):
            version = version_match.group(1).upper()
        return f"{year}-{month}-{day}_{version}"
    return value or "Unknown"
