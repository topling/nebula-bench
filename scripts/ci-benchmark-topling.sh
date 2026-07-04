#!/usr/bin/env bash
# CI/local 1M benchmark: rocksdb (原版) | conservative | enterprise
# 性能用例复用 nebula 官方 tests/bench/（20000×50 ≈ 1M）
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${CI_BENCHMARK_WORKDIR:-${RUNNER_TEMP:-${BENCH_ROOT}}}"
NEBULA_ROOT="${NEBULA_ROOT:-${WORK}/nebula}"
TOPLINGDB_ROOT="${TOPLINGDB_ROOT:-${WORK}/toplingdb}"
BENCH_PROFILE="${BENCH_PROFILE:-conservative}"
JOBS="${JOBS:-$(nproc)}"

suffix() {
  case "${BENCH_PROFILE}" in
    rocksdb) echo "rocksdb" ;;
    conservative) echo "conservative" ;;
    enterprise) echo "enterprise" ;;
    *) echo "unknown profile: ${BENCH_PROFILE}" >&2; exit 1 ;;
  esac
}

PROFILE_SUFFIX="$(suffix)"
TP_PREFIX="${NEBULA_ROOT}/build/third-party/install"
case "${BENCH_PROFILE}" in
  rocksdb) BUILD_DIR="${NEBULA_ROOT}/build-rocksdb" ;;
  conservative|enterprise) BUILD_DIR="${NEBULA_ROOT}/build-topling" ;;
esac
case "${BENCH_PROFILE}" in
  rocksdb) INSTALL_DIR="${NEBULA_ROOT}/install-rocksdb" ;;
  conservative|enterprise) INSTALL_DIR="${NEBULA_ROOT}/install-topling" ;;
esac

# shellcheck source=nebula-bench-paths.sh
source "${BENCH_ROOT}/scripts/nebula-bench-paths.sh"
DATA_DIR="$(nebula_bench_data_dir "${PROFILE_SUFFIX}")"

log() { echo "[ci-benchmark:${BENCH_PROFILE}] $*"; }

install_system_deps() {
  if [[ "${CI:-}" != "true" && "${INSTALL_SYSTEM_DEPS:-}" != "1" ]]; then
    return 0
  fi
  log "installing system packages"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git wget curl build-essential cmake python3 python3-pip python3-venv \
    libaio-dev libgflags-dev zlib1g-dev libbz2-dev \
    libcurl4-gnutls-dev liburing-dev libsnappy-dev liblz4-dev libzstd-dev
}

ensure_toplingdb() {
  if [[ -f "${TOPLINGDB_ROOT}/librocksdb.so" ]]; then
    log "reuse ToplingDB at ${TOPLINGDB_ROOT}"
    return 0
  fi
  if [[ ! -d "${TOPLINGDB_ROOT}/.git" ]]; then
    log "cloning ToplingDB into ${TOPLINGDB_ROOT}"
    git clone --depth 1 --recursive https://github.com/topling/toplingdb.git "${TOPLINGDB_ROOT}"
  fi
  log "building ToplingDB shared_lib"
  make -C "${TOPLINGDB_ROOT}" -j"${JOBS}" \
    DEBUG_LEVEL=0 DISABLE_JEMALLOC=1 TOPLING_USE_DYNAMIC_TLS=1 shared_lib
}

ensure_third_party() {
  if [[ -d "${TP_PREFIX}/include" ]]; then
    log "reuse third-party at ${TP_PREFIX}"
    return 0
  fi
  log "downloading Nebula third-party"
  mkdir -p "$(dirname "${TP_PREFIX}")"
  bash "${NEBULA_ROOT}/third-party/install-third-party.sh" --prefix="${TP_PREFIX}"
}

build_nebula() {
  export BUILD_DIR INSTALL_DIR NEBULA_THIRDPARTY_ROOT="${TP_PREFIX}" BENCH_ROOT NEBULA_ROOT
  case "${BENCH_PROFILE}" in
    rocksdb)
      log "building NebulaGraph with third-party RocksDB"
      bash "${BENCH_ROOT}/scripts/build-rocksdb.sh"
      ;;
    conservative|enterprise)
      log "building NebulaGraph with ToplingDB (${BENCH_PROFILE})"
      export TOPLINGDB_ROOT TOPLING_MIGRATE_PROFILE="${BENCH_PROFILE}"
      bash "${BENCH_ROOT}/scripts/build-topling.sh"
      ;;
  esac
}

wait_graph_query_ready() {
  local port
  port="$(graph_port)"
  # shellcheck source=bench-python-env.sh
  source "${BENCH_ROOT}/scripts/bench-python-env.sh"
  export BENCH_GRAPH_PORT="${port}"
  log "waiting for graph query ready on 127.0.0.1:${port}"
  "${BENCH_PYTHON}" "${BENCH_ROOT}/scripts/bench-wait-graph-ready.py"
}

