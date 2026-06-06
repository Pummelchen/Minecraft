#!/usr/bin/env python3
"""Replace Productive Farming's unsupported bucket model loader with a safe fallback."""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import zipfile
from pathlib import Path


ITEM_DEFINITION_PATH = "assets/productivefarming/items/nutrient_water_bucket.json"
LEGACY_MODEL_PATH = "assets/productivefarming/models/item/nutrient_water_bucket.json"
MODEL_PATHS = {
    ITEM_DEFINITION_PATH,
    LEGACY_MODEL_PATH,
}
ITEM_DEFINITION_FALLBACK = {
    "model": {
        "type": "minecraft:model",
        "model": "minecraft:item/water_bucket",
    },
}
LEGACY_MODEL_FALLBACK = {
    "parent": "minecraft:item/generated",
    "textures": {
        "layer0": "minecraft:item/water_bucket",
    },
}

FALLBACKS = {
    ITEM_DEFINITION_PATH: ITEM_DEFINITION_FALLBACK,
    LEGACY_MODEL_PATH: LEGACY_MODEL_FALLBACK,
}


def patch_jar(source: Path, target: Path) -> int:
    patched = 0
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(delete=False, suffix=".jar", dir=str(target.parent)) as tmp:
        tmp_path = Path(tmp.name)
    try:
        with zipfile.ZipFile(source, "r") as src, zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as dst:
            for info in src.infolist():
                data = src.read(info.filename)
                if info.filename in MODEL_PATHS:
                    try:
                        parsed = json.loads(data.decode("utf-8"))
                    except json.JSONDecodeError as exc:
                        raise RuntimeError(f"invalid JSON in {info.filename}: {exc}") from exc
                    fallback = FALLBACKS[info.filename]
                    encoded = json.dumps(fallback, indent=2, sort_keys=True).encode("utf-8") + b"\n"
                    if parsed != fallback:
                        data = encoded
                        patched += 1
                dst.writestr(info, data)
        if patched == 0:
            raise RuntimeError("no known Productive Farming bucket model defect found")
        shutil.move(str(tmp_path), target)
    finally:
        tmp_path.unlink(missing_ok=True)
    return patched


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    patched = patch_jar(args.source, args.target)
    print(f"source={args.source}")
    print(f"target={args.target}")
    print(f"patched_models={patched}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
