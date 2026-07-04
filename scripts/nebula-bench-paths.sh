#!/usr/bin/env bash
# 数据目录与 install 前缀分离；conservative/enterprise 共用 install-topling 二进制。

nebula_bench_data_dir() {
  : "${NEBULA_ROOT:?NEBULA_ROOT must be set}"
  echo "${NEBULA_ROOT}/data-${1}"
}

nebula_bench_conf_src() {
  local profile=$1 bench_root=$2
  case "${profile}" in
    rocksdb) echo "${bench_root}/conf/nebula-standalone-bench.conf" ;;
    conservative) echo "${bench_root}/conf/nebula-standalone-topling-conservative.conf" ;;
    enterprise) echo "${bench_root}/conf/nebula-standalone-topling-enterprise.conf" ;;
    *)
      echo "unknown profile: ${profile}" >&2
      return 1
      ;;
  esac
}

nebula_bench_validate_profile() {
  case "${1}" in
    rocksdb|conservative|enterprise) return 0 ;;
    *)
      echo "unknown profile: ${1}" >&2
      return 1
      ;;
  esac
}

nebula_bench_format_bytes() {
  local bytes=$1
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "${bytes}"
  else
    printf '%sB' "${bytes}"
  fi
}

# preflight：conf 模板须含 4 处 @NEBULA_DATA_DIR@（pid/log/storage/meta）
nebula_bench_check_conf_templates() {
  local bench_root=$1
  local conf count
  for conf in \
    nebula-standalone-bench.conf \
    nebula-standalone-topling-conservative.conf \
    nebula-standalone-topling-enterprise.conf
  do
    if [[ ! -f "${bench_root}/conf/${conf}" ]]; then
      echo "missing conf template: conf/${conf}" >&2
      return 1
    fi
    count="$(grep -cF '@NEBULA_DATA_DIR@' "${bench_root}/conf/${conf}" || true)"
    if [[ "${count}" -ne 4 ]]; then
      echo "conf/${conf}: expected 4x @NEBULA_DATA_DIR@, got ${count}" >&2
      return 1
    fi
  done
}

nebula_bench_install_standalone_conf() {
  local profile=$1 install_dir=$2 bench_root=$3
  local data_dir src
  data_dir="$(nebula_bench_data_dir "${profile}")"
  src="$(nebula_bench_conf_src "${profile}" "${bench_root}")"
  mkdir -p "${data_dir}/storage" "${data_dir}/meta" "${data_dir}/logs" "${data_dir}/pids"
  sed "s|@NEBULA_DATA_DIR@|${data_dir}|g" "${src}" > "${install_dir}/etc/nebula-standalone.conf"
  rm -f "${install_dir}/cluster.id"
  ln -sf "${data_dir}/cluster.id" "${install_dir}/cluster.id"
}

# 测完后记录数据目录占用；stdout 为逻辑字节的可读格式（与 JSON 一致），并写入 JSON。
nebula_bench_record_data_dir_size() {
  local profile=$1
  local out_json="${2:-${NEBULA_ROOT}/tests/.pytest/benchmark-ci-${profile}-data.json}"
  local data_dir bytes storage_bytes meta_bytes disk_bytes human

  data_dir="$(nebula_bench_data_dir "${profile}")"
  if [[ ! -d "${data_dir}" ]]; then
    echo "data dir not found: ${data_dir}" >&2
    return 1
  fi

  bytes="$(du -sb "${data_dir}" | cut -f1)"
  if [[ -d "${data_dir}/storage" ]]; then
    storage_bytes="$(du -sb "${data_dir}/storage" | cut -f1)"
  else
    storage_bytes=0
  fi
  if [[ -d "${data_dir}/meta" ]]; then
    meta_bytes="$(du -sb "${data_dir}/meta" | cut -f1)"
  else
    meta_bytes=0
  fi
  disk_bytes="$(( $(du -sk "${data_dir}" | cut -f1) * 1024 ))"
  human="$(nebula_bench_format_bytes "${bytes}")"

  mkdir -p "$(dirname "${out_json}")"
  cat > "${out_json}" <<EOF
{
  "profile": "${profile}",
  "data_dir": "${data_dir}",
  "data_dir_bytes": ${bytes},
  "data_dir_disk_bytes": ${disk_bytes},
  "storage_bytes": ${storage_bytes},
  "meta_bytes": ${meta_bytes}
}
EOF

  printf '%s' "${human}"
}
