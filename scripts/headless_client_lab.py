#!/usr/bin/env python3
"""Headless real-client smoke tests for the Pummelchen modpack.

This is intentionally a real Minecraft Java client path, not a protocol bot.
It syncs the active client package into a dedicated game directory, launches
HeadlessMC with HMC-Specifics under Xvfb or an existing DISPLAY, joins the
server through quick-play, sends movement/screenshot commands, and records the
run in SQLite.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import os
import random
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import server_ops
from moddb import connect, init_db, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_BASE_DIR = Path("/var/minecraft_mods/headless_client_lab")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_HMC_VERSION = "2.9.0"
DEFAULT_MINECRAFT_VERSION = "26.1.2"
DEFAULT_LOADER = "neoforge"
DEFAULT_SERVER_HOST = "127.0.0.1"
DEFAULT_SERVER_PORT = 25565
DEFAULT_JAVA_BIN = Path("/usr/lib/jvm/java-25-openjdk-amd64/bin/java")
FATAL_PATTERNS = re.compile(
    r"Minecraft has crashed|Reported exception|Crash report|Failed to compile.*shader|"
    r"Shader compilation failed|EXCEPTION_ACCESS_VIOLATION|OpenGL.*fatal|Invalid session|"
    r"multiplayer\.disconnect\.unverified_username|Authentication servers are down|"
    r"Failed to connect to the server|Connection refused|Timed out",
    re.IGNORECASE,
)


def now_label(prefix: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", prefix).strip("_") or "headless_client"
    return f"{safe}_{dt.datetime.now(dt.UTC).strftime('%Y%m%d_%H%M%S')}"


def hmc_download_urls(version: str) -> list[str]:
    return [
        f"https://github.com/3arthqu4ke/HeadlessMc/releases/download/{version}/headlessmc-launcher-{version}.jar",
        f"https://github.com/headlesshq/headlessmc/releases/download/{version}/headlessmc-launcher-{version}.jar",
        f"https://github.com/headlesshq/headlessmc/releases/download/{version}/headlessmc-launcher.jar",
    ]


def java_bin() -> str:
    return str(DEFAULT_JAVA_BIN if DEFAULT_JAVA_BIN.exists() else "java")


def run_text(cmd: list[str], timeout: int = 20, env: dict[str, str] | None = None) -> str:
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, timeout=timeout, env=env).strip()
    except Exception:
        return ""


def active_release_id(conn: sqlite3.Connection, server_key: str) -> str:
    row = conn.execute(
        """
        SELECT release_id
        FROM pack_releases
        WHERE server_key = ? AND active = 1
        ORDER BY activated_at DESC, created_at DESC
        LIMIT 1
        """,
        (server_key,),
    ).fetchone()
    return str(row["release_id"]) if row else ""


def server_instance_id(conn: sqlite3.Connection, args: argparse.Namespace) -> int | None:
    try:
        return server_ops.ensure_server_instance(
            conn,
            server_key=args.server_key,
            display_name="Pummelchen Server",
            server_dir=args.server_dir,
            active=True,
        )
    except Exception:
        row = conn.execute("SELECT id FROM server_instances WHERE server_key = ?", (args.server_key,)).fetchone()
        return int(row["id"]) if row else None


def create_run(conn: sqlite3.Connection, args: argparse.Namespace, run_label: str, run_dir: Path, game_dir: Path) -> int:
    cur = conn.execute(
        """
        INSERT INTO headless_client_runs(
            server_instance_id, release_id, run_label, started_at, status,
            minecraft_version, loader, server_host, server_port,
            requested_duration_seconds, game_dir, run_dir, notes
        ) VALUES (?, ?, ?, ?, 'running', ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            server_instance_id(conn, args),
            active_release_id(conn, args.server_key) or None,
            run_label,
            utc_now(),
            args.minecraft_version,
            args.loader,
            args.server_host,
            args.server_port,
            args.duration,
            str(game_dir),
            str(run_dir),
            "HeadlessMC/HMC-Specifics real-client smoke run",
        ),
    )
    conn.commit()
    return int(cur.lastrowid)


def finish_run(
    conn: sqlite3.Connection,
    run_id: int,
    *,
    status: str,
    duration_seconds: float,
    display: str,
    renderer_summary: str,
    hmc_log: Path,
    mc_log: Path,
    crash_count: int,
    fatal_count: int,
    notes: str,
) -> None:
    conn.execute(
        """
        UPDATE headless_client_runs
        SET completed_at = ?, status = ?, duration_seconds = ?, display = ?,
            renderer_summary = ?, hmc_log_path = ?, minecraft_log_path = ?,
            crash_report_count = ?, fatal_log_count = ?, notes = ?
        WHERE id = ?
        """,
        (
            utc_now(),
            status,
            duration_seconds,
            display,
            renderer_summary,
            str(hmc_log),
            str(mc_log),
            crash_count,
            fatal_count,
            notes,
            run_id,
        ),
    )
    conn.commit()


