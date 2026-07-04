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


def _find_profile_report(root: Path, profile: str) -> Path | None:
    name = f"benchmark-ci-{profile}-report.json"
    for path in root.rglob(name):
        return path
    return None


def _comparison(results: dict[str, Any]) -> dict[str, Any]:
    storage: dict[str, int | None] = {}
    perf: dict[str, dict[str, dict[str, Any]]] = {}

    for profile, doc in results.items():
        st = doc.get("storage") or {}
        storage[profile] = st.get("data_dir_bytes") if st.get("available") else None

        for bench in (doc.get("performance") or {}).get("benchmarks") or []:
            key = bench.get("fullname") or bench.get("name") or "unknown"
            perf.setdefault(key, {})[profile] = {
                "mean": bench.get("mean"),
                "median": bench.get("median"),
                "unit": bench.get("unit"),
                "rounds": bench.get("rounds"),
            }

    return {
        "storage_data_dir_bytes": storage,
        "performance_by_benchmark": perf,
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
            summary.write("| profile | status | data_dir_bytes |\n")
            summary.write("|---------|--------|----------------|\n")
            for profile in PROFILES:
                doc = results.get(profile)
                if not doc:
                    summary.write(f"| {profile} | _missing_ | — |\n")
                    continue
                status = (doc.get("outcome") or {}).get("status", "?")
                nbytes = (doc.get("storage") or {}).get("data_dir_bytes", "—")
                summary.write(f"| {profile} | `{status}` | `{nbytes}` |\n")
            summary.write("\n## Full JSON\n\n```json\n")
            json.dump(merged, summary, indent=2, ensure_ascii=False)
            summary.write("\n```\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
