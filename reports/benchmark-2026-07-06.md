# NebulaGraph × ToplingDB 性能对比报告

**Workflow**：[#28817653689](https://github.com/topling/nebula-topling-bench/actions/runs/28817653689)（`b775110`，最新）  
**日期**：2026-07-06

## 日志结论（以 Actions 为准）

| Profile | ToplingDB `shared_lib` | Nebula 编译 | Benchmark 失败点 |
|---------|------------------------|-------------|------------------|
| **rocksdb** | — | ✅ | pytest：`Host not enough!`（`SHOW HOSTS` 空结果即误判就绪） |
| **conservative** | ✅ | ❌ | **编排错误**：`static_lib` + `bench-patch-nebula-rocksdb-link.sh` 改链 `librocksdb.a` |
| **enterprise** | ✅ | ❌ | 同上 |

ToplingDB 构建与 `librocksdb.so` 产出正常；conservative/enterprise 链接失败是 **nebula-topling-bench 擅自改链接方式** 导致，不是 ToplingDB 有问题。

## rocksdb 根因

Run `28817653689` job `rocksdb`：

1. standalone 启动成功，端口 `9669` 就绪  
2. `bench-wait-graph-ready.py` 用 `SHOW HOSTS` **仅判断 `is_succeeded()`**，空表也通过  
3. pytest `prepare` → `CREATE SPACE` → **`Host not enough!`**

修复：等待 `SHOW HOSTS` 出现 **ONLINE** 的 storage 行后再跑 bench。

## conservative / enterprise 根因（b775110）

同一 run 日志：

```
[ci-benchmark:conservative] building ToplingDB static lib
[ci-benchmark:conservative] rebuilding ToplingDB shared_lib ...
bash .../bench-patch-nebula-rocksdb-link.sh
...
undefined reference to rocksdb::GetDBOptionsFromMap ...
```

违反 [`PROJECT_IRON_RULES.md`](../PROJECT_IRON_RULES.md) **铁律 #1**（须 shared 链接；已在本仓库回滚）。

## 复现

https://github.com/topling/nebula-topling-bench/actions/workflows/benchmark.yml
