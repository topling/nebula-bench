# Source after BENCH_ROOT and NEBULA_ROOT are set. Exports BENCH_PYTHON.
: "${BENCH_ROOT:?BENCH_ROOT must be set}"
: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"
_bench_venv="${BENCH_ROOT}/.venv-bench-ci"
if [[ ! -x "${_bench_venv}/bin/python" ]]; then
  if ! python3 -m venv "${_bench_venv}" 2>/dev/null; then
    rm -rf "${_bench_venv}"
    if [[ "${CI:-}" == "true" || "${INSTALL_SYSTEM_DEPS:-}" == "1" ]]; then
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip
      python3 -m venv "${_bench_venv}"
    else
      echo "failed to create ${_bench_venv}; install python3-venv" >&2
      exit 1
    fi
  fi
fi
"${_bench_venv}/bin/pip" install -q -r "${BENCH_ROOT}/requirements-bench-ci.txt"
BENCH_PYTHON="${_bench_venv}/bin/python"
export BENCH_PYTHON
