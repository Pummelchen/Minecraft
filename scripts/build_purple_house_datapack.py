#!/usr/bin/env python3
"""Build the Pummelchen Purple House worldgen datapack."""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import sys
import tempfile
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT_DIR = Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT_DIR / "server-datapacks-src" / "pummelchen-purple-house"
OUTPUT_ZIP = ROOT_DIR / "server-datapacks" / "pummelchen-purple-house.zip"
NAMESPACE = "pummelchen"
STRUCTURE_NAME = "purple_house"
PACK_FORMAT = 81
SUPPORTED_FORMATS = [81, 94]
DATA_VERSION = 4325
SPACING_CHUNKS = 108
SEPARATION_CHUNKS = 36
SALT = 20260606
ZIP_DATE = (2026, 6, 6, 0, 0, 0)


TAG_END = 0
TAG_BYTE = 1
TAG_INT = 3
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10


@dataclass(frozen=True)
class NbtList:
    item_type: int
    items: list[Any]


@dataclass(frozen=True)
class State:
    name: str
    props: tuple[tuple[str, str], ...] = ()


def st(name: str, **props: str) -> State:
    return State(name, tuple(sorted((key, str(value)) for key, value in props.items())))


AIR = st("minecraft:air")


class Structure:
    def __init__(self, size: tuple[int, int, int]) -> None:
        self.size = size
        self.blocks: dict[tuple[int, int, int], State] = {}

    def set(self, x: int, y: int, z: int, state: State) -> None:
        sx, sy, sz = self.size
        if not (0 <= x < sx and 0 <= y < sy and 0 <= z < sz):
            raise ValueError(f"block outside structure bounds: {(x, y, z)}")
        self.blocks[(x, y, z)] = state

    def fill(self, x1: int, y1: int, z1: int, x2: int, y2: int, z2: int, state: State) -> None:
        for x in range(min(x1, x2), max(x1, x2) + 1):
            for y in range(min(y1, y2), max(y1, y2) + 1):
                for z in range(min(z1, z2), max(z1, z2) + 1):
                    self.set(x, y, z, state)

    def clear(self, x1: int, y1: int, z1: int, x2: int, y2: int, z2: int) -> None:
        self.fill(x1, y1, z1, x2, y2, z2, AIR)

    def hollow_box(
        self,
        x1: int,
        y1: int,
        z1: int,
        x2: int,
        y2: int,
        z2: int,
        wall: State,
        floor: State,
        ceiling: State | None = None,
    ) -> None:
        self.clear(x1 + 1, y1 + 1, z1 + 1, x2 - 1, y2 - 1, z2 - 1)
        self.fill(x1, y1, z1, x2, y1, z2, floor)
        if ceiling is not None:
            self.fill(x1, y2, z1, x2, y2, z2, ceiling)
        self.fill(x1, y1 + 1, z1, x2, y2, z1, wall)
        self.fill(x1, y1 + 1, z2, x2, y2, z2, wall)
        self.fill(x1, y1 + 1, z1, x1, y2, z2, wall)
        self.fill(x2, y1 + 1, z1, x2, y2, z2, wall)


def nbt_type(value: Any) -> int:
    if isinstance(value, int):
        return TAG_INT
    if isinstance(value, str):
        return TAG_STRING
    if isinstance(value, NbtList):
        return TAG_LIST
    if isinstance(value, dict):
        return TAG_COMPOUND
    raise TypeError(f"unsupported NBT value: {value!r}")


def write_name(buf: bytearray, name: str) -> None:
    raw = name.encode("utf-8")
    buf.extend(struct.pack(">H", len(raw)))
    buf.extend(raw)


