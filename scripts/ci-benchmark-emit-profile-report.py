#!/usr/bin/env python3
"""生成单 profile 的 AI 友好 JSON 报告（合并性能与存储）。"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
STORAGE_SCHEMA_VERSION = 2
STAGE_BYTE_FIELDS = (
    "data_dir_disk_bytes",
    "data_dir_apparent_bytes",
    "storage_disk_bytes",
    "storage_apparent_bytes",
    "meta_disk_bytes",
    "meta_apparent_bytes",
)
MEASUREMENT_ORDER = (
    "insert_write → post_insert_storage → read_post_insert → "
    "pre_compact_storage → compact → post_compact_storage → "
    "read_post_compact → lookup_official"
)


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        with path.open(encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        return {"_load_error": str(exc), "_path": str(path)}


def _simplify_benchmarks(raw: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not raw or "_load_error" in raw:
        return []
    out: list[dict[str, Any]] = []
    for item in raw.get("benchmarks") or []:
        stats = item.get("stats") or {}
        out.append(
            {
                "name": item.get("name"),
                "fullname": item.get("fullname"),
                "unit": stats.get("unit") or item.get("unit"),
                "mean": stats.get("mean"),
                "median": stats.get("median"),
                "min": stats.get("min"),
                "max": stats.get("max"),
                "stddev": stats.get("stddev"),
                "rounds": stats.get("rounds"),
                "ops": stats.get("ops"),
            }
        )
    return out


def _load_benchmark_files(pytest_dir: Path, profile: str) -> tuple[list[dict[str, Any]], list[str]]:
    benchmarks: list[dict[str, Any]] = []
    load_errors: list[str] = []
    for suffix in ("", "-read-post-insert", "-read-post-compact", "-lookup"):
        path = pytest_dir / f"benchmark-ci-{profile}{suffix}.json"
        raw = _read_json(path)
        if raw is None:
            continue
        if "_load_error" in raw:
            load_errors.append(f"{path.name}: {raw['_load_error']}")
            continue
        benchmarks.extend(_simplify_benchmarks(raw))
    return benchmarks, load_errors


def _stage_bytes_complete(stages: dict[str, Any], stage_name: str) -> bool:
    stage = stages.get(stage_name)
    if not isinstance(stage, dict):
        return False
    return all(
        isinstance(stage.get(field), int) and stage[field] >= 0 for field in STAGE_BYTE_FIELDS
    )


def _status(
    bench_rc: int,
    benchmarks: list[dict[str, Any]],
    storage: dict[str, Any] | None,
    perf_errors: list[str],
) -> str:
    compact = (storage or {}).get("compact") or {}
    if compact.get("outcome") == "failed":
        return "compact_failed"
    if bench_rc != 0:
        return "benchmark_failed"
    stages = (storage or {}).get("stages") or {}
    compact_path_taken = "pre_compact" in stages or compact.get("outcome") is not None
    if compact_path_taken and not _stage_bytes_complete(stages, "post_compact"):
        return "storage_incomplete"
    if perf_errors:
        return "performance_missing"
    if not benchmarks:
        return "performance_empty"
    return "success"


def _stage_value(stages: dict[str, Any], stage: str, field: str) -> int | None:
    block = stages.get(stage) or {}
    value = block.get(field)
    return value if isinstance(value, int) else None


def main() -> int:
    nebula_root = Path(os.environ["NEBULA_ROOT"])
    profile = os.environ["BENCH_PROFILE"]
    bench_rc = int(os.environ.get("BENCH_RC", "0"))

    pytest_dir = nebula_root / "tests" / ".pytest"
    perf_path = pytest_dir / f"benchmark-ci-{profile}.json"
    read1_path = pytest_dir / f"benchmark-ci-{profile}-read-post-insert.json"
    read2_path = pytest_dir / f"benchmark-ci-{profile}-read-post-compact.json"
    lookup_perf_path = pytest_dir / f"benchmark-ci-{profile}-lookup.json"
    storage_path = pytest_dir / f"benchmark-ci-{profile}-data.json"
    compact_path = pytest_dir / f"benchmark-ci-{profile}-compact.json"
    report_path = pytest_dir / f"benchmark-ci-{profile}-report.json"

    benchmarks, perf_errors = _load_benchmark_files(pytest_dir, profile)
    storage_raw = _read_json(storage_path)
    status = _status(bench_rc, benchmarks, storage_raw, perf_errors)

    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "storage_schema_version": STORAGE_SCHEMA_VERSION,
        "document_type": "nebula_bench_profile_result",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profile": profile,
        "outcome": {
            "status": status,
            "benchmark_exit_code": bench_rc,
            "phase_rc": os.environ.get("BENCH_PHASE_RC"),
        },
        "provenance": {
            "bench_repository": os.environ.get("GITHUB_REPOSITORY"),
            "workflow": os.environ.get("GITHUB_WORKFLOW"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "github_sha": os.environ.get("GITHUB_SHA"),
            "github_ref": os.environ.get("GITHUB_REF"),
            "nebula_repo": os.environ.get("NEBULA_REPO"),
            "nebula_ref": os.environ.get("NEBULA_REF"),
            "measurement_order": MEASUREMENT_ORDER,
        },
        "files": {
            "performance_insert": str(perf_path),
            "performance_read_post_insert": str(read1_path),
            "performance_read_post_compact": str(read2_path),
            "performance_lookup": str(lookup_perf_path),
            "storage": str(storage_path),
            "compact": str(compact_path),
            "report": str(report_path),
        },
        "performance": {
            "available": bool(benchmarks) and not perf_errors,
            "benchmark_count": len(benchmarks),
            "benchmarks": benchmarks,
            "load_errors": perf_errors or None,
        },
        "storage": (
            {
                "available": True,
                **{k: v for k, v in storage_raw.items() if not k.startswith("_")},
            }
            if storage_raw and "_load_error" not in storage_raw
            else {
                "available": False,
                "load_error": (storage_raw or {}).get("_load_error")
                if storage_raw
                else "file not found",
            }
        ),
    }

    pytest_dir.mkdir(parents=True, exist_ok=True)
    with report_path.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"[ci-benchmark:{profile}] AI report: {report_path}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        stages = (report["storage"] if report["storage"].get("available") else {}).get(
            "stages", {}
        )
        compact = (report["storage"] if report["storage"].get("available") else {}).get(
            "compact", {}
        )
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(f"## Profile: `{profile}`\n\n")
            summary.write(f"- **status**: `{status}`\n")
            summary.write(f"- **benchmark_exit_code**: `{bench_rc}`\n")
            if report["storage"].get("available"):
                summary.write(
                    "| stage | data_dir_disk | data_dir_apparent | compact_sec |\n"
                )
                summary.write("|-------|---------------|-------------------|-------------|\n")
                summary.write(
                    f"| post_insert | `{_stage_value(stages, 'post_insert', 'data_dir_disk_bytes')}` "
                    f"| `{_stage_value(stages, 'post_insert', 'data_dir_apparent_bytes')}` | — |\n"
                )
                summary.write(
                    f"| pre_compact | `{_stage_value(stages, 'pre_compact', 'data_dir_disk_bytes')}` "
                    f"| `{_stage_value(stages, 'pre_compact', 'data_dir_apparent_bytes')}` | — |\n"
                )
                summary.write(
                    f"| post_compact | `{_stage_value(stages, 'post_compact', 'data_dir_disk_bytes')}` "
                    f"| `{_stage_value(stages, 'post_compact', 'data_dir_apparent_bytes')}` "
                    f"| `{compact.get('duration_sec')}` |\n"
                )
            summary.write("\n```json\n")
            json.dump(report, summary, indent=2, ensure_ascii=False)
            summary.write("\n```\n\n")

    print("NEBULA_BENCH_PROFILE_REPORT_JSON=" + json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    for key in ("NEBULA_ROOT", "BENCH_ROOT", "BENCH_PROFILE"):
        if key not in os.environ:
            print(f"missing env: {key}", file=sys.stderr)
            sys.exit(2)
    sys.exit(main())
