#!/usr/bin/env python3
"""Cleanup old mod acceptance lab work directories and logs.

This script removes lab work directories and logs older than a specified age
to prevent disk space exhaustion from accumulated test artifacts.
"""

from __future__ import annotations

import argparse
import datetime as dt
import shutil
import sys
from pathlib import Path


DEFAULT_LAB_ROOT = Path("/var/minecraft_mods/mod_acceptance_lab")
DEFAULT_DAYS = 7


def cleanup_lab_root(lab_root: Path, max_age_days: int, dry_run: bool = False) -> tuple[int, int]:
    """Remove work and log directories older than max_age_days.

    Returns:
        (removed_count, freed_bytes)
    """
    if not lab_root.exists():
        return 0, 0

    removed = 0
    freed_bytes = 0
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=max_age_days)
    cutoff_ts = cutoff.timestamp()

    for subdir in ("work", "logs", "client-work", "client-logs"):
        dir_path = lab_root / subdir
        if not dir_path.exists():
            continue
        for item in sorted(dir_path.iterdir()):
            try:
                mtime = dt.datetime.fromtimestamp(item.stat().st_mtime, tz=dt.timezone.utc)
                if mtime < cutoff:
                    size = sum(f.stat().st_size for f in item.rglob("*") if f.is_file())
                    if dry_run:
                        print(f"[DRY-RUN] Would remove {item} (age: {dt.datetime.now(dt.timezone.utc) - mtime}, size: {size} bytes)")
                    else:
                        shutil.rmtree(item)
                        print(f"Removed {item} (age: {dt.datetime.now(dt.timezone.utc) - mtime}, freed: {size} bytes)")
                    removed += 1
                    freed_bytes += size
            except (OSError, ValueError) as e:
                print(f"Error processing {item}: {e}", file=sys.stderr)

    return removed, freed_bytes


def main() -> int:
    parser = argparse.ArgumentParser(description="Cleanup old mod acceptance lab artifacts")
    parser.add_argument("--lab-root", type=Path, default=DEFAULT_LAB_ROOT)
    parser.add_argument("--max-age-days", type=int, default=DEFAULT_DAYS, help="Maximum age in days before cleanup")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be removed without removing")
    args = parser.parse_args()

    removed, freed = cleanup_lab_root(args.lab_root, args.max_age_days, dry_run=args.dry_run)
    print(f"Cleanup complete: removed {removed} directories, freed {freed} bytes ({freed / (1024**3):.2f} GiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())