# NebulaGraph × ToplingDB 性能对比报告

**Workflow**：[topling/nebula-bench #28741557759](https://github.com/topling/nebula-bench/actions/runs/28741557759)  
**日期**：2026-07-05  
**分支**：`nebula-bench@dc06e7b` · `topling/nebula@toplingdb-bench` (`b8868c248`)  
**结论**：❌ 三组均未产出有效 benchmark 数据

## 概要

| Profile | Preflight | 编译 | Benchmark | 结果 |
|---------|-----------|------|-----------|------|
| **rocksdb**（基线） | ✅ | ✅ | ❌ pytest | 无性能数据 |
| **conservative**（ToplingDB mimic） | ✅ | ❌ 链接 | — | 无性能数据 |
| **enterprise**（ToplingDB） | ✅ | ❌ 链接 | — | 无性能数据 |

用例：nebula 官方 `tests/bench/insert.py` + `lookup.py`（20000×50 ≈ 1M 点/边）。

## 各组详情

### rocksdb（第三方 `librocksdb.a`）

- **编译/安装**：成功，`install-rocksdb` 可用。
- **Standalone**：已启动，graph 端口 `9669` 就绪。
- **Benchmark 失败**：
  ```
  FileNotFoundError: .../nebula/tests/.pytest/nebula
  ```
  原因：通过 `--address` 外挂 standalone 时，官方测试框架仍要求 `tests/.pytest/nebula` 与 `tests/.pytest/spaces`（ normally 由 `nebula-test-run.py` 写入），CI 未初始化。
- **Artifact**：`benchmark-rocksdb.json` 仅 166 字节，无有效 benchmark 条目。

### conservative / enterprise（ToplingDB `librocksdb.so`）

- **ToplingDB**：clone + `make shared_lib` 成功。
- **Nebula 编译失败**（链接阶段）：
  ```
  undefined reference to `rocksdb::GetDBOptionsFromMap(...)`
  undefined reference to `rocksdb::GetColumnFamilyOptionsFromMap(...)`
  undefined reference to `rocksdb::GetBlockBasedTableOptionsFromMap(...)`
  undefined reference to `rocksdb::NewLRUCache(...)`
  ```
  位置：`src/kvstore/RocksEngineConfig.cpp`
- **后续**：因 `install-{profile}` 未生成，`run-standalone-topling.sh` 报 `No such file or directory`。
- **Artifact**：无 benchmark JSON。

## 根因分析

1. **rocksdb pytest 环境**（nebula-bench 可修）：编排层未 seed `tests/.pytest/*` 状态文件。
2. **ToplingDB 链接 ABI**（需 nebula 侧决策）：Nebula 用 third-party 头文件编译 `RocksEngineConfig.cpp`，但链接 ToplingDB 的 `librocksdb.so`；符号签名/导出与 bundled RocksDB 不一致，导致 undefined reference。仅改 `FindRocksdb.cmake` 不足以完成链接，除非 ToplingDB 与 Nebula 所用 RocksDB API 完全兼容，或 Nebula 增加最小适配。

## 本轮 nebula-bench CI 修复（已合并）

| Commit | 内容 |
|--------|------|
| `22705cd` | `requirements-bench-ci.txt` 替代 legacy `tests/requirements.txt` |
| `dc06e7b` | `bench-patch-nebula-tests.sh` 修补 upstream `lookup.py` |
| `2654c97` | Preflight 改为 import 校验 |
| `8791278` / `dc06e7b` | lookup 语法补丁 |

## 后续行动

| 优先级 | 项 | 负责 |
|--------|-----|------|
| P0 | `bench-seed-pytest-state.sh` 在跑 pytest 前写入 `.pytest/nebula` + `.pytest/spaces` | nebula-bench（本 commit，待下轮 workflow 验证） |
| P0 | ToplingDB 链接 undefined reference：对齐头文件/库版本或最小 src 适配 | nebula `toplingdb-bench`（需确认是否允许超出 `FindRocksdb.cmake`） |
| P1 | 下轮 workflow 通过后，本报告追加 benchmark 数值表 | nebula-bench |

## 复现

```bash
# 仅通过 GitHub Actions
# https://github.com/topling/nebula-bench/actions/workflows/benchmark.yml
```
