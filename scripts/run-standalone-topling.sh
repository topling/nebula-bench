#!/usr/bin/env bash
set -euo pipefail

: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOPLINGDB_ROOT="${TOPLINGDB_ROOT:-$(cd "${NEBULA_ROOT}/../toplingdb" && pwd)}"
PROFILE="${TOPLING_MIGRATE_PROFILE:-enterprise}"
INSTALL_DIR="${INSTALL_DIR:-${NEBULA_ROOT}/install-topling}"
CMD="${1:-}"

case "${PROFILE}" in
  conservative)
    CONF="${NEBULA_ROOT}/conf/topling-mimic-rocksdb.yaml"
    WEB_DIR="/dev/shm/nebula_topling_conservative"
    ;;
  enterprise)
    CONF="${NEBULA_ROOT}/conf/topling-enterprise.yaml"
    WEB_DIR="/dev/shm/db_bench_enterprise"
    ;;
  *)
    echo "Unknown TOPLING_MIGRATE_PROFILE=${PROFILE}" >&2
    exit 1
    ;;
esac

if [[ ! -f "${CONF}" ]]; then
  echo "Easy Migrate config not found: ${CONF}" >&2
  exit 1
fi

if [[ "${CMD}" == "start" ]]; then
  mkdir -p "${WEB_DIR}"
  cp -f "${TOPLINGDB_ROOT}/sideplugin/rockside/src/topling/web/index.html" \
        "${TOPLINGDB_ROOT}/sideplugin/rockside/src/topling/web/style.css" \
        "${WEB_DIR}/" 2>/dev/null || true
  export LD_LIBRARY_PATH="${TOPLINGDB_ROOT}:${LD_LIBRARY_PATH:-}"
  export TOPLINGDB_EASY_MIGRATE_CONF="${CONF}"
  export ROCKSDB_KICK_OUT_OPTIONS_FILE=1
  export TOPLINGDB_GetContext_sampling=kNone
fi

# shellcheck source=nebula-topling-bench-paths.sh
source "${BENCH_ROOT}/scripts/nebula-topling-bench-paths.sh"
if [[ "${CMD}" == "start" ]]; then
  nebula_bench_install_standalone_conf "${PROFILE}" "${INSTALL_DIR}" "${BENCH_ROOT}"
fi

cd "${INSTALL_DIR}"
exec scripts/nebula-standalone.service "$@"
