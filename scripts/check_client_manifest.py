#!/usr/bin/env python3
"""Validate Pummelchen client-package manifests."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from pummelchen_utils import sha256_file

MANAGED_SECTIONS = {"mods", "resourcepacks", "shaderpacks", "tools"}


def _is_managed_tool(path: Path) -> bool:
    if path.name in {"upload-token.txt", "upload-token.txt.example"}:
        return False
    if path.name.startswith("."):
        return False
    if path.suffix.lower() not in {".sh", ".java", ".txt", ".md", ".json"}:
        return False
    return True


def parse_manifest(path: Path) -> list[tuple[str, str, int, str]]:
    rows: list[tuple[str, str, int, str]] = []
    section = ""
    for line_number, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if not section:
            raise ValueError(f"{path}:{line_number}: manifest entry before section header")
        parts = raw.split("\t")
        if len(parts) < 3:
            raise ValueError(f"{path}:{line_number}: expected name, size, sha256 columns")
        if section in MANAGED_SECTIONS:
            try:
                size = int(parts[1])
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid size {parts[1]!r}") from exc
            expected = parts[2].removeprefix("sha256:")
            if len(expected) != 64:
                raise ValueError(f"{path}:{line_number}: invalid sha256 {parts[2]!r}")
            rows.append((section, parts[0], size, expected))
    return rows


def validate_manifest(package_dir: Path, *, strict: bool) -> list[str]:
    problems: list[str] = []
    manifest = package_dir / "manifest.txt"
    if not manifest.exists():
        return [f"missing manifest: {manifest}"]
    try:
        rows = parse_manifest(manifest)
    except Exception as exc:
        return [str(exc)]
    seen: set[tuple[str, str]] = set()
    for section, name, size, expected_hash in rows:
        key = (section, name)
        if key in seen:
            problems.append(f"duplicate manifest entry: {section}/{name}")
            continue
        seen.add(key)
        path = package_dir / section / name
        if not path.exists():
            if strict:
                problems.append(f"manifest file missing: {section}/{name}")
            continue
        if not path.is_file():
            problems.append(f"manifest path is not a file: {section}/{name}")
            continue
        if path.stat().st_size != size:
            problems.append(f"size mismatch: {section}/{name}")
        actual = sha256_file(path)
        if actual != expected_hash:
            problems.append(f"sha256 mismatch: {section}/{name}")
    if strict:
        for section in MANAGED_SECTIONS:
            folder = package_dir / section
            if not folder.exists():
                continue
            for path in sorted(folder.iterdir(), key=lambda item: item.name.lower()):
                if not path.is_file():
                    continue
                if section == "tools" and not _is_managed_tool(path):
                    continue
                if (section, path.name) not in seen:
                    problems.append(f"untracked client file: {section}/{path.name}")
    return problems


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_dir", type=Path)
    parser.add_argument("--strict", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    problems = validate_manifest(args.package_dir, strict=args.strict)
    if problems:
        for problem in problems:
            print(f"ERROR {problem}", file=sys.stderr)
        return 1
    print("client_manifest=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
