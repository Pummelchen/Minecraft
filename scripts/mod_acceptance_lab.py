#!/usr/bin/env python3
"""Isolated mod acceptance tests before mods enter the live Pummelchen pack.

The lab creates throwaway NeoForge server directories, installs only the target
jar set plus its required dependency closure, boots a disposable world on a
non-live port, exercises a small chunk-generation area, and records the result
in SQLite. It is intentionally separate from the gameplay load lab: this tool
answers "can these jars coexist at all?" before broader player/load testing.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as dt
import hashlib
import os
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Any, Iterable, Sequence

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.10 fallback.
    tomllib = None  # type: ignore[assignment]

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import process_url_batch as processor
import server_ops
from moddb import connect, init_db, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_LAB_ROOT = Path("/var/minecraft_mods/mod_acceptance_lab")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_DISPLAY_NAME = "Pummelchen Server"
DEFAULT_BUNDLE_SIZE = 25
IGNORED_DEPENDENCIES = {
    "java",
    "minecraft",
    "forge",
    "neoforge",
    "minecraftforge",
}
STATIC_DEPENDENCY_HINTS = {
    b"terrablender/api/": "terrablender",
    b"terrablender.api.": "terrablender",
    b"productivelib": "productivelib",
}
ERROR_RE = re.compile(
    r"(^|[^A-Za-z])ERROR([^A-Za-z]|$)|Exception|Crash report|Failed to start|"
    r"ModLoadingException|Missing.*dependencies|UnsupportedClassVersion|mixin apply failed|"
    r"NoClassDefFoundError|ClassNotFoundException|server watchdog",
    re.IGNORECASE,
)


@dataclasses.dataclass(frozen=True)
class ModJar:
    path: Path
    file_name: str
    mod_ids: tuple[str, ...]
    required_deps: tuple[str, ...]
    mod_id: int | None = None
    mod_name: str = ""
    source_url: str = ""


@dataclasses.dataclass(frozen=True)
class LabResult:
    status: str
    log_path: Path
    boot_seconds: float
    idle_seconds: float
    error_count: int
    severe_errors: tuple[str, ...]
    notes: str


def safe_label(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_")[:120] or "acceptance"


def now_label(prefix: str) -> str:
    return f"{safe_label(prefix)}_{dt.datetime.now(dt.UTC).strftime('%Y%m%d_%H%M%S')}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_mod_id(value: str | None) -> str:
    return re.sub(r"[^a-z0-9_]+", "", (value or "").strip().lower())


def toml_metadata(path: Path) -> tuple[set[str], set[str], list[str]]:
    mod_ids: set[str] = set()
    required: set[str] = set()
    warnings: list[str] = []
    if tomllib is None:
        return mod_ids, required, ["tomllib unavailable; metadata dependency scan skipped"]
    if not zipfile.is_zipfile(path):
        return mod_ids, required, ["not a zip/jar file"]
    metadata_paths = ("META-INF/neoforge.mods.toml", "META-INF/mods.toml")
    try:
        with zipfile.ZipFile(path) as archive:
            existing = set(archive.namelist())
            for metadata_path in metadata_paths:
                if metadata_path not in existing:
                    continue
                try:
                    data = tomllib.loads(archive.read(metadata_path).decode("utf-8", errors="replace"))
                except Exception as exc:
                    warnings.append(f"{metadata_path}: {type(exc).__name__}: {exc}")
                    continue
                for mod_entry in data.get("mods") or []:
                    mod_id = normalize_mod_id(str(mod_entry.get("modId") or ""))
                    if mod_id:
                        mod_ids.add(mod_id)
                dependency_groups = data.get("dependencies") or {}
                if isinstance(dependency_groups, dict):
                    for deps in dependency_groups.values():
                        if isinstance(deps, dict):
                            deps = [deps]
                        if not isinstance(deps, list):
                            continue
                        for dep in deps:
                            if not isinstance(dep, dict):
                                continue
                            dep_id = normalize_mod_id(str(dep.get("modId") or ""))
                            side = str(dep.get("side") or "").strip().upper()
                            dep_type = str(dep.get("type") or "").strip().lower()
                            mandatory_value = dep.get("mandatory", True)
                            mandatory = str(mandatory_value).strip().lower() not in {"false", "0", "no"}
                            if (
                                dep_id
                                and dep_id not in IGNORED_DEPENDENCIES
                                and mandatory is not False
                                and dep_type in {"", "required"}
                                and side != "CLIENT"
                            ):
                                required.add(dep_id)
                break
    except Exception as exc:
        warnings.append(f"metadata scan failed: {type(exc).__name__}: {exc}")
    return mod_ids, required, warnings


def static_dependency_hints(path: Path) -> set[str]:
    found: set[str] = set()
    if not zipfile.is_zipfile(path):
        return found
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if info.file_size > 2_000_000:
                    continue
                suffix = Path(info.filename).suffix.lower()
                if suffix not in {".class", ".json", ".toml", ".mcmeta"}:
                    continue
                try:
                    data = archive.read(info.filename)
                except Exception:
                    continue
                for needle, dep_id in STATIC_DEPENDENCY_HINTS.items():
                    if needle in data:
                        found.add(dep_id)
    except Exception:
        return found
    return found


def split_db_file_names(value: str) -> list[str]:
    names: list[str] = []
    for raw in re.split(r"\s*(?:;|\+)\s*", value or ""):
        name = Path(raw.strip()).name
        if name and name.lower() not in {"not installed", "not included"}:
            names.append(name)
    return names


def db_file_map(conn: sqlite3.Connection) -> dict[str, sqlite3.Row]:
    rows = conn.execute(
        """
        SELECT m.id AS mod_id, m.name, m.primary_url, msf.file_name, msf.source_url
        FROM mod_server_files msf
        JOIN mods m ON m.id = msf.mod_id
        WHERE msf.selected = 1
        ORDER BY msf.installed_on_server DESC, msf.included_in_client DESC, msf.id
        """
    ).fetchall()
    mapped: dict[str, sqlite3.Row] = {}
    for row in rows:
        for name in split_db_file_names(str(row["file_name"] or "")):
            mapped.setdefault(name.lower(), row)
    return mapped


def build_mod_jar(path: Path, mapped: sqlite3.Row | None = None) -> ModJar:
    mod_ids, deps, warnings = toml_metadata(path)
    deps.update(static_dependency_hints(path))
    if not mod_ids:
        fallback = normalize_mod_id(path.stem.split("-")[0])
        if fallback:
            mod_ids.add(fallback)
    if warnings and not mod_ids:
        deps.add("__metadata_unreadable__")
    return ModJar(
        path=path,
        file_name=path.name,
        mod_ids=tuple(sorted(mod_ids)),
        required_deps=tuple(sorted(dep for dep in deps if dep not in mod_ids)),
        mod_id=int(mapped["mod_id"]) if mapped and mapped["mod_id"] is not None else None,
        mod_name=str(mapped["name"] or "") if mapped else path.stem,
        source_url=str(mapped["source_url"] or mapped["primary_url"] or "") if mapped else "",
    )


def active_server_jars(server_dir: Path, conn: sqlite3.Connection) -> list[ModJar]:
    mods_dir = server_dir / "mods"
    mapped = db_file_map(conn)
    jars: list[ModJar] = []
    if not mods_dir.exists():
        return jars
    for path in sorted(mods_dir.iterdir(), key=lambda item: item.name.lower()):
        if path.is_file() and path.suffix.lower() in {".jar", ".zip"}:
            jars.append(build_mod_jar(path, mapped.get(path.name.lower())))
    return jars


def external_jars(paths: Sequence[Path]) -> list[ModJar]:
    jars: list[ModJar] = []
    for path in paths:
        if not path.exists():
            raise SystemExit(f"candidate file not found: {path}")
        jars.append(build_mod_jar(path))
    return jars


def mod_id_index(jars: Iterable[ModJar]) -> dict[str, ModJar]:
    index: dict[str, ModJar] = {}
    for jar in jars:
        for mod_id in jar.mod_ids:
            index.setdefault(mod_id, jar)
    return index


def dependency_closure(targets: Sequence[ModJar], available: Sequence[ModJar]) -> tuple[list[ModJar], list[str]]:
    index = mod_id_index(available)
    selected: dict[Path, ModJar] = {jar.path: jar for jar in targets}
    missing: set[str] = set()
    queue: list[ModJar] = list(targets)
    while queue:
        jar = queue.pop(0)
        for dep_id in jar.required_deps:
            if dep_id in IGNORED_DEPENDENCIES:
                continue
            dependency = index.get(dep_id)
            if dependency is None:
                missing.add(dep_id)
                continue
            if dependency.path not in selected:
                selected[dependency.path] = dependency
                queue.append(dependency)
    return sorted(selected.values(), key=lambda jar: jar.file_name.lower()), sorted(missing)


def find_free_port(start: int = 25580, end: int = 25680) -> int:
    for port in range(start, end):
        with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError(f"no free local port in {start}-{end - 1}")


def read_properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def write_properties(path: Path, values: dict[str, str]) -> None:
    lines = [f"{key}={value}" for key, value in sorted(values.items())]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def copy_optional_tree(src: Path, dst: Path) -> None:
    if src.exists() and src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=True)


def prepare_lab_server(
    *,
    source_server: Path,
    lab_dir: Path,
    jars: Sequence[ModJar],
    port: int,
    heap_mb: int,
) -> None:
    if lab_dir.exists():
        shutil.rmtree(lab_dir)
    lab_dir.mkdir(parents=True)
    for name in ("libraries",):
        src = source_server / name
        if src.exists():
            (lab_dir / name).symlink_to(src, target_is_directory=True)
    for name in ("run.sh", "start.sh", "eula.txt"):
        src = source_server / name
        if src.exists():
            shutil.copy2(src, lab_dir / name)
    if not (lab_dir / "eula.txt").exists():
        (lab_dir / "eula.txt").write_text("eula=true\n", encoding="utf-8")
    for script in ("run.sh", "start.sh"):
        path = lab_dir / script
        if path.exists():
            path.chmod(0o755)
    (lab_dir / "user_jvm_args.txt").write_text(
        "\n".join(
            [
                "-Xms512M",
                f"-Xmx{heap_mb}M",
                "-XX:+UseG1GC",
                "-Dfile.encoding=UTF-8",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    copy_optional_tree(source_server / "config", lab_dir / "config")
    copy_optional_tree(source_server / "defaultconfigs", lab_dir / "defaultconfigs")
    mods_dir = lab_dir / "mods"
    mods_dir.mkdir()
    for jar in jars:
        shutil.copy2(jar.path, mods_dir / jar.file_name)
    properties = read_properties(source_server / "server.properties")
    properties.update(
        {
            "allow-flight": "true",
            "enable-command-block": "true",
            "enable-rcon": "false",
            "enable-status": "false",
            "enforce-secure-profile": "false",
            "level-name": "world",
            "max-players": "1",
            "motd": "Pummelchen Mod Acceptance Lab",
            "online-mode": "false",
            "query.port": str(port),
            "rcon.port": str(port + 1000),
            "server-ip": "127.0.0.1",
            "server-port": str(port),
            "simulation-distance": "4",
            "view-distance": "5",
            "white-list": "false",
        }
    )
    write_properties(lab_dir / "server.properties", properties)


def wait_for_done_or_exit(proc: subprocess.Popen[str], log_path: Path, timeout: int) -> tuple[str, float]:
    started = time.monotonic()
    deadline = started + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return "exited", time.monotonic() - started
        if log_path.exists() and "Done (" in log_path.read_text(encoding="utf-8", errors="replace"):
            return "started", time.monotonic() - started
        time.sleep(1)
    return "timeout", time.monotonic() - started


def exercise_chunks(proc: subprocess.Popen[str], radius: int) -> None:
    if radius <= 0 or not proc.stdin:
        return
    for x in range(-radius, radius + 1):
        for z in range(-radius, radius + 1):
            try:
                proc.stdin.write(f"forceload add {x} {z}\n")
                proc.stdin.flush()
            except Exception:
                return
            time.sleep(0.05)


def stop_process(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    try:
        if proc.stdin:
            proc.stdin.write("stop\n")
            proc.stdin.flush()
    except Exception:
        pass
    try:
        proc.wait(timeout=60)
        return
    except subprocess.TimeoutExpired:
        pass
    with contextlib.suppress(Exception):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(Exception):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=20)


def severe_errors(log_path: Path) -> tuple[int, tuple[str, ...]]:
    if not log_path.exists():
        return 0, ()
    raw = [
        f"{index}:{line}"
        for index, line in enumerate(log_path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1)
        if ERROR_RE.search(line)
    ]
    if not raw:
        return 0, ()
    temp = log_path.with_suffix(log_path.suffix + ".errors")
    temp.write_text("\n".join(raw), encoding="utf-8")
    return len(raw), tuple(processor.filtered_error_lines(temp))


def run_lab_server(
    *,
    source_server: Path,
    work_dir: Path,
    log_path: Path,
    jars: Sequence[ModJar],
    boot_timeout: int,
    idle_seconds: int,
    heap_mb: int,
    exercise_radius: int,
) -> LabResult:
    port = find_free_port()
    prepare_lab_server(source_server=source_server, lab_dir=work_dir, jars=jars, port=port, heap_mb=heap_mb)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    proc: subprocess.Popen[str] | None = None
    status = "failed"
    boot_seconds = 0.0
    idle_elapsed = 0.0
    notes = ""
    try:
        with log_path.open("w", encoding="utf-8") as log_handle:
            proc = subprocess.Popen(
                ["bash", "start.sh"],
                cwd=work_dir,
                stdin=subprocess.PIPE,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
            boot_status, boot_seconds = wait_for_done_or_exit(proc, log_path, boot_timeout)
            if boot_status != "started":
                notes = f"server boot {boot_status} before Done"
            else:
                exercise_chunks(proc, exercise_radius)
                idle_start = time.monotonic()
                while time.monotonic() - idle_start < idle_seconds:
                    if proc.poll() is not None:
                        notes = f"server exited during idle after {time.monotonic() - idle_start:.1f}s"
                        break
                    time.sleep(1)
                idle_elapsed = time.monotonic() - idle_start
                if not notes:
                    status = "passed"
                    notes = "server reached Done and survived idle/chunk exercise"
    finally:
        if proc is not None:
            stop_process(proc)
    error_count, severe = severe_errors(log_path)
    if severe:
        status = "failed"
        notes = "severe log errors: " + " | ".join(severe[:3])
    return LabResult(
        status=status,
        log_path=log_path,
        boot_seconds=boot_seconds,
        idle_seconds=idle_elapsed,
        error_count=error_count,
        severe_errors=severe,
        notes=notes,
    )


def server_instance_id(conn: sqlite3.Connection, args: argparse.Namespace) -> int | None:
    try:
        return server_ops.ensure_server_instance(
            conn,
            server_key=args.server_key,
            display_name=DEFAULT_DISPLAY_NAME,
            server_dir=args.server_dir,
            active=True,
        )
    except Exception:
        row = conn.execute("SELECT id FROM server_instances WHERE server_key = ?", (args.server_key,)).fetchone()
        return int(row["id"]) if row else None


def create_run(conn: sqlite3.Connection, args: argparse.Namespace, run_label: str, run_type: str, target_count: int) -> int:
    cur = conn.execute(
        """
        INSERT INTO mod_acceptance_runs(
            server_instance_id, run_label, run_type, started_at, status,
            bundle_size, target_count, lab_root, notes
        ) VALUES (?, ?, ?, ?, 'running', ?, ?, ?, ?)
        """,
        (
            server_instance_id(conn, args),
            run_label,
            run_type,
            utc_now(),
            getattr(args, "bundle_size", None),
            target_count,
            str(args.lab_root),
            "Isolated NeoForge throwaway-server acceptance run",
        ),
    )
    conn.commit()
    return int(cur.lastrowid)


def insert_item(
    conn: sqlite3.Connection,
    run_id: int,
    *,
    ordinal: int,
    bundle_index: int | None,
    stage: str,
    status: str,
    targets: Sequence[ModJar],
    included: Sequence[ModJar],
    missing: Sequence[str],
    result: LabResult | None,
    notes: str,
) -> None:
    mod_id = targets[0].mod_id if targets and len(targets) == 1 else None
    conn.execute(
        """
        INSERT INTO mod_acceptance_items(
            acceptance_run_id, mod_id, ordinal, bundle_index, stage, status,
            target_file_names, included_file_names, missing_dependencies,
            log_path, boot_seconds, idle_seconds, error_count, severe_error_count,
            notes, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            run_id,
            mod_id,
            ordinal,
            bundle_index,
            stage,
            status,
            "\n".join(jar.file_name for jar in targets),
            "\n".join(jar.file_name for jar in included),
            "\n".join(missing),
            str(result.log_path) if result else "",
            result.boot_seconds if result else None,
            result.idle_seconds if result else None,
            result.error_count if result else None,
            len(result.severe_errors) if result else None,
            notes,
            utc_now(),
        ),
    )