def write_payload(buf: bytearray, tag: int, value: Any) -> None:
    if tag == TAG_BYTE:
        buf.extend(struct.pack(">b", int(value)))
    elif tag == TAG_INT:
        buf.extend(struct.pack(">i", int(value)))
    elif tag == TAG_STRING:
        raw = str(value).encode("utf-8")
        buf.extend(struct.pack(">H", len(raw)))
        buf.extend(raw)
    elif tag == TAG_LIST:
        assert isinstance(value, NbtList)
        buf.append(value.item_type)
        buf.extend(struct.pack(">i", len(value.items)))
        for item in value.items:
            write_payload(buf, value.item_type, item)
    elif tag == TAG_COMPOUND:
        assert isinstance(value, dict)
        for key, child in value.items():
            child_tag = nbt_type(child)
            buf.append(child_tag)
            write_name(buf, key)
            write_payload(buf, child_tag, child)
        buf.append(TAG_END)
    else:
        raise TypeError(f"unsupported NBT tag: {tag}")


def write_nbt_gzip(root: dict[str, Any]) -> bytes:
    raw = bytearray()
    raw.append(TAG_COMPOUND)
    write_name(raw, "")
    write_payload(raw, TAG_COMPOUND, root)
    payload = bytes(raw)
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-zlib.MAX_WBITS)
    compressed = compressor.compress(payload) + compressor.flush()
    header = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff"
    trailer = struct.pack("<II", zlib.crc32(payload) & 0xFFFFFFFF, len(payload) & 0xFFFFFFFF)
    return header + compressed + trailer


def state_compound(state: State) -> dict[str, Any]:
    payload: dict[str, Any] = {"Name": state.name}
    if state.props:
        payload["Properties"] = {key: value for key, value in state.props}
    return payload


def build_nbt(structure: Structure) -> bytes:
    palette: list[State] = []
    palette_index: dict[State, int] = {}
    blocks: list[dict[str, Any]] = []
    for pos, state in sorted(structure.blocks.items(), key=lambda item: (item[0][1], item[0][2], item[0][0])):
        if state not in palette_index:
            palette_index[state] = len(palette)
            palette.append(state)
        blocks.append(
            {
                "pos": NbtList(TAG_INT, [pos[0], pos[1], pos[2]]),
                "state": palette_index[state],
            }
        )
    root = {
        "DataVersion": DATA_VERSION,
        "size": NbtList(TAG_INT, list(structure.size)),
        "palette": NbtList(TAG_COMPOUND, [state_compound(state) for state in palette]),
        "blocks": NbtList(TAG_COMPOUND, blocks),
        "entities": NbtList(TAG_COMPOUND, []),
    }
    return write_nbt_gzip(root)


def fence_state(east: bool = False, north: bool = False, south: bool = False, west: bool = False) -> State:
    return st(
        "minecraft:oak_fence",
        east=str(east).lower(),
        north=str(north).lower(),
        south=str(south).lower(),
        west=str(west).lower(),
        waterlogged="false",
    )


def add_fence_line(structure: Structure, points: Iterable[tuple[int, int, int]]) -> None:
    cells = set(points)
    for x, y, z in cells:
        structure.set(
            x,
            y,
            z,
            fence_state(
                east=(x + 1, y, z) in cells,
                west=(x - 1, y, z) in cells,
                south=(x, y, z + 1) in cells,
                north=(x, y, z - 1) in cells,
            ),
        )


def add_railing(structure: Structure, x1: int, z1: int, x2: int, z2: int, y: int, gaps: set[tuple[int, int]] | None = None) -> None:
    gaps = gaps or set()
    cells: list[tuple[int, int, int]] = []
    for x in range(x1, x2 + 1):
        for z in (z1, z2):
            if (x, z) not in gaps:
                cells.append((x, y, z))
    for z in range(z1, z2 + 1):
        for x in (x1, x2):
            if (x, z) not in gaps:
                cells.append((x, y, z))
    add_fence_line(structure, cells)


