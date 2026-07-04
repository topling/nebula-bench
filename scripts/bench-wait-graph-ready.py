#!/usr/bin/env python3
"""等待 graph 可查询且 SHOW HOSTS 有 ONLINE 的 storage（CREATE SPACE 需要）。"""
from __future__ import annotations

import os
import sys
import time

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool


def _row_cells(row) -> list:
    """nebula3 ResultSet.row_values() 在不同版本返回 list 或带 .values 的对象。"""
    if hasattr(row, "values"):
        return row.values
    return row


def _hosts_ready(resp) -> bool:
    if resp is None or not resp.is_succeeded():
        return False
    if resp.row_size() == 0:
        return False
    keys = [k.decode() if isinstance(k, bytes) else str(k) for k in resp.keys()]
    try:
        status_idx = keys.index("Status")
    except ValueError:
        return resp.row_size() > 0
    online = 0
    for i in range(resp.row_size()):
        cells = _row_cells(resp.row_values(i))
        if status_idx >= len(cells):
            continue
        status = cells[status_idx].as_string()
        if status == "ONLINE":
            online += 1
    min_hosts = int(os.environ.get("BENCH_MIN_ONLINE_HOSTS", "1"))
    return online >= min_hosts


def main() -> int:
    host = os.environ.get("BENCH_GRAPH_HOST", "127.0.0.1")
    port = int(os.environ["BENCH_GRAPH_PORT"])
    user = os.environ.get("BENCH_GRAPH_USER", "root")
    password = os.environ.get("BENCH_GRAPH_PASSWORD", "nebula")
    timeout_sec = int(os.environ.get("BENCH_GRAPH_READY_TIMEOUT", "300"))
    interval_sec = float(os.environ.get("BENCH_GRAPH_READY_INTERVAL", "2"))

    pool = ConnectionPool()
    if not pool.init([(host, port)], Config()):
        print(f"fail to init connection pool {host}:{port}", file=sys.stderr)
        return 1

    deadline = time.monotonic() + timeout_sec
    last_err = "no ONLINE host in SHOW HOSTS"
    while time.monotonic() < deadline:
        session = pool.get_session(user, password)
        try:
            resp = session.execute("SHOW HOSTS")
            if _hosts_ready(resp):
                print(f"graph {host}:{port} ready: SHOW HOSTS has ONLINE storage")
                return 0
            if resp is not None and not resp.is_succeeded():
                last_err = resp.error_msg()
            elif resp is not None:
                last_err = f"SHOW HOSTS rows={resp.row_size()}, waiting for ONLINE storage"
        finally:
            session.release()
        time.sleep(interval_sec)

    print(
        f"timeout waiting for storage hosts on {host}:{port}: {last_err}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    if "BENCH_GRAPH_PORT" not in os.environ:
        print("missing env: BENCH_GRAPH_PORT", file=sys.stderr)
        sys.exit(2)
    sys.exit(main())