graph_port() {
  case "${BENCH_PROFILE}" in
    rocksdb) echo 9669 ;;
    conservative) echo 39669 ;;
    enterprise) echo 49669 ;;
  esac
}

wait_graph_port() {
  local host="127.0.0.1" port="$1" wait_sec="${2:-300}"
  local start=$SECONDS
  while (( SECONDS - start < wait_sec )); do
    if (echo >/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
      log "graph ${host}:${port} is accepting connections"
      return 0
    fi
    sleep 2
  done
  echo "timeout waiting for ${host}:${port}" >&2
  return 1
}

start_standalone() {
  log "starting standalone"
  rm -rf "${DATA_DIR}"
  export INSTALL_DIR NEBULA_ROOT
  case "${BENCH_PROFILE}" in
    rocksdb)
      bash "${BENCH_ROOT}/scripts/run-standalone-bench.sh" start
      bash "${BENCH_ROOT}/scripts/run-standalone-bench.sh" status
      ;;
    conservative|enterprise)
      export TOPLINGDB_ROOT TOPLING_MIGRATE_PROFILE="${BENCH_PROFILE}"
      bash "${BENCH_ROOT}/scripts/run-standalone-topling.sh" start
      bash "${BENCH_ROOT}/scripts/run-standalone-topling.sh" status
      ;;
  esac
  wait_graph_port "$(graph_port)" 300
  wait_graph_query_ready
}

stop_standalone() {
  export INSTALL_DIR NEBULA_ROOT
  case "${BENCH_PROFILE}" in
    rocksdb)
      bash "${BENCH_ROOT}/scripts/run-standalone-bench.sh" stop || true
      ;;
    conservative|enterprise)
      export TOPLINGDB_ROOT TOPLING_MIGRATE_PROFILE="${BENCH_PROFILE}"
      bash "${BENCH_ROOT}/scripts/run-standalone-topling.sh" stop || true
      ;;
  esac
}

run_official_bench() {
  local port json
  port="$(graph_port)"
  json="${NEBULA_ROOT}/tests/.pytest/benchmark-ci-${BENCH_PROFILE}.json"
  mkdir -p "$(dirname "${json}")"
  log "running official tests/bench on 127.0.0.1:${port}"
  export BENCH_ROOT
  # shellcheck source=bench-patch-nebula-tests.sh
  source "${BENCH_ROOT}/scripts/bench-patch-nebula-tests.sh"
  # shellcheck source=bench-python-env.sh
  source "${BENCH_ROOT}/scripts/bench-python-env.sh"
  export PYTHONPATH="${NEBULA_ROOT}"
  # conf 中 heartbeat_interval_secs=10 → get_delay_time 公式 (10+1)*3
  export NEBULA_BENCH_FIXED_GRAPH_DELAY=33
  # shellcheck source=bench-seed-pytest-state.sh
  source "${BENCH_ROOT}/scripts/bench-seed-pytest-state.sh"
  "${BENCH_PYTHON}" -m pytest \
    "${NEBULA_ROOT}/tests/bench/insert.py" \
    "${NEBULA_ROOT}/tests/bench/lookup.py" \
    --address="127.0.0.1:${port}" \
    --stop_nebula=false --rm_dir=false \
    --benchmark-only \
    --benchmark-json="${json}" -v
}

record_bench_data_size() {
  local human bytes size_json="${NEBULA_ROOT}/tests/.pytest/benchmark-ci-${BENCH_PROFILE}-data.json"
  if ! human="$(nebula_bench_record_data_dir_size "${PROFILE_SUFFIX}" "${size_json}")"; then
    log "warn: failed to record data_dir size (${DATA_DIR})"
    return 0
  fi
  bytes="$(du -sb "${DATA_DIR}" | cut -f1)"
  log "data_dir ${DATA_DIR} size: ${human} (${bytes} bytes, ${size_json})"
}

emit_profile_report() {
  local bench_rc=$1
  # shellcheck source=bench-python-env.sh
  source "${BENCH_ROOT}/scripts/bench-python-env.sh"
  export BENCH_RC="${bench_rc}"
  "${BENCH_PYTHON}" "${BENCH_ROOT}/scripts/ci-benchmark-emit-profile-report.py"
}

main() {
  if [[ ! -d "${NEBULA_ROOT}" ]]; then
    echo "NEBULA_ROOT not found: ${NEBULA_ROOT}" >&2
    exit 1
  fi
  trap stop_standalone EXIT
  install_system_deps
  ensure_third_party
  if [[ "${BENCH_PROFILE}" != "rocksdb" ]]; then
    ensure_toplingdb
  fi
  build_nebula
  start_standalone
  local bench_rc=0
  run_official_bench || bench_rc=$?
  record_bench_data_size
  emit_profile_report "${bench_rc}"
  log "benchmark finished"
  (( bench_rc )) && exit "${bench_rc}"
}

main "$@"