def add_door(structure: Structure, x: int, y: int, z: int, facing: str, hinge: str = "left") -> None:
    structure.set(
        x,
        y,
        z,
        st("minecraft:dark_oak_door", facing=facing, half="lower", hinge=hinge, open="false", powered="false"),
    )
    structure.set(
        x,
        y + 1,
        z,
        st("minecraft:dark_oak_door", facing=facing, half="upper", hinge=hinge, open="false", powered="false"),
    )


def add_bed(structure: Structure, x: int, y: int, z: int, facing: str) -> None:
    dx, dz = {"north": (0, -1), "south": (0, 1), "east": (1, 0), "west": (-1, 0)}[facing]
    structure.set(x, y, z, st("minecraft:purple_bed", facing=facing, occupied="false", part="foot"))
    structure.set(x + dx, y, z + dz, st("minecraft:purple_bed", facing=facing, occupied="false", part="head"))


def add_double_plant(structure: Structure, x: int, y: int, z: int, name: str) -> None:
    structure.set(x, y, z, st(f"minecraft:{name}", half="lower"))
    structure.set(x, y + 1, z, st(f"minecraft:{name}", half="upper"))


def add_windows(structure: Structure) -> None:
    glass = st("minecraft:purple_stained_glass")
    for x in (20, 24, 32, 36):
        structure.fill(x, 8, 34, x + 1, 10, 34, glass)
    for x in (21, 35):
        structure.fill(x, 15, 30, x + 2, 17, 30, glass)
    for z in (14, 24):
        structure.fill(15, 8, z, 15, 10, z + 2, glass)
        structure.fill(41, 8, z, 41, 10, z + 2, glass)
    for x in (8, 48):
        structure.fill(x, 8, 33, x + 2, 10, 33, glass)
    for z in (13, 27):
        structure.fill(18, 15, z, 18, 17, z + 2, glass)
        structure.fill(38, 15, z, 38, 17, z + 2, glass)


def add_landscaping(structure: Structure) -> None:
    grass = st("minecraft:grass_block")
    path = st("minecraft:dirt_path")
    podzol = st("minecraft:podzol")
    purpur = st("minecraft:purpur_block")
    quartz = st("minecraft:smooth_quartz")
    water = st("minecraft:water")
    structure.fill(0, 0, 0, 56, 0, 56, grass)
    structure.fill(17, 0, 35, 39, 0, 56, path)
    structure.fill(0, 0, 37, 56, 0, 43, path)
    structure.fill(25, 0, 0, 31, 0, 37, path)

    structure.fill(20, 0, 40, 36, 0, 54, grass)
    structure.fill(21, 1, 41, 35, 1, 53, purpur)
    structure.fill(23, 1, 43, 33, 1, 51, quartz)
    structure.fill(25, 1, 45, 31, 1, 49, water)
    structure.set(28, 2, 47, st("minecraft:sea_lantern"))

    flowers = [
        "allium",
        "azure_bluet",
        "blue_orchid",
        "cornflower",
        "dandelion",
        "lily_of_the_valley",
        "orange_tulip",
        "pink_tulip",
        "poppy",
        "purple_concrete",
        "white_tulip",
    ]
    flower_points: list[tuple[int, int]] = []
    for x in range(2, 55, 3):
        flower_points.extend([(x, 3), (x, 5), (x, 51), (x, 54)])
    for z in range(3, 55, 3):
        flower_points.extend([(3, z), (5, z), (51, z), (54, z)])
    for index, (x, z) in enumerate(flower_points):
        if 16 <= x <= 42 and 7 <= z <= 35:
            continue
        name = flowers[index % len(flowers)]
        if name == "purple_concrete":
            structure.set(x, 1, z, st("minecraft:purple_carpet"))
        else:
            structure.set(x, 1, z, st(f"minecraft:{name}"))
    for x, z, name in ((8, 7, "lilac"), (49, 7, "lilac"), (9, 49, "rose_bush"), (48, 49, "peony")):
        structure.set(x, 0, z, podzol)
        add_double_plant(structure, x, 1, z, name)


