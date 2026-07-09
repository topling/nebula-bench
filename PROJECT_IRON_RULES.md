# 项目铁律

本文件是 **nebula-topling-bench 仓库的硬性约束**，对人、对 CI、对 AI 均有效。  
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
| 本仓库职责 | **编排**（启停、采盘、compact、报告合并）、**配置**；**不得** patch checkout 出的 nebula 源码（见铁律 #5） |
| 读/写性能数据 | 必须来自官方 benchmark 的 pytest-benchmark 输出，不得由本仓库自写 pytest 用例产出 |

### 明确禁止

1. 在本仓库新增 **pytest 性能测试**（含 `Test*` 类、`@pytest.mark.benchmark`、复制官方逻辑后改 space/查询的「仿官方」脚本）
2. 将自写 Python 测试复制进 `nebula/tests/bench/` 或以任何路径冒充官方 benchmark
3. 以「官方用例不满足场景」为由，**静默** workaround（含 patch、自写用例）；须**报错停工**，等维护者书面确认后再定方案
4. 用 shell/curl 手写 nGQL 循环冒充 benchmark 并写入 `-report.json` 的 `performance` 段

### 允许（不属于「自写 benchmark」）

| 类型 | 示例 | 说明 |
|------|------|------|
| 编排脚本 | `bench-compact-spaces.py`、`bench-storage-record.py`、`bench-wait-graph-ready.py` | 不产出 pytest-benchmark 性能曲线 |
| 报告/合并 | `ci-benchmark-emit-profile-report.py`、`ci-benchmark-merge-reports.py` | 消费官方 benchmark JSON |

### 逃生路线（唯一合规出口）

需要新性能场景或 insert/compact 前后读对比时：

| 步骤 | 做什么 | 不做什么 |
|------|--------|----------|
| 1 | 查 nebula `tests/bench/` 是否已有对应用例 | 在本仓库新建 `bench-*-*.py` 测试 |
| 2 | 编排层多次调用**同一官方文件**（如 compact 前后各跑 `lookup.py`），用 env 区分阶段 | 复制 lookup 逻辑写「read_post_insert」类脚本 |
| 3 | 官方缺能力 → **报错停工**，等维护者书面决策 | patch、自写平行测试、改报告糊弄 |
| 4 | 仅采盘/compact 指标 → 用 `bench-storage-record.py` 等编排脚本 | 用自写查询测读性能 |

**一句话**：性能数字必须来自 nebula 官方 `tests/bench/`；本仓库只编排、采盘与报告，**不得 patch upstream、不得擅自当测试作者**。

---

## 铁律 #3：本地 NebulaGraph 源码树只读参考

**适用范围**：AI 与本仓库维护者在排查 nebula 上游行为、git 历史、用例语义时。

### 已定契约

