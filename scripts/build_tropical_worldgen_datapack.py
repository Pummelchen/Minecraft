#!/usr/bin/env python3
"""Build the Pummelchen tropical worldgen override datapack.

The live server uses Terralith's Lithostitched overworld biome parameter list.
This script starts from that known-good parameter list and redirects selected
warm land climate cells into bamboo jungle, jungle, tropical jungle, and sakura
valley biomes. It intentionally avoids oceans, rivers, beaches, swamps, caves,
and existing cherry/jungle cells.
"""

from __future__ import annotations

import argparse
import json
import shutil
import zipfile
from collections import Counter
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = Path("/tmp/pummelchen-terralith-overworld.json")
DEFAULT_SRC_DIR = ROOT_DIR / "server-datapacks-src" / "pummelchen-tropical-worldgen"
DEFAULT_ZIP = ROOT_DIR / "server-datapacks" / "pummelchen-tropical-worldgen.zip"

BIOME_LIST_KEY = "lithostitched:biomes"
SURFACE_DEPTH = [-0.005, 0]

TROPICAL_TARGETS = {
    "minecraft:bamboo_jungle",
    "minecraft:jungle",
    "minecraft:sparse_jungle",
    "terralith:tropical_jungle",
    "terralith:jungle_mountains",
    "terralith:rocky_jungle",
    "terralith:amethyst_rainforest",
}

CHERRY_TARGETS = {
    "minecraft:cherry_grove",
    "terralith:sakura_grove",
    "terralith:sakura_valley",
}

EXCLUDED_LANDSCAPE_MARKERS = (
    "ocean",
    "river",
    "beach",
    "shore",
    "swamp",
    "mushroom",
    "cave/",
)

ASSIGNMENT_CYCLE = (
    "minecraft:bamboo_jungle",
    "terralith:sakura_valley",
    "terralith:tropical_jungle",
    "minecraft:bamboo_jungle",
    "minecraft:jungle",
    "terralith:amethyst_rainforest",
    "minecraft:sparse_jungle",
    "terralith:rocky_jungle",
    "minecraft:bamboo_jungle",
    "terralith:tropical_jungle",
)

VOLUME_KEYS = ("weirdness", "continentalness", "erosion", "temperature", "humidity")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-overworld-json", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--src-dir", type=Path, default=DEFAULT_SRC_DIR)
    parser.add_argument("--zip-output", type=Path, default=DEFAULT_ZIP)
    parser.add_argument("--check", action="store_true", help="validate and report without writing files")
    return parser.parse_args()


def load_source(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload.get(BIOME_LIST_KEY), list):
        raise ValueError(f"{path} does not contain {BIOME_LIST_KEY}")
    if payload.get("preset") != "minecraft:overworld":
        raise ValueError(f"{path} is not an overworld biome parameter list")
    return payload


def overlaps(entry: dict[str, Any], key: str, low: float, high: float) -> bool:
    value = entry["parameters"].get(key)
    return isinstance(value, list) and float(value[1]) > low and float(value[0]) < high


def is_surface_land(entry: dict[str, Any]) -> bool:
    biome = str(entry.get("biome") or "")
    return (
        entry.get("parameters", {}).get("depth") == SURFACE_DEPTH
        and not any(marker in biome for marker in EXCLUDED_LANDSCAPE_MARKERS)
    )


def is_tropical_candidate(entry: dict[str, Any]) -> bool:
    biome = str(entry.get("biome") or "")
    if biome in TROPICAL_TARGETS or biome in CHERRY_TARGETS:
        return False
    return (
        is_surface_land(entry)
        and overlaps(entry, "temperature", 0.2, 1.0)
        and overlaps(entry, "humidity", -0.35, 1.0)
    )


def width(value: Any) -> float:
    if not isinstance(value, list):
        return 0.0
    return max(0.0, float(value[1]) - float(value[0]))


def climate_volume(entry: dict[str, Any]) -> float:
    product = 1.0
    for key in VOLUME_KEYS:
        product *= width(entry["parameters"][key])
    return product


