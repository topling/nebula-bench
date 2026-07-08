# 项目铁律

本文件是 **nebula-bench 仓库的硬性约束**，对人、对 CI、对 AI 均有效。  
未经项目维护者**书面确认**，下列事项一律不得实施。

---

## 铁律 #1：ToplingDB 须 shared 链接

**适用范围**：`conservative`、`enterprise` profile（凡使用 ToplingDB 的路径）。

### 已定契约

| 项 | 要求 |
|----|------|
| Nebula 链接库 | ToplingDB 源码树内的 **`librocksdb.so`（shared only）** |
| 配置方式 | cmake `-DEXTERNAL_TOPLINGDB_ROOT=...`（`USE_TOPLINGDB=ON`，nebula 默认） |
| 运行时加载 | `LD_LIBRARY_PATH` 含 `${TOPLINGDB_ROOT}`（见 `scripts/run-standalone-topling.sh`） |
| ToplingDB 构建 | CI/本地仅 `make shared_lib`，**不**构建 `static_lib` 用于 Nebula |

### 明确禁止

1. `make static_lib` 或链接 **`librocksdb.a`** 给 Nebula × ToplingDB
2. 修改 nebula `FindRocksdb.cmake` 的 `find_library`，使 `librocksdb.a` 优先于 `librocksdb.so`
3. 新增 `bench-patch-*-rocksdb-link*` 等脚本，在 CI 中篡改 Nebula 链接逻辑
4. 以「绕过 undefined reference / ABI」为由，静默改为 static、whole-archive、或 third-party 头 + Topling 静态库混链

### 与 `rocksdb` profile 的区分（不得混谈）

- **`rocksdb` profile**：cmake `-DUSE_TOPLINGDB=OFF`，Nebula 使用 third-party 内置 **`librocksdb.a`**，与 ToplingDB **无关**
- 上述铁律**只**约束 ToplingDB profile，不得把 ToplingDB 链接失败归咎于「ToplingDB 本身有问题」而未先查编排是否违反本铁律

### 逃生路线（唯一合规出口）

链接失败、undefined reference、ABI 对不上时，**不得**改链接模型。唯一允许的出路：

| 步骤 | 做什么 | 不做什么 |
|------|--------|----------|
| 1 | ToplingDB 只 `make shared_lib`，产出 `librocksdb.so` | `make static_lib`、`librocksdb.a` |
| 2 | Nebula cmake `-DEXTERNAL_TOPLINGDB_ROOT=...` 链 `.so` | 改 `find_library` 优先级、patch 链接脚本、patch `RocksEngineConfig` |
| 3 | 运行时 `LD_LIBRARY_PATH` 含 `${TOPLINGDB_ROOT}` | 静态 whole-archive、third-party 头 + Topling 静库混链 |
| 4 | 仍失败 → 去 **ToplingDB 或 nebula `toplingdb-bench` 仓库**修根因 | 在本仓库偷偷换 static / 混链 |

**一句话**：卡住也只能继续走 shared 这条路；没有「换 static 就能过」的旁门。

### 链接失败时的排查流程

1. 先核对编排是否违反上文（是否误触 `static_lib`、是否缺 `LD_LIBRARY_PATH`）
2. 定位根因（头文件来源、库来源、API 签名）
3. 在 ToplingDB / nebula 对应仓库提修复——**不得**在本仓库改链接契约

---

## 铁律 #2：性能基准只准调用 Nebula 官方 benchmark

**适用范围**：本仓库一切 CI、本地 bench 编排、脚本与 AI 生成的改动。

### 已定契约

| 项 | 要求 |
|----|------|
| 性能用例来源 | **仅** nebula 仓库 `tests/bench/` 下官方用例（如 `insert.py`、`lookup.py`、`delete.py` 等，以 checkout 的 nebula ref 为准） |
| 执行方式 | 通过 pytest 调用上述官方文件；可传 `--address`、`--benchmark-json` 等既有 pytest 选项 |
| 本仓库职责 | **编排**（启停、采盘、compact、报告合并）、**补丁**（`bench-patch-nebula-tests.sh` 对 upstream 最小 workaround）、**配置** |
| 读/写性能数据 | 必须来自官方 benchmark 的 pytest-benchmark 输出，不得由本仓库自写 pytest 用例产出 |

### 明确禁止

1. 在本仓库新增 **pytest 性能测试**（含 `Test*` 类、`@pytest.mark.benchmark`、复制官方逻辑后改 space/查询的「仿官方」脚本）
2. 将自写 Python 测试复制进 `nebula/tests/bench/` 或以任何路径冒充官方 benchmark
3. 以「官方用例不满足场景」为由，**静默**新增测读写性能的替代测试；若官方确实不够，须维护者书面确认后改 **nebula 上游** `tests/bench/`，而非本仓库
4. 用 shell/curl 手写 nGQL 循环冒充 benchmark 并写入 `-report.json` 的 `performance` 段

### 允许（不属于「自写 benchmark」）

| 类型 | 示例 | 说明 |
|------|------|------|
| 编排脚本 | `bench-compact-spaces.py`、`bench-storage-record.py`、`bench-wait-graph-ready.py` | 不产出 pytest-benchmark 性能曲线 |
| upstream 补丁 | `bench-patch-nebula-tests.sh` | 仅修复 `--address`、delay、SKIP_CLEANUP 等运行期问题，**不**新增 benchmark 用例 |
| 报告/合并 | `ci-benchmark-emit-profile-report.py`、`ci-benchmark-merge-reports.py` | 消费官方 benchmark JSON |

### 逃生路线（唯一合规出口）

需要新性能场景或 insert/compact 前后读对比时：

| 步骤 | 做什么 | 不做什么 |
|------|--------|----------|
| 1 | 查 nebula `tests/bench/` 是否已有对应用例 | 在本仓库新建 `bench-*-*.py` 测试 |
| 2 | 编排层多次调用**同一官方文件**（如 compact 前后各跑 `lookup.py`），用 env 区分阶段 | 复制 lookup 逻辑写「read_post_insert」类脚本 |
| 3 | 官方确实缺能力 → 向 **nebula `toplingdb-bench`** 提 PR 扩展 `tests/bench/` | 在本仓库长期维护平行测试套件 |
| 4 | 仅采盘/compact 指标 → 用 `bench-storage-record.py` 等编排脚本 | 用自写查询测读性能 |

**一句话**：性能数字必须来自 nebula 官方 `tests/bench/`；本仓库只编排、补丁、采盘与报告，**不得擅自当测试作者**。

---

## 修订

新增铁律请在本文件追加「铁律 #N」，并在 `README.md` 登记。
