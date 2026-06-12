#!/usr/bin/env python3
"""Shared helpers for safe world reset scripts."""

from __future__ import annotations

import gzip
import re
import shutil
import socket
import secrets
import struct
import subprocess
import time
from pathlib import Path


DEFAULT_PROJECT_DIR = Path("/var/minecraft_mods")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_SERVICE = "pummelchen-minecraft.service"
RCON_HOST = "127.0.0.1"
RCON_TIMEOUT = 2.5
RCON_COMMAND_TIMEOUT = 90.0
RCON_AUTH = 3
RCON_COMMAND = 2
RCON_AUTH_FAIL = -1
RCON_CONNECT_TIMEOUT = 0.5
RCON_RESPONSE_ATTEMPTS = 4
SERVICE_STOP_TIMEOUT = 45
SERVICE_FORCE_TIMEOUT = 15

TAG_END = 0
TAG_BYTE = 1
TAG_SHORT = 2
TAG_INT = 3
TAG_LONG = 4
TAG_FLOAT = 5
TAG_DOUBLE = 6
TAG_BYTE_ARRAY = 7
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10
TAG_INT_ARRAY = 11
TAG_LONG_ARRAY = 12


def read_properties(path: Path) -> tuple[list[str], dict[str, str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines() if path.exists() else []
    values: dict[str, str] = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return lines, values


def write_properties(path: Path, updates: dict[str, str]) -> None:
    lines, _values = read_properties(path)
    seen: set[str] = set()
    merged: list[str] = []
    for raw in lines:
        if "=" in raw and not raw.lstrip().startswith("#"):
            key = raw.split("=", 1)[0].strip()
            if key in updates:
                merged.append(f"{key}={updates[key]}")
                seen.add(key)
                continue
        merged.append(raw)
    for key, value in updates.items():
        if key not in seen:
            merged.append(f"{key}={value}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(merged) + "\n", encoding="utf-8")


def ensure_rcon_enabled(properties_path: Path, rcon_port: int, dry_run: bool) -> tuple[str, bool, int]:
    current = properties_path.read_text(encoding="utf-8") if properties_path.exists() else ""
    _, values = read_properties(properties_path)
    enable = values.get("enable-rcon", "false").strip().lower() == "true"
    password = values.get("rcon.password", "").strip()
    port = values.get("rcon.port", str(rcon_port)).strip()
    if enable and password:
        try:
            return current, False, int(port)
        except ValueError:
            return current, False, rcon_port
    if dry_run:
        print("DRY-RUN skip rcon bootstrap (would enable temporary RCON)")
        return current, False, rcon_port
    generated_password = password if password else f"pummelchen-{secrets.token_hex(8)}"
    updates = {
        "enable-rcon": "true",
        "rcon.port": str(rcon_port if port.isdigit() else rcon_port),
        "rcon.password": generated_password,
    }
    write_properties(properties_path, updates)
    return current, True, rcon_port


def restore_file(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def wait_for_rcon(port: int, host: str = RCON_HOST, timeout: int = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=RCON_CONNECT_TIMEOUT):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def _read_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    received = 0
    while received < length:
        piece = sock.recv(length - received)
        if not piece:
            raise ConnectionError("closed while reading RCON packet")
        chunks.append(piece)
        received += len(piece)
    return b"".join(chunks)


def _rcon_packet(request_id: int, packet_type: int, payload: str) -> bytes:
    body = struct.pack("<ii", request_id, packet_type) + payload.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(body)) + body


def _read_rcon_packet(sock: socket.socket) -> tuple[int, int, str]:
    header = _read_exact(sock, 4)
    (length,) = struct.unpack("<i", header)
    if length < 10 or length > 1_048_576:
        raise OSError(f"invalid RCON packet length {length}")
    body = _read_exact(sock, length)
    request_id, packet_type = struct.unpack("<ii", body[:8])
    payload = body[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, payload


def _read_matching_rcon_packet(sock: socket.socket, expected_request_id: int) -> tuple[int, int, str]:
    last_error: Exception | None = None
    for _ in range(RCON_RESPONSE_ATTEMPTS):
        try:
            response_id, response_type, response = _read_rcon_packet(sock)
        except Exception as exc:
            last_error = exc
            continue
        if response_id == expected_request_id or response_id == RCON_AUTH_FAIL:
            return response_id, response_type, response
        if response_id == 0:
            continue
    if last_error:
        raise last_error
    raise OSError(f"unexpected RCON response id for request {expected_request_id}")


def rcon_command(host: str, port: int, password: str, command: str, timeout: float = RCON_TIMEOUT) -> str:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(_rcon_packet(1, RCON_AUTH, password))
        auth_id, _auth_type, _auth_payload = _read_matching_rcon_packet(sock, 1)
        if auth_id == RCON_AUTH_FAIL:
            raise PermissionError("RCON authentication failed")
        sock.sendall(_rcon_packet(2, RCON_COMMAND, command))
        response_id, _response_type, response = _read_matching_rcon_packet(sock, 2)
        if response_id != 2:
            if response_id != 0:
                raise OSError("unexpected RCON response id")
            response_id, _response_type, response = _read_matching_rcon_packet(sock, 2)
            if response_id != 2:
                raise OSError("unexpected RCON response id")
        if _is_rcon_command_failure(response):
            raise RuntimeError(f"RCON command failed: {command}: {response}")
        return response


def run_rcon_commands(
    host: str,
    port: int,
    password: str,
    commands: list[str],
    timeout: float = RCON_TIMEOUT,
) -> list[str]:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(_rcon_packet(1, RCON_AUTH, password))
        auth_id, _auth_type, _auth_payload = _read_matching_rcon_packet(sock, 1)
        if auth_id == RCON_AUTH_FAIL:
            raise PermissionError("RCON authentication failed")
        responses: list[str] = []
        next_request_id = 2
        for command in commands:
            sock.sendall(_rcon_packet(next_request_id, RCON_COMMAND, command))
            response_id, _response_type, response = _read_matching_rcon_packet(sock, next_request_id)
            if response_id != next_request_id and response_id != 0:
                raise OSError(f"unexpected RCON response id for {command}: {response_id}")
            if _is_rcon_command_failure(response):
                raise RuntimeError(f"RCON command failed: {command}: {response}")
            responses.append(response)
            next_request_id += 1
        return responses


def _clean_minecraft_output(text: str) -> str:
    return re.sub(r"\u00a7.", "", text).strip()


def _is_rcon_command_failure(response: str) -> bool:
    clean = _clean_minecraft_output(response).lower()
    if not clean or clean.startswith("done") or clean == "ok" or clean.startswith("set "):
        return False
    if clean == "no player was found":
        return False
    return any(
        token in clean
        for token in (
            "unknown or invalid command",
            "unknown command",
            "invalid command",
            "permission",
            "not enough arguments",
            "incorrect argument",
            "only players",
            "failure",
            "could not",
            "cannot",
            "not permitted",
            "timed out",
            "no such",
        )
    )


def active_world_name(server_dir: Path) -> str:
    _lines, values = read_properties(server_dir / "server.properties")
    level_name = values.get("level-name") or "world"
    level_path = Path(level_name)
    if level_path.is_absolute() or ".." in level_path.parts:
        raise SystemExit(f"unsafe level-name in server.properties: {level_name!r}")
    return level_name


def copy_if_changed(src: Path, dst: Path) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.read_bytes() == src.read_bytes():
        return False
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    shutil.copy2(src, tmp)
    tmp.replace(dst)
    return True


def _service_transitioning(service: str) -> bool:
    result = subprocess.run(
        ["systemctl", "show", service, "--property=ActiveState,SubState", "--value"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    state = result.stdout.lower()
    return "deactivating" in state or "stopping" in state


def stop_service(service: str, dry_run: bool) -> None:
    if dry_run:
        print(f"DRY-RUN systemctl stop {service}")
        return
    try:
        subprocess.run(["systemctl", "stop", service], check=False, timeout=SERVICE_STOP_TIMEOUT)
        deadline = time.time() + SERVICE_STOP_TIMEOUT
        while time.time() < deadline:
            if not _service_transitioning(service):
                return
            time.sleep(1)
    except subprocess.TimeoutExpired:
        print(f"warning=systemctl_stop_timeout service={service}")
    subprocess.run(
        ["systemctl", "kill", "--kill-whom=main", "--signal=SIGKILL", service],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + SERVICE_FORCE_TIMEOUT
    while time.time() < deadline:
        if not _service_transitioning(service):
            break
        time.sleep(1)
    if _service_transitioning(service):
        subprocess.run(
            ["systemctl", "kill", "--kill-whom=all", "--signal=SIGKILL", service],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    subprocess.run(["systemctl", "reset-failed", service], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def start_service(service: str, dry_run: bool) -> None:
    if dry_run:
        print(f"DRY-RUN systemctl start {service}")
        return
    subprocess.run(["systemctl", "start", service], check=True)


def wait_for_done(service: str, started_at: float, timeout: int) -> bool:
    if timeout <= 0:
        return False
    deadline = time.time() + timeout
    since = f"@{int(started_at)}"
    while time.time() < deadline:
        result = subprocess.run(
            ["journalctl", "-u", service, "--since", since, "--no-pager"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if "Done (" in result.stdout:
            return True
        time.sleep(3)
    return False


def backup_world(world_dir: Path, backup_root: Path, dry_run: bool) -> Path | None:
    if not world_dir.exists():
        return None
    if not world_dir.name or world_dir.resolve() == world_dir.parent.resolve():
        raise SystemExit(f"refusing to move directory that resolves to its parent: {world_dir}")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup = backup_root / f"{world_dir.name}-{stamp}"
    index = 1
    while backup.exists():
        index += 1
        backup = backup_root / f"{world_dir.name}-{stamp}-{index}"
    if dry_run:
        print(f"DRY-RUN move {world_dir} {backup}")
        return backup
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(world_dir), str(backup))
    return backup


def datapack_sources(project_dir: Path, server_dir: Path) -> list[Path]:
    candidates = []
    for root in (project_dir / "server-datapacks", server_dir / "server-datapacks"):
        if root.exists():
            candidates.extend(sorted(path for path in root.iterdir() if path.is_file() and path.suffix == ".zip"))
    deduped: dict[str, Path] = {}
    for path in candidates:
        deduped[path.name] = path
    return list(deduped.values())


def install_datapacks(
    project_dir: Path,
    server_dir: Path,
    world_dir: Path,
    install_place_pack: bool = False,
    origin: tuple[int, int, int] | None = None,
    spawn: tuple[int, int, int] | None = None,
) -> int:
    del install_place_pack, origin, spawn
    changed = 0
    server_datapacks = server_dir / "server-datapacks"
    world_datapacks = world_dir / "datapacks"
    world_datapacks.mkdir(parents=True, exist_ok=True)
    for source in datapack_sources(project_dir, server_dir):
        if copy_if_changed(source, server_datapacks / source.name):
            changed += 1
        if copy_if_changed(source, world_datapacks / source.name):
            changed += 1
    return changed


def _read_string(payload: bytes, offset: int) -> tuple[str, int]:
    size = struct.unpack_from(">H", payload, offset)[0]
    offset += 2
    end = offset + size
    value = payload[offset:end].decode("utf-8", errors="replace")
    return value, end


def _parse_payload(payload: bytes, offset: int, tag: int) -> tuple[object, int]:
    if tag == TAG_END:
        return None, offset
    if tag == TAG_BYTE:
        return struct.unpack_from(">b", payload, offset)[0], offset + 1
    if tag == TAG_SHORT:
        return struct.unpack_from(">h", payload, offset)[0], offset + 2
    if tag == TAG_INT:
        return struct.unpack_from(">i", payload, offset)[0], offset + 4
    if tag == TAG_LONG:
        return struct.unpack_from(">q", payload, offset)[0], offset + 8
    if tag == TAG_FLOAT:
        return struct.unpack_from(">f", payload, offset)[0], offset + 4
    if tag == TAG_DOUBLE:
        return struct.unpack_from(">d", payload, offset)[0], offset + 8
    if tag == TAG_BYTE_ARRAY:
        count = struct.unpack_from(">i", payload, offset)[0]
        offset += 4
        return payload[offset : offset + count], offset + count
    if tag == TAG_STRING:
        value, offset = _read_string(payload, offset)
        return value, offset
    if tag == TAG_LIST:
        element_tag = payload[offset]
        offset += 1
        count = struct.unpack_from(">i", payload, offset)[0]
        offset += 4
        items: list[object] = []
        for _ in range(count):
            item, offset = _parse_payload(payload, offset, element_tag)
            items.append(item)
        return items, offset
    if tag == TAG_COMPOUND:
        compound: dict[str, object] = {}
        while True:
            child_tag = payload[offset]
            offset += 1
            if child_tag == TAG_END:
                return compound, offset
            name, offset = _read_string(payload, offset)
            value, offset = _parse_payload(payload, offset, child_tag)
            compound[name] = value
    if tag == TAG_INT_ARRAY:
        count = struct.unpack_from(">i", payload, offset)[0]
        return [struct.unpack_from(">i", payload, offset + 4 + i * 4)[0] for i in range(count)], offset + 4 + count * 4
    if tag == TAG_LONG_ARRAY:
        count = struct.unpack_from(">i", payload, offset)[0]
        values = []
        cursor = offset + 4
        for _ in range(count):
            values.append(struct.unpack_from(">q", payload, cursor)[0])
            cursor += 8
        return values, cursor
    raise TypeError(f"unsupported nbt tag {tag}")


def _read_level_root(payload: bytes) -> dict[str, object]:
    if not payload or payload[0] != TAG_COMPOUND:
        return {}
    _, name_end = _read_string(payload, 1)
    root, _cursor = _parse_payload(payload, name_end, TAG_COMPOUND)
    if not isinstance(root, dict):
        return {}
    return root


def read_level_spawn(world_dir: Path) -> tuple[int, int, int] | None:
    level_dat = world_dir / "level.dat"
    if not level_dat.exists():
        return None
    try:
        raw = level_dat.read_bytes()
    except OSError:
        return None
    try:
        payload = gzip.decompress(raw)
    except OSError:
        payload = raw
    root = _read_level_root(payload)
    data = root.get("Data")
    if not isinstance(data, dict):
        return None
    sx = data.get("SpawnX")
    sy = data.get("SpawnY")
    sz = data.get("SpawnZ")
    if isinstance(sx, int) and isinstance(sy, int) and isinstance(sz, int):
        return (sx, sy, sz)
    spawn_entry = data.get("spawn")
    if isinstance(spawn_entry, dict):
        spawn_pos = spawn_entry.get("pos")
        if (
            isinstance(spawn_pos, list)
            and len(spawn_pos) == 3
            and all(isinstance(v, int) for v in spawn_pos)
        ):
            return int(spawn_pos[0]), int(spawn_pos[1]), int(spawn_pos[2])
    return None