def add_basement(structure: Structure) -> None:
    stone = st("minecraft:stone_bricks")
    polished = st("minecraft:polished_deepslate")
    quartz = st("minecraft:smooth_quartz")
    amethyst = st("minecraft:amethyst_block")
    structure.hollow_box(16, 0, 9, 40, 5, 32, stone, polished, st("minecraft:oak_planks"))
    structure.fill(18, 0, 11, 38, 0, 30, quartz)
    structure.fill(27, 0, 12, 29, 0, 29, amethyst)
    structure.fill(17, 1, 12, 17, 4, 30, st("minecraft:bookshelf"))
    structure.fill(39, 1, 12, 39, 3, 30, st("minecraft:barrel", facing="west", open="false"))
    structure.fill(23, 1, 28, 33, 1, 28, st("minecraft:furnace", facing="north", lit="false"))
    structure.fill(24, 1, 29, 32, 1, 29, st("minecraft:blast_furnace", facing="north", lit="false"))
    structure.set(28, 1, 17, st("minecraft:enchanting_table"))
    structure.fill(25, 1, 15, 31, 1, 15, st("minecraft:bookshelf"))
    structure.fill(25, 1, 19, 31, 1, 19, st("minecraft:bookshelf"))
    for x in (19, 37):
        for z in (11, 30):
            structure.fill(x, 1, z, x, 5, z, st("minecraft:spruce_log", axis="y"))
            structure.set(x, 5, z, st("minecraft:lantern", hanging="true", waterlogged="false"))
    for step in range(5):
        structure.set(20, 1 + step, 23 - step, st("minecraft:smooth_quartz_stairs", facing="south", half="bottom", shape="straight", waterlogged="false"))
        structure.set(21, 1 + step, 23 - step, st("minecraft:smooth_quartz_stairs", facing="south", half="bottom", shape="straight", waterlogged="false"))
    structure.clear(20, 5, 18, 22, 6, 23)


