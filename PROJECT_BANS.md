# 项目禁令

本文件是 **nebula-bench 仓库的硬性约束**，对人、对 CI、对 AI 均有效。  
未经项目维护者**书面确认**，下列事项一律不得实施。

---

## 禁令 #1：ToplingDB 禁止 static 链接

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
- 上述禁令**只**约束 ToplingDB profile，不得把 ToplingDB 链接失败归咎于「ToplingDB 本身有问题」而未先查编排是否违反本禁令

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

## 修订

新增禁令请在本文件追加「禁令 #N」，并在 `README.md` 登记。