def init_database(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
    print("schema=ok")
    return 0


def setup(args: argparse.Namespace) -> int:
    args.base_dir.mkdir(parents=True, exist_ok=True)
    args.base_dir.chmod(0o700)
    game_dir = args.base_dir / "game"
    for subdir in ("mods", "resourcepacks", "shaderpacks", "logs", "crash-reports", "screenshots", "run"):
        (game_dir / subdir).mkdir(parents=True, exist_ok=True)
    jar = args.base_dir / "headlessmc-launcher.jar"
    if args.dry_run:
        print(f"would_download={hmc_download_urls(args.hmc_version)[0]}")
        print(f"target={jar}")
        return 0
    if not jar.exists() or args.force:
        tmp = jar.with_suffix(".jar.tmp")
        errors: list[str] = []
        for url in hmc_download_urls(args.hmc_version):
            try:
                urllib.request.urlretrieve(url, tmp)
                break
            except Exception as exc:
                errors.append(f"{url}: {type(exc).__name__}: {exc}")
        else:
            raise RuntimeError("Could not download HeadlessMC:\n" + "\n".join(errors))
        tmp.replace(jar)
        jar.chmod(0o600)
    print(f"hmc_jar={jar}")
    print(f"game_dir={game_dir}")
    print("login_command=" + login_command(args))
    return 0


def clean_copy_section(src: Path, dst: Path, patterns: tuple[str, ...]) -> tuple[int, int]:
    dst.mkdir(parents=True, exist_ok=True)
    for path in dst.iterdir():
        if path.is_file() and any(path.match(pattern) for pattern in patterns):
            path.unlink()
    copied = 0
    bytes_total = 0
    if src.exists():
        files: list[Path] = []
        for pattern in patterns:
            files.extend(src.glob(pattern))
        for path in sorted(set(files), key=lambda item: item.name.lower()):
            target = dst / path.name
            shutil.copy2(path, target)
            copied += 1
            bytes_total += target.stat().st_size
    return copied, bytes_total


def seed_options(game_dir: Path) -> None:
    options = game_dir / "options.txt"
    values = {
        "pauseOnLostFocus": "false",
        "onboardAccessibility": "false",
        "fullscreen": "false",
        "renderDistance": "6",
        "simulationDistance": "4",
        "maxFps": "60",
    }
    existing: dict[str, str] = {}
    if options.exists():
        for line in options.read_text(encoding="utf-8", errors="replace").splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                existing[key] = value
    existing.update(values)
    options.write_text("\n".join(f"{key}:{value}" for key, value in sorted(existing.items())) + "\n", encoding="utf-8")


def sync_client_package(args: argparse.Namespace) -> int:
    package_dir = args.server_dir / "client-package"
    game_dir = args.base_dir / "game"
    if args.dry_run:
        print(f"package_dir={package_dir}")
        print(f"game_dir={game_dir}")
        return 0
    if not package_dir.exists():
        raise SystemExit(f"client package directory not found: {package_dir}")
    game_dir.mkdir(parents=True, exist_ok=True)
    counts = {
        "mods": clean_copy_section(package_dir / "mods", game_dir / "mods", ("*.jar", "*.zip")),
        "resourcepacks": clean_copy_section(package_dir / "resourcepacks", game_dir / "resourcepacks", ("*.zip", "*.jar")),
        "shaderpacks": clean_copy_section(package_dir / "shaderpacks", game_dir / "shaderpacks", ("*.zip", "*.jar")),
    }
    seed_options(game_dir)
    for section, (count, bytes_total) in counts.items():
        print(f"{section}={count} bytes={bytes_total}")
    return 0


def login_command(args: argparse.Namespace) -> str:
    jar = args.base_dir / "headlessmc-launcher.jar"
    game_dir = args.base_dir / "game"
    return f"{java_bin()} -Dhmc.gamedir={game_dir} -Dhmc.jline.enabled=false -jar {jar}"


def login(args: argparse.Namespace) -> int:
    print(login_command(args))
    print("Inside HeadlessMC, run: login")
    print("Complete the Microsoft device-code login from another browser, then run: account")
    return 0


def latest_log(game_dir: Path) -> Path:
    return game_dir / "logs" / "latest.log"


def crash_reports_since(game_dir: Path, marker: Path) -> list[Path]:
    reports = game_dir / "crash-reports"
    if not reports.exists():
        return []
    marker_time = marker.stat().st_mtime if marker.exists() else 0
    return [path for path in reports.glob("*.txt") if path.stat().st_mtime >= marker_time]


def fatal_lines(paths: Sequence[Path]) -> list[str]:
    lines: list[str] = []
    for path in paths:
        if not path.exists():
            continue
        for index, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
            if FATAL_PATTERNS.search(line):
                lines.append(f"{path}:{index}:{line}")
    return lines


def read_file(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def send_command(proc: subprocess.Popen[str], command: str) -> None:
    if proc.stdin is None:
        raise RuntimeError("HeadlessMC stdin is closed")
    proc.stdin.write(command + "\n")
    proc.stdin.flush()


def wait_for_ingame(proc: subprocess.Popen[str], hmc_log: Path, game_dir: Path, marker: Path, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError("HeadlessMC exited before the client reached in-game state")
        send_command(proc, "gui")
        time.sleep(5)
        text = read_file(hmc_log)
        if "Minecraft is currently not displaying a Gui" in text or "currently not displaying a Gui" in text:
            return
        crashes = crash_reports_since(game_dir, marker)
        fatals = fatal_lines([hmc_log, latest_log(game_dir)])
        if crashes:
            raise RuntimeError("Minecraft wrote a crash report before reaching in-game state")
        if fatals:
            raise RuntimeError("fatal client log pattern before reaching in-game state: " + fatals[0])
    raise RuntimeError("timed out before reaching in-game state")


def stop_process(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    with contextlib.suppress(Exception):
        send_command(proc, "quit")
    try:
        proc.wait(timeout=20)
        return
    except subprocess.TimeoutExpired:
        pass
    with contextlib.suppress(Exception):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(Exception):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=10)


def start_xvfb(run_dir: Path) -> tuple[subprocess.Popen[str] | None, str, dict[str, str]]:
    env = os.environ.copy()
    if env.get("DISPLAY"):
        return None, env["DISPLAY"], env
    display = ":99"
    env["DISPLAY"] = display
    xvfb = shutil.which("Xvfb")
    if not xvfb:
        raise RuntimeError("Xvfb is not installed and DISPLAY is not set")
    log = (run_dir / "xvfb.log").open("w", encoding="utf-8")
    proc = subprocess.Popen(
        [xvfb, display, "-screen", "0", "1920x1080x24", "-ac", "+extension", "GLX", "+render", "-noreset"],
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    time.sleep(2)
    return proc, display, env


def stop_xvfb(proc: subprocess.Popen[str] | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    with contextlib.suppress(Exception):
        os.killpg(proc.pid, signal.SIGTERM)
    with contextlib.suppress(Exception):
        proc.wait(timeout=10)


def renderer_summary(run_dir: Path, env: dict[str, str]) -> str:
    text = run_text(["glxinfo", "-B"], timeout=20, env=env)
    (run_dir / "glxinfo.txt").write_text(text + "\n", encoding="utf-8")
    for line in text.splitlines():
        if "renderer string" in line.lower() or "opengl renderer" in line.lower():
            return line.strip()
    return text.splitlines()[0].strip() if text.splitlines() else ""


def run_smoke(args: argparse.Namespace) -> int:
    run_label = args.run_label or now_label("headless_client")
    game_dir = args.base_dir / "game"
    run_dir = args.base_dir / "run" / run_label
    hmc_jar = args.base_dir / "headlessmc-launcher.jar"
    if args.dry_run:
        print(f"run_label={run_label}")
        print(f"game_dir={game_dir}")
        print(
            "launch="
            f"launch {args.loader}:{args.minecraft_version} -specifics --jvm \"-Xmx{args.heap_gb}G\" "
            f"--game-args \"--quickPlayMultiplayer {args.server_host}:{args.server_port}\""
        )
        return 0
    if not hmc_jar.exists():
        raise SystemExit(f"HeadlessMC jar missing, run setup first: {hmc_jar}")
    if not (game_dir / "mods").exists():
        raise SystemExit("game directory is not prepared, run sync first")
    run_dir.mkdir(parents=True, exist_ok=True)
    marker = run_dir / "start.marker"
    marker.write_text(utc_now() + "\n", encoding="utf-8")
    hmc_log = run_dir / "headlessmc.log"
    mc_log = latest_log(game_dir)
    display = ""
    renderer = ""
    xvfb_proc: subprocess.Popen[str] | None = None
    proc: subprocess.Popen[str] | None = None
    status = "failed"
    notes = ""
    start = time.monotonic()
    with connect(args.db) as conn:
        init_db(conn)
        run_id = create_run(conn, args, run_label, run_dir, game_dir)
    try:
        xvfb_proc, display, env = start_xvfb(run_dir)
        renderer = renderer_summary(run_dir, env)
        with hmc_log.open("w", encoding="utf-8") as log_handle:
            proc = subprocess.Popen(
                [
                    java_bin(),
                    f"-Dhmc.gamedir={game_dir}",
                    "-Dhmc.jline.enabled=false",
                    "-jar",
                    str(hmc_jar),
                ],
                stdin=subprocess.PIPE,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                env=env,
                start_new_session=True,
            )
            time.sleep(4)
            launch = (
                f"launch {args.loader}:{args.minecraft_version} -specifics "
                f'--jvm "-Xmx{args.heap_gb}G" '
                f'--game-args "--quickPlayMultiplayer {args.server_host}:{args.server_port}"'
            )
            send_command(proc, launch)
            wait_for_ingame(proc, hmc_log, game_dir, marker, args.ingame_timeout)
            end = time.monotonic() + args.duration
            commands = [
                "key w --duration 900",
                "key w --duration 900",
                "key a --duration 700",
                "key d --duration 700",
                "key s --duration 400",
                "key space --duration 250",
                "key f2",
            ]
            while time.monotonic() < end:
                if proc.poll() is not None:
                    raise RuntimeError("HeadlessMC/Minecraft exited during walk test")
                crashes = crash_reports_since(game_dir, marker)
                fatals = fatal_lines([hmc_log, mc_log])
                if crashes:
                    raise RuntimeError("Minecraft wrote a crash report during walk test")
                if fatals:
                    raise RuntimeError("fatal client log pattern during walk test: " + fatals[0])
                send_command(proc, random.choice(commands))
                time.sleep(1)
            send_command(proc, "disconnect")
            time.sleep(2)
            status = "passed"
            notes = f"joined {args.server_host}:{args.server_port} and walked for {args.duration}s"
    except Exception as exc:
        notes = f"{type(exc).__name__}: {exc}"
    finally:
        if proc is not None:
            stop_process(proc)
        stop_xvfb(xvfb_proc)
        crashes = crash_reports_since(game_dir, marker)
        fatals = fatal_lines([hmc_log, mc_log])
        if status == "passed" and (crashes or fatals):
            status = "failed"
            notes = "post-run crash/fatal pattern found"
        with connect(args.db) as conn:
            init_db(conn)
            finish_run(
                conn,
                run_id,
                status=status,
                duration_seconds=time.monotonic() - start,
                display=display,
                renderer_summary=renderer,
                hmc_log=hmc_log,
                mc_log=mc_log,
                crash_count=len(crashes),
                fatal_count=len(fatals),
                notes=notes,
            )
    print(f"run_label={run_label}")
    print(f"status={status}")
    print(f"renderer={renderer}")
    print(f"hmc_log={hmc_log}")
    print(f"minecraft_log={mc_log}")
    print(f"notes={notes}")
    return 0 if status == "passed" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--base-dir", type=Path, default=DEFAULT_BASE_DIR)
    parser.add_argument("--hmc-version", default=DEFAULT_HMC_VERSION)
    parser.add_argument("--minecraft-version", default=DEFAULT_MINECRAFT_VERSION)
    parser.add_argument("--loader", default=DEFAULT_LOADER)
    parser.add_argument("--server-host", default=DEFAULT_SERVER_HOST)
    parser.add_argument("--server-port", type=int, default=DEFAULT_SERVER_PORT)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    setup_parser = sub.add_parser("setup")
    setup_parser.add_argument("--force", action="store_true")
    setup_parser.add_argument("--dry-run", action="store_true")
    sync_parser = sub.add_parser("sync")
    sync_parser.add_argument("--dry-run", action="store_true")
    sub.add_parser("login-command")
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--run-label")
    run_parser.add_argument("--duration", type=int, default=600)
    run_parser.add_argument("--ingame-timeout", type=int, default=240)
    run_parser.add_argument("--heap-gb", type=int, default=4)
    run_parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "init":
        return init_database(args)
    if args.command == "setup":
        return setup(args)
    if args.command == "sync":
        return sync_client_package(args)
    if args.command == "login-command":
        return login(args)
    if args.command == "run":
        return run_smoke(args)
    raise SystemExit(f"unknown command {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