def add_main_house(structure: Structure) -> None:
    oak = st("minecraft:oak_planks")
    stripped = st("minecraft:stripped_oak_log", axis="y")
    purple = st("minecraft:purple_terracotta")
    smooth = st("minecraft:smooth_quartz")
    dark = st("minecraft:dark_oak_planks")

    structure.fill(3, 6, 12, 53, 6, 39, oak)
    add_railing(structure, 3, 12, 53, 39, 7, gaps={(27, 39), (28, 39), (10, 39), (47, 39)})

    structure.hollow_box(16, 6, 10, 40, 12, 34, purple, smooth, oak)
    structure.hollow_box(4, 6, 15, 16, 11, 33, st("minecraft:oak_planks"), dark, oak)
    structure.hollow_box(40, 6, 15, 52, 11, 33, st("minecraft:oak_planks"), dark, oak)
    structure.hollow_box(18, 13, 8, 38, 18, 30, st("minecraft:stripped_birch_log", axis="y"), smooth, None)

    for x in (4, 16, 40, 52):
        for z in (15, 33):
            structure.fill(x, 6, z, x, 13, z, stripped)
    for x in (16, 40):
        for z in (10, 34):
            structure.fill(x, 6, z, x, 18, z, stripped)
    for x in (18, 38):
        for z in (8, 30):
            structure.fill(x, 13, z, x, 19, z, stripped)

    structure.clear(26, 7, 34, 29, 9, 34)
    add_door(structure, 27, 7, 34, "south", "left")
    add_door(structure, 28, 7, 34, "south", "right")
    structure.clear(27, 13, 30, 29, 15, 30)
    add_door(structure, 28, 13, 30, "south", "left")
    add_windows(structure)

    structure.fill(23, 7, 18, 33, 7, 25, st("minecraft:purple_carpet"))
    structure.fill(18, 7, 12, 24, 7, 16, st("minecraft:smooth_quartz_slab", type="bottom", waterlogged="false"))
    structure.set(19, 8, 13, st("minecraft:smoker", facing="south", lit="false"))
    structure.set(20, 8, 13, st("minecraft:furnace", facing="south", lit="false"))
    structure.set(21, 8, 13, st("minecraft:cauldron"))
    structure.set(23, 8, 13, st("minecraft:barrel", facing="south", open="false"))
    structure.fill(29, 7, 15, 34, 7, 15, st("minecraft:dark_oak_slab", type="bottom", waterlogged="false"))
    for x in (29, 31, 33):
        structure.set(x, 8, 15, st("minecraft:flower_pot"))
    for x, z in ((26, 23), (27, 23), (30, 23), (31, 23)):
        structure.set(x, 7, z, st("minecraft:purple_wool"))
    structure.fill(27, 7, 22, 30, 7, 22, st("minecraft:dark_oak_slab", type="bottom", waterlogged="false"))
    for x, z in ((22, 30), (35, 30), (22, 12), (35, 12)):
        structure.set(x, 8, z, st("minecraft:lantern", hanging="false", waterlogged="false"))

    for step in range(6):
        structure.set(35, 7 + step, 25 - step, st("minecraft:oak_stairs", facing="south", half="bottom", shape="straight", waterlogged="false"))
        structure.set(36, 7 + step, 25 - step, st("minecraft:oak_stairs", facing="south", half="bottom", shape="straight", waterlogged="false"))
    structure.clear(34, 12, 18, 37, 13, 25)

    structure.fill(23, 13, 31, 35, 13, 36, oak)
    add_railing(structure, 23, 31, 35, 36, 14, gaps={(28, 31)})
    structure.fill(22, 14, 32, 36, 14, 32, st("minecraft:purple_carpet"))

    add_bed(structure, 22, 14, 14, "east")
    structure.fill(27, 14, 16, 34, 14, 16, st("minecraft:purple_carpet"))
    structure.fill(29, 14, 20, 35, 14, 20, st("minecraft:bookshelf"))
    structure.fill(21, 14, 23, 25, 14, 23, st("minecraft:barrel", facing="north", open="false"))
    structure.set(33, 14, 24, st("minecraft:crafting_table"))
    for x, z in ((20, 12), (36, 12), (20, 28), (36, 28)):
        structure.set(x, 15, z, st("minecraft:lantern", hanging="false", waterlogged="false"))


def add_roofs_and_terraces(structure: Structure) -> None:
    purpur_stairs_n = st("minecraft:purpur_stairs", facing="north", half="bottom", shape="straight", waterlogged="false")
    purpur_stairs_s = st("minecraft:purpur_stairs", facing="south", half="bottom", shape="straight", waterlogged="false")
    trim = st("minecraft:polished_deepslate")
    roof_block = st("minecraft:purpur_block")
    for z in range(7, 32):
        slope = min(z - 7, 31 - z)
        y = 18 + max(0, slope)
        state = purpur_stairs_n if z <= 19 else purpur_stairs_s
        for x in range(13, 44):
            structure.set(x, y, z, state)
        if z in (7, 31, 19, 20):
            structure.fill(13, y + 1, z, 43, y + 1, z, trim)
    for x in (13, 43):
        for z in range(8, 31):
            slope = min(z - 7, 31 - z)
            for y in range(18, 18 + max(0, slope)):
                structure.set(x, y, z, st("minecraft:stripped_oak_log", axis="x"))
    structure.fill(23, 24, 19, 33, 24, 20, roof_block)
    structure.fill(25, 25, 19, 31, 25, 20, trim)

    for x1, x2 in ((3, 17), (39, 53)):
        structure.fill(x1, 12, 14, x2, 12, 34, st("minecraft:oak_planks"))
        add_railing(structure, x1, 14, x2, 34, 13)
        structure.fill(x1 + 2, 13, 17, x2 - 2, 13, 22, st("minecraft:grass_block"))
        structure.fill(x1 + 2, 13, 25, x2 - 2, 13, 31, st("minecraft:farmland", moisture="7"))
        structure.fill(x1 + 6, 13, 27, x1 + 6, 13, 29, st("minecraft:water"))
        for x in range(x1 + 3, x2 - 2):
            if x == x1 + 6:
                continue
            for z in range(26, 31):
                structure.set(x, 14, z, st("minecraft:wheat", age="7"))
        for x in range(x1 + 3, x2 - 2, 2):
            structure.set(x, 14, 18, st("minecraft:allium"))
            structure.set(x, 14, 21, st("minecraft:cornflower"))
        for x, z in ((x1 + 2, 17), (x2 - 2, 17), (x1 + 2, 31), (x2 - 2, 31)):
            structure.set(x, 14, z, st("minecraft:lantern", hanging="false", waterlogged="false"))


