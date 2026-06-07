#!/usr/bin/env python3
"""Sync local Pummelchen project mods into the tracker and live folders."""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from moddb import connect, init_db, row_hash, slugify, status_rank, utc_now
from neoforge_metadata import load_neoforge_metadata


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_PROJECT_DIR = Path("/var/minecraft_mods")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_MODS_DIR = Path("/var/minecraft_mods/Pummelchen_Mods")
DEFAULT_TARGET_MC = "26.1.2"


@dataclass(frozen=True)
class ParsedMod:
    canonical_id: str
    name: str
    version: str
    dependencies: tuple[str, ...]
    metadata_source: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_id(value: str | None) -> str:
    return "".join(ch for ch in (value or "").lower().replace(".", "_") if ch.isalnum() or ch == "_")


def parse_dependencies(dep_records: list[dict[str, Any]]) -> set[str]:
    deps: set[str] = set()
    for dep in dep_records:
        if not isinstance(dep, dict):
            continue
        dep_id = normalize_id(str(dep.get("modId") or dep.get("mod_id") or ""))
        if not dep_id:
            continue
        side = str(dep.get("side") or dep.get("sides") or "").strip().upper()
        dep_type = str(dep.get("type") or "").strip().lower()
        mandatory = str(dep.get("mandatory") or "").strip().lower() not in {"false", "0", "no"}
        if side == "CLIENT" or (dep_type not in {"", "required"}) or not mandatory:
            continue
        deps.add(dep_id)
    return deps


def parse_neoforge_metadata(data: dict[str, Any], file_name: str | None = None) -> ParsedMod:
    mod_ids: list[str] = []
    names: list[str] = []
    versions: list[str] = []
    dependencies: set[str] = set()

    for mod_entry in data.get("mods") or []:
        if not isinstance(mod_entry, dict):
            continue
        mod_id = normalize_id(str(mod_entry.get("modId") or ""))
        if mod_id:
            mod_ids.append(mod_id)
        if mod_entry.get("displayName"):
            names.append(str(mod_entry["displayName"]).strip())
        elif mod_entry.get("name"):
            names.append(str(mod_entry["name"]).strip())
        if mod_entry.get("version"):
            versions.append(str(mod_entry["version"]).strip())

    dependencies_map = data.get("dependencies")
    if isinstance(dependencies_map, dict):
        for owner_deps in dependencies_map.values():
            if isinstance(owner_deps, dict):
                owner_deps = [owner_deps]
            if isinstance(owner_deps, list):
                dependencies.update(parse_dependencies([item for item in owner_deps if isinstance(item, dict)]))

    if not mod_ids:
        canonical = "unknown"
        name = "Unknown Mod"
    else:
        canonical = mod_ids[0]
        name = names[0] or canonical.replace("_", " ").title()
    if canonical == "unknown" and file_name:
        canonical = normalize_id(Path(file_name).stem)
        name = name or canonical.replace("_", " ").title() or "Unknown Mod"

    return ParsedMod(
        canonical_id=canonical,
        name=name,
        version=versions[0] if versions else "unknown",
        dependencies=tuple(sorted(dependencies)),
        metadata_source="neoforge",
    )


def parse_fabric_metadata(payload: bytes, file_name: str | None = None) -> ParsedMod | None:
    try:
        payload_data = json.loads(payload.decode("utf-8", errors="replace"))
    except Exception:
        return None

    if not isinstance(payload_data, dict):
        return None

    mod_id = normalize_id(str(payload_data.get("id") or payload_data.get("name") or ""))
    name = str(payload_data.get("name") or mod_id.replace("_", " "))
    version = str(payload_data.get("version") or "unknown")
    dependencies: list[tuple[str, Any]] = []
    for dep_name, dep_constraint in (payload_data.get("depends") or {}).items():
        if str(dep_constraint).strip().lower() in {"minecraft", "java", "fabric-loader"}:
            continue
        dependencies.append((normalize_id(dep_name), dep_constraint))
    if not mod_id and file_name:
        mod_id = normalize_id(Path(file_name).stem)

    if not mod_id:
        return None

    return ParsedMod(
        canonical_id=mod_id,
        name=name or "Unknown Mod",
        version=version or "unknown",
        dependencies=tuple(sorted(dep for dep, _ in dependencies)),
        metadata_source="fabric",
    )