def rewrite_biomes(payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    output = json.loads(json.dumps(payload))
    biomes = output[BIOME_LIST_KEY]
    source_biomes = payload[BIOME_LIST_KEY]

    changed = 0
    original_tropical_volume = sum(
        climate_volume(entry)
        for entry in source_biomes
        if entry["biome"] in TROPICAL_TARGETS
    )
    original_cherry_volume = sum(
        climate_volume(entry)
        for entry in source_biomes
        if entry["biome"] in CHERRY_TARGETS
    )
    added_volume = 0.0
    replaced = Counter()
    assigned = Counter()

    for index, entry in enumerate(biomes):
        if not is_tropical_candidate(entry):
            continue
        new_biome = ASSIGNMENT_CYCLE[changed % len(ASSIGNMENT_CYCLE)]
        replaced[entry["biome"]] += 1
        assigned[new_biome] += 1
        added_volume += climate_volume(entry)
        entry["biome"] = new_biome
        changed += 1

    final_tropical_volume = sum(
        climate_volume(entry)
        for entry in biomes
        if entry["biome"] in TROPICAL_TARGETS
    )
    final_cherry_volume = sum(
        climate_volume(entry)
        for entry in biomes
        if entry["biome"] in CHERRY_TARGETS
    )
    final_counts = Counter(entry["biome"] for entry in biomes)
    report = {
        "total_entries": len(biomes),
        "changed_entries": changed,
        "original_tropical_volume": original_tropical_volume,
        "final_tropical_volume": final_tropical_volume,
        "tropical_factor": final_tropical_volume / original_tropical_volume,
        "original_cherry_volume": original_cherry_volume,
        "final_cherry_volume": final_cherry_volume,
        "cherry_factor": final_cherry_volume / original_cherry_volume,
        "added_volume": added_volume,
        "replaced": dict(sorted(replaced.items())),
        "assigned": dict(sorted(assigned.items())),
        "final_counts": {
            biome: final_counts[biome]
            for biome in sorted(TROPICAL_TARGETS | CHERRY_TARGETS)
            if final_counts[biome]
        },
    }
    if report["tropical_factor"] < 5.0:
        raise ValueError(f"tropical biome factor too low: {report['tropical_factor']:.2f}x")
    if assigned["minecraft:bamboo_jungle"] < 20:
        raise ValueError("bamboo jungle assignment did not meaningfully increase")
    if assigned["terralith:sakura_valley"] < 20:
        raise ValueError("sakura valley assignment did not meaningfully increase")
    return output, report


def write_src_datapack(src_dir: Path, overworld: dict[str, Any], report: dict[str, Any]) -> None:
    if src_dir.exists():
        shutil.rmtree(src_dir)
    target = src_dir / "data" / "minecraft" / "worldgen" / "multi_noise_biome_source_parameter_list"
    target.mkdir(parents=True)
    (src_dir / "pack.mcmeta").write_text(
        json.dumps(
            {
                "pack": {
                    "description": {
                        "text": "Pummelchen Tropical Worldgen - increases bamboo jungles, jungles, and nearby sakura valleys"
                    },
                    "min_format": [101, 1],
                    "max_format": 101,
                }
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (target / "overworld.json").write_text(json.dumps(overworld, indent=2) + "\n", encoding="utf-8")
    (src_dir / "TROPICAL_WORLDGEN.md").write_text(
        "# Pummelchen Tropical Worldgen\n\n"
        "This datapack overrides Terralith's Lithostitched overworld biome parameter list.\n"
        "It redirects selected warm land climate cells into bamboo jungle, jungle,\n"
        "Terralith tropical jungle/rainforest variants, and Terralith sakura valley.\n"
        "Oceans, rivers, beaches, swamps, caves, and existing jungle/cherry cells are not rewritten.\n\n"
        f"- Changed entries: {report['changed_entries']} of {report['total_entries']}\n"
        f"- Tropical rough climate-volume factor: {report['tropical_factor']:.2f}x\n"
        f"- Cherry/sakura rough climate-volume factor: {report['cherry_factor']:.2f}x\n",
        encoding="utf-8",
    )


def write_zip(src_dir: Path, zip_output: Path) -> None:
    zip_output.parent.mkdir(parents=True, exist_ok=True)
    tmp = zip_output.with_suffix(zip_output.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(src_dir.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(src_dir).as_posix())
    tmp.replace(zip_output)


def main() -> int:
    args = parse_args()
    source = load_source(args.source_overworld_json)
    output, report = rewrite_biomes(source)
    print(json.dumps(report, indent=2, sort_keys=True))
    if not args.check:
        write_src_datapack(args.src_dir, output, report)
        write_zip(args.src_dir, args.zip_output)
        print(f"wrote_src={args.src_dir}")
        print(f"wrote_zip={args.zip_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