def add_front_stairs_and_arcade(structure: Structure) -> None:
    stair = st("minecraft:oak_stairs", facing="south", half="bottom", shape="straight", waterlogged="false")
    stone = st("minecraft:stone_bricks")
    for x1, x2 in ((3, 15), (41, 53)):
        for step in range(6):
            z = 45 - step
            y = 1 + step
            for x in range(x1, x2 + 1):
                structure.set(x, y, z, stair)
                if y > 1:
                    structure.fill(x, 1, z, x, y - 1, z, st("minecraft:oak_planks"))
        structure.fill(x1, 1, 35, x1, 6, 45, stone)
        structure.fill(x2, 1, 35, x2, 6, 45, stone)
    for x in (6, 14, 42, 50):
        for z in (35, 39):
            structure.fill(x, 1, z, x, 6, z, st("minecraft:spruce_log", axis="y"))
            structure.set(x, 6, z, st("minecraft:lantern", hanging="true", waterlogged="false"))
    structure.fill(8, 1, 35, 21, 5, 39, AIR)
    structure.fill(35, 1, 35, 49, 5, 39, AIR)
    for x in (8, 21, 35, 49):
        for z in (35, 39):
            structure.fill(x, 1, z, x, 6, z, st("minecraft:spruce_log", axis="y"))


def build_structure() -> Structure:
    structure = Structure((57, 32, 57))
    add_landscaping(structure)
    add_basement(structure)
    add_main_house(structure)
    add_front_stairs_and_arcade(structure)
    add_roofs_and_terraces(structure)
    return structure


def json_bytes(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=False) + "\n").encode("utf-8")


def datapack_files() -> dict[str, bytes]:
    structure = build_structure()
    return {
        "pack.mcmeta": json_bytes(
            {
                "pack": {
                    "pack_format": PACK_FORMAT,
                    "supported_formats": SUPPORTED_FORMATS,
                    "description": "Pummelchen Purple House: rare purple modern survival mansion structure.",
                }
            }
        ),
        f"data/{NAMESPACE}/worldgen/structure/{STRUCTURE_NAME}.json": json_bytes(
            {
                "type": "minecraft:jigsaw",
                "biomes": f"#{NAMESPACE}:has_structure/{STRUCTURE_NAME}",
                "step": "surface_structures",
                "terrain_adaptation": "beard_thin",
                "start_pool": f"{NAMESPACE}:{STRUCTURE_NAME}/start_pool",
                "size": 1,
                "start_height": {"absolute": 0},
                "max_distance_from_center": 80,
                "project_start_to_heightmap": "WORLD_SURFACE_WG",
                "use_expansion_hack": False,
            }
        ),
        f"data/{NAMESPACE}/worldgen/structure_set/{STRUCTURE_NAME}.json": json_bytes(
            {
                "structures": [{"structure": f"{NAMESPACE}:{STRUCTURE_NAME}", "weight": 1}],
                "placement": {
                    "type": "minecraft:random_spread",
                    "spacing": SPACING_CHUNKS,
                    "separation": SEPARATION_CHUNKS,
                    "salt": SALT,
                },
            }
        ),
        f"data/{NAMESPACE}/worldgen/template_pool/{STRUCTURE_NAME}/start_pool.json": json_bytes(
            {
                "name": f"{NAMESPACE}:{STRUCTURE_NAME}/start_pool",
                "fallback": "minecraft:empty",
                "elements": [
                    {
                        "weight": 1,
                        "element": {
                            "element_type": "minecraft:single_pool_element",
                            "location": f"{NAMESPACE}:{STRUCTURE_NAME}",
                            "projection": "rigid",
                            "processors": "minecraft:empty",
                        },
                    }
                ],
            }
        ),
        f"data/{NAMESPACE}/tags/worldgen/biome/has_structure/{STRUCTURE_NAME}.json": json_bytes(
            {"replace": False, "values": ["#minecraft:is_overworld"]}
        ),
        f"data/{NAMESPACE}/structures/{STRUCTURE_NAME}.nbt": build_nbt(structure),
    }


