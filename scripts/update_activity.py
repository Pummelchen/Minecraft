#!/usr/bin/env python3
"""Lightweight activity feed for the daily update pipeline.

Writes timestamped activity entries to a JSON file that the status site
reads via JavaScript to show live pipeline progress.
"""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path


DEFAULT_PATH = Path("/var/minecraft_mods/site/public/update-activity.json")
MAX_ENTRIES = 50


def log_activity(
    message: str,
    *,
    stage: str = "",
    status: str = "info",
    activity_path: Path | None = None,
) -> None:
    """Append a timestamped activity entry to the feed file.

    Safe to call from any pipeline step. Failures are silently ignored so
    activity logging never breaks the pipeline.
    """
    path = activity_path or DEFAULT_PATH
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        entries: list[dict[str, str]] = []
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                entries = data.get("entries", [])
            except Exception:
                entries = []
        now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        entries.append({
            "timestamp": now,
            "stage": stage,
            "status": status,
            "message": message,
        })
        entries = entries[-MAX_ENTRIES:]
        payload = {
            "updated_at": now,
            "entry_count": len(entries),
            "entries": entries,
        }
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        os.replace(str(tmp), str(path))
    except Exception:
        pass


def clear_activity(*, activity_path: Path | None = None) -> None:
    """Reset the activity feed at the start of a new pipeline run."""
    path = activity_path or DEFAULT_PATH
    try:
        now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        payload = {"updated_at": now, "entry_count": 0, "entries": []}
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        os.replace(str(tmp), str(path))
    except Exception:
        pass
