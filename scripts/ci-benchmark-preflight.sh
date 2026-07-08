#!/usr/bin/env bash
# Fast checks before 1h+ compile/bench. Must finish in seconds.
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEBULA_ROOT="${NEBULA_ROOT:?NEBULA_ROOT must be set}"
BENCH_PROFILE="${BENCH_PROFILE:-conservative}"

log() { echo "[ci-preflight:${BENCH_PROFILE}] $*"; }

case "${BENCH_PROFILE}" in
  rocksdb|conservative|enterprise) ;;
  *)
    echo "unknown BENCH_PROFILE=${BENCH_PROFILE}" >&2
    exit 1
    ;;
esac

if [[ ! -d "${NEBULA_ROOT}" ]]; then
  echo "NEBULA_ROOT not found: ${NEBULA_ROOT}" >&2
  exit 1
fi

for rel in \
  tests/bench/insert.py \
  tests/bench/lookup.py \
  tests/requirements.txt \
  cmake/FindRocksdb.cmake \
  conf/topling-mimic-rocksdb.yaml \
  conf/topling-enterprise.yaml
do
  if [[ ! -f "${NEBULA_ROOT}/${rel}" ]]; then
    echo "missing in nebula checkout: ${rel}" >&2
    exit 1
  fi
done

for rel in \
  PROJECT_BANS.md \
  scripts/build-topling.sh \
  scripts/build-rocksdb.sh \
  scripts/run-standalone-topling.sh \
  scripts/run-standalone-bench.sh \
  scripts/nebula-bench-paths.sh \
  scripts/ci-benchmark-emit-profile-report.py \
  scripts/ci-benchmark-merge-reports.py \
  scripts/bench-storage-record.py \
  scripts/bench-compact-spaces.py \
  scripts/bench-read-insert-space.py \
  scripts/bench-wait-graph-ready.py \
  scripts/bench-patch-nebula-tests.sh \
  requirements-bench-ci.txt \
  conf/nebula-standalone-bench.conf \
  conf/nebula-standalone-topling-conservative.conf \
  conf/nebula-standalone-topling-enterprise.conf
do
  if [[ ! -f "${BENCH_ROOT}/${rel}" ]]; then
    echo "missing in bench repo: ${rel}" >&2
    exit 1
  fi
done

# shellcheck source=nebula-bench-paths.sh
source "${BENCH_ROOT}/scripts/nebula-bench-paths.sh"
nebula_bench_check_conf_templates "${BENCH_ROOT}"

if [[ -f "${BENCH_ROOT}/scripts/bench-patch-nebula-rocksdb-link.sh" ]]; then
  echo "forbidden script present (see PROJECT_BANS.md #1): bench-patch-nebula-rocksdb-link.sh" >&2
  exit 1
fi
if grep -q 'static_lib' "${BENCH_ROOT}/scripts/ci-benchmark-topling.sh"; then
  echo "forbidden: make static_lib in ci-benchmark-topling.sh (see PROJECT_BANS.md #1)" >&2
  exit 1
fi
if [[ -f "${BENCH_ROOT}/scripts/bench-patch-nebula-kvstore.sh" ]]; then
  echo "forbidden obsolete patch (nebula upstream fixed): bench-patch-nebula-kvstore.sh" >&2
  exit 1
fi
if ! grep -q 'USE_TOPLINGDB' "${NEBULA_ROOT}/cmake/FindRocksdb.cmake"; then
  echo "nebula checkout too old: cmake/FindRocksdb.cmake missing USE_TOPLINGDB" >&2
  exit 1
fi
if ! grep -q 'ROCKSDB_MAJOR >= 8' "${NEBULA_ROOT}/src/kvstore/RocksEngineConfig.cpp"; then
  echo "nebula checkout too old: RocksEngineConfig missing ToplingDB API shims" >&2
  exit 1
fi

mkdir -p "${NEBULA_ROOT}/tests/.pytest"

export BENCH_ROOT
# shellcheck source=bench-patch-nebula-tests.sh
source "${BENCH_ROOT}/scripts/bench-patch-nebula-tests.sh"
for _bench in insert.py lookup.py; do
  _pf="${NEBULA_ROOT}/tests/bench/${_bench}"
  if ! grep -q 'NEBULA_BENCH_SKIP_CLEANUP' "${_pf}"; then
    echo "bench patch missing SKIP_CLEANUP guard in tests/bench/${_bench}" >&2
    exit 1
  fi
  if ! grep -q 'vid_type=INT64' "${_pf}"; then
    echo "bench patch missing vid_type=INT64 in tests/bench/${_bench}" >&2
    exit 1
  fi
