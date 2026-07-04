#!/usr/bin/env bash
# Seed tests/.pytest/{nebula,spaces} for official bench when using --address
# (nebula-test-run.py normally writes these when it starts the cluster).
set -euo pipefail

: "${NEBULA_ROOT:?NEBULA_ROOT must be set}"
: "${BENCH_PROFILE:?BENCH_PROFILE must be set}"

port=9669
case "${BENCH_PROFILE}" in
  conservative) port=39669 ;;
  enterprise) port=49669 ;;
esac

tmpdir="${NEBULA_ROOT}/tests/.pytest"
mkdir -p "${tmpdir}"

printf '%s\n' \
  "{\"ip\":\"127.0.0.1\",\"port\":[${port}],\"work_dir\":\"/tmp/nebula-bench\",\"enable_ssl\":\"false\",\"enable_graph_ssl\":\"false\",\"ca_signed\":\"false\"}" \
  > "${tmpdir}/nebula"

printf '%s\n' \
  '[{"name":"nba","vid_type":"FIXED_STRING(32)","partition_num":10,"replica_factor":1,"charset":"utf8","collate":"utf8_bin"},{"name":"student","vid_type":"FIXED_STRING(32)","partition_num":10,"replica_factor":1,"charset":"utf8","collate":"utf8_bin"}]' \
  > "${tmpdir}/spaces"