| 项 | 要求 |
|----|------|
| 本地路径 | 兄弟目录 **`../nebulagraph-toplingdb`**（相对本仓库根；对应 [topling/nebulagraph](https://github.com/topling/nebulagraph) 本地 checkout） |
| 允许用途 | **只读**交叉访问：读源码、查 `git log` / `git blame` / diff、对照 `tests/bench/` 与历史变更 |
| 编译与测试 | **不得**以其为 `NEBULA_ROOT` 做本仓库 bench 的编译、启动 standalone 或 pytest benchmark |
| 权威 checkout | CI 与本仓库脚本规定的 nebula 来源仍为 workflow / 环境变量 checkout 的 **`topling/nebula` `@toplingdb-bench`**（或维护者书面指定的 ref） |

### 明确禁止

1. 将 `../nebulagraph-toplingdb` 设为 `NEBULA_ROOT` 运行 `scripts/ci-benchmark-*.sh`、`build-*.sh`、`run-standalone-*.sh`
2. 在该目录内执行 `make` / `cmake --build` / pytest benchmark，并把结果当作本仓库 bench 的验收依据
3. 未维护者确认，把该树内的文件路径或 ref 写进 CI workflow 替代 `topling/nebula` checkout

### 允许（不属于违规）

| 类型 | 示例 | 说明 |
|------|------|------|
| 读源码 | `tests/bench/lookup.py`、历史 commit 中的用例实现 | 理解 upstream 语义、定位 CI 失败根因 |
| 查 git 历史 | `git log -p -- tests/bench/lookup.py` | 追溯「何时引入写数 / index 语法」等 |
| 对照 diff | 与 CI checkout 的 `topling/nebula` 同路径文件比对 | 不替代 CI 源码树 |

**一句话**：`../nebulagraph-toplingdb` 是**参考书**，不是本仓库 bench 的**编译测试树**。

---

## 铁律 #4：官方用例名不符实须报错，禁止 patch 绕路

**适用范围**：编排任务所需语义与 nebula 任何官方脚本**文件名 / 用例名所暗示的行为**不一致，且若不 patch upstream 文件就无法完成目标时。

### 何谓「名不符实」

| 表现 | 示例 |
|------|------|
| 文件名暗示只读，实际含大量写数 | `lookup.py` 的 `prepare()` 建 space 并 `insert_vertices` ~1M，benchmark 段才是 LOOKUP |
| 编排目标与用例数据域不一致 | bench 要「insert 后读 / compact 后读」，官方用例却读写另一 space、或第二次 pytest 必须跳过 `prepare` 插数 |
| patch 改的是**测试语义**而非挂载方式 | sed 注入 `NEBULA_BENCH_LOOKUP_QUERY_ONLY` 改写 `prepare()` 分支；为凑场景改 space / 查询 / 阶段生命周期 |

### 已定契约

| 项 | 要求 |
|----|------|
| AI / 维护者发现上述缺口 | **立即停止**，向维护者**书面报告**（现象、官方脚本实际行为、与编排目标的差距） |
| 等待决策 | 维护者书面确认前，**不得** patch、自写用例、改报告语义等方式让 CI 「看起来跑通」 |
| 后续怎么走 | **由维护者决定**（缩 scope、换 ref、改编排目标等）；AI **不得**自行选定「去上游修」或其他出路 |

### 明确禁止

1. 发现名不符实仍 **patch** checkout 出的 nebula 文件（含 `bench-patch-nebula-tests.sh`），**静默改** `prepare()` / `cleanup()` / benchmark 逻辑以「完成任务」（见铁律 #5）
2. 把 patch 后的行为仍标成 `read_post_insert`、`lookup_official` 等**误导性**报告字段而不说明语义已变
3. 以「先跑通 CI 再说」为由跳过报告，直接 push

### 报告最少须含

1. 编排目标（一句话）
2. 官方脚本名与实际行为（附路径 / 函数，如 `tests/bench/lookup.py::prepare`）
3. 为何「不 patch 就完不成」或「patch 会改语义」
4. 可选应对方向（**仅供维护者选用**，AI 不得擅自执行）：调整 bench 目标 / 换 checkout ref / 暂缓该阶段指标 / 其他维护者书面指定的出路

**一句话**：官方用例**名不符实**且要靠 patch 才能凑任务时，**报错停工**；**不得 patch**（见铁律 #5），**不得** AI 自行决定去上游修。

---

## 铁律 #5：不得 patch checkout 出的 nebula 源码

**适用范围**：CI / 本地 bench 所用 **`NEBULA_ROOT`** 下一切文件（含 `tests/bench/`、`tests/common/`、`cmake/` 等 checkout 产物）。

### 已定契约

| 项 | 要求 |
|----|------|
| nebula 源码 | 以 workflow / 环境 checkout 的 ref 为准，**原样**使用 |
| 本仓库允许改动 | 仅 **nebula-topling-bench 自身**路径（`scripts/`、`conf/`、workflow 等），不得写入 `${NEBULA_ROOT}` |
| 官方能力不足 | **报错停工**（见铁律 #4）；**不得 patch**；后续**仅维护者**书面决策 |
| pytest 传参 | 仅使用 upstream 已支持的 CLI 选项（如 `--address`、`--benchmark-json`）；**不得**靠 sed / 运行时注入改 upstream 文件 |

### 明确禁止

1. 运行、`source` 或维护 **`bench-patch-nebula-tests.sh`** 及一切 `bench-patch-nebula-*` 脚本
2. 对 `${NEBULA_ROOT}` 做 `sed -i`、Python 改写、`cp` 覆盖——无论动机是语法修、delay、SKIP_CLEANUP、QUERY_ONLY 或 `--address`
3. patch **`nebula_test_suite.py`** 等 checkout 内公共测试基建
4. 在 preflight / CI 中**校验 patch marker 存在**（如要求文件含 `NEBULA_BENCH_SKIP_CLEANUP`）——等于把 patch 固化为契约

### 缺口出现时的流程

| 步骤 | 做什么 | 不做什么 |
|------|--------|----------|
| 1 | 对照官方 `tests/bench/` 与编排目标，确认缺口 | patch |
| 2 | **书面报告**维护者，**停工** | `bench-patch-*.sh`、自写 workaround |
| 3 | 等维护者书面决策后再动 | AI 自行 push、自行「去上游修」、临时 patch |

**一句话**：**checkout 出的 nebula 一行都不许改**；缺能力 → **报错停工**，**零 patch**，出路**只由维护者定**。

---

## 修订

新增铁律请在本文件追加「铁律 #N」，并在 `README.md` 登记。
