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

nebula_bench_du_disk_bytes() {
  local path=$1
  echo $(( $(du -sk "${path}" | cut -f1) * 1024 ))
}

# 测完后记录数据目录占用；stdout 为实际占盘可读格式，并写入 JSON。
# data_dir_bytes / storage_bytes / meta_bytes 均为 du -sk 块占用（非 du -sb 逻辑长度）。
nebula_bench_record_data_dir_size() {
  local profile=$1
  local out_json="${2:-${NEBULA_ROOT}/tests/.pytest/benchmark-ci-${profile}-data.json}"
  local data_dir bytes storage_bytes meta_bytes disk_bytes storage_disk meta_disk
  local apparent_bytes storage_apparent meta_apparent human stage

  data_dir="$(nebula_bench_data_dir "${profile}")"
  if [[ ! -d "${data_dir}" ]]; then
    echo "data dir not found: ${data_dir}" >&2
    return 1
  fi

  disk_bytes="$(nebula_bench_du_disk_bytes "${data_dir}")"
  bytes="${disk_bytes}"
  storage_disk=0
  meta_disk=0
  storage_apparent=0
  meta_apparent=0
  if [[ -d "${data_dir}/storage" ]]; then
    storage_disk="$(nebula_bench_du_disk_bytes "${data_dir}/storage")"
    storage_bytes="${storage_disk}"
    storage_apparent="$(du -sb "${data_dir}/storage" | cut -f1)"
  else
    storage_bytes=0
  fi
  if [[ -d "${data_dir}/meta" ]]; then
    meta_disk="$(nebula_bench_du_disk_bytes "${data_dir}/meta")"
    meta_bytes="${meta_disk}"
    meta_apparent="$(du -sb "${data_dir}/meta" | cut -f1)"
  else
    meta_bytes=0
  fi
  apparent_bytes="$(du -sb "${data_dir}" | cut -f1)"
  human="$(nebula_bench_format_bytes "${bytes}")"
  stage="${NEBULA_BENCH_STORAGE_STAGE:-post_insert_pre_drop}"

  mkdir -p "$(dirname "${out_json}")"
  cat > "${out_json}" <<EOF
{
  "profile": "${profile}",
  "data_dir": "${data_dir}",
  "measurement_stage": "${stage}",
  "measurement_method": "du -sk (disk blocks)",
  "data_dir_bytes": ${bytes},
  "data_dir_disk_bytes": ${disk_bytes},
  "data_dir_apparent_bytes": ${apparent_bytes},
  "storage_bytes": ${storage_bytes},
  "storage_disk_bytes": ${storage_disk},
  "storage_apparent_bytes": ${storage_apparent},
  "meta_bytes": ${meta_bytes},
  "meta_disk_bytes": ${meta_disk},
  "meta_apparent_bytes": ${meta_apparent}
}
EOF

  printf '%s' "${human}"
}
