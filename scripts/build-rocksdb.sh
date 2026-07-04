#!/usr/bin/env bash
set -euo pipefail

: "${BENCH_ROOT:?BENCH_ROOT must be set}"
: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"

NEBULA_TP="${NEBULA_THIRDPARTY_ROOT:-${NEBULA_ROOT}/build/third-party/install}"
BUILD_DIR="${BUILD_DIR:-${NEBULA_ROOT}/build-rocksdb}"
INSTALL_DIR="${INSTALL_DIR:-${NEBULA_ROOT}/install-rocksdb}"

if [[ ! -d "${NEBULA_TP}/include" ]]; then
  echo "Nebula third-party not found: ${NEBULA_TP}" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# rocksdb 基线：关闭 USE_TOPLINGDB，使用 third-party 内置 librocksdb.a
env -u EXTERNAL_TOPLINGDB_ROOT cmake .. \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DENABLE_STANDALONE_VERSION=ON \
  -DENABLE_TESTING=OFF \
  -DENABLE_WERROR=OFF \
  -DUSE_TOPLINGDB=OFF \
  -DNEBULA_THIRDPARTY_ROOT="${NEBULA_TP}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"

cmake --build . -j"$(nproc)"
cmake --install .

# shellcheck source=nebula-bench-paths.sh
source "${BENCH_ROOT}/scripts/nebula-bench-paths.sh"
nebula_bench_install_standalone_conf rocksdb "${INSTALL_DIR}" "${BENCH_ROOT}"
echo "Installed RocksDB baseline to ${INSTALL_DIR}"