def finish_run(conn: sqlite3.Connection, run_id: int, status: str) -> None:
    counts = conn.execute(
        """
        SELECT
            SUM(CASE WHEN status = 'passed' THEN 1 ELSE 0 END) AS passed,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed,
            SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) AS blocked
        FROM mod_acceptance_items
        WHERE acceptance_run_id = ?
        """,
        (run_id,),
    ).fetchone()
    conn.execute(
        """
        UPDATE mod_acceptance_runs
        SET completed_at = ?, status = ?, passed_count = ?, failed_count = ?, blocked_count = ?
        WHERE id = ?
        """,
        (
            utc_now(),
            status,
            int(counts["passed"] or 0),
            int(counts["failed"] or 0),
            int(counts["blocked"] or 0),
            run_id,
        ),
    )
    conn.commit()


def selected_subset(items: Sequence[ModJar], limit: int, offset: int) -> list[ModJar]:
    subset = list(items[offset:])
    return subset[:limit] if limit else subset


def print_plan(jars: Sequence[ModJar], bundle_size: int) -> None:
    print(f"active_server_jars={len(jars)}")
    print(f"bundle_size={bundle_size}")
    print(f"bundle_count={(len(jars) + bundle_size - 1) // bundle_size if bundle_size else 0}")
    for index, jar in enumerate(jars[:20], start=1):
        deps = ",".join(jar.required_deps) if jar.required_deps else "-"
        ids = ",".join(jar.mod_ids) if jar.mod_ids else "-"
        print(f"{index}\t{jar.file_name}\tmod_ids={ids}\trequires={deps}")
    if len(jars) > 20:
        print(f"... {len(jars) - 20} more")


