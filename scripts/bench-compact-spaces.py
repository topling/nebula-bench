#!/usr/bin/env python3
"""对全部 graph space 执行 SUBMIT JOB COMPACT 并输出 JSON。"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool

STORAGE_HTTP_PORTS = {
    "rocksdb": 19779,
    "conservative": 39880,
    "enterprise": 49880,
}


def _row_cells(row) -> list:
    if hasattr(row, "values"):
        return row.values
    return row


def _cell_str(cell) -> str:
    if cell is None:
        return ""
    if hasattr(cell, "as_string"):
        return cell.as_string()
    return str(cell)


def _keys(resp) -> list[str]:
    return [k.decode() if isinstance(k, bytes) else str(k) for k in resp.keys()]


def _execute(session, query: str):
    resp = session.execute(query)
    if not resp.is_succeeded():
        raise RuntimeError(f"{query!r} failed: {resp.error_msg()}")
    return resp


def _list_spaces(session, override: list[str] | None) -> list[str]:
    if override:
        return override
    resp = _execute(session, "SHOW SPACES")
    keys = _keys(resp)
    try:
        name_idx = keys.index("Name")
    except ValueError:
        name_idx = 0
    spaces: list[str] = []
    for i in range(resp.row_size()):
        cells = _row_cells(resp.row_values(i))
        if name_idx < len(cells):
            spaces.append(_cell_str(cells[name_idx]))
    return spaces


def _submit_compact(session, space: str) -> int:
    _execute(session, f"USE `{space}`")
    resp = _execute(session, "SUBMIT JOB COMPACT")
    if resp.row_size() == 0:
        raise RuntimeError(f"SUBMIT JOB COMPACT returned no rows for space {space!r}")
    keys = _keys(resp)
    try:
        id_idx = keys.index("New Job Id")
    except ValueError:
        id_idx = 0
    cells = _row_cells(resp.row_values(0))
    job_id = int(_cell_str(cells[id_idx]))
    return job_id


def _job_status(session, job_id: int) -> str:
    resp = _execute(session, f"SHOW JOB {job_id}")
    if resp.row_size() == 0:
        return "UNKNOWN"
    keys = _keys(resp)
    try:
        status_idx = keys.index("Status")
    except ValueError:
        status_idx = 1 if len(keys) > 1 else 0
    cells = _row_cells(resp.row_values(0))
    return _cell_str(cells[status_idx])


def _poll_jobs(
    session,
    job_ids: list[int],
    timeout_sec: float,
    interval_sec: float,
) -> tuple[bool, str | None]:
    deadline = time.monotonic() + timeout_sec
    pending = set(job_ids)
    last_status: dict[int, str] = {}
    while pending and time.monotonic() < deadline:
        finished: list[int] = []
        for job_id in sorted(pending):
            status = _job_status(session, job_id)
            last_status[job_id] = status
            if status in ("FINISHED", "FAILED", "STOPPED", "TIMEOUT"):
                finished.append(job_id)
                if status != "FINISHED":
                    return False, f"job {job_id} ended with {status}"
        for job_id in finished:
            pending.discard(job_id)
        if pending:
            time.sleep(interval_sec)
    if pending:
        return False, f"timeout waiting for jobs: {sorted(pending)} last={last_status}"
    return True, None


def _write_compact_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _diagnostic_context(profile: str, host: str, port: int) -> str:
    http_port = STORAGE_HTTP_PORTS.get(profile, "?")
    return f"graph={host}:{port} ws_storage_http_port={http_port} profile={profile}"


def main() -> int:
    host = os.environ.get("BENCH_GRAPH_HOST", "127.0.0.1")
    port = int(os.environ["BENCH_GRAPH_PORT"])
    user = os.environ.get("BENCH_GRAPH_USER", "root")
    password = os.environ.get("BENCH_GRAPH_PASSWORD", "nebula")
    profile = os.environ.get("BENCH_PROFILE", "conservative")
    timeout_sec = float(os.environ.get("BENCH_COMPACT_TIMEOUT_SEC", "3600"))
    interval_sec = float(os.environ.get("BENCH_COMPACT_POLL_INTERVAL", "2"))
    out_json = Path(
        os.environ.get(
            "BENCH_COMPACT_JSON",
            f"{os.environ['NEBULA_ROOT']}/tests/.pytest/benchmark-ci-{profile}-compact.json",
        )
    )

    spaces_override = None
    raw_spaces = os.environ.get("BENCH_COMPACT_SPACES", "").strip()
    if raw_spaces:
        spaces_override = [s.strip() for s in raw_spaces.split(",") if s.strip()]

    payload: dict[str, Any] = {
        "duration_sec": None,
        "spaces": [],
        "job_ids": [],
        "outcome": None,
        "error": None,
    }
    exit_code = 0

    pool = ConnectionPool()
    if not pool.init([(host, port)], Config()):
        payload["outcome"] = "failed"
        payload["error"] = (
            f"fail to init connection pool; {_diagnostic_context(profile, host, port)}"
        )
        _write_compact_json(out_json, payload)
        print(payload["error"], file=sys.stderr)
        return 1

    session = pool.get_session(user, password)
    started: float | None = None
    try:
        spaces = _list_spaces(session, spaces_override)
        payload["spaces"] = spaces
        job_ids: list[int] = []
        for space in spaces:
            if started is None:
                started = time.monotonic()
            job_ids.append(_submit_compact(session, space))
        payload["job_ids"] = job_ids

        ok, err = _poll_jobs(session, job_ids, timeout_sec, interval_sec)
        payload["duration_sec"] = (
            round(time.monotonic() - started, 3) if started is not None else None
        )
        if ok:
            payload["outcome"] = "success"
        else:
            payload["outcome"] = "failed"
            payload["error"] = f"{err}; {_diagnostic_context(profile, host, port)}"
            exit_code = 1
    except Exception as exc:  # noqa: BLE001 — must always emit JSON
        payload["duration_sec"] = (
            round(time.monotonic() - started, 3) if started is not None else None
        )
        payload["outcome"] = "failed"
        payload["error"] = f"{exc}; {_diagnostic_context(profile, host, port)}"
        exit_code = 1
    finally:
        session.release()
        _write_compact_json(out_json, payload)

    if exit_code:
        print(payload.get("error") or "compact failed", file=sys.stderr)
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    for key in ("BENCH_GRAPH_PORT", "NEBULA_ROOT"):
        if key not in os.environ:
            print(f"missing env: {key}", file=sys.stderr)
            sys.exit(2)
    sys.exit(main())
