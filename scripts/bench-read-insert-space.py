#!/usr/bin/env python3
"""在 benchinsertspace 上做 compact 前/后读性能（pytest-benchmark）。"""
from __future__ import annotations

import os
import sys
import time

import pytest

from tests.common.nebula_test_suite import NebulaTestSuite

SPACE = "benchinsertspace"
INDEX_DEFS = (
    ("personName", "CREATE TAG index IF NOT EXISTS personName on person(name)"),
    ("personAge", "CREATE TAG index IF NOT EXISTS personAge on person(age)"),
)
LOOKUP_QUERIES = (
    "lookup on person where person.age < 0 ",
    "lookup on person where person.age > 0 ",
    "lookup on person where person.age > 60",
    "lookup on person where person.age > 90",
    'lookup on person where person.name == "sssssaass" ',
    'lookup on person where person.name == "saaaaaass" ',
    "lookup on person where person.age < 10 ",
    "lookup on person where person.age > 80 ",
    "lookup on person where person.age > 60",
    "lookup on person where person.age > 90",
)


def _read_stage() -> str:
    return os.environ.get("BENCH_READ_STAGE", "post_insert")


class TestBenchReadInsertSpace(NebulaTestSuite):
    @classmethod
    def prepare(cls) -> None:
        resp = cls.execute(f"USE {SPACE}")
        cls.check_resp_succeeded(resp)
        if _read_stage() == "post_insert":
            for _, ddl in INDEX_DEFS:
                resp = cls.execute(ddl)
                cls.check_resp_succeeded(resp)
            time.sleep(cls.delay)
        cls._wait_indexes_ready()

    @classmethod
    def cleanup(cls) -> None:
        if os.environ.get("NEBULA_BENCH_SKIP_CLEANUP"):
            return
        resp = cls.execute(f"DROP SPACE {SPACE}")
        cls.check_resp_succeeded(resp)

    @classmethod
    def _wait_indexes_ready(cls) -> None:
        timeout_sec = int(os.environ.get("BENCH_INDEX_READY_TIMEOUT_SEC", "300"))
        interval_sec = float(os.environ.get("BENCH_INDEX_READY_INTERVAL", "2"))
        deadline = time.monotonic() + timeout_sec
        expected = {name for name, _ in INDEX_DEFS}
        while time.monotonic() < deadline:
            if cls._indexes_ready(expected):
                return
            time.sleep(interval_sec)
        pytest.fail("index ready timeout")

    @classmethod
    def _index_status(cls, index_name: str) -> str | None:
        status_resp = cls.execute("SHOW TAG INDEX STATUS")
        if not status_resp.is_succeeded() or status_resp.row_size() == 0:
            return None
        status_keys = [
            k.decode() if isinstance(k, bytes) else str(k) for k in status_resp.keys()
        ]
        try:
            idx_name = status_keys.index("Index Name")
            idx_status = status_keys.index("Index Status")
        except ValueError:
            return None
        for i in range(status_resp.row_size()):
            row = status_resp.row_values(i)
            cells = row.values if hasattr(row, "values") else row
            if idx_name >= len(cells) or idx_status >= len(cells):
                continue
            if cells[idx_name].as_string() != index_name:
                continue
            return cells[idx_status].as_string()
        return None

    @classmethod
    def _indexes_ready(cls, expected: set[str]) -> bool:
        resp = cls.execute("SHOW TAG INDEXES")
        if not resp.is_succeeded():
            return False
        keys = [k.decode() if isinstance(k, bytes) else str(k) for k in resp.keys()]
        try:
            name_idx = keys.index("Index Name")
        except ValueError:
            name_idx = 0
        found: set[str] = set()
        for i in range(resp.row_size()):
            row = resp.row_values(i)
            cells = row.values if hasattr(row, "values") else row
            if name_idx < len(cells):
                found.add(cells[name_idx].as_string())
        if not expected.issubset(found):
            return False

        status_unusable = False
        for index_name in sorted(expected):
            status = cls._index_status(index_name)
            if status is None:
                status_unusable = True
                continue
            if status != "FINISHED":
                return False
        if status_unusable:
            print(
                "warn: SHOW TAG INDEX STATUS unavailable, unparseable, or index missing; "
                "retrying index ready probe",
                file=sys.stderr,
            )
            return False
        return True

    def _run_lookups(self) -> None:
        for query in LOOKUP_QUERIES:
            resp = self.execute(query)
            self.check_resp_succeeded(resp)

    @pytest.mark.skipif(_read_stage() != "post_insert", reason="BENCH_READ_STAGE != post_insert")
    @pytest.mark.benchmark(
        group="read",
        min_time=0.1,
        max_time=0.5,
        min_rounds=1,
        timer=time.time,
        disable_gc=True,
        warmup=False,
    )
    def test_read_post_insert(self, benchmark) -> None:
        benchmark(self._run_lookups)

    @pytest.mark.skipif(_read_stage() != "post_compact", reason="BENCH_READ_STAGE != post_compact")
    @pytest.mark.benchmark(
        group="read",
        min_time=0.1,
        max_time=0.5,
        min_rounds=1,
        timer=time.time,
        disable_gc=True,
        warmup=False,
    )
    def test_read_post_compact(self, benchmark) -> None:
        benchmark(self._run_lookups)