done
# shellcheck source=bench-python-env.sh
source "${BENCH_ROOT}/scripts/bench-python-env.sh"

_preflight_log="$(mktemp)"
if ! "${BENCH_PYTHON}" -c "
import sys
sys.path.insert(0, '${NEBULA_ROOT}')
import tests.bench.insert  # noqa: F401
import tests.bench.lookup  # noqa: F401
print('bench modules ok')
" >"${_preflight_log}" 2>&1; then
  cat "${_preflight_log}" >&2
  rm -f "${_preflight_log}"
  exit 1
fi
rm -f "${_preflight_log}"

# read 基准须在 tests/bench 下 invoke，否则 pytest 无法识别 --address
_read_bench="${NEBULA_ROOT}/tests/bench/bench-read-insert-space.py"
cp "${BENCH_ROOT}/scripts/bench-read-insert-space.py" "${_read_bench}"
export PYTHONPATH="${NEBULA_ROOT}"
_preflight_log="$(mktemp)"
if ! "${BENCH_PYTHON}" -m pytest "${_read_bench}" \
  --collect-only \
  --address=127.0.0.1:9669 --stop_nebula=false --rm_dir=false \
  -q >"${_preflight_log}" 2>&1; then
  echo "bench-read-insert-space pytest options smoke failed" >&2
  cat "${_preflight_log}" >&2
  rm -f "${_preflight_log}"
  exit 1
fi
rm -f "${_preflight_log}"

# storage schema v2 smoke（不依赖 nebula 进程）
_smoke_profile="preflight-smoke"
_smoke_dir="${NEBULA_ROOT}/data-${_smoke_profile}"
_smoke_json="${NEBULA_ROOT}/tests/.pytest/preflight-storage-smoke.json"
_smoke_compact="${BENCH_ROOT}/scripts/fixtures/benchmark-data-v2-compact.json"
rm -rf "${_smoke_dir}" "${_smoke_json}"
mkdir -p "${_smoke_dir}/storage" "${_smoke_dir}/meta"
echo "bench" > "${_smoke_dir}/storage/sample.dat"
echo "meta" > "${_smoke_dir}/meta/sample.dat"

if ! "${BENCH_PYTHON}" "${BENCH_ROOT}/scripts/bench-storage-record.py" init \
  --profile "${_smoke_profile}" --out "${_smoke_json}"; then
  echo "bench-storage-record init failed" >&2
  rm -rf "${_smoke_dir}" "${_smoke_json}"
  exit 1
fi

for _stage in post_insert pre_compact post_compact; do
  if ! "${BENCH_PYTHON}" "${BENCH_ROOT}/scripts/bench-storage-record.py" append-stage \
    --profile "${_smoke_profile}" --stage "${_stage}" --out "${_smoke_json}" \
    --nebula-root "${NEBULA_ROOT}"; then
    echo "bench-storage-record append-stage ${_stage} failed" >&2
    rm -rf "${_smoke_dir}" "${_smoke_json}"
    exit 1
  fi
done

if ! "${BENCH_PYTHON}" "${BENCH_ROOT}/scripts/bench-storage-record.py" merge-compact \
  --compact-json "${_smoke_compact}" --out "${_smoke_json}"; then
  echo "bench-storage-record merge-compact failed" >&2
  rm -rf "${_smoke_dir}" "${_smoke_json}"
  exit 1
fi

if ! "${BENCH_PYTHON}" -c "
import json
from pathlib import Path
path = Path('${_smoke_json}')
doc = json.loads(path.read_text())
assert doc.get('schema_version') == 2, doc.get('schema_version')
fields = (
    'data_dir_disk_bytes', 'data_dir_apparent_bytes',
    'storage_disk_bytes', 'storage_apparent_bytes',
    'meta_disk_bytes', 'meta_apparent_bytes',
)
for stage in ('post_insert', 'pre_compact', 'post_compact'):
    block = doc['stages'][stage]
    for key in fields:
        val = block[key]
        assert isinstance(val, int) and val >= 0, (stage, key, val)
compact = doc['compact']
assert compact['outcome'] == 'success'
assert isinstance(compact['duration_sec'], (int, float))
assert compact['job_ids'] == [42]
assert doc['data_dir_disk_bytes'] == doc['stages']['post_insert']['data_dir_disk_bytes']
print('storage v2 smoke ok')
"; then
  echo "storage v2 type assertion failed" >&2
  rm -rf "${_smoke_dir}" "${_smoke_json}"
  exit 1
fi

rm -rf "${_smoke_dir}" "${_smoke_json}"

log "ok"