def run_singles(args: argparse.Namespace) -> int:
    run_label = args.run_label or now_label("single_mod_acceptance")
    with connect(args.db) as conn:
        init_db(conn)
        active = active_server_jars(args.server_dir, conn)
        targets = selected_subset(active, args.limit, args.offset)
        if args.dry_run:
            print_plan(targets, args.bundle_size)
            return 0
        args.lab_root.mkdir(parents=True, exist_ok=True)
        run_id = create_run(conn, args, run_label, "single", len(targets))
        work_root = args.lab_root / "work" / run_label
        log_root = args.lab_root / "logs" / run_label
        final_status = "passed"
        for ordinal, target in enumerate(targets, start=1 + args.offset):
            included, missing = dependency_closure([target], active)
            if missing:
                insert_item(
                    conn,
                    run_id,
                    ordinal=ordinal,
                    bundle_index=None,
                    stage="single",
                    status="blocked",
                    targets=[target],
                    included=included,
                    missing=missing,
                    result=None,
                    notes="missing dependency mod ids: " + ", ".join(missing),
                )
                final_status = "failed"
                conn.commit()
                print(f"{ordinal}/{len(active)} blocked {target.file_name}: missing {', '.join(missing)}", flush=True)
                continue
            item_label = safe_label(f"{ordinal:03d}_{target.file_name}")
            result = run_lab_server(
                source_server=args.server_dir,
                work_dir=work_root / item_label,
                log_path=log_root / f"{item_label}.log",
                jars=included,
                boot_timeout=args.boot_timeout,
                idle_seconds=args.idle_seconds,
                heap_mb=args.heap_mb,
                exercise_radius=args.exercise_radius,
            )
            insert_item(
                conn,
                run_id,
                ordinal=ordinal,
                bundle_index=None,
                stage="single",
                status=result.status,
                targets=[target],
                included=included,
                missing=(),
                result=result,
                notes=result.notes,
            )
            conn.commit()
            if result.status != "passed":
                final_status = "failed"
            print(f"{ordinal}/{len(active)} {result.status} {target.file_name}", flush=True)
            if not args.keep_lab:
                shutil.rmtree(work_root / item_label, ignore_errors=True)
        finish_run(conn, run_id, final_status)
    print(f"run_label={run_label}")
    print(f"status={final_status}")
    return 0 if final_status == "passed" else 1


