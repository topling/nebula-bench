#!/usr/bin/env bash
set -euo pipefail

: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-${NEBULA_ROOT}/install-rocksdb}"
CMD="${1:-}"

# shellcheck source=nebula-bench-paths.sh
source "${BENCH_ROOT}/scripts/nebula-bench-paths.sh"
if [[ "${CMD}" == "start" ]]; then
  nebula_bench_install_standalone_conf rocksdb "${INSTALL_DIR}" "${BENCH_ROOT}"
fi

cd "${INSTALL_DIR}"
exec scripts/nebula-standalone.service "$@"
