#!/usr/bin/env bash
# Work around upstream tests/bench issues when using --address (nebula repo stays minimal).
set -euo pipefail
: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"

_lookup="${NEBULA_ROOT}/tests/bench/lookup.py"
if [[ -f "${_lookup}" ]]; then
  if grep -q '^from graph import ttypes$' "${_lookup}"; then
    sed -i '/^from graph import ttypes$/d' "${_lookup}"
  fi
  if grep -q "replica_factor=self.replica_factor)')" "${_lookup}"; then
    sed -i "s/replica_factor=self.replica_factor)')/replica_factor=self.replica_factor))/" "${_lookup}"
  fi
fi

for _bench in insert.py lookup.py; do
  _f="${NEBULA_ROOT}/tests/bench/${_bench}"
  [[ -f "${_f}" ]] || continue
  if grep -q 'CREATE SPACE IF NOT EXISTS' "${_f}" && ! grep -q 'vid_type=' "${_f}"; then
    sed -i 's/replica_factor={replica_factor})/replica_factor={replica_factor}, vid_type=INT64)/' "${_f}"
  fi
done

_insert="${NEBULA_ROOT}/tests/bench/insert.py"
if [[ -f "${_insert}" ]] && grep -q 'self\.graph_delay' "${_insert}"; then
  sed -i 's/self\.graph_delay/self.delay/g' "${_insert}"
fi

# 外挂 standalone 时 get configs 可能长期 Not ready；CI 用 NEBULA_BENCH_FIXED_GRAPH_DELAY 固定 sleep。
_suite="${NEBULA_ROOT}/tests/common/nebula_test_suite.py"
if [[ -f "${_suite}" ]] && ! grep -q 'NEBULA_BENCH_FIXED_GRAPH_DELAY' "${_suite}"; then
  python3 - "${_suite}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
needles = (
    "    @classmethod\n"
    "    def set_delay(self):\n"
    "        self.delay = get_delay_time(self.client)",
    "    @classmethod\n"
    "    def set_delay(self):\n"
    "        self.delay = self.graph_delay = get_delay_time(self.client)",
)
replacement = (
    "    @classmethod\n"
    "    def set_delay(self):\n"
    "        import os\n"
    "        fixed = os.environ.get(\"NEBULA_BENCH_FIXED_GRAPH_DELAY\")\n"
    "        if fixed is not None:\n"
    "            self.delay = int(fixed)\n"
    "            return\n"
    "        self.delay = get_delay_time(self.client)"
)
for needle in needles:
    if needle in text:
        path.write_text(text.replace(needle, replacement, 1))
        break
else:
    if "NEBULA_BENCH_FIXED_GRAPH_DELAY" in text:
        sys.exit(0)
    print(f"set_delay pattern not found in {path}", file=sys.stderr)
    sys.exit(1)
PY
fi