def bundle_targets(jars: Sequence[ModJar], bundle_size: int) -> list[list[ModJar]]:
    if bundle_size < 1:
        raise SystemExit("--bundle-size must be at least 1")
    return [list(jars[index : index + bundle_size]) for index in range(0, len(jars), bundle_size)]


def run_bundles(args: argparse.Namespace) -> int:
    run_label = args.run_label or now_label("bundle_acceptance")
    with connect(args.db) as conn:
        init_db(conn)
        active = active_server_jars(args.server_dir, conn)
        bundles = bundle_targets(active, args.bundle_size)
        selected = bundles[args.offset :]
        if args.limit:
            selected = selected[: args.limit]
        if args.dry_run:
            print(f"active_server_jars={len(active)}")
            print(f"selected_bundles={len(selected)}")
            for index, bundle in enumerate(selected[:10], start=1 + args.offset):
                print(f"bundle={index}\ttargets={len(bundle)}\tfirst={bundle[0].file_name if bundle else '-'}")
            return 0
        args.lab_root.mkdir(parents=True, exist_ok=True)
        run_id = create_run(conn, args, run_label, "bundle", sum(len(bundle) for bundle in selected))
        work_root = args.lab_root / "work" / run_label
        log_root = args.lab_root / "logs" / run_label
        final_status = "passed"
        for bundle_index, bundle in enumerate(selected, start=1 + args.offset):
            included, missing = dependency_closure(bundle, active)
            if missing:
                insert_item(
                    conn,
                    run_id,
                    ordinal=bundle_index,
                    bundle_index=bundle_index,
                    stage="bundle",
                    status="blocked",
                    targets=bundle,
                    included=included,
                    missing=missing,
                    result=None,
                    notes="missing dependency mod ids: " + ", ".join(missing),
                )
                final_status = "failed"
                conn.commit()
                print(f"bundle {bundle_index} blocked: missing {', '.join(missing)}", flush=True)
                continue
            item_label = safe_label(f"bundle_{bundle_index:03d}")
            result = run_lab_server(
                source_server=args.server_dir,
                work_dir=work_root / item_label,
                log_path=log_root / f"{item_label}.log",
                jars=included,
                boot_timeout=args.boot_timeout,
                idle_seconds=args.idle_seconds,
                heap_mb=args.heap_mb,
                exercise_radius=args.exercise_radius,
            )
            insert_item(
                conn,
                run_id,
                ordinal=bundle_index,
                bundle_index=bundle_index,
                stage="bundle",
                status=result.status,
                targets=bundle,
                included=included,
                missing=(),
                result=result,
                notes=result.notes,
            )
            conn.commit()
            if result.status != "passed":
                final_status = "failed"
            print(f"bundle {bundle_index}/{len(bundles)} {result.status} targets={len(bundle)} included={len(included)}", flush=True)
            if not args.keep_lab:
                shutil.rmtree(work_root / item_label, ignore_errors=True)
        finish_run(conn, run_id, final_status)
    print(f"run_label={run_label}")
    print(f"status={final_status}")
    return 0 if final_status == "passed" else 1


