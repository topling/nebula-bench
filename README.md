# nebula-bench

NebulaGraph 性能对比编排仓库（仅 bash + workflow + 配置）。

> **项目铁律**（硬性约束，变更须维护者确认）：[`PROJECT_IRON_RULES.md`](PROJECT_IRON_RULES.md)

- checkout [topling/nebula](https://github.com/topling/nebula) `@toplingdb-bench`（ToplingDB 动态链接集成，见 nebula README ToplingDB 节）
- 性能用例复用 nebula 官方 `tests/bench/`
- 三组并行：RocksDB 基线 / ToplingDB conservative / enterprise

## 本仓库

| 路径 | 说明 |
|------|------|
| [`PROJECT_IRON_RULES.md`](PROJECT_IRON_RULES.md) | 项目铁律 |
| `.github/workflows/benchmark.yml` | CI |
| `scripts/*.sh` | 构建、启动、跑 bench |
| `conf/*.conf` | standalone 端口与数据路径模板（`@NEBULA_DATA_DIR@`） |

## 目录约定（均在 `${NEBULA_ROOT}` 下）

| 用途 | RocksDB | ToplingDB（conservative / enterprise） |
|------|---------|----------------------------------------|
| Nebula 编译 | `build-rocksdb` | `build-topling`（共用） |
| 二进制 install | `install-rocksdb` | `install-topling`（共用） |
| 运行数据 | `data-rocksdb/` | `data-conservative/`、`data-enterprise/` |
| ToplingDB 库编译 | — | 兄弟目录 `../toplingdb`（源码树内 make） |

测毕产出（`${NEBULA_ROOT}/tests/.pytest/`，AI 友好 JSON）：

| 文件 | 说明 |
|------|------|
| `benchmark-ci-<profile>.json` | pytest-benchmark 原始性能 |
| `benchmark-ci-<profile>-data.json` | 数据目录尺寸 |
| `benchmark-ci-<profile>-report.json` | 单 profile 合并报告（`document_type=nebula_bench_profile_result`） |
| `benchmark-run-report.json` | workflow 合并总报告（artifact `benchmark-run-report`） |

日志中搜索 `NEBULA_BENCH_PROFILE_REPORT_JSON=` / `NEBULA_BENCH_RUN_REPORT_JSON=` 可机器采集单行 JSON。

## nebula `toplingdb-bench` 分支与构建参数

nebula 上游已集成 ToplingDB 动态链接（`USE_TOPLINGDB`、`EXTERNAL_TOPLINGDB_ROOT`、`RocksEngineConfig` API 兼容层）。本仓库编排：

| Profile | CMake 要点 |
|---------|------------|
| **rocksdb** | `-DUSE_TOPLINGDB=OFF`，使用 third-party `librocksdb.a` |
| **conservative / enterprise** | `-DEXTERNAL_TOPLINGDB_ROOT=${TOPLINGDB_ROOT}`，链 `librocksdb.so`（仅 shared） |

ToplingDB **须 shared 链接**——见 [`PROJECT_IRON_RULES.md`](PROJECT_IRON_RULES.md) 铁律 #1。  
性能基准**只准调用 nebula 官方 `tests/bench/`**——见 [`PROJECT_IRON_RULES.md`](PROJECT_IRON_RULES.md) 铁律 #2。

以下两个 yaml 仅为开箱即用的 Easy Migrate 示例，编译运行不依赖它们；本仓库 bench 启动脚本会引用它们做 conservative / enterprise 对比：

- `conf/topling-mimic-rocksdb.yaml` — conservative（mimic RocksDB）
- `conf/topling-enterprise.yaml` — enterprise
