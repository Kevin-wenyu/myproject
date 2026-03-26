# pg 企业级 DBA 工具增强设计

**版本**: 1.0
**日期**: 2026-03-26
**作者**: Kevin

## 目标

将 pg 工具从"碎片化命令集"升级为"DBA 专家诊断工具"，提供可靠、深入、场景化的诊断能力。

## 用户需求

- **信息分散**: 诊断问题需要手动组合多个命令
- **输出不够深入**: 缺少根因分析和优化建议
- **结果可靠性**: 格式不一致、边界处理不完善
- **特定场景缺失**: 连接池、复制故障、性能抖动等

## 实现方案

采用增强单体架构，保持工具简洁，按优先级分四个模块实现。

---

## 模块一：可靠性修复（P0）

### 1.1 输出格式标准化

**统一规范**:
- 表格输出：列对齐、表头分隔线、一致列宽
- 空结果：`[INFO] No results found`
- 错误信息：`[ERROR] <具体原因>`
- 警告信息：`[WARN] <具体原因>`
- 数值格式：百分比保留1位小数，大数字千分位分隔

### 1.2 边界处理框架

新增通用函数：

```bash
# 统一错误处理
safe_execute() {
  local cmd="$1"
  local fallback="${2:-}"
  result=$(eval "$cmd" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    case "$result" in
      *"permission denied"*)  echo "[ERROR] Permission denied - check role privileges" ;;
      *"does not exist"*)     echo "[WARN] Required object not found" ;;
      *"connection"*)         echo "[ERROR] Connection failed" ;;
      *)                      echo "[ERROR] $result" ;;
    esac
    [ -n "$fallback" ] && eval "$fallback"
    return 1
  fi
  echo "$result"
}

# 扩展依赖检测
require_extension() {
  local ext="$1"
  if [ -z "$(extension_installed "$ext")" ]; then
    echo "[WARN] Extension '$ext' not installed"
    return 1
  fi
  return 0
}

# 权限检测
require_privilege() {
  local privilege="$1"
  local has_priv
  has_priv=$(q "SELECT has_database_privilege(current_database(), '$privilege');" 2>/dev/null)
  if [ "$has_priv" != "t" ]; then
    echo "[WARN] Missing privilege: $privilege"
    return 1
  fi
  return 0
}

# 空结果处理
handle_empty_result() {
  local result="$1"
  local message="${2:-No results found}"
  if [ -z "$result" ] || [ "$result" = " " ]; then
    echo "[INFO] $message"
    return 0
  fi
  echo "$result"
}
```

### 1.3 版本兼容性

扩展 `init_version_features()`:

```bash
init_version_features() {
  # pg_stat_statements 列名兼容
  init_pg_stat_statements_columns

  # 等待事件视图
  if [ "$PG_MAJOR_VERSION" -ge 10 ]; then
    WAIT_EVENTS_QUERY="SELECT event_type, event, count(*) FROM pg_stat_wait_events..."
  else
    WAIT_EVENTS_QUERY="SELECT wait_event_type, wait_event, count(*) FROM pg_stat_activity..."
  fi

  # 复制特性
  HAS_REPLICATION_SLOTS=$([ "$PG_MAJOR_VERSION" -ge 10 ] && echo true || echo false)

  # 进程管理
  if [ "$PG_MAJOR_VERSION" -ge 14 ]; then
    PG_TERMINATE_BACKEND="pg_terminate_backend(pid, 60)"  # 带超时
  else
    PG_TERMINATE_BACKEND="pg_terminate_backend(pid)"
  fi
}
```

---

## 模块二：输出深度增强（P1）

### 2.1 慢查询增强命令 `slow_enhanced`

**输出结构**:
```
╔══════════════════════════════════════════════════════╗
║ PID: 12345 | Duration: 45s | User: app_user          ║
╠══════════════════════════════════════════════════════╣
║ QUERY:                                               ║
║ SELECT * FROM orders WHERE status = 'pending'        ║
╠══════════════════════════════════════════════════════╣
║ EXECUTION PLAN:                                      ║
║ [!] Seq Scan on orders (cost=0.00..1M rows=5M)      ║
║ [!] Estimated vs Actual: 5M vs 127 rows             ║
╠══════════════════════════════════════════════════════╣
║ WAIT EVENTS:                                         ║
║ DataFileRead: 32s (71%) | BufferPin: 8s (18%)       ║
╠══════════════════════════════════════════════════════╣
║ SUGGESTIONS:                                         ║
║ * Missing index on orders(status)                    ║
║ * Statistics outdated (last analyzed: 3 days ago)    ║
╚══════════════════════════════════════════════════════╝
```

**实现要点**:
- 自动 EXPLAIN ANALYZE（需要权限）
- 等待事件分析（查询 pg_stat_activity 的 wait_event）
- 优化建议生成（基于查询模式和表统计）

### 2.2 锁问题增强命令 `blocking_enhanced`

**输出结构**:
```
╔══════════════════════════════════════════════════════╗
║ BLOCKING CHAIN (3 levels)                            ║
╠══════════════════════════════════════════════════════╣
║ L1: PID 1001 (AccessExclusiveLock on orders)        ║
║  └─ L2: PID 1002 (waiting for AccessShareLock)      ║
║      └─ L3: PID 1003 (waiting for RowShareLock)     ║
╠══════════════════════════════════════════════════════╣
║ ROOT CAUSE:                                          ║
║ PID 1001: ALTER TABLE orders ADD COLUMN ...          ║
║ Running for 12 minutes (DDL during peak hours)       ║
╠══════════════════════════════════════════════════════╣
║ IMPACT: 5 sessions waiting, 8 minutes total wait     ║
╠══════════════════════════════════════════════════════╣
║ ACTIONS:                                             ║
║ * pg cancel 1001    (try cancel first)              ║
║ * pg kill 1001      (if cancel fails)               ║
║ * Schedule DDL during maintenance window             ║
╚══════════════════════════════════════════════════════╝
```

