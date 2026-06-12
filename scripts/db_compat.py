#!/usr/bin/env python3
"""Read-only SQLite/DuckDB compatibility helpers for generated web outputs."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

from moddb import connect as sqlite_connect


class MappingRow(Mapping[str, Any]):
    """Small row object that behaves like sqlite3.Row for dict(row) and row[name]."""

    def __init__(self, columns: Sequence[str], values: Sequence[Any]):
        self._columns = list(columns)
        self._values = list(values)
        self._by_name = {column: value for column, value in zip(self._columns, self._values)}

    def __getitem__(self, key: str | int) -> Any:
        if isinstance(key, int):
            return self._values[key]
        return self._by_name[key]

    def __iter__(self) -> Iterator[str]:
        return iter(self._columns)

    def __len__(self) -> int:
        return len(self._columns)

    def keys(self) -> list[str]:
        return list(self._columns)


class DuckDBCursor:
    def __init__(self, cursor: Any):
        self._cursor = cursor
        self._columns = [column[0] for column in (cursor.description or [])]

    def fetchone(self) -> MappingRow | None:
        row = self._cursor.fetchone()
        return MappingRow(self._columns, row) if row is not None else None

    def fetchall(self) -> list[MappingRow]:
        return [MappingRow(self._columns, row) for row in self._cursor.fetchall()]

    def __iter__(self) -> Iterator[MappingRow]:
        return iter(self.fetchall())


class DuckDBCompatConnection:
    is_duckdb_compat = True

    def __init__(self, path: Path):
        import duckdb  # type: ignore[import-not-found]

        self.path = path
        self._conn = duckdb.connect(str(path), read_only=True)
        self._conn.execute("SET search_path = raw")

    def execute(self, sql: str, parameters: Sequence[Any] | None = None) -> DuckDBCursor:
        cursor = self._conn.execute(sql, parameters or [])
        return DuckDBCursor(cursor)

    def has_table(self, table_name: str) -> bool:
        row = self._conn.execute(
            """
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema IN ('raw', 'reporting', 'core')
              AND table_name = ?
            LIMIT 1
            """,
            [table_name],
        ).fetchone()
        return row is not None

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "DuckDBCompatConnection":
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()


def connect_readonly(db_path: Path) -> sqlite3.Connection | DuckDBCompatConnection:
    """Open SQLite normally or DuckDB read-only when the path ends in .duckdb."""

    if db_path.suffix.lower() == ".duckdb":
        return DuckDBCompatConnection(db_path)
    return sqlite_connect(db_path)
