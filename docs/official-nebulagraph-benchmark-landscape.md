---
document_type: nebula_official_benchmark_landscape
version: "1.0"
last_updated: "2026-07-08"
language: zh-CN
scope: upper_layer_official_only
out_of_scope:
  - nebula/tests/bench/          # pytest-benchmark，仓库内工程用例，非官方对外 benchmark 主链路
  - nebula/src/**/test/*Benchmark.cpp
  - nebula/build/bin/*_bm
  - nebula/src/tools/storage-perf/  # Storage RPC 压测工具，非集群 nGQL 上层 bench
primary_official_toolchain:
  - https://github.com/vesoft-inc/nebula-bench
  - https://github.com/vesoft-inc/k6-plugin
  - https://github.com/vesoft-inc/nebula-importer
  - https://github.com/ldbc/ldbc_snb_datagen_spark
official_docs_entry:
  - https://docs.nebula-graph.io/master/nebula-bench/
---

# NebulaGraph 官方上层 Benchmark 全景（AI 参考）

> 本文档汇总 **vesoft 官方对外 benchmark 体系**（集群级、LDBC 数据集、k6 压测、官方报告）。
> ** deliberately 不包含** nebula 源码仓库内的工程内 bench（`tests/bench/`、`*Benchmark.cpp`、`storage_perf` 等）。

---

## 1. 范围定义

### 1.1 IN_SCOPE（本文覆盖）

| 类别 | 说明 |
|------|------|
| **官方压测工具链** | NebulaGraph Bench + k6-plugin + Importer + LDBC SNB 数据 |
| **官方 Benchmark 报告** | nebula-graph.io 发布的版本性能报告 |
| **官方文档中的性能口径** | 监控指标定义、LDBC 背景、调优文档引用的 bench 场景 |
| **官方转载的第三方对比** | 美团、腾讯云等（引用性质，非标准复现路径） |

### 1.2 OUT_OF_SCOPE（本文不覆盖）

| 路径/产物 | 性质 | 为何不纳入「上层官方 bench」 |
|-----------|------|------------------------------|
| `nebula/tests/bench/` | pytest-benchmark 端到端小数据集用例 | 未出现在官方文档 / nebula-bench 主流程；`tests/README.md` 未提及 |
| `nebula/src/**/test/*Benchmark.cpp` → `*_bm` | 模块级微基准可执行文件 | 开发/PR 自测，无官方使用文档 |
| `nebula/src/tools/storage-perf/` | Storage RPC 压测（getNeighbors 等） | Storage 层工具；CMake 常默认注释；非 graphd 全链路 |
| TCK `profiling query` | 执行计划校验 | 正确性/优化器，非吞吐延迟压测 |

### 1.3 与「本仓库 nebula-topling-bench（topling）」的关系

| 维度 | vesoft 官方上层 bench | 本仓库 `topling/nebula-topling-bench` |
|------|----------------------|-------------------------------|
| 用例来源 | `vesoft-inc/nebula-bench` 的 k6 场景 | nebula `tests/bench/`（工程内） |
| 数据 | LDBC SNB（SF1～SF100+） | 用例内自建小 space |
| 目标 | 版本发布性能报告、集群压测 | ToplingDB vs RocksDB 编排对比 |
| 官方性 | vesoft 文档入口 |  fork 编排仓库，**不是** vesoft 官方 nebula-bench |

AI 在讨论「NebulaGraph 官方 benchmark」时，应默认指向 **vesoft-inc/nebula-bench 工具链**，而非 nebula 仓库 `tests/bench/`。

---

## 2. 官方上层工具链（核心）

### 2.1 组件与职责

```text
ldbc_snb_datagen ──► NebulaGraph Bench (run.py data)
        │
        ▼
nebula-importer ◄── NebulaGraph Bench (run.py import)
        │
        ▼
   NebulaGraph 集群 (metad / storaged / graphd)
        │
        ▼
k6 + k6-plugin (xk6-nebula) ◄── NebulaGraph Bench (run.py stress run)
        │
        ▼
   output/  (JSON/CSV 结果)
```

| 组件 | 官方仓库 | 职责 |
|------|----------|------|
| **NebulaGraph Bench** | [vesoft-inc/nebula-bench](https://github.com/vesoft-inc/nebula-bench) | 造数、导入、调度 k6 场景 |
| **k6-plugin** | [vesoft-inc/k6-plugin](https://github.com/vesoft-inc/k6-plugin) | k6 扩展，经 nebula-go 连接 graphd |
| **nebula-importer** | [vesoft-inc/nebula-importer](https://github.com/vesoft-inc/nebula-importer) | 批量导入 LDBC 数据（Bench 依赖 **Importer v3.x**；v4.x 尚未支持） |
| **LDBC SNB datagen** | [ldbc_snb_datagen_spark v0.3.3](https://github.com/ldbc/ldbc_snb_datagen_spark/tree/v0.3.3) | 标准 SNB 数据集生成 |

### 2.2 官方文档入口

- 主入口：[NebulaGraph Bench - Database Manual](https://docs.nebula-graph.io/master/nebula-bench/)
- 流程说明（较细）：[3.0.1 nebula-bench](https://docs.nebula-graph.io/3.0.1/nebula-bench/) — 明确三步：datagen → Importer → K6 + XK6-Nebula
- LDBC 背景：[Related technologies - LDBC](https://docs.nebula-graph.io/3.0.2/1.introduction/0-2.relates/)

### 2.3 标准执行命令

```bash
git clone https://github.com/vesoft-inc/nebula-bench.git
cd nebula-bench
pip3 install -r requirements.txt
./scripts/setup.sh          # 编译 importer、k6 等

python3 run.py data         # 生成 LDBC 数据
python3 run.py import       # 导入集群（需配置 NEBULA_* 环境变量）
python3 run.py stress scenarios                    # 列出场景
python3 run.py stress run                          # 跑全部场景（默认 vu/时长见 README）
python3 run.py stress run -scenario go.Go1StepEdge --args='-u 10 -d 3s'
```

场景定义目录：`nebula_bench/scenarios/`  
结果输出目录：`output/`（如 `result_Go1Step.json`）

### 2.4 版本配套矩阵（节选，以 nebula-bench release 为准）

| NebulaGraph Bench | NebulaGraph | k6-plugin | NebulaGraph Importer |
|-------------------|-------------|-----------|----------------------|
| v1.2.0 | v3.1.0 | v1.0.0 | v3.1.0 |
| v1.1.0 | v3.0.x | v0.0.9 | v3.0.x |
| v1.0.0 | v2.6.x | v0.0.8 | v2.6.x |

复现官方报告前，**必须**按上表对齐 tag，不可混用未验证版本。

---

## 3. 官方 Benchmark 报告

### 3.1 统一免责声明（所有官方报告均含）

> 以 LDBC SNB 为**参考起点**；**未经 LDBC 审计**；**不是** LDBC 官方 Benchmark Results。

### 3.2 社区版报告

| 版本 | URL | 数据集 | 集群配置（报告内） | 压测工具 |
|------|-----|--------|-------------------|----------|
| v3.4.0 | [v3.4.0-benchmark-report](https://nebula-graph.io/posts/v3.4.0-benchmark-report) | LDBC-SNB **SF100**（~100GB，约 2.82 亿点 / 17.7 亿边） | 24 分区 × 3 副本 | k6 + nebula-go |
| v3.5.0 | [nebulagraph-benchmark-3.5.0](https://nebula-graph.io/posts/nebulagraph-benchmark-3.5.0) | 同上 SF100 | 同上 | k6 + nebula-go |

**v3.4.0 基线**：对比官方发布版 **v3.3.0**。

### 3.3 企业版报告（节选）

| 版本 | URL | 说明 |
|------|-----|------|
| Enterprise v5.0 Preview | [technical-preview-of-nebulagraph-enterprise-v5.0](https://nebula-graph.io/posts/technical-preview-of-nebulagraph-enterprise-v5.0) | LDBC SNB **Interactive**；P99 延迟；GQL vs openCypher；SF100 三节点集群 |

### 3.4 官方报告中的典型用例名

与 `nebula-bench` 场景 / 报告章节对应，AI 检索时可作关键词：

| 类别 | 用例名 / 模式 |
|------|----------------|
| GO | `Go1StepEdge`, `Go2StepEdge`, `Go3StepEdge`, `Go1~3 StepEdge_count` |
| MATCH | `MatchTest1`～`MatchTest5`, `MATCH Index`, `MATCH Two-Hop`, `MATCH count`, `Match2HOP_count` |
| LOOKUP | LOOKUP 索引扫描类 |
| 路径 | `FindShortestPath`, `FIND ALL PATH`（v3.5 重点优化） |

### 3.5 指标口径（官方报告统一）

| 指标 | 定义 |
|------|------|
| **Latency** | 服务端处理时间（k6-plugin / nebula-go 返回） |
| **ResponseTime** | Latency + 网络传输 + 客户端反序列化 |
| **vu** | k6 virtual user，即并发用户数（如 `50_vu` = 50 并发） |
| **QPS** | 报告图表中的吞吐（视具体用例） |

---

## 4. 官方文档中的性能相关内容（非完整 bench 套件）

| 文档 | URL | 用途 |
|------|-----|------|
| Query performance metrics | [监控指标](https://docs.nebula-graph.io/3.5.0/6.monitor-and-metrics/1.query-performance-metrics/) | 运行时 `query_latency_us`, `slow_query_latency_us`, `num_slow_queries` 等 |
| Enable AutoFDO | [AutoFDO 调优](https://docs.nebula-graph.io/3.4.2/8.service-tuning/enable_autofdo_for_nebulagraph/) | 用 nebula-bench 场景（FindShortestPath、Go1Step 等）对比编译优化 |
| NebulaGraph Bench 文档 | [master/nebula-bench](https://docs.nebula-graph.io/master/nebula-bench/) | 官方对外 benchmark 唯一文档入口 |

---

## 5. 官方渠道转载的第三方对比（非标准复现）

发在 nebula-graph.io、由外部团队执行；**工具链与 nebula-bench 不完全相同**：

| 文章 | URL |
|------|-----|
| 美团：NebulaGraph vs Dgraph vs JanusGraph | [benchmarking-mainstream-graph-databases](https://www.download.nebula-graph.io/posts/benchmarking-mainstraim-graph-databases-dgraph-nebula-graph-janusgraph) |
| 腾讯云：Neo4j vs NebulaGraph vs JanusGraph | [performance-comparison](https://nebula-graph.io/posts/performance-comparison-neo4j-janusgraph-nebula-graph) |

归类：**选型参考**，不能替代 nebula-bench 标准流程。

---

## 6. 决策树（AI 快速路由）

```text
用户问「NebulaGraph 官方怎么测性能？」
  └─► 是集群级 / 发布报告口径？
        ├─ 是 → vesoft-inc/nebula-bench + LDBC SNB + k6-plugin
        │       文档: docs.nebula-graph.io/.../nebula-bench/
        └─ 否 → 是否 nebula 源码仓库内 *Benchmark.cpp / tests/bench？
              ├─ 是 → OUT_OF_SCOPE（工程内，非官方上层）
              └─ 否 → 是否运行时监控？
                    └─ 是 → query_latency_us 等 HTTP metrics
```

```text
用户问「如何复现 v3.5 官方报告？」
  1. 部署 NebulaGraph v3.5.0（24 分区 × 3 副本）
  2. checkout nebula-bench 与 v3.5 配套的 release tag
  3. 导入 LDBC-SNB SF100
  4. k6 跑报告列出的场景（Go/MATCH/LOOKUP/FIND ALL PATH）
  5. 对比 Latency / ResponseTime / vu 维度
  ✗ 不要跑 nebula/build/bin/get_neighbors_bm
  ✗ 不要跑 nebula/tests/bench/
```

---

## 7. 结构化摘要（machine-readable）

```json
{
  "official_upper_layer_benchmark": {
    "orchestrator": "vesoft-inc/nebula-bench",
    "load_generator": "k6 + vesoft-inc/k6-plugin",
    "data_pipeline": ["ldbc_snb_datagen_spark", "vesoft-inc/nebula-importer"],
    "dataset_standard": "LDBC SNB (SF100 in v3.4/v3.5 reports)",
    "docs": "https://docs.nebula-graph.io/master/nebula-bench/",
    "reports": [
      "https://nebula-graph.io/posts/v3.4.0-benchmark-report",
      "https://nebula-graph.io/posts/nebulagraph-benchmark-3.5.0",
      "https://nebula-graph.io/posts/technical-preview-of-nebulagraph-enterprise-v5.0"
    ]
  },
  "excluded_internal_bench": {
    "nebula/tests/bench": "pytest-benchmark, not in official docs",
    "nebula/src/**/test/*Benchmark.cpp": "module micro-benchmarks (*_bm)",
    "nebula/src/tools/storage-perf": "storage RPC perf tool, often disabled in CMake"
  },
  "this_repo_nebula_topling_bench": {
    "repo": "topling/nebula-topling-bench",
    "uses": "nebula/tests/bench (internal, OUT_OF_SCOPE for official landscape)",
    "purpose": "ToplingDB vs RocksDB orchestration",
    "not_same_as": "vesoft-inc/nebula-bench"
  }
}
```

---

## 8. 参考链接速查

| 资源 | URL |
|------|-----|
| NebulaGraph Bench 仓库 | https://github.com/vesoft-inc/nebula-bench |
| k6-plugin | https://github.com/vesoft-inc/k6-plugin |
| nebula-importer | https://github.com/vesoft-inc/nebula-importer |
| 官方 Bench 文档 | https://docs.nebula-graph.io/master/nebula-bench/ |
| v3.4.0 报告 | https://nebula-graph.io/posts/v3.4.0-benchmark-report |
| v3.5.0 报告 | https://nebula-graph.io/posts/nebulagraph-benchmark-3.5.0 |
| LDBC 官网 | https://ldbc.github.io/ |

---

## 9. 维护说明

- 本文基于 2026-07-08 对 vesoft 官方文档、nebula-graph.io 报告、GitHub 公开仓库的调研。
- 若 vesoft 发布新版本报告或 nebula-bench release 矩阵变更，应更新 §2.4、§3.2 与 §7 JSON。
- 本文**不**描述 nebula 源码内工程 bench 的编译与运行方式。
