#!/usr/bin/env python3
"""Safely replace the active world with a new seeded world and pregenerate spawn."""

from __future__ import annotations

import argparse
import math
import secrets
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import pummelchen_world_reset as reset

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True)


DEFAULT_PROJECT_DIR = reset.DEFAULT_PROJECT_DIR
DEFAULT_SERVER_DIR = reset.DEFAULT_SERVER_DIR
DEFAULT_SERVICE = reset.DEFAULT_SERVICE
DEFAULT_RADIUS_BLOCKS = 1000
DEFAULT_BATCH_SIZE = 256
DEFAULT_BATCH_PAUSE = 0.25
DEFAULT_PREGEM_TIMEOUT = 3600

SAFETY_GAMERULES = {
    "keep_inventory": "true",
    "mob_griefing": "false",
    "projectiles_can_break_blocks": "false",
    "block_explosion_drop_decay": "false",
    "mob_explosion_drop_decay": "false",
    "tnt_explodes": "false",
    "tnt_explosion_drop_decay": "false",
}


def pregeneration_chunks(
    spawn: tuple[int, int, int],
    radius_blocks: int,
    *,
    shape: str,
) -> list[tuple[int, int]]:
    radius_blocks = max(0, radius_blocks)
    sx, _sy, sz = spawn
    min_chunk_x = math.floor((sx - radius_blocks) / 16)
    max_chunk_x = math.floor((sx + radius_blocks) / 16)
    min_chunk_z = math.floor((sz - radius_blocks) / 16)
    max_chunk_z = math.floor((sz + radius_blocks) / 16)
    chunks: list[tuple[int, int]] = []
    for chunk_x in range(min_chunk_x, max_chunk_x + 1):
        for chunk_z in range(min_chunk_z, max_chunk_z + 1):
            if shape == "circle":
                center_x = chunk_x * 16 + 8
                center_z = chunk_z * 16 + 8
                if ((center_x - sx) ** 2 + (center_z - sz) ** 2) ** 0.5 > radius_blocks:
                    continue
            chunks.append((chunk_x, chunk_z))
    return chunks


def chunk_to_block_position(chunk_x: int, chunk_z: int) -> tuple[int, int]:
    return chunk_x * 16 + 8, chunk_z * 16 + 8


def chunk_segments(chunks: list[tuple[int, int]]) -> list[tuple[int, int, int, int, int]]:
    by_z: dict[int, list[int]] = {}
    for chunk_x, chunk_z in chunks:
        by_z.setdefault(chunk_z, []).append(chunk_x)
    segments: list[tuple[int, int, int, int, int]] = []
    for chunk_z in sorted(by_z):
        sorted_x = sorted(set(by_z[chunk_z]))
        start_x = sorted_x[0]
        previous_x = sorted_x[0]
        for chunk_x in sorted_x[1:]:
            if chunk_x == previous_x + 1:
                previous_x = chunk_x
                continue
            segments.append((start_x, chunk_z, previous_x, chunk_z, previous_x - start_x + 1))
            start_x = previous_x = chunk_x
        segments.append((start_x, chunk_z, previous_x, chunk_z, previous_x - start_x + 1))
    return segments


def forceload_command(action: str, segment: tuple[int, int, int, int, int]) -> str:
    start_x, start_z, end_x, end_z, _count = segment
    start_block_x, start_block_z = chunk_to_block_position(start_x, start_z)
    end_block_x, end_block_z = chunk_to_block_position(end_x, end_z)
    if start_x == end_x and start_z == end_z:
        return f"forceload {action} {start_block_x} {start_block_z}"
    return f"forceload {action} {start_block_x} {start_block_z} {end_block_x} {end_block_z}"


def apply_safety_gamerules(rcon_port: int, password: str, *, dry_run: bool) -> None:
    commands = [f"gamerule {name} {value}" for name, value in SAFETY_GAMERULES.items()]
    if dry_run:
        for command in commands:
            print(f"DRY-RUN rcon {command}")
        return
    responses = reset.run_rcon_commands(
        reset.RCON_HOST,
        rcon_port,
        password,
        commands,
        timeout=reset.RCON_COMMAND_TIMEOUT,
    )
    for command, response in zip(commands, responses):
        clean = reset._clean_minecraft_output(response)
        print(f"gamerule_applied={command}\tresponse={clean}")


