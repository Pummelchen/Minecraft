#!/usr/bin/env python3
"""Repair client-side resource defects in MOTS Structures 1.4."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


LANG_PATH = "assets/mot/lang/en_us.json"
ITEM_MODEL_PATHS = (
    "assets/minecraft/items/filled_map.json",
    "assets/minecraft/items/ominous_trial_key.json",
    "assets/minecraft/items/trial_key.json",
)


def patch_lang(data: str) -> tuple[str, int]:
    patched = data
    replacements = {
        r'("item\.mot\.chart\.village_taiga"\s*:\s*"Taiga Village Chart")(\r?\n\s*"item\.mot\.chart\.explorer_jungle")': r"\1,\2",
        r'("item\.mot\.chart\.explorer_jungle"\s*:\s*"Jungle Explorer Chart")(\r?\n\s*\r?\n\s*\r?\n\s*"advancement\.mot\.adventure\.find_resin_crypt\.title")': r"\1,\2",
    }
    changes = 0
    for needle, replacement in replacements.items():
        patched, count = re.subn(needle, replacement, patched, count=1)
        changes += count
    legacy_replacements = (
        (
            '"item.mot.chart.village_taiga": "Taiga Village Chart"\n'
            '    "item.mot.chart.explorer_jungle": "Jungle Explorer Chart"',
            '"item.mot.chart.village_taiga": "Taiga Village Chart",\n'
            '    "item.mot.chart.explorer_jungle": "Jungle Explorer Chart"',
        ),
        (
            '"item.mot.chart.explorer_jungle": "Jungle Explorer Chart"\n\n\n'
            '    "advancement.mot.adventure.find_resin_crypt.title"',
            '"item.mot.chart.explorer_jungle": "Jungle Explorer Chart",\n\n\n'
            '    "advancement.mot.adventure.find_resin_crypt.title"',
        ),
    )
    for needle, replacement in legacy_replacements:
        if needle in patched:
            patched = patched.replace(needle, replacement, 1)
            changes += 1
    json.loads(patched)
    return patched, changes


def model_reference(entry: object) -> str:
    if not isinstance(entry, dict):
        return ""
    model = entry.get("model")
    if isinstance(model, str):
        return model
    if isinstance(model, dict):
        nested = model.get("model")
        if isinstance(nested, str):
            return nested
    return ""


def remove_dnt_references(payload: bytes) -> tuple[bytes, int]:
    data = json.loads(payload.decode("utf-8"))
    model = data.get("model") if isinstance(data, dict) else None
    if not isinstance(model, dict):
        return payload, 0

    changes = 0
    cases = model.get("cases")
    if isinstance(cases, list):
        kept_cases = []
        for entry in cases:
            when = entry.get("when") if isinstance(entry, dict) else None
            ref = model_reference(entry)
            if (isinstance(when, str) and when.startswith("dnt:")) or ref.startswith("dnt:"):
                changes += 1
                continue
            kept_cases.append(entry)
        model["cases"] = kept_cases

    entries = model.get("entries")
    if isinstance(entries, list):
        kept_entries = []
        for entry in entries:
            if model_reference(entry).startswith("dnt:"):
                changes += 1
                continue
            kept_entries.append(entry)
        model["entries"] = kept_entries

    if changes == 0:
        return payload, 0
    return (json.dumps(data, indent=2, ensure_ascii=False) + "\n").encode("utf-8"), changes


def patch_jar(source: Path, target: Path) -> int:
    if not source.is_file():
        raise FileNotFoundError(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source, "r") as src:
        if LANG_PATH not in src.namelist():
            raise RuntimeError(f"{LANG_PATH} not found in {source}")
        original = src.read(LANG_PATH).decode("utf-8")
        patched, changes = patch_lang(original)
        patched_items: dict[str, bytes] = {}
        item_changes = 0
        for path in ITEM_MODEL_PATHS:
            if path not in src.namelist():
                continue
            patched_item, count = remove_dnt_references(src.read(path))
            if count:
                patched_items[path] = patched_item
                item_changes += count
        if changes == 0 and item_changes == 0:
            raise RuntimeError("no known MOTS resource defect found")
        with tempfile.NamedTemporaryFile(prefix=target.name, suffix=".tmp", dir=target.parent, delete=False) as handle:
            tmp_path = Path(handle.name)
        try:
            with zipfile.ZipFile(tmp_path, "w") as dst:
                for item in src.infolist():
                    if item.filename == LANG_PATH:
                        payload = patched.encode("utf-8")
                    elif item.filename in patched_items:
                        payload = patched_items[item.filename]
                    else:
                        payload = src.read(item.filename)
                    dst.writestr(item, payload)
            shutil.move(str(tmp_path), target)
        finally:
            tmp_path.unlink(missing_ok=True)
    return changes + item_changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    changes = patch_jar(args.source, args.target)
    print(f"patched_resource_count={changes}")
    print(f"target={args.target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