def inspect_mod_file(path: Path) -> tuple[ParsedMod | None, list[str]]:
    if not zipfile.is_zipfile(path):
        return None, [f"{path.name}: not a jar/zip archive"]

    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            for metadata_path in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml"):
                if metadata_path in names:
                    try:
                        return (
                            parse_neoforge_metadata(
                                load_neoforge_metadata(archive.read(metadata_path)),
                                file_name=path.name,
                            ),
                            [],
                        )
                    except Exception as exc:
                        return None, [f"{path.name}: failed to parse {metadata_path}: {type(exc).__name__}"]

            if "fabric.mod.json" in names:
                parsed = parse_fabric_metadata(archive.read("fabric.mod.json"), file_name=path.name)
                if parsed:
                    return parsed, []
                return None, [f"{path.name}: fabric.mod.json could not be parsed"]
    except Exception as exc:
        return None, [f"{path.name}: malformed archive: {type(exc).__name__}: {exc}"]

    return None, [f"{path.name}: no supported mod metadata"]


def ensure_import(conn: sqlite3.Connection, row_count: int, source_file: Path) -> int:
    existing = conn.execute(
        "SELECT id FROM imports WHERE source_file = ? ORDER BY imported_at DESC LIMIT 1",
        (str(source_file),),
    ).fetchone()
    if existing:
        return int(existing["id"]) if isinstance(existing, sqlite3.Row) else int(existing[0])
    cur = conn.execute(
        """
        INSERT INTO imports(imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (utc_now(), str(source_file), "local", "pummelchen_mods", "Pummelchen_Mods", row_count),
    )
    return int(cur.lastrowid)


def upsert_entry(
    conn: sqlite3.Connection,
    *,
    import_id: int,
    jar_path: Path,
    metadata: ParsedMod,
    target_mc: str,
    include_server: bool,
    include_client: bool,
) -> bool:
    now = utc_now()
    digest = sha256_file(jar_path)
    file_name = jar_path.name
    canonical_key = slugify(metadata.canonical_id)
    source_url = f"local://Pummelchen_Mods/{file_name}"
    row_cells = [
        str(file_name),
        "Server+Client" if include_server and include_client else "Server",
        "Mod",
        "OK",
        target_mc,
        "OK",
        "Included",
        now[:10],
        source_url,
        now,
        metadata.version,
        metadata.name,
        metadata.metadata_source,
        ",".join(metadata.dependencies),
        digest,
    ]
    row_hash_value = row_hash([str(v) for v in row_cells])
    active_status, rank = status_rank("OK", "OK", "Included")

    existing = conn.execute(
        """
        SELECT id FROM mods
        WHERE canonical_key = ? AND duplicate_of_id IS NULL
        ORDER BY CASE WHEN primary_url = ? THEN 0 ELSE 1 END, id
        LIMIT 1
        """,
        (canonical_key, source_url),
    ).fetchone()

    values = {
        "import_id": import_id,
        "original_sheet_row": 0,
        "category": "Project Mods",
        "name": metadata.name or metadata.canonical_id,
        "canonical_key": canonical_key,
        "installation": "Server+Client" if include_server and include_client else "Server" if include_server else "Client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": target_mc,
        "server_status": "OK",
        "client_package": "Included" if include_client else "Not included",
        "last_tested": now[:10],
        "active_status": active_status,
        "status_rank": rank,
        "primary_url": source_url,
        "row_hash": row_hash_value,
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
        values["canonical_key"] = canonical_key
        values["created_at"] = now
        cur = conn.execute(
            """
            INSERT INTO mods(
                import_id, original_sheet_row, category, name, canonical_key, installation,
                entry_type, tested, target_mc, server_status, client_package,
                last_tested, active_status, status_rank, primary_url, row_hash,
                created_at, updated_at
            ) VALUES (
                :import_id, :original_sheet_row, :category, :name, :canonical_key, :installation,
                :entry_type, :tested, :target_mc, :server_status, :client_package,
                :last_tested, :active_status, :status_rank, :primary_url, :row_hash,
                :created_at, :updated_at
            )
            """,
            values,
        )
        mod_id = int(cur.lastrowid)

    notes_text = (
        f"Project mod tracked from Pummelchen_Mods; metadata={metadata.metadata_source}, "
        f"version={metadata.version}, deps={','.join(metadata.dependencies) if metadata.dependencies else 'none'}."
    )
    conn.execute(
        """
        INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET
            notes_1 = excluded.notes_1,
            notes_2 = excluded.notes_2,
            migration_notes = excluded.migration_notes
        """,
        (mod_id, metadata.metadata_source, f"file={file_name}", notes_text),
    )

    conn.execute("DELETE FROM mod_files WHERE mod_id = ? AND role = 'server_file'", (mod_id,))
    conn.execute(
        """
        INSERT INTO mod_files(
            mod_id, role, file_name, path_hint, installed_on_server,
            included_in_client, status
        ) VALUES (?, 'server_file', ?, ?, ?, ?, 'OK')
        """,
        (
            mod_id,
            file_name,
            str(jar_path.parent),
            int(include_server),
            int(include_client),
        ),
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
            "local",
            source_url,
            "local",
            canonical_key,
            f"Project mod {file_name} from Pummelchen_Mods sha256:{digest}",
            digest[:12],
            "project",
        ),
    )

    risk_flags = "local,custom"
    dependency_notes = ",".join(metadata.dependencies) if metadata.dependencies else "none"
    conn.execute(
        """
        INSERT INTO mod_metadata(
            mod_id, group_tag, side, summary, gameplay_tags,
            risk_flags, dependency_notes, performance_notes, metadata_source, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET
            group_tag = excluded.group_tag,
            side = excluded.side,
            summary = excluded.summary,
            gameplay_tags = excluded.gameplay_tags,
            risk_flags = excluded.risk_flags,
            dependency_notes = excluded.dependency_notes,
            performance_notes = excluded.performance_notes,
            metadata_source = excluded.metadata_source,
            updated_at = excluded.updated_at
        """,
        (
            mod_id,
            "Project Mods",
            "server+client",
            f"Locally maintained server/client mod for Pummelchen: {metadata.name} v{metadata.version}.",
            "project,custom,server+client",
            risk_flags,
            dependency_notes,
            "No production performance profile attached yet.",
            "sync_pummelchen_mods.py",
            now,
        ),
    )

    exists = conn.execute(
        "SELECT 1 FROM test_runs WHERE mod_id = ? AND test_label = 'pummelchen_mod_registered' LIMIT 1",
        (mod_id,),
    ).fetchone()
    if not exists:
        conn.execute(
            """
            INSERT INTO test_runs(mod_id, tested_at, test_label, status, error_count, log_path, notes)
            VALUES (?, ?, 'pummelchen_mod_registered', 'OK', 0, '', ?)
            """,
            (mod_id, now, notes_text),
        )

    return True


def copy_if_changed(src: Path, dst: Path) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and sha256_file(src) == sha256_file(dst):
        return False
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    tmp.write_bytes(src.read_bytes())
    tmp.replace(dst)
    return True


def run_sync(args: argparse.Namespace) -> int:
    mods_dir = args.mods_dir
    mods_dir.mkdir(parents=True, exist_ok=True)
    files = sorted((
        path
        for path in mods_dir.iterdir()
        if path.is_file() and path.suffix.lower() in {".jar", ".zip"}
    ), key=lambda item: item.name.lower())

    if args.check:
        problems: list[str] = []
        for path in files:
            parsed, notes = inspect_mod_file(path)
            if not parsed:
                problems.extend(notes)
        for problem in problems:
            print(f"ERROR {problem}")
        print(f"pummelchen_mods=ok count={len(files)}")
        return 0 if not problems else 1

    changed = 0
    registered = 0
    with connect(args.db) as conn:
        init_db(conn)
        import_id = ensure_import(conn, len(files), source_file=args.mods_dir / ".pummelchen_mods_import")
        for path in files:
            parsed, notes = inspect_mod_file(path)
            if not parsed:
                if notes:
                    print(f"WARN {path.name}: {notes[0]}")
                continue
            if upsert_entry(
                conn,
                import_id=import_id,
                jar_path=path,
                metadata=parsed,
                target_mc=args.target_mc,
                include_server=not args.exclude_server,
                include_client=not args.exclude_client,
            ):
                registered += 1
            if not args.exclude_server:
                if copy_if_changed(path, args.server_dir / "mods" / path.name):
                    changed += 1
            if args.include_client and not args.exclude_client:
                if copy_if_changed(path, args.server_dir / "client-package" / "mods" / path.name):
                    changed += 1
        conn.commit()

    print(f"pummelchen_mods_found={len(files)}")
    print(f"pummelchen_mods_registered={registered}")
    print(f"pummelchen_mods_changed={changed}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--project-dir", type=Path, default=DEFAULT_PROJECT_DIR)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--mods-dir", type=Path, default=DEFAULT_MODS_DIR)
    parser.add_argument("--target-mc", default=DEFAULT_TARGET_MC)
    parser.add_argument("--include-client", action="store_true", default=True)
    parser.add_argument("--exclude-client", action="store_true")
    parser.add_argument("--include-server", action="store_true", default=True)
    parser.add_argument("--exclude-server", action="store_true")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    include_client = args.include_client and not args.exclude_client
    include_server = args.include_server and not args.exclude_server
    if not include_server and not include_client:
        print("WARN exclude_client and exclude_server both set; nothing to sync")
        include_server = True

    args.include_client = include_client
    args.exclude_client = not include_client
    args.exclude_server = not include_server

    return run_sync(args)


if __name__ == "__main__":
    raise SystemExit(main())
