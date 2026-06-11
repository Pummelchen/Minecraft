#!/usr/bin/env python3
"""Check whether a newer NeoForge loader exists for the pinned Minecraft line."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Sequence

DEFAULT_METADATA_URL = "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"


def parse_version(value: str) -> tuple[int | str, ...]:
    parts: list[int | str] = []
    for token in re.split(r"([0-9]+)", value):
        if not token:
            continue
        parts.append(int(token) if token.isdigit() else token)
    return tuple(parts)


def load_metadata(url: str, timeout: float) -> list[str]:
    request = urllib.request.Request(url, headers={"User-Agent": "PummelchenNeoForgeVersionCheck/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = response.read()
    root = ET.fromstring(payload)
    return [node.text.strip() for node in root.findall("./versioning/versions/version") if node.text and node.text.strip()]


def latest_for_minecraft(versions: Sequence[str], minecraft_version: str) -> str:
    prefix = f"{minecraft_version}."
    compatible = [version for version in versions if version == minecraft_version or version.startswith(prefix)]
    if not compatible:
        return ""
    return sorted(compatible, key=parse_version)[-1]


def write_status(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current", required=True, help="Current pinned NeoForge version, for example 26.1.2.71")
    parser.add_argument("--minecraft-version", required=True, help="Pinned Minecraft version, for example 26.1.2")
    parser.add_argument("--metadata-url", default=DEFAULT_METADATA_URL)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--write-json", type=Path, default=None)
    parser.add_argument("--fail-if-newer", action="store_true")
    parser.add_argument("--allow-network-failure", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    checked_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    payload: dict[str, object] = {
        "checked_at": checked_at,
        "minecraft_version": args.minecraft_version,
        "current_neoforge_version": args.current,
        "metadata_url": args.metadata_url,
        "latest_neoforge_version": "",
        "update_available": False,
        "status": "unknown",
        "message": "",
    }
    try:
        versions = load_metadata(args.metadata_url, args.timeout)
        latest = latest_for_minecraft(versions, args.minecraft_version)
        if not latest:
            payload.update(
                {
                    "status": "warning",
                    "message": f"No NeoForge metadata version found for Minecraft {args.minecraft_version}",
                }
            )
            print(f"neoforge_version_status=warning current={args.current} latest=")
            code = 1
        else:
            update_available = parse_version(latest) > parse_version(args.current)
            payload.update(
                {
                    "latest_neoforge_version": latest,
                    "update_available": update_available,
                    "status": "update_available" if update_available else "current",
                    "message": (
                        f"Newer NeoForge {latest} is available for Minecraft {args.minecraft_version}"
                        if update_available
                        else f"NeoForge {args.current} is current for Minecraft {args.minecraft_version}"
                    ),
                }
            )
            print(
                "neoforge_version_status={status} current={current} latest={latest}".format(
                    status=payload["status"],
                    current=args.current,
                    latest=latest,
                )
            )
            code = 2 if update_available and args.fail_if_newer else 0
    except (urllib.error.URLError, TimeoutError, ET.ParseError, OSError) as exc:
        payload.update({"status": "error", "message": f"{type(exc).__name__}: {exc}"})
        print(f"neoforge_version_status=error current={args.current} latest= reason={type(exc).__name__}: {exc}")
        code = 0 if args.allow_network_failure else 1
    if args.write_json:
        write_status(args.write_json, payload)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
