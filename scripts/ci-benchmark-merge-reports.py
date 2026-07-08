#!/usr/bin/env python3
"""合并各 profile 报告为单次 workflow 的 AI 友好总报告。"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
PROFILES = ("rocksdb", "conservative", "enterprise")
STORAGE_STAGE_COLUMNS = (
    ("post_insert_disk", "post_insert", "data_dir_disk_bytes"),
    ("post_insert_apparent", "post_insert", "data_dir_apparent_bytes"),
    ("pre_compact_disk", "pre_compact", "data_dir_disk_bytes"),
    ("pre_compact_apparent", "pre_compact", "data_dir_apparent_bytes"),
    ("post_compact_disk", "post_compact", "data_dir_disk_bytes"),
    ("post_compact_apparent", "post_compact", "data_dir_apparent_bytes"),
)


def _find_profile_report(root: Path, profile: str) -> Path | None:
    name = f"benchmark-ci-{profile}-report.json"
    for path in root.rglob(name):
        return path
    return None


def _stage_field(st: dict[str, Any], stage: str, field: str) -> int | None:
    stages = st.get("stages") or {}
    block = stages.get(stage) or {}
    value = block.get(field)
    if isinstance(value, int):
        return value
    if stage == "post_insert":
        if field == "data_dir_disk_bytes":
            legacy = st.get("data_dir_disk_bytes", st.get("data_dir_bytes"))
            return legacy if isinstance(legacy, int) else None
        if field == "data_dir_apparent_bytes":
            legacy = st.get("data_dir_apparent_bytes")
            return legacy if isinstance(legacy, int) else None
    return None


def _compact_sec(st: dict[str, Any]) -> float | None:
    compact = st.get("compact") or {}
    value = compact.get("duration_sec")
    return value if isinstance(value, (int, float)) else None


def _comparison(results: dict[str, Any]) -> dict[str, Any]:
    storage_cols: dict[str, dict[str, int | float | None]] = {
        col: {} for col, _, _ in STORAGE_STAGE_COLUMNS
    }
    storage_cols["compact_sec"] = {}
    perf: dict[str, dict[str, dict[str, Any]]] = {}
    derived: dict[str, dict[str, int | None]] = {
        "compact_disk_saved": {},
        "compact_apparent_saved": {},
    }

    for profile, doc in results.items():
        st = doc.get("storage") or {}
        if not st.get("available"):
            for col, _, _ in STORAGE_STAGE_COLUMNS:
                storage_cols[col][profile] = None
            storage_cols["compact_sec"][profile] = None
            continue

        for col, stage, field in STORAGE_STAGE_COLUMNS:
            storage_cols[col][profile] = _stage_field(st, stage, field)
        storage_cols["compact_sec"][profile] = _compact_sec(st)

        pre_disk = _stage_field(st, "pre_compact", "data_dir_disk_bytes")
        post_disk = _stage_field(st, "post_compact", "data_dir_disk_bytes")
        if isinstance(pre_disk, int) and isinstance(post_disk, int):
            derived["compact_disk_saved"][profile] = pre_disk - post_disk
        pre_apparent = _stage_field(st, "pre_compact", "data_dir_apparent_bytes")
        post_apparent = _stage_field(st, "post_compact", "data_dir_apparent_bytes")
        if isinstance(pre_apparent, int) and isinstance(post_apparent, int):
            derived["compact_apparent_saved"][profile] = pre_apparent - post_apparent

        for bench in (doc.get("performance") or {}).get("benchmarks") or []:
            fullname = bench.get("fullname") or bench.get("name") or "unknown"
            key = fullname
            if "read_post_insert" in fullname:
                key = "read_post_insert"
            elif "read_post_compact" in fullname:
                key = "read_post_compact"
            perf.setdefault(key, {})[profile] = {
                "mean": bench.get("mean"),
                "median": bench.get("median"),
                "unit": bench.get("unit"),
                "rounds": bench.get("rounds"),
            }

    return {
        **storage_cols,
        "compact_disk_saved": derived["compact_disk_saved"] or None,
        "compact_apparent_saved": derived["compact_apparent_saved"] or None,
        "performance_by_benchmark": perf,
        # 兼容旧字段名
        "storage_data_dir_disk_bytes": storage_cols["post_insert_disk"],
        "storage_data_dir_bytes": storage_cols["post_insert_disk"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="artifact 下载目录")
    parser.add_argument("--output", required=True, help="合并报告输出路径")
    args = parser.parse_args()

    root = Path(args.input)
    results: dict[str, Any] = {}
    missing: list[str] = []

    for profile in PROFILES:
        path = _find_profile_report(root, profile)
        if path is None:
            missing.append(profile)
            continue
        with path.open(encoding="utf-8") as f:
            results[profile] = json.load(f)

    merged: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "document_type": "nebula_bench_run_report",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profiles_expected": list(PROFILES),
        "profiles_present": list(results.keys()),
        "profiles_missing": missing,
        "provenance": {
            "bench_repository": os.environ.get("GITHUB_REPOSITORY"),
            "workflow": os.environ.get("GITHUB_WORKFLOW"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "github_sha": os.environ.get("GITHUB_SHA"),
            "github_ref": os.environ.get("GITHUB_REF"),
        },
        "results": results,
        "comparison": _comparison(results),
    }

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as f:
        json.dump(merged, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"merged AI report: {out}")
    print("NEBULA_BENCH_RUN_REPORT_JSON=" + json.dumps(merged, ensure_ascii=False))

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "w", encoding="utf-8") as summary:
            summary.write("# Nebula Benchmark — AI Run Report\n\n")
            summary.write(
                "| profile | status | post_insert_disk | pre_compact_disk | "
                "post_compact_disk | compact_sec |\n"
            )
            summary.write(
                "|---------|--------|------------------|------------------|"
                "-------------------|-------------|\n"
            )
            for profile in PROFILES:
                doc = results.get(profile)
                if not doc:
                    summary.write(f"| {profile} | _missing_ | — | — | — | — |\n")
                    continue
                status = (doc.get("outcome") or {}).get("status", "?")
                st = doc.get("storage") or {}
                post_insert = _stage_field(st, "post_insert", "data_dir_disk_bytes")
                pre_compact = _stage_field(st, "pre_compact", "data_dir_disk_bytes")
                post_compact = _stage_field(st, "post_compact", "data_dir_disk_bytes")
                compact_sec = _compact_sec(st)
                summary.write(
                    f"| {profile} | `{status}` | `{post_insert}` | `{pre_compact}` | "
                    f"`{post_compact}` | `{compact_sec}` |\n"
                )
            summary.write("\n## Full JSON\n\n```json\n")
            json.dump(merged, summary, indent=2, ensure_ascii=False)
            summary.write("\n```\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