def pregenerate_chunks(
    chunks: list[tuple[int, int]],
    rcon_port: int,
    password: str,
    *,
    batch_size: int,
    batch_pause: float,
    timeout: int,
    dry_run: bool,
) -> None:
    if not chunks:
        print("pregenerate_chunks=0")
        return
    segments = chunk_segments(chunks)
    print(f"pregenerate_chunks={len(chunks)}")
    print(f"pregenerate_segments={len(segments)}")
    if dry_run:
        first = chunks[0]
        last = chunks[-1]
        print(f"DRY-RUN pregenerate first_chunk={first[0]},{first[1]} last_chunk={last[0]},{last[1]}")
        return

    started = time.monotonic()
    loaded: list[tuple[int, int, int, int, int]] = []
    loaded_count = 0
    completed_count = 0
    for segment in segments:
        segment_count = segment[4]
        if timeout > 0 and time.monotonic() - started > timeout:
            raise TimeoutError(f"pregeneration timeout after {completed_count}/{len(chunks)} chunks")
        reset.rcon_command(
            reset.RCON_HOST,
            rcon_port,
            password,
            forceload_command("add", segment),
            timeout=reset.RCON_COMMAND_TIMEOUT,
        )
        loaded.append(segment)
        loaded_count += segment_count
        if loaded_count >= batch_size or segment == segments[-1]:
            reset.rcon_command(reset.RCON_HOST, rcon_port, password, "save-all flush", timeout=reset.RCON_COMMAND_TIMEOUT)
            for loaded_segment in loaded:
                reset.rcon_command(
                    reset.RCON_HOST,
                    rcon_port,
                    password,
                    forceload_command("remove", loaded_segment),
                    timeout=reset.RCON_COMMAND_TIMEOUT,
                )
            completed_count += loaded_count
            print(f"pregenerate_progress={min(completed_count, len(chunks))}/{len(chunks)}")
            loaded.clear()
            loaded_count = 0
            if batch_pause > 0:
                time.sleep(batch_pause)
    reset.rcon_command(reset.RCON_HOST, rcon_port, password, "save-all flush", timeout=reset.RCON_COMMAND_TIMEOUT)
    print(f"pregenerate_done=1\tchunks={len(chunks)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, default=DEFAULT_PROJECT_DIR)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--service", default=DEFAULT_SERVICE)
    parser.add_argument("--seed", default=str(secrets.randbelow(2**63)))
    parser.add_argument("--radius-blocks", type=int, default=DEFAULT_RADIUS_BLOCKS)
    parser.add_argument(
        "--diameter-blocks",
        type=int,
        default=None,
        help="deprecated alias; radius will be half this value when --radius-blocks is omitted",
    )
    parser.add_argument("--shape", choices=("square", "circle"), default="circle")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--batch-pause", type=float, default=DEFAULT_BATCH_PAUSE)
    parser.add_argument("--pregenerate-timeout", type=int, default=DEFAULT_PREGEM_TIMEOUT)
    parser.add_argument("--rcon-port", type=int, default=25575)
    parser.add_argument("--wait-timeout", type=int, default=240)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true", help="required confirmation for destructive world reset")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.yes:
        print("ERROR destructive reset requires --yes", file=sys.stderr)
        return 2
    if args.radius_blocks <= 0:
        raise SystemExit("--radius-blocks must be positive")
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be positive")

    server_dir = args.server_dir
    world_name = reset.active_world_name(server_dir)
    world_dir = server_dir / world_name
    if not world_name or world_dir.resolve() == server_dir.resolve():
        raise SystemExit(f"refusing to reset server directory as world: level-name={world_name!r}")
    seed = str(args.seed).strip() or str(secrets.randbelow(2**63))
    radius_blocks = args.radius_blocks
    if args.diameter_blocks is not None:
        radius_blocks = args.diameter_blocks // 2
    if radius_blocks <= 0:
        raise SystemExit("pregeneration radius must be positive")

    print(f"world_name={world_name}")
    print(f"world_seed={seed}")
    print(f"radius_blocks={radius_blocks}")
    print(f"diameter_blocks={radius_blocks * 2}")
    print(f"pregenerate_shape={args.shape}")
    print(f"rcon_port={args.rcon_port}")

    reset.stop_service(args.service, args.dry_run)
    backup = reset.backup_world(world_dir, server_dir / "world-reset-backups", args.dry_run)
    print(f"world_backup={backup or ''}")

    if args.dry_run:
        print("DRY-RUN write server.properties level-seed, bonus-chest, and project datapacks")
        print(f"world_dir={world_dir}")
        chunks = pregeneration_chunks((0, 0, 0), radius_blocks, shape=args.shape)
        pregenerate_chunks(
            chunks,
            args.rcon_port,
            "",
            batch_size=args.batch_size,
            batch_pause=args.batch_pause,
            timeout=args.pregenerate_timeout,
            dry_run=True,
        )
        return 0

    reset.write_properties(
        server_dir / "server.properties",
        {"level-name": world_name, "level-seed": seed, "bonus-chest": "true"},
    )
    changed = reset.install_datapacks(
        args.project_dir,
        server_dir,
        world_dir,
        install_place_pack=False,
        origin=(0, 80, 0),
        spawn=(0, 83, 0),
    )
    print(f"datapacks_changed={changed}")

    props_path = server_dir / "server.properties"
    restored_contents, changed_rcon, rcon_port = reset.ensure_rcon_enabled(props_path, args.rcon_port, args.dry_run)
    try:
        started_at = time.time()
        reset.start_service(args.service, args.dry_run)
        done = reset.wait_for_done(args.service, started_at, args.wait_timeout)
        print(f"server_done_seen={int(done)}")
        if not done:
            raise TimeoutError(f"server did not finish booting within {args.wait_timeout}s")
        if not reset.wait_for_rcon(rcon_port, timeout=reset.RCON_BOOT_TIMEOUT):
            raise TimeoutError(f"RCON unavailable on port {rcon_port}")
        _lines, values = reset.read_properties(props_path)
        password = values.get("rcon.password", "").strip()
        if not password:
            raise RuntimeError("RCON password missing after bootstrap")
        apply_safety_gamerules(rcon_port, password, dry_run=False)
        detected_spawn = reset.read_level_spawn(world_dir) or (0, 0, 0)
        print(f"detected_spawn={detected_spawn[0]},{detected_spawn[1]},{detected_spawn[2]}")
        chunks = pregeneration_chunks(detected_spawn, radius_blocks, shape=args.shape)
        pregenerate_chunks(
            chunks,
            rcon_port,
            password,
            batch_size=args.batch_size,
            batch_pause=args.batch_pause,
            timeout=args.pregenerate_timeout,
            dry_run=False,
        )
    finally:
        if changed_rcon:
            reset.stop_service(args.service, args.dry_run)
            reset.restore_file(props_path, restored_contents)
            reset.start_service(args.service, args.dry_run)
            print("rcon_bootstrap_restored=1")

    print(f"world_dir={world_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
