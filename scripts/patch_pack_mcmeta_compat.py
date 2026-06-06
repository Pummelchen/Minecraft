#!/usr/bin/env python3
"""Clamp mod pack.mcmeta resource metadata to a target Minecraft pack format."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


PACK_MCMETA = "pack.mcmeta"


def patch_pack_metadata(payload: bytes, *, target_format: int, min_format: int) -> tuple[bytes, int]:
    data = json.loads(payload.decode("utf-8"))
    pack = data.get("pack") if isinstance(data, dict) else None
    if not isinstance(pack, dict):
        return payload, 0

    changes = 0
    pack_format = pack.get("pack_format")
    if not isinstance(pack_format, int) or pack_format < min_format or pack_format > target_format:
        pack["pack_format"] = target_format
        changes += 1

    supported = pack.get("supported_formats")
    should_clamp = False
    if isinstance(supported, list) and supported:
        numeric = [value for value in supported if isinstance(value, int)]
        should_clamp = bool(numeric and (min(numeric) < min_format or max(numeric) > target_format))
    elif isinstance(supported, dict):
        max_value = supported.get("max_format")
        should_clamp = isinstance(max_value, int) and max_value > target_format

    if should_clamp:
        pack["supported_formats"] = [min_format, target_format]
        changes += 1

    if changes == 0:
        return payload, 0
    return (json.dumps(data, indent=2, ensure_ascii=False) + "\n").encode("utf-8"), changes


def patch_jar(source: Path, target: Path, *, target_format: int, min_format: int) -> int:
    if not source.is_file():
        raise FileNotFoundError(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source, "r") as src:
        if PACK_MCMETA not in src.namelist():
            raise RuntimeError(f"{PACK_MCMETA} not found in {source}")
        patched, changes = patch_pack_metadata(
            src.read(PACK_MCMETA),
            target_format=target_format,
            min_format=min_format,
        )
        if changes == 0:
            raise RuntimeError("pack.mcmeta did not need compatibility clamping")
        with tempfile.NamedTemporaryFile(prefix=target.name, suffix=".tmp", dir=target.parent, delete=False) as handle:
            tmp_path = Path(handle.name)
        try:
            with zipfile.ZipFile(tmp_path, "w") as dst:
                for item in src.infolist():
                    payload = patched if item.filename == PACK_MCMETA else src.read(item.filename)
                    dst.writestr(item, payload)
            shutil.move(str(tmp_path), target)
        finally:
            tmp_path.unlink(missing_ok=True)
    return changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--target-format", type=int, default=64)
    parser.add_argument("--min-format", type=int, default=15)
    args = parser.parse_args()
    changes = patch_jar(args.source, args.target, target_format=args.target_format, min_format=args.min_format)
    print(f"patched_resource_count={changes}")
    print(f"target={args.target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
