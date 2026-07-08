#!/usr/bin/env python3
"""Schema v2 多 stage 占盘 JSON：init / append-stage / merge-compact。"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2
VALID_STAGES = frozenset({"post_insert", "pre_compact", "post_compact"})
STAGE_BYTE_FIELDS = (
    "data_dir_disk_bytes",
    "data_dir_apparent_bytes",
    "storage_disk_bytes",
    "storage_apparent_bytes",
    "meta_disk_bytes",
    "meta_apparent_bytes",
)


def _du_disk_bytes(path: Path) -> int:
    proc = subprocess.run(
        ["du", "-sk", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(proc.stdout.split()[0]) * 1024


def _du_apparent_bytes(path: Path) -> int:
    proc = subprocess.run(
        ["du", "-sb", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(proc.stdout.split()[0])


def _data_dir_for_profile(profile: str, nebula_root: Path) -> Path:
    return nebula_root / f"data-{profile}"


def _measure_paths(data_dir: Path) -> dict[str, int]:
    storage_dir = data_dir / "storage"
    meta_dir = data_dir / "meta"
    storage_disk = _du_disk_bytes(storage_dir) if storage_dir.is_dir() else 0
    meta_disk = _du_disk_bytes(meta_dir) if meta_dir.is_dir() else 0
    storage_apparent = _du_apparent_bytes(storage_dir) if storage_dir.is_dir() else 0
    meta_apparent = _du_apparent_bytes(meta_dir) if meta_dir.is_dir() else 0
    return {
        "data_dir_disk_bytes": _du_disk_bytes(data_dir),
        "data_dir_apparent_bytes": _du_apparent_bytes(data_dir),
        "storage_disk_bytes": storage_disk,
        "storage_apparent_bytes": storage_apparent,
        "meta_disk_bytes": meta_disk,
        "meta_apparent_bytes": meta_apparent,
    }


def _validate_stage_bytes(stage: dict[str, Any]) -> None:
    for key in STAGE_BYTE_FIELDS:
        value = stage[key]
        if not isinstance(value, int) or value < 0:
            raise ValueError(f"{key} must be int >= 0, got {value!r}")


def _load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def _write_json(path: Path, doc: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _empty_shell(profile: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "profile": profile,
        "measurement_methods": {
            "disk_bytes": "du -sk (actual blocks allocated)",
            "apparent_bytes": "du -sb (logical file sizes)",
        },
        "stages": {},
        "compact": {
            "duration_sec": None,
            "spaces": [],
            "job_ids": [],
            "outcome": None,
            "error": None,
        },
    }


def cmd_init(args: argparse.Namespace) -> int:
    _write_json(Path(args.out), _empty_shell(args.profile))
    return 0


def cmd_append_stage(args: argparse.Namespace) -> int:
    if args.stage not in VALID_STAGES:
        print(f"invalid stage: {args.stage}", file=sys.stderr)
        return 2

    out_path = Path(args.out)
    nebula_root = Path(args.nebula_root)
    data_dir = _data_dir_for_profile(args.profile, nebula_root)
    if not data_dir.is_dir():
        print(f"data dir not found: {data_dir}", file=sys.stderr)
        return 1

    doc = _load_json(out_path) if out_path.is_file() else _empty_shell(args.profile)
    stage_payload = _measure_paths(data_dir)
    stage_payload["recorded_at"] = datetime.now(timezone.utc).isoformat()
    _validate_stage_bytes(stage_payload)

    doc.setdefault("stages", {})[args.stage] = stage_payload
    if args.stage == "post_insert":
        doc["data_dir_disk_bytes"] = stage_payload["data_dir_disk_bytes"]
        doc["data_dir_apparent_bytes"] = stage_payload["data_dir_apparent_bytes"]

    _write_json(out_path, doc)
    return 0


def cmd_merge_compact(args: argparse.Namespace) -> int:
    out_path = Path(args.out)
    compact_path = Path(args.compact_json)
    if not compact_path.is_file():
        print(f"compact json not found: {compact_path}", file=sys.stderr)
        return 1
    if not out_path.is_file():
        print(f"data json not found: {out_path}", file=sys.stderr)
        return 1

    compact_doc = _load_json(compact_path)
    doc = _load_json(out_path)
    doc["compact"] = compact_doc
    _write_json(out_path, doc)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="bench storage schema v2 recorder")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="create empty schema v2 shell")
    p_init.add_argument("--profile", required=True)
    p_init.add_argument("--out", required=True)

    p_append = sub.add_parser("append-stage", help="measure du and append one stage")
    p_append.add_argument("--profile", required=True)
    p_append.add_argument("--stage", required=True)
    p_append.add_argument("--out", required=True)
    p_append.add_argument(
        "--nebula-root",
        default=None,
        help="defaults to NEBULA_ROOT env",
    )

    p_merge = sub.add_parser("merge-compact", help="merge -compact.json into -data.json")
    p_merge.add_argument("--compact-json", required=True)
    p_merge.add_argument("--out", required=True)

    args = parser.parse_args()
    if args.command == "append-stage" and args.nebula_root is None:
        import os

        if "NEBULA_ROOT" not in os.environ:
            print("missing --nebula-root or NEBULA_ROOT", file=sys.stderr)
            return 2
        args.nebula_root = os.environ["NEBULA_ROOT"]

    if args.command == "init":
        return cmd_init(args)
    if args.command == "append-stage":
        return cmd_append_stage(args)
    if args.command == "merge-compact":
        return cmd_merge_compact(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
