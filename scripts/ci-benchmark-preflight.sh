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

# storage 采集函数 smoke test（不依赖 nebula 进程）
_smoke_profile="preflight-smoke"
_smoke_dir="${NEBULA_ROOT}/data-${_smoke_profile}"
_smoke_json="${NEBULA_ROOT}/tests/.pytest/preflight-storage-smoke.json"
rm -rf "${_smoke_dir}"
mkdir -p "${_smoke_dir}/storage" "${_smoke_dir}/meta"
echo "bench" > "${_smoke_dir}/storage/sample.dat"
export NEBULA_BENCH_STORAGE_STAGE=preflight_smoke
if ! nebula_bench_record_data_dir_size "${_smoke_profile}" "${_smoke_json}" >/dev/null; then
  echo "nebula_bench_record_data_dir_size smoke test failed" >&2
  rm -rf "${_smoke_dir}" "${_smoke_json}"
  exit 1
fi
if ! grep -q '"measurement_stage": "preflight_smoke"' "${_smoke_json}"; then
  echo "storage json missing expected measurement_stage" >&2
  rm -rf "${_smoke_dir}" "${_smoke_json}"
  exit 1
fi
rm -rf "${_smoke_dir}" "${_smoke_json}"
unset NEBULA_BENCH_STORAGE_STAGE

log "ok"
