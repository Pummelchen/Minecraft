#!/usr/bin/env python3
"""Install and register project-owned custom server datapacks."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from moddb import connect, init_db, slugify, status_rank, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_PROJECT_DIR = Path("/var/minecraft_mods")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_METADATA = Path("server-datapacks-src/custom_datapacks.json")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_entries(project_dir: Path, metadata_path: Path) -> list[dict[str, Any]]:
    path = metadata_path if metadata_path.is_absolute() else project_dir / metadata_path
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("datapacks"), list):
        raise ValueError(f"expected datapacks list in {path}")
    entries = payload["datapacks"]
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError(f"invalid datapack entry in {path}: {entry!r}")
        for key in ("name", "file_name", "canonical_key", "target_mc", "notes"):
            if not str(entry.get(key) or "").strip():
                raise ValueError(f"missing {key} in custom datapack metadata")
    return entries


def validate_entries(project_dir: Path, entries: list[dict[str, Any]]) -> list[str]:
    problems: list[str] = []
    seen_files: set[str] = set()
    for entry in entries:
        file_name = str(entry["file_name"])
        if "/" in file_name or "\\" in file_name or not file_name.endswith(".zip"):
            problems.append(f"invalid datapack file name: {file_name}")
            continue
        if file_name in seen_files:
            problems.append(f"duplicate datapack file name: {file_name}")
        seen_files.add(file_name)
        path = project_dir / "server-datapacks" / file_name
        if not path.exists():
            problems.append(f"missing datapack zip: {path}")
            continue
        try:
            digest = sha256_file(path)
        except OSError as exc:
            problems.append(f"cannot read datapack zip {path}: {exc}")
            continue
        expected_sha = str(entry.get("sha256") or "").strip()
        if expected_sha and expected_sha != digest:
            problems.append(f"sha256 mismatch for {file_name}: expected {expected_sha}, got {digest}")
    return problems


def ensure_import(conn: sqlite3.Connection, metadata_path: Path, row_count: int) -> int:
    existing = conn.execute(
        "SELECT id FROM imports WHERE source_file = ? ORDER BY imported_at DESC LIMIT 1",
        (str(metadata_path),),
    ).fetchone()
    if existing:
        return int(existing["id"])
    cur = conn.execute(
        """
        INSERT INTO imports(imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (utc_now(), str(metadata_path), "local", "custom_datapacks", "server-datapacks-src/custom_datapacks.json", row_count),
    )
    return int(cur.lastrowid)


