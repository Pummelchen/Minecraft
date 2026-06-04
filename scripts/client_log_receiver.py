#!/usr/bin/env python3
"""Receive Pummelchen client diagnostic bundles from macOS clients."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import secrets
import shutil
import sqlite3
import tempfile
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_UPLOAD_DIR = Path("/var/minecraft_mods/client_log_uploads")
DEFAULT_TOKEN_FILE = Path("/var/minecraft_mods/secrets/client-log-upload.token")
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7791
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 35


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def safe_name(value: str, fallback: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    cleaned = cleaned.strip("._")
    return cleaned[:120] or fallback


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_token(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    token = secrets.token_urlsafe(32)
    path.write_text(token + "\n", encoding="utf-8")
    path.chmod(0o600)
    return token


def init_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS client_log_uploads (
                id INTEGER PRIMARY KEY,
                uploaded_at TEXT NOT NULL,
                client_id TEXT NOT NULL,
                remote_addr TEXT,
                file_name TEXT NOT NULL,
                stored_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                pack_sha256 TEXT,
                minecraft_version TEXT,
                os_summary TEXT,
                java_summary TEXT,
                crash_headline TEXT,
                notes TEXT
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_client_log_uploads_uploaded ON client_log_uploads(uploaded_at)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_client_log_uploads_client ON client_log_uploads(client_id)")


def read_zip_text(archive_path: Path, candidates: tuple[str, ...], max_bytes: int = 64_000) -> str:
    try:
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            name_set = set(names)
            for candidate in candidates:
                if candidate in name_set:
                    with archive.open(candidate) as handle:
                        return handle.read(max_bytes).decode("utf-8", errors="replace")
            for name in names:
                if any(name.endswith(f"/{candidate}") for candidate in candidates):
                    with archive.open(name) as handle:
                        return handle.read(max_bytes).decode("utf-8", errors="replace")
    except Exception:
        return ""
    return ""


def metadata_from_zip(archive_path: Path) -> dict[str, str]:
    summary = read_zip_text(archive_path, ("summary.txt", "diagnostics/summary.txt"))
    crash = read_zip_text(archive_path, ("crash-headline.txt", "diagnostics/crash-headline.txt"), max_bytes=8_000)
    values: dict[str, str] = {}
    for line in summary.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    if crash.strip():
        values["crash_headline"] = crash.strip().splitlines()[0][:500]
    return values


class UploadHandler(BaseHTTPRequestHandler):
    server_version = "PummelchenClientLogReceiver/1.0"

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(REQUEST_TIMEOUT_SECONDS)

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"ok": True})
            return
        self.send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        if self.path not in {"/upload", "/client-logs/upload"}:
            self.send_json(404, {"ok": False, "error": "not_found"})
            return

        token = self.headers.get("X-Pummelchen-Upload-Token", "")
        if not secrets.compare_digest(token, self.server.upload_token):
            self.send_json(403, {"ok": False, "error": "forbidden"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(411, {"ok": False, "error": "missing_length"})
            return
        if length <= 0:
            self.send_json(400, {"ok": False, "error": "empty_upload"})
            return
        if length > self.server.max_upload_bytes:
            self.send_json(413, {"ok": False, "error": "too_large"})
            return

        client_id = safe_name(self.headers.get("X-Pummelchen-Client-Id", ""), "unknown-client")
        original_name = safe_name(self.headers.get("X-Pummelchen-Filename", ""), "pummelchen-client-logs.zip")
        if not original_name.endswith(".zip"):
            original_name += ".zip"

        now = dt.datetime.now(dt.UTC)
        day_dir = self.server.upload_dir / now.strftime("%Y") / now.strftime("%m") / now.strftime("%d")
        day_dir.mkdir(parents=True, exist_ok=True)
        stored_name = f"{now.strftime('%Y%m%dT%H%M%SZ')}_{client_id}_{original_name}"
        final_path = day_dir / stored_name

        temp_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(dir=day_dir, prefix=".upload-", delete=False) as tmp:
                temp_path = Path(tmp.name)
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        temp_path.unlink(missing_ok=True)
                        self.send_json(400, {"ok": False, "error": "truncated_upload"})
                        return
                    tmp.write(chunk)
                    remaining -= len(chunk)
        except (OSError, TimeoutError):
            if temp_path:
                temp_path.unlink(missing_ok=True)
            self.send_json(408, {"ok": False, "error": "upload_timeout"})
            return

        if not zipfile.is_zipfile(temp_path):
            temp_path.unlink(missing_ok=True)
            self.send_json(400, {"ok": False, "error": "not_zip"})
            return

        digest = sha256_file(temp_path)
        shutil.move(str(temp_path), final_path)
        final_path.chmod(0o640)

        meta = metadata_from_zip(final_path)
        remote_addr = self.headers.get("X-Real-IP") or self.client_address[0]
        with sqlite3.connect(self.server.db_path) as conn:
            cursor = conn.execute(
                """
                INSERT INTO client_log_uploads(
                    uploaded_at, client_id, remote_addr, file_name, stored_path,
                    size_bytes, sha256, pack_sha256, minecraft_version,
                    os_summary, java_summary, crash_headline, notes
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    utc_now(),
                    client_id,
                    remote_addr,
                    original_name,
                    str(final_path),
                    final_path.stat().st_size,
                    digest,
                    self.headers.get("X-Pummelchen-Pack-Sha", "") or meta.get("pack_sha256", ""),
                    meta.get("minecraft_version", ""),
                    meta.get("os", ""),
                    meta.get("java", ""),
                    meta.get("crash_headline", ""),
                    meta.get("notes", ""),
                ),
            )
            upload_id = int(cursor.lastrowid)

        self.send_json(
            200,
            {
                "ok": True,
                "id": upload_id,
                "sha256": digest,
                "stored": stored_name,
                "size_bytes": final_path.stat().st_size,
            },
        )


class UploadServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        *,
        db_path: Path,
        upload_dir: Path,
        upload_token: str,
        max_upload_bytes: int,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.db_path = db_path
        self.upload_dir = upload_dir
        self.upload_token = upload_token
        self.max_upload_bytes = max_upload_bytes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--upload-dir", type=Path, default=DEFAULT_UPLOAD_DIR)
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--max-mb", type=int, default=25)
    parser.add_argument("--print-token", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    token = ensure_token(args.token_file)
    if args.print_token:
        print(token)
        return

    init_db(args.db)
    args.upload_dir.mkdir(parents=True, exist_ok=True)
    server = UploadServer(
        (args.host, args.port),
        UploadHandler,
        db_path=args.db,
        upload_dir=args.upload_dir,
        upload_token=token,
        max_upload_bytes=args.max_mb * 1024 * 1024,
    )
    print(f"client_log_receiver listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
