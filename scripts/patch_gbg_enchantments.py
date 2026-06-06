#!/usr/bin/env python3
"""Patch Gamingbarn-style gun loot tables for the Minecraft 26 enchantment component codec."""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Sequence


def rewrite_value(value: Any) -> tuple[Any, int]:
    changes = 0
    if isinstance(value, dict):
        rewritten: dict[str, Any] = {}
        for key, item in value.items():
            if key == "minecraft:enchantments" and isinstance(item, dict) and "levels" not in item:
                rewritten[key] = {"levels": item}
                changes += 1
                continue
            new_item, item_changes = rewrite_value(item)
            rewritten[key] = new_item
            changes += item_changes
        return rewritten, changes
    if isinstance(value, list):
        rewritten_list = []
        for item in value:
            new_item, item_changes = rewrite_value(item)
            rewritten_list.append(new_item)
            changes += item_changes
        return rewritten_list, changes
    return value, 0


def patch_jar(source: Path, target: Path) -> tuple[int, int]:
    if not zipfile.is_zipfile(source):
        raise SystemExit(f"not a jar/zip file: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    patched_files = 0
    patched_components = 0
    with tempfile.NamedTemporaryFile(dir=target.parent, suffix=".jar.tmp", delete=False) as handle:
        tmp = Path(handle.name)
    try:
        with zipfile.ZipFile(source) as src, zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as dst:
            for info in src.infolist():
                data = src.read(info.filename)
                if info.filename.endswith(".json") and b'"minecraft:enchantments"' in data:
                    try:
                        parsed = json.loads(data.decode("utf-8"))
                    except Exception:
                        dst.writestr(info, data)
                        continue
                    rewritten, changes = rewrite_value(parsed)
                    if changes:
                        data = (json.dumps(rewritten, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
                        patched_files += 1
                        patched_components += changes
                dst.writestr(info, data)
        tmp.replace(target)
        shutil.copymode(source, target)
    finally:
        tmp.unlink(missing_ok=True)
    return patched_files, patched_components


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    files, components = patch_jar(args.source, args.target)
    print(f"source={args.source}")
    print(f"target={args.target}")
    print(f"patched_files={files}")
    print(f"patched_components={components}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
