#!/usr/bin/env python3
"""Atomically rebuild the server DuckDB read model from the live SQLite DB."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path


DEFAULT_SQLITE = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_DUCKDB = Path("/var/minecraft_mods/data/pummelchen.duckdb")
DEFAULT_PROJECT_ROOT = Path("/var/minecraft_mods")


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rebuild(sqlite_path: Path, duckdb_path: Path, project_root: Path) -> int:
    import duckdb  # type: ignore[import-not-found]

    migration = project_root / "database/duckdb/migrations/001_foundation.sql"
    normalize = project_root / "database/duckdb/normalize_from_raw.sql"
    for path in (sqlite_path, migration, normalize):
        if not path.exists():
            raise FileNotFoundError(path)

    duckdb_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = duckdb_path.with_name(f".{duckdb_path.name}.tmp.{os.getpid()}")
    if tmp.exists():
        tmp.unlink()

    conn = duckdb.connect(str(tmp))
    try:
        conn.execute(migration.read_text(encoding="utf-8"))
        checksum = sha256_file(migration)
        conn.execute(
            f"""
            DELETE FROM core.schema_migrations WHERE version = 1;
            INSERT INTO core.schema_migrations(version, name, applied_at, checksum)
            VALUES (1, 'phase1_foundation', now(), {sql_literal(checksum)});
            """
        )
        conn.execute("INSTALL sqlite; LOAD sqlite;")
        conn.execute(f"ATTACH {sql_literal(str(sqlite_path))} AS sqlite_source (TYPE sqlite);")
        tables = [
            row[0]
            for row in conn.execute("SHOW TABLES FROM sqlite_source").fetchall()
            if row[0] and not str(row[0]).startswith("v_")
        ]
        for table in tables:
            ident = quote_identifier(str(table))
            conn.execute(f"DROP TABLE IF EXISTS raw.{ident};")
            conn.execute(f"CREATE TABLE raw.{ident} AS SELECT * FROM sqlite_source.{ident};")
        conn.execute(normalize.read_text(encoding="utf-8"))
        conn.close()
        tmp.replace(duckdb_path)
        return len(tables)
    except Exception:
        conn.close()
        if tmp.exists():
            tmp.unlink()
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sqlite", type=Path, default=DEFAULT_SQLITE)
    parser.add_argument("--duckdb", type=Path, default=DEFAULT_DUCKDB)
    parser.add_argument("--project-root", type=Path, default=DEFAULT_PROJECT_ROOT)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    count = rebuild(args.sqlite, args.duckdb, args.project_root)
    print(f"duckdb_rebuild=ok raw_tables={count} duckdb={args.duckdb}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
