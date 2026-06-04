#!/usr/bin/env python3
"""Write live system stats JSON for the Pummelchen status site."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT = Path("/var/minecraft_mods/site/public/live-stats.json")
DEFAULT_STATE = Path("/var/minecraft_mods/site/live-stats-history.json")
DEFAULT_SERVER = Path("/var/minecraft_26.1.2")
DEFAULT_HISTORY = 120


def human_bytes(value: float) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TB"


def percent(value: float, total: float) -> str:
    if not total:
        return "0%"
    return f"{(value / total) * 100:.1f}%"


def parse_meminfo() -> dict[str, int]:
    path = Path("/proc/meminfo")
    if not path.exists():
        return {}
    values: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            values[parts[0].rstrip(":")] = int(parts[1]) * 1024
    return values


def read_load_percent(cpu_count: int | None) -> tuple[list[float], str]:
    try:
        loads = list(os.getloadavg())
    except OSError:
        loads = [0.0, 0.0, 0.0]
    if not cpu_count:
        return loads, "Unknown"
    labels = ("1m", "5m", "15m")
    return loads, " / ".join(f"{label} {(load / cpu_count) * 100:.1f}%" for label, load in zip(labels, loads))


def read_cpu_times() -> dict[str, int] | None:
    path = Path("/proc/stat")
    if not path.exists():
        return None
    parts = path.read_text(encoding="utf-8", errors="replace").splitlines()[0].split()
    if not parts or parts[0] != "cpu":
        return None
    values = [int(part) for part in parts[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return {"total": sum(values), "idle": idle}


def cpu_usage_percent(previous: dict[str, int] | None, current: dict[str, int] | None) -> float:
    if not previous or not current:
        return 0.0
    total_delta = current["total"] - previous["total"]
    idle_delta = current["idle"] - previous["idle"]
    if total_delta <= 0:
        return 0.0
    return max(0.0, min(100.0, ((total_delta - idle_delta) / total_delta) * 100))


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_json_atomic(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def build_payload(server_dir: Path, state: dict[str, Any], history_limit: int) -> tuple[dict[str, Any], dict[str, Any]]:
    now = dt.datetime.now(dt.UTC)
    cpu_count = os.cpu_count() or 1
    current_cpu = read_cpu_times()
    cpu_percent = cpu_usage_percent(state.get("previous_cpu"), current_cpu)
    loads, load_text = read_load_percent(cpu_count)

    mem = parse_meminfo()
    mem_total = mem.get("MemTotal", 0)
    mem_available = mem.get("MemAvailable", 0)
    mem_used = max(mem_total - mem_available, 0)
    mem_used_percent = (mem_used / mem_total) * 100 if mem_total else 0.0

    disk = shutil.disk_usage(server_dir if server_dir.exists() else "/")
    disk_used_percent = (disk.used / disk.total) * 100 if disk.total else 0.0
    disk_free_gb = disk.free / (1024 ** 3)

    sample = {
        "t": now.isoformat(timespec="seconds"),
        "cpu_percent": round(cpu_percent, 2),
        "load1_percent": round((loads[0] / cpu_count) * 100, 2),
        "ram_used_percent": round(mem_used_percent, 2),
        "disk_used_percent": round(disk_used_percent, 2),
        "disk_free_gb": round(disk_free_gb, 2),
    }
    history = list(state.get("history") or [])
    history.append(sample)
    history = history[-history_limit:]

    payload = {
        "generated_at": now.isoformat(timespec="seconds"),
        "interval_seconds": 30,
        "stats": {
            "Generated": now.strftime("%Y-%m-%d %H:%M UTC"),
            "CPU usage": f"{cpu_percent:.1f}%",
            "Load average": load_text,
            "RAM used": f"{human_bytes(mem_used)} ({percent(mem_used, mem_total)})",
            "RAM available": human_bytes(mem_available),
            "Disk used/free": (
                f"{human_bytes(disk.used)} / {human_bytes(disk.total)} "
                f"({percent(disk.used, disk.total)}); {human_bytes(disk.free)} free"
            ),
        },
        "metrics": sample,
        "history": history,
    }
    next_state = {
        "previous_cpu": current_cpu,
        "history": history,
    }
    return payload, next_state


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER)
    parser.add_argument("--history-limit", type=int, default=DEFAULT_HISTORY)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    state = read_json(args.state)
    payload, next_state = build_payload(args.server_dir, state, max(2, args.history_limit))
    write_json_atomic(args.state, next_state)
    write_json_atomic(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