def run_files(args: argparse.Namespace) -> int:
    run_label = args.run_label or now_label("candidate_acceptance")
    with connect(args.db) as conn:
        init_db(conn)
        targets = external_jars(args.files)
        available = list(targets)
        if args.include_active_deps:
            available.extend(active_server_jars(args.server_dir, conn))
        included, missing = dependency_closure(targets, available)
        if args.dry_run:
            print(f"candidate_files={len(targets)}")
            print(f"included_files={len(included)}")
            print("missing_dependencies=" + ",".join(missing))
            for jar in included:
                print(jar.file_name)
            return 0 if not missing else 2
        args.lab_root.mkdir(parents=True, exist_ok=True)
        run_id = create_run(conn, args, run_label, "candidate", len(targets))
        if missing:
            insert_item(
                conn,
                run_id,
                ordinal=1,
                bundle_index=None,
                stage="candidate",
                status="blocked",
                targets=targets,
                included=included,
                missing=missing,
                result=None,
                notes="missing dependency mod ids: " + ", ".join(missing),
            )
            finish_run(conn, run_id, "failed")
            print("status=blocked")
            print("missing_dependencies=" + ",".join(missing))
            return 2
        result = run_lab_server(
            source_server=args.server_dir,
            work_dir=args.lab_root / "work" / run_label / "candidate",
            log_path=args.lab_root / "logs" / run_label / "candidate.log",
            jars=included,
            boot_timeout=args.boot_timeout,
            idle_seconds=args.idle_seconds,
            heap_mb=args.heap_mb,
            exercise_radius=args.exercise_radius,
        )
        insert_item(
            conn,
            run_id,
            ordinal=1,
            bundle_index=None,
            stage="candidate",
            status=result.status,
            targets=targets,
            included=included,
            missing=(),
            result=result,
            notes=result.notes,
        )
        finish_run(conn, run_id, result.status)
    if not args.keep_lab:
        shutil.rmtree(args.lab_root / "work" / run_label / "candidate", ignore_errors=True)
    print(f"run_label={run_label}")
    print(f"status={result.status}")
    print(f"log_path={result.log_path}")
    if result.severe_errors:
        print("--- severe errors ---")
        for line in result.severe_errors[:20]:
            print(line)
    return 0 if result.status == "passed" else 1


