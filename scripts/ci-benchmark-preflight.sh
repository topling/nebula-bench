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

log "ok"
