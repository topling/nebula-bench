#!/usr/bin/env bash
set -euo pipefail

: "${BENCH_ROOT:?BENCH_ROOT must be set}"
: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"

TOPLINGDB_ROOT="${TOPLINGDB_ROOT:-$(cd "${NEBULA_ROOT}/../toplingdb" && pwd)}"
NEBULA_TP="${NEBULA_THIRDPARTY_ROOT:-${NEBULA_ROOT}/build/third-party/install}"
PROFILE="${TOPLING_MIGRATE_PROFILE:-enterprise}"
BUILD_DIR="${BUILD_DIR:-${NEBULA_ROOT}/build-topling}"
INSTALL_DIR="${INSTALL_DIR:-${NEBULA_ROOT}/install-topling}"

# shellcheck source=nebula-topling-bench-paths.sh
source "${BENCH_ROOT}/scripts/nebula-topling-bench-paths.sh"
nebula_bench_validate_profile "${PROFILE}"

if [[ ! -f "${TOPLINGDB_ROOT}/librocksdb.so" ]]; then
  echo "ToplingDB shared lib not found: ${TOPLINGDB_ROOT}/librocksdb.so" >&2
  exit 1
fi

if [[ ! -d "${NEBULA_TP}/include" ]]; then
  echo "Nebula third-party not found: ${NEBULA_TP}" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake .. \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DENABLE_STANDALONE_VERSION=ON \
  -DENABLE_TESTING=OFF \
  -DENABLE_WERROR=OFF \
  -DNEBULA_THIRDPARTY_ROOT="${NEBULA_TP}" \
  -DEXTERNAL_TOPLINGDB_ROOT="${TOPLINGDB_ROOT}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"

cmake --build . -j"$(nproc)"
cmake --install .

nebula_bench_install_standalone_conf "${PROFILE}" "${INSTALL_DIR}" "${BENCH_ROOT}"

echo "Installed to ${INSTALL_DIR} (profile=${PROFILE})"
