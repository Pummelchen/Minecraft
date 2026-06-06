#!/usr/bin/env python3
"""Apply project-owned server config file overrides."""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def iter_override_files(source: Path) -> list[Path]:
    if not source.exists():
        return []
    if not source.is_dir():
        raise SystemExit(f"override source is not a directory: {source}")
    files: list[Path] = []
    for path in source.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"refusing symlink in config overrides: {path}")
        if path.is_file():
            files.append(path)
    return sorted(files, key=lambda item: item.as_posix().lower())


def apply_overrides(source: Path, target: Path, *, dry_run: bool = False) -> int:
    source = source.resolve()
    target = target.resolve()
    changed = 0
    for src in iter_override_files(source):
        rel = src.relative_to(source)
        if rel.is_absolute() or ".." in rel.parts:
            raise SystemExit(f"invalid override path: {rel}")
        dst = target / rel
        new_bytes = src.read_bytes()
        old_bytes = dst.read_bytes() if dst.exists() else None
        if old_bytes == new_bytes:
            continue
        changed += 1
        print(f"config_override_changed={rel.as_posix()}")
        if dry_run:
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(f".{dst.name}.tmp")
        tmp.write_bytes(new_bytes)
        shutil.copymode(src, tmp)
        tmp.replace(dst)
    print(f"config_overrides_changed={changed}")
    return changed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    apply_overrides(args.source, args.target, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