### 2.3 现有命令增强

| 命令 | 新增字段/功能 |
|------|--------------|
| `top_time` | shared_blks_hit, shared_blks_read, temp_blks_written |
| `cache_hit` | 趋势指示 (stable ↑↓), 阈值判断 (< 90% 警告) |
| `wait_events` | 事件类型解读, TOP 3 等待占比 |
| `bloat` | 建议操作 (VACUUM FULL / REINDEX / 考虑重建) |
| `idle_tx` | 持续时间, 持锁情况, 建议操作 |
| `repl_lag` | 延迟原因分析, 积压趋势 |

---

## 模块三：组合诊断命令（P2）

### 3.1 命令入口

```bash
pg diagnose <场景> [参数]

场景列表:
  slow_query [pid]    慢查询完整诊断
  lock_issue          锁问题完整诊断
  connection          连接问题诊断
  replication         复制问题诊断
  performance         性能下降诊断
  health              综合健康检查
```

### 3.2 场景实现

**slow_query 诊断流程**:
1. 查询基本信息 (`slow_enhanced`)
2. 相关查询分析 (`top_time`, `top_io`)
3. 系统状态 (`wait_events`, `cache_hit`)
4. 整合建议

**lock_issue 诊断流程**:
1. 锁链分析 (`blocking_enhanced`)
2. 锁详情 (`locks`, `lock_chain`)
3. 相关事务 (`idle_tx`, `long_txs`)
4. 根因分析和操作建议

**connection 诊断流程**:
1. 连接概览 (`conn`, `conn_limit`)
2. 连接来源分析
3. 问题连接识别 (`idle_tx`, 长时间 idle)
4. 连接池建议

**replication 诊断流程**:
1. 复制状态 (`repl`, `repl_lag`)
2. Slot 状态 (`slot`, `slot_usage`)
3. 延迟分析和风险提示

**performance 诊断流程**:
1. 快速健康检查 (`health`, `cache_hit`)
2. 资源消耗 (`io_stats`, `temp_files`)
3. 问题查询 (`top_time`, `top_io`)
4. 优化建议

**health 诊断流程**:
1. 全面检查（组合多个现有命令）
2. 问题汇总（按严重程度排序）
3. 建议操作

---

## 模块四：新增诊断场景（P3）

### 4.1 连接池诊断

```bash
cmd_connection_diagnosis() {
  # 连接来源分布
  q "SELECT application_name, client_addr, count(*)
     FROM pg_stat_activity GROUP BY 1, 2 ORDER BY 3 DESC;"

  # 连接泄漏检测 (idle > 10min)
  q "SELECT pid, usename, application_name, query_start, state
     FROM pg_stat_activity
     WHERE state = 'idle' AND query_start < now() - interval '10 minutes';"

  # 连接风暴检测
  # 分析最近连接建立时间分布

  # 连接池配置建议
  # 基于当前连接数和 max_connections 计算
}
```

### 4.2 复制诊断

```bash
cmd_replication_diagnosis() {
  # 延迟详情
  cmd_repl_lag

  # Slot 积压
  cmd_slot_usage

  # 复制冲突（如果有）
  q "SELECT * FROM pg_stat_database_conflicts;"

  # 延迟原因分析
  # 基于 write_lag, flush_lag, replay_lag 分析瓶颈
}
```

### 4.3 性能抖动诊断

```bash
cmd_performance_diagnosis() {
  # 当前状态快照
  cmd_cache_hit
  cmd_io_stats
  cmd_wait_events

  # 周期性指标对比
  # 需要两次采样，计算变化率

  # 资源竞争识别
  cmd_locks
  cmd_blocking
}
```

### 4.4 容量规划

```bash
cmd_capacity_analysis() {
  # 表增长趋势
  q "SELECT schemaname, relname,
       pg_size_pretty(pg_total_relation_size(relid)) as size,
       n_live_tup, n_dead_tup
     FROM pg_stat_user_tables
     ORDER BY pg_total_relation_size(relid) DESC LIMIT 20;"

  # 索引膨胀评估
  cmd_bloat

  # 存储空间预测
  cmd_db_size
  cmd_ts_size
}
```

---

## 文件结构

保持单体脚本，按模块组织：

```
pg (单体脚本)
├── 1-500:     配置与工具函数
├── 500-600:   可靠性基础设施 (新增)
├── 600-1500:  基础命令 (优化边界处理)
├── 1500-2200: 增强命令 (新增 slow_enhanced, blocking_enhanced)
├── 2200-2800: 组合诊断命令 (新增 diagnose 入口)
├── 2800-3200: 新诊断场景 (新增)
└── 3200+:     调度器 (扩展)
```

---

## 实现顺序

1. **P0 可靠性修复** - 基础设施函数 + 现有命令边界处理
2. **P1 输出增强** - slow_enhanced, blocking_enhanced + 现有命令增强
3. **P2 组合诊断** - diagnose 命令 + 5个诊断场景
4. **P3 新场景** - 连接池、复制、性能抖动、容量规划

---

## 测试策略

1. 回归测试: 现有 `pg_regression_test.sh` 保持通过
2. 边界测试: 无数据库连接、权限不足、扩展未安装
3. 版本测试: PostgreSQL 12/14/16 兼容性
4. 输出测试: 验证格式一致性