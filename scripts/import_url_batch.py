#!/usr/bin/env python3
"""Import a pasted URL batch into the Minecraft mod tracker.

The SQLite database is the source of truth. This script keeps a durable record
of every pasted URL in url_batches/url_batch_items and inserts pending mods for
previously unseen CurseForge project slugs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sqlite3
from pathlib import Path
from typing import Sequence
from urllib.parse import urlparse

from moddb import HEADERS, connect, row_hash, slugify, source_kind, utc_now


BATCH_SCHEMA = """
CREATE TABLE IF NOT EXISTS url_batches (
    id INTEGER PRIMARY KEY,
    batch_name TEXT NOT NULL UNIQUE,
    source_file TEXT NOT NULL,
    imported_at TEXT NOT NULL,
    raw_url_count INTEGER NOT NULL,
    unique_url_count INTEGER NOT NULL,
    unique_project_count INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS url_batch_items (
    id INTEGER PRIMARY KEY,
    batch_id INTEGER NOT NULL REFERENCES url_batches(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    raw_url TEXT NOT NULL,
    normalized_url TEXT NOT NULL,
    source_kind TEXT NOT NULL,
    host TEXT,
    project_class TEXT,
    project_slug TEXT,
    canonical_key TEXT NOT NULL,
    mod_id INTEGER REFERENCES mods(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    process_status TEXT NOT NULL,
    note TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(batch_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_url_batch_items_batch ON url_batch_items(batch_id);
CREATE INDEX IF NOT EXISTS idx_url_batch_items_mod ON url_batch_items(mod_id);
CREATE INDEX IF NOT EXISTS idx_url_batch_items_status ON url_batch_items(process_status);
CREATE INDEX IF NOT EXISTS idx_url_batch_items_key ON url_batch_items(canonical_key);
"""


CURSEFORGE_PROJECT_RE = re.compile(
    r"^/minecraft/(?P<class>mc-mods|texture-packs|data-packs|shaders|worlds)/(?P<slug>[^/?#]+)"
)


def read_urls(path: Path) -> list[str]:
    urls: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        urls.append(value)
    return urls


def normalize_url(url: str) -> tuple[str, str, str, str, str, str]:
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path
    project_class = ""
    slug = ""
    normalized = url
    kind, _, _ = source_kind(url)

    if "curseforge.com" in host:
        match = CURSEFORGE_PROJECT_RE.match(path)
        if match:
            project_class = match.group("class")
            slug = match.group("slug")
            normalized = f"https://www.curseforge.com/minecraft/{project_class}/{slug}"
            kind = "curseforge"
    elif "modrinth.com" in host:
        parts = [part for part in path.split("/") if part]
        if len(parts) >= 2:
            project_class = parts[0]
            slug = parts[1]
            normalized = f"https://modrinth.com/{project_class}/{slug}"
            kind = "modrinth"

    canonical_key = slugify(slug or normalized)
    return normalized, kind, host, project_class, slug, canonical_key


def humanize_slug(slug: str) -> str:
    words = [word for word in re.split(r"[-_]+", slug) if word]
    if not words:
        return "Imported Mod"
    return " ".join(word.capitalize() for word in words)


def make_row_hash(
    name: str,
    url: str,
    target_mc: str,
    migration_note: str,
) -> str:
    cells = [
        name,
        "Server + client",
        "Mod",
        "Pending",
        "",
        "",
        url,
        target_mc,
        "Pending: URL imported",
        "",
        "Pending",
        "",
        "",
        migration_note,
    ]
    if len(cells) != len(HEADERS):
        raise ValueError("row shape drifted")
    return row_hash(cells)


def ensure_batch(
    conn: sqlite3.Connection,
    batch_name: str,
    source_file: Path,
    urls: Sequence[str],
    now: str,
) -> int:
    identities = [normalize_url(url)[5] for url in urls]
    exact = {normalize_url(url)[0] for url in urls}
    projects = set(identities)
    row = conn.execute(
        "SELECT id FROM url_batches WHERE batch_name = ?",
        (batch_name,),
    ).fetchone()
    if row:
        batch_id = int(row["id"])
        conn.execute("DELETE FROM url_batch_items WHERE batch_id = ?", (batch_id,))
        conn.execute(
            """
            UPDATE url_batches
            SET source_file = ?, imported_at = ?, raw_url_count = ?,
                unique_url_count = ?, unique_project_count = ?
            WHERE id = ?
            """,
            (str(source_file), now, len(urls), len(exact), len(projects), batch_id),
        )
        return batch_id

    cur = conn.execute(
        """
        INSERT INTO url_batches(
            batch_name, source_file, imported_at, raw_url_count,
            unique_url_count, unique_project_count
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        (batch_name, str(source_file), now, len(urls), len(exact), len(projects)),
    )
    return int(cur.lastrowid)


def ensure_import(conn: sqlite3.Connection, batch_name: str, source_file: Path, row_count: int, now: str) -> int:
    cur = conn.execute(
        """
        INSERT INTO imports(
            imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count
        ) VALUES (?, ?, NULL, ?, ?, ?)
        """,
        (now, str(source_file), "SQLite URL Batch", batch_name, row_count),
    )
    return int(cur.lastrowid)


def append_note(conn: sqlite3.Connection, mod_id: int, addition: str) -> None:
    row = conn.execute(
        "SELECT notes_1, notes_2, migration_notes FROM mod_notes WHERE mod_id = ?",
        (mod_id,),
    ).fetchone()
    notes_1 = row["notes_1"] if row else ""
    notes_2 = row["notes_2"] if row else ""
    existing = (row["migration_notes"] if row else "") or ""
    merged = existing if addition in existing else f"{existing} {addition}".strip()
    conn.execute(
        """
        INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET
            notes_1 = excluded.notes_1,
            notes_2 = excluded.notes_2,
            migration_notes = excluded.migration_notes
        """,
        (mod_id, notes_1 or "", notes_2 or "", merged),
    )


def find_existing_mod(conn: sqlite3.Connection, canonical_key: str, normalized_url: str) -> sqlite3.Row | None:
    row = conn.execute(
        """
        SELECT m.*
        FROM mods m
        LEFT JOIN source_urls su ON su.mod_id = m.id
        WHERE m.duplicate_of_id IS NULL
          AND (m.canonical_key = ? OR su.url = ?)
        ORDER BY m.status_rank DESC, m.id ASC
        LIMIT 1
        """,
        (canonical_key, normalized_url),
    ).fetchone()
    return row


def insert_pending_mod(
    conn: sqlite3.Connection,
    import_id: int,
    name: str,
    canonical_key: str,
    normalized_url: str,
    target_mc: str,
    now: str,
    migration_note: str,
) -> int:
    next_row = conn.execute(
        "SELECT COALESCE(MAX(original_sheet_row), 0) + 1 AS row_number FROM mods"
    ).fetchone()["row_number"]
    fingerprint = make_row_hash(name, normalized_url, target_mc, migration_note)
    cur = conn.execute(
        """
        INSERT INTO mods(
            import_id, original_sheet_row, category, name, canonical_key,
            installation, entry_type, tested, target_mc, server_status,
            client_package, last_tested, active_status, status_rank, primary_url,
            is_duplicate, duplicate_of_id, row_hash, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)
        """,
        (
            import_id,
            next_row,
            "Requested URL batch",
            name,
            canonical_key,
            "Server + client",
            "Mod",
            "Pending",
            target_mc,
            "Pending: URL imported",
            "Pending",
            "",
            "pending",
            10,
            normalized_url,
            fingerprint,
            now,
            now,
        ),
    )
    mod_id = int(cur.lastrowid)
    conn.execute(
        "INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes) VALUES (?, '', '', ?)",
        (mod_id, migration_note),
    )
    return mod_id


def ensure_source_url(
    conn: sqlite3.Connection,
    mod_id: int,
    normalized_url: str,
    kind: str,
    host: str,
    slug: str,
    is_primary: int,
) -> None:
    exists = conn.execute(
        "SELECT 1 FROM source_urls WHERE mod_id = ? AND url = ? LIMIT 1",
        (mod_id, normalized_url),
    ).fetchone()
    if exists:
        return
    conn.execute(
        """
        INSERT INTO source_urls(
            mod_id, source_kind, url, host, project_slug, resolved_source,
            file_id, release_channel, is_primary
        ) VALUES (?, ?, ?, ?, ?, ?, '', '', ?)
        """,
        (mod_id, kind, normalized_url, host, slug, "URL batch import only", is_primary),
    )


def import_urls(conn: sqlite3.Connection, args: argparse.Namespace) -> dict[str, int]:
    conn.executescript(BATCH_SCHEMA)
    now = utc_now()
    urls = read_urls(args.url_file)
    batch_id = ensure_batch(conn, args.batch_name, args.url_file, urls, now)
    import_id = ensure_import(conn, args.batch_name, args.url_file, len(urls), now)

    counts = {
        "raw": len(urls),
        "inserted": 0,
        "existing": 0,
        "duplicates_in_batch": 0,
        "source_urls_added": 0,
    }
    seen: dict[str, int] = {}
    batch_note = f"Imported from SQLite URL batch {args.batch_name} on {dt.date.today().isoformat()}."

    for ordinal, raw_url in enumerate(urls, start=1):
        normalized, kind, host, project_class, slug, canonical_key = normalize_url(raw_url)
        note = ""
        process_status = "queued"
        action = "inserted"
        mod_id: int | None

        if canonical_key in seen:
            mod_id = seen[canonical_key]
            action = "duplicate_in_batch"
            process_status = "duplicate"
            note = "Duplicate project already listed earlier in this batch."
            counts["duplicates_in_batch"] += 1
        else:
            existing = find_existing_mod(conn, canonical_key, normalized)
            if existing:
                mod_id = int(existing["id"])
                seen[canonical_key] = mod_id
                action = "existing"
                process_status = existing["active_status"] or "existing"
                append_note(conn, mod_id, batch_note)
                before = conn.total_changes
                ensure_source_url(conn, mod_id, normalized, kind, host, slug, 0)
                if conn.total_changes > before:
                    counts["source_urls_added"] += 1
                counts["existing"] += 1
            else:
                name = humanize_slug(slug or canonical_key)
                mod_id = insert_pending_mod(
                    conn,
                    import_id,
                    name,
                    canonical_key,
                    normalized,
                    args.target_mc,
                    now,
                    batch_note,
                )
                seen[canonical_key] = mod_id
                ensure_source_url(conn, mod_id, normalized, kind, host, slug, 1)
                counts["source_urls_added"] += 1
                counts["inserted"] += 1

        conn.execute(
            """
            INSERT INTO url_batch_items(
                batch_id, ordinal, raw_url, normalized_url, source_kind, host,
                project_class, project_slug, canonical_key, mod_id, action,
                process_status, note, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                batch_id,
                ordinal,
                raw_url,
                normalized,
                kind,
                host,
                project_class,
                slug,
                canonical_key,
                mod_id,
                action,
                process_status,
                note,
                now,
                now,
            ),
        )

    conn.commit()
    return counts


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url_file", type=Path)
    parser.add_argument("--db", type=Path, default=Path("data/minecraft_mods.sqlite"))
    parser.add_argument("--batch-name", required=True)
    parser.add_argument("--target-mc", default="26.1.2")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    with connect(args.db) as conn:
        counts = import_urls(conn, args)
    for key, value in counts.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