def init_database(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
    print("schema=ok")
    return 0


def plan(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
        print_plan(active_server_jars(args.server_dir, conn), args.bundle_size)
    return 0


def add_run_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--run-label")
    parser.add_argument("--boot-timeout", type=int, default=300)
    parser.add_argument("--idle-seconds", type=int, default=45)
    parser.add_argument("--heap-mb", type=int, default=2048)
    parser.add_argument("--exercise-radius", type=int, default=2)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--keep-lab", action="store_true")
    parser.add_argument("--dry-run", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--lab-root", type=Path, default=DEFAULT_LAB_ROOT)
    parser.add_argument("--bundle-size", type=int, default=DEFAULT_BUNDLE_SIZE)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    sub.add_parser("plan")
    singles = sub.add_parser("run-singles")
    add_run_args(singles)
    bundles = sub.add_parser("run-bundles")
    add_run_args(bundles)
    files = sub.add_parser("run-files")
    add_run_args(files)
    files.add_argument("--include-active-deps", action="store_true")
    files.add_argument("files", type=Path, nargs="+")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "init":
        return init_database(args)
    if args.command == "plan":
        return plan(args)
    if args.command == "run-singles":
        return run_singles(args)
    if args.command == "run-bundles":
        return run_bundles(args)
    if args.command == "run-files":
        return run_files(args)
    raise SystemExit(f"unknown command {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
