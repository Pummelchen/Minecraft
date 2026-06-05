#!/usr/bin/env python3
"""Normalize resource-pack metadata keys that crash modern Minecraft clients."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


@dataclass(frozen=True)
class Change:
    path: Path
    member: str
    added_keys: int
    removed_keys: int


ROOT_SCHEMA_TRANSITION_FORMAT = 82
OVERLAY_SCHEMA_TRANSITION_FORMAT = 65


def candidate_files(path: Path) -> list[Path]:
    if path.is_file() and path.suffix.lower() == ".zip":
        return [path]
    if path.is_file() and path.suffix.lower() == ".jar":
        return [path]
    roots: list[Path] = []
    if (path / "mods").is_dir():
        roots.append(path / "mods")
    if (path / "resourcepacks").is_dir():
        roots.append(path / "resourcepacks")
    if not roots and path.is_dir():
        roots.append(path)
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        files.extend(item for item in root.iterdir() if item.is_file() and item.suffix.lower() in {".zip", ".jar"})
    return sorted(set(files), key=lambda item: item.name.lower())


def format_major(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, list) and value:
        return format_major(value[0])
    if isinstance(value, dict):
        for key in ("min_inclusive", "min_format"):
            major = format_major(value.get(key))
            if major is not None:
                return major
    return None


def format_max_major(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, list) and value:
        return format_major(value[0])
    if isinstance(value, dict):
        for key in ("max_inclusive", "max_format"):
            major = format_major(value.get(key))
            if major is not None:
                return major
    return None


def range_from_value(value: Any) -> list[int] | None:
    if isinstance(value, list) and len(value) >= 2:
        minimum = format_major(value[0])
        maximum = format_major(value[1])
        if minimum is not None and maximum is not None:
            return [minimum, maximum]
    minimum = format_major(value)
    maximum = format_max_major(value)
    if minimum is None or maximum is None:
        return None
    return [minimum, maximum]


def make_formats_value(entry: dict[str, Any]) -> list[int] | None:
    min_format = format_major(entry.get("min_format"))
    max_format = format_major(entry.get("max_format"))
    if min_format is None or max_format is None:
        return range_from_value(entry.get("formats"))
    return [min_format, max_format]


def pack_min_format(pack: Any) -> int | None:
    if not isinstance(pack, dict):
        return None
    for key in ("min_format", "supported_formats"):
        major = format_major(pack.get(key))
        if major is not None:
            return major
    return format_major(pack.get("pack_format"))


def pack_max_format(pack: Any) -> int | None:
    if not isinstance(pack, dict):
        return None
    major = format_major(pack.get("max_format"))
    if major is not None:
        return major
    supported = range_from_value(pack.get("supported_formats"))
    if supported is not None:
        return supported[1]
    return format_max_major(pack.get("pack_format"))


def pack_format_major(pack: Any) -> int | None:
    if not isinstance(pack, dict):
        return None
    return format_major(pack.get("pack_format"))


def root_pack_uses_modern_schema(pack: Any) -> bool:
    minimum = pack_min_format(pack)
    return minimum is not None and minimum >= ROOT_SCHEMA_TRANSITION_FORMAT


def overlay_entries_use_modern_schema(pack: Any) -> bool:
    pack_format = pack_format_major(pack)
    if pack_format is not None:
        return pack_format >= OVERLAY_SCHEMA_TRANSITION_FORMAT
    minimum = pack_min_format(pack)
    return minimum is not None and minimum >= OVERLAY_SCHEMA_TRANSITION_FORMAT


def sanitize_root_pack(pack: Any) -> tuple[int, int]:
    if not isinstance(pack, dict):
        return 0, 0
    added = 0
    removed = 0
    if root_pack_uses_modern_schema(pack):
        supported = range_from_value(pack.get("supported_formats"))
        if "min_format" not in pack and supported is not None:
            pack["min_format"] = supported[0]
            added += 1
        if "max_format" not in pack and supported is not None:
            pack["max_format"] = supported[1]
            added += 1
        if "supported_formats" in pack:
            del pack["supported_formats"]
            removed += 1
        return added, removed
    min_format = pack_min_format(pack)
    max_format = pack_max_format(pack)
    if min_format is None:
        return added, removed
    if max_format is None:
        max_format = min_format
    supported_formats = [min_format, max_format]
    if pack.get("supported_formats") != supported_formats:
        pack["supported_formats"] = supported_formats
        added += 1
    for key in ("min_format", "max_format"):
        if key in pack:
            del pack[key]
            removed += 1
    return added, removed


def should_remove_member(member: str) -> bool:
    parts = member.split("/")
    return (
        member.startswith("__MACOSX/")
        or member.startswith("._")
        or "/._" in member
        or any(part == ".DS_Store" for part in parts)
    )


def sanitize_overlay_entries(entries: Any, *, pack: Any, target: str) -> tuple[int, int]:
    if not isinstance(entries, list):
        return 0, 0
    added = 0
    removed = 0
    use_modern_schema = overlay_entries_use_modern_schema(pack)
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        formats_value = make_formats_value(entry)
        if use_modern_schema:
            if formats_value is not None:
                if "min_format" not in entry:
                    entry["min_format"] = formats_value[0]
                    added += 1
                if "max_format" not in entry:
                    entry["max_format"] = formats_value[1]
                    added += 1
            if "formats" in entry:
                del entry["formats"]
                removed += 1
            continue
        if formats_value is not None and entry.get("formats") != formats_value:
            entry["formats"] = formats_value
            added += 1
        if formats_value is not None:
            if "min_format" not in entry:
                entry["min_format"] = formats_value[0]
                added += 1
            if "max_format" not in entry:
                entry["max_format"] = formats_value[1]
                added += 1
    return added, removed


def sanitize_pack_metadata(metadata: dict[str, Any], *, target: str) -> tuple[int, int]:
    added, removed = sanitize_root_pack(metadata.get("pack"))
    pack = metadata.get("pack")
    for key, value in metadata.items():
        if key == "overlays" or key.endswith(":overlays"):
            if isinstance(value, dict):
                entry_added, entry_removed = sanitize_overlay_entries(
                    value.get("entries"),
                    pack=pack,
                    target=target,
                )
                added += entry_added
                removed += entry_removed
    return added, removed


def rewrite_zip_member(path: Path, replacements: dict[str, bytes], removals: set[str] | None = None) -> None:
    removals = removals or set()
    with tempfile.NamedTemporaryFile(prefix=f"{path.name}.", suffix=".tmp", delete=False) as handle:
        tmp_path = Path(handle.name)
    try:
        with zipfile.ZipFile(path, "r") as source, zipfile.ZipFile(tmp_path, "w") as target:
            written: set[str] = set()
            for info in source.infolist():
                if info.filename in removals:
                    continue
                if info.filename in written:
                    continue
                written.add(info.filename)
                data = replacements.get(info.filename)
                if data is None:
                    data = source.read(info.filename)
                target.writestr(info, data)
        shutil.move(str(tmp_path), path)
    finally:
        tmp_path.unlink(missing_ok=True)


def sanitize_zip(path: Path, *, write: bool, target: str) -> list[Change]:
    changes: list[Change] = []
    replacements: dict[str, bytes] = {}
    removals: set[str] = set()
    try:
        with zipfile.ZipFile(path, "r") as archive:
            for member in archive.namelist():
                if should_remove_member(member):
                    removals.add(member)
                    changes.append(Change(path=path, member=member, added_keys=0, removed_keys=1))
                    continue
                if not member.endswith("pack.mcmeta"):
                    continue
                try:
                    metadata = json.loads(archive.read(member).decode("utf-8-sig"))
                except Exception as exc:
                    raise ValueError(f"{path}:{member}: invalid pack.mcmeta JSON: {exc}") from exc
                added, removed = sanitize_pack_metadata(metadata, target=target)
                if added or removed:
                    changes.append(Change(path=path, member=member, added_keys=added, removed_keys=removed))
                    replacements[member] = (json.dumps(metadata, indent=2, sort_keys=False) + "\n").encode("utf-8")
    except zipfile.BadZipFile as exc:
        raise ValueError(f"{path}: invalid zip file: {exc}") from exc
    if write and (replacements or removals):
        rewrite_zip_member(path, replacements, removals)
    return changes


def sanitize_path(path: Path, *, write: bool, target: str = "server") -> list[Change]:
    changes: list[Change] = []
    for candidate in candidate_files(path):
        changes.extend(sanitize_zip(candidate, write=write, target=target))
    return changes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="client-package directory, resourcepacks directory, or one resource-pack zip")
    parser.add_argument("--write", action="store_true", help="rewrite affected zip files in place")
    parser.add_argument(
        "--target",
        choices=("server", "client"),
        default="server",
        help="metadata compatibility target. Server and client reject different overlay schema edges.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        changes = sanitize_path(args.path, write=args.write, target=args.target)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for change in changes:
        action = "sanitized" if args.write else "would_sanitize"
        print(
            f"{action}\t{change.path}\t{change.member}"
            f"\tadded_keys={change.added_keys}\tremoved_keys={change.removed_keys}"
        )
    print(f"resource_pack_metadata_changes={len(changes)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