def write_source(files: dict[str, bytes], source_dir: Path) -> None:
    if source_dir.exists():
        shutil.rmtree(source_dir)
    source_dir.mkdir(parents=True, exist_ok=True)
    for rel, data in files.items():
        path = source_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def write_zip(files: dict[str, bytes], output_zip: Path) -> None:
    output_zip.parent.mkdir(parents=True, exist_ok=True)
    tmp = output_zip.with_suffix(output_zip.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_STORED) as archive:
        for rel in sorted(files):
            info = zipfile.ZipInfo(rel, ZIP_DATE)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            archive.writestr(info, files[rel])
    tmp.replace(output_zip)


def compare_tree(files: dict[str, bytes], source_dir: Path) -> list[str]:
    problems: list[str] = []
    expected = set(files)
    actual = {
        path.relative_to(source_dir).as_posix()
        for path in source_dir.rglob("*")
        if path.is_file()
    } if source_dir.exists() else set()
    for rel in sorted(expected - actual):
        problems.append(f"missing source file: {rel}")
    for rel in sorted(actual - expected):
        problems.append(f"unexpected source file: {rel}")
    for rel in sorted(expected & actual):
        if (source_dir / rel).read_bytes() != files[rel]:
            problems.append(f"source drift: {rel}")
    return problems


def build_expected_zip(files: dict[str, bytes]) -> bytes:
    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "pack.zip"
        write_zip(files, path)
        return path.read_bytes()


def check(files: dict[str, bytes], source_dir: Path, output_zip: Path) -> int:
    problems = compare_tree(files, source_dir)
    if not output_zip.exists():
        problems.append(f"missing datapack zip: {output_zip}")
    elif output_zip.read_bytes() != build_expected_zip(files):
        problems.append(f"datapack zip drift: {output_zip}")
    for rel, data in files.items():
        if rel.endswith(".json") or rel == "pack.mcmeta":
            json.loads(data.decode("utf-8"))
        if rel.endswith(".nbt") and not data.startswith(b"\x1f\x8b"):
            problems.append(f"structure is not gzip NBT: {rel}")
    if problems:
        for problem in problems:
            print(f"ERROR {problem}")
        return 1
    print(f"purple_house_datapack=ok zip={output_zip}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=SOURCE_DIR)
    parser.add_argument("--output-zip", type=Path, default=OUTPUT_ZIP)
    parser.add_argument("--check", action="store_true", help="verify generated source and zip are current")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    files = datapack_files()
    if args.check:
        return check(files, args.source_dir, args.output_zip)
    write_source(files, args.source_dir)
    write_zip(files, args.output_zip)
    print(f"purple_house_datapack_built={args.output_zip}")
    print(f"purple_house_source={args.source_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