def upsert_entry(
    conn: sqlite3.Connection,
    *,
    import_id: int,
    entry: dict[str, Any],
    project_dir: Path,
    server_dir: Path,
    metadata_path: Path,
) -> int:
    now = utc_now()
    file_name = str(entry["file_name"])
    zip_path = project_dir / "server-datapacks" / file_name
    digest = sha256_file(zip_path)
    canonical_key = slugify(str(entry.get("canonical_key") or entry["name"]))
    active_status, rank = status_rank("OK", "OK", "Not required (server datapack)")
    row_hash = hashlib.sha256(
        json.dumps(entry, sort_keys=True).encode("utf-8") + digest.encode("ascii")
    ).hexdigest()
    existing = conn.execute(
        "SELECT id FROM mods WHERE canonical_key = ? AND duplicate_of_id IS NULL ORDER BY id LIMIT 1",
        (canonical_key,),
    ).fetchone()
    values = {
        "import_id": import_id,
        "original_sheet_row": int(entry.get("original_sheet_row") or 0),
        "category": str(entry.get("category") or "Custom Datapacks"),
        "name": str(entry["name"]),
        "canonical_key": canonical_key,
        "installation": str(entry.get("installation") or "Server"),
        "entry_type": str(entry.get("entry_type") or "Datapack"),
        "tested": "OK",
        "target_mc": str(entry["target_mc"]),
        "server_status": "OK",
        "client_package": "Not required (server datapack)",
        "last_tested": str(entry.get("last_tested") or now[:10]),
        "active_status": active_status,
        "status_rank": rank,
        "primary_url": str(entry.get("source_url") or f"local://server-datapacks/{file_name}"),
        "row_hash": row_hash,
        "updated_at": now,
    }
    if existing:
        mod_id = int(existing["id"])
        conn.execute(
            """
            UPDATE mods SET
                import_id = :import_id,
                original_sheet_row = :original_sheet_row,
                category = :category,
                name = :name,
                installation = :installation,
                entry_type = :entry_type,
                tested = :tested,
                target_mc = :target_mc,
                server_status = :server_status,
                client_package = :client_package,
                last_tested = :last_tested,
                active_status = :active_status,
                status_rank = :status_rank,
                primary_url = :primary_url,
                row_hash = :row_hash,
                updated_at = :updated_at
            WHERE id = :mod_id
            """,
            {**values, "mod_id": mod_id},
        )
    else:
        cur = conn.execute(
            """
            INSERT INTO mods(
                import_id, original_sheet_row, category, name, canonical_key, installation,
                entry_type, tested, target_mc, server_status, client_package,
                last_tested, active_status, status_rank, primary_url, row_hash, created_at, updated_at
            )
            VALUES (
                :import_id, :original_sheet_row, :category, :name, :canonical_key, :installation,
                :entry_type, :tested, :target_mc, :server_status, :client_package,
                :last_tested, :active_status, :status_rank, :primary_url, :row_hash, :created_at, :updated_at
            )
            """,
            {**values, "created_at": now},
        )
        mod_id = int(cur.lastrowid)

    conn.execute(
        """
        INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET
            notes_1 = excluded.notes_1,
            notes_2 = excluded.notes_2,
            migration_notes = excluded.migration_notes
        """,
        (
            mod_id,
            str(entry.get("notes_1") or ""),
            str(entry.get("notes_2") or ""),
            str(entry["notes"]),
        ),
    )
    conn.execute("DELETE FROM mod_files WHERE mod_id = ?", (mod_id,))
    conn.execute(
        """
        INSERT INTO mod_files(mod_id, role, file_name, path_hint, installed_on_server, included_in_client, status)
        VALUES (?, 'server_datapack', ?, ?, 1, 0, 'OK')
        """,
        (mod_id, file_name, str(server_dir / "server-datapacks")),
    )
    conn.execute("DELETE FROM source_urls WHERE mod_id = ?", (mod_id,))
    conn.execute(
        """
        INSERT INTO source_urls(
            mod_id, source_kind, url, host, project_slug, resolved_source,
            file_id, release_channel, is_primary
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
        """,
        (
            mod_id,
            str(entry.get("source_kind") or "local"),
            str(entry.get("source_url") or f"local://server-datapacks/{file_name}"),
            "local",
            canonical_key,
            f"Project custom datapack {file_name} sha256:{digest}",
            digest[:12],
            "custom",
        ),
    )
    test_label = str(entry.get("test_label") or "custom_datapack_registered")
    exists = conn.execute(
        "SELECT 1 FROM test_runs WHERE mod_id = ? AND test_label = ? LIMIT 1",
        (mod_id, test_label),
    ).fetchone()
    if not exists:
        conn.execute(
            """
            INSERT INTO test_runs(mod_id, tested_at, test_label, status, error_count, log_path, notes)
            VALUES (?, ?, ?, 'OK', 0, '', ?)
            """,
            (mod_id, now, test_label, f"Registered from {metadata_path}; zip sha256:{digest}."),
        )
    return mod_id


def copy_if_changed(src: Path, dst: Path) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and sha256_file(src) == sha256_file(dst):
        return False
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    shutil.copy2(src, tmp)
    tmp.replace(dst)
    return True


def active_world_dir(server_dir: Path) -> Path:
    level_name = "world"
    properties = server_dir / "server.properties"
    if properties.exists():
        for raw in properties.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip() == "level-name":
                level_name = value.strip() or "world"
                break
    level_path = Path(level_name)
    if level_path.is_absolute() or ".." in level_path.parts:
        raise ValueError(f"unsafe level-name in {properties}: {level_name!r}")
    return server_dir / level_path


def install_entries(project_dir: Path, server_dir: Path, entries: list[dict[str, Any]]) -> int:
    changed = 0
    world_datapacks = active_world_dir(server_dir) / "datapacks"
    for entry in entries:
        file_name = str(entry["file_name"])
        src = project_dir / "server-datapacks" / file_name
        if copy_if_changed(src, server_dir / "server-datapacks" / file_name):
            changed += 1
        if copy_if_changed(src, world_datapacks / file_name):
            changed += 1
    return changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--project-dir", type=Path, default=DEFAULT_PROJECT_DIR)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--check", action="store_true", help="validate metadata and zip files without installing")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    metadata_path = args.metadata if args.metadata.is_absolute() else args.project_dir / args.metadata
    entries = load_entries(args.project_dir, args.metadata)
    problems = validate_entries(args.project_dir, entries)
    if problems:
        for problem in problems:
            print(f"ERROR {problem}")
        return 1
    if args.check:
        print(f"custom_datapacks=ok count={len(entries)}")
        return 0

    changed = install_entries(args.project_dir, args.server_dir, entries)
    with connect(args.db) as conn:
        init_db(conn)
        import_id = ensure_import(conn, metadata_path, len(entries))
        mod_ids = [
            upsert_entry(
                conn,
                import_id=import_id,
                entry=entry,
                project_dir=args.project_dir,
                server_dir=args.server_dir,
                metadata_path=metadata_path,
            )
            for entry in entries
        ]
        conn.commit()
    print(f"custom_datapacks_registered={len(mod_ids)}")
    print(f"custom_datapacks_changed={changed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
