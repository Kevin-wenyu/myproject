# pg 企业级 DBA 工具增强实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 pg 工具升级为企业级 DBA 诊断工具，提供可靠、深入、场景化的诊断能力。

**Architecture:** 增强单体架构，在现有 pg 脚本中添加可靠性基础设施、增强命令、组合诊断入口和新诊断场景。

**Tech Stack:** Bash 4.0+, PostgreSQL 9.6-18, psql client

---

## 文件变更概览

| 文件 | 操作 | 说明 |
|------|------|------|
| `pg` | 修改 | 主脚本，添加所有新功能 |
| `pg_regression_test.sh` | 修改 | 添加新命令测试 |

---

## Phase 1: 可靠性基础设施 (P0)

### Task 1: 添加输出格式化工具函数

**Files:**
- Modify: `pg:105-120` (在 colorize 函数后添加)

- [ ] **Step 1: 在 colorize 函数后添加格式化工具函数**

在 `pg` 文件中，找到 `colorize()` 函数结束位置（约 116 行），在其后添加：

```bash

# ============================================
# OUTPUT FORMATTING UTILITIES
# ============================================

# 统一消息前缀
msg_info()  { echo "[INFO] $1"; }
msg_warn()  { colorize yellow "[WARN] $1"; }
msg_error() { colorize red "[ERROR] $1"; }

# 空结果处理
handle_empty() {
  local result="$1"
  local message="${2:-No results found}"
  if [ -z "$result" ] || [ "$result" = " " ] || [ "$result" = "" ]; then
    msg_info "$message"
    return 0
  fi
  echo "$result"
}

# 数值格式化 - 百分比保留1位小数
format_percent() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    printf "%.1f%%" "$value"
  else
    echo "$value"
  fi
}

# 数值格式化 - 大数字千分位
format_number() {
  local num="$1"
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    printf "%'d" "$num"
  else
    echo "$num"
  fi
}

# 表格分隔线
print_separator() {
  local width="${1:-80}"
  printf "%${width}s\n" | tr ' ' '-'
}
```

- [ ] **Step 2: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 3: 提交**

```bash
git add pg
git commit -m "feat: add output formatting utilities

- Add msg_info, msg_warn, msg_error for consistent messaging
- Add handle_empty for empty result handling
- Add format_percent and format_number for numeric formatting
- Add print_separator for table output

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: 添加错误处理工具函数

**Files:**
- Modify: `pg:165-190` (在 extension_installed 函数后添加)

- [ ] **Step 1: 在 extension_installed 函数后添加错误处理函数**

在 `extension_installed()` 函数后（约 188 行）添加：

```bash

# ============================================
# ERROR HANDLING UTILITIES
# ============================================

# 安全执行 - 统一错误处理
safe_execute() {
  local cmd="$1"
  local fallback="${2:-}"

  local result
  result=$(eval "$cmd" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    case "$result" in
      *"permission denied"*)
        msg_error "Permission denied - check role privileges"
        ;;
      *"does not exist"*)
        msg_warn "Required object not found"
        ;;
      *"connection"*|*"connect"*)
        msg_error "Connection failed - check PostgreSQL status and connection parameters"
        ;;
      *"syntax error"*)
        msg_error "SQL syntax error"
        ;;
      *)
        msg_error "$result"
        ;;
    esac
    [ -n "$fallback" ] && eval "$fallback"
    return 1
  fi
  echo "$result"
  return 0
}

# 扩展依赖检查 - 带提示
require_extension() {
  local ext="$1"
  local hint="${2:-Run: CREATE EXTENSION $ext;}"

  if [ -z "$(extension_installed "$ext")" ]; then
    msg_warn "Extension '$ext' not installed. $hint"
    return 1
  fi
  return 0
}

# 权限检查
require_privilege() {
  local privilege="$1"
  local has_priv
  has_priv=$(q "SELECT has_database_privilege(current_database(), '$privilege');" 2>/dev/null)
  if [ "$has_priv" != "t" ]; then
    msg_warn "Missing privilege: $privilege"
    return 1
  fi
  return 0
}

# 超级用户检查
require_superuser() {
  local is_superuser
  is_superuser=$(q "SELECT current_setting('is_superuser');" 2>/dev/null)
  if [ "$is_superuser" != "on" ]; then
    msg_warn "This command requires superuser privileges"
    return 1
  fi
  return 0
}
```

- [ ] **Step 2: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 3: 提交**

```bash
git add pg
git commit -m "feat: add error handling utilities

- Add safe_execute for unified error handling with context-aware messages
- Add require_extension for extension dependency checking with hints
- Add require_privilege and require_superuser for permission checks

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: 扩展版本兼容性检测

**Files:**
- Modify: `pg:142-166` (修改 init_pg_stat_statements_columns 和添加 init_version_features)

- [ ] **Step 1: 在 get_version 函数后添加 init_version_features 函数**

找到 `get_version()` 函数结束位置（约 142 行），在其后添加：

```bash

# ============================================
# VERSION COMPATIBILITY
# ============================================

init_version_features() {
  # pg_stat_statements 列名兼容 (PG 13+ 使用 total_exec_time)
  init_pg_stat_statements_columns

  # 等待事件 (PG 10+ 有独立的 pg_stat_wait_events, PG 17+ 有 pg_wait_events)
  if [ "$PG_MAJOR_VERSION" -ge 17 ]; then
    HAS_PG_WAIT_EVENTS=true
    WAIT_EVENTS_SOURCE="pg_wait_events"
  elif [ "$PG_MAJOR_VERSION" -ge 10 ]; then
    HAS_PG_WAIT_EVENTS=false
    WAIT_EVENTS_SOURCE="pg_stat_activity"
  else
    HAS_PG_WAIT_EVENTS=false
    WAIT_EVENTS_SOURCE="pg_stat_activity"
  fi

  # 复制槽 (PG 10+)
  HAS_REPLICATION_SLOTS=$([ "$PG_MAJOR_VERSION" -ge 10 ] && echo true || echo false)

  # 进程管理 (PG 14+ terminate_backend 支持超时参数)
  if [ "$PG_MAJOR_VERSION" -ge 14 ]; then
    PG_TERMINATE_FUNC="pg_terminate_backend(pid, 60)"
  else
    PG_TERMINATE_FUNC="pg_terminate_backend(pid)"
  fi

  # Checkpoint 统计 (PG 17+)
  HAS_PG_STAT_CHECKPOUNTS=$([ "$PG_MAJOR_VERSION" -ge 17 ] && echo true || echo false)

  # WAL 指标 (PG 18+ pg_stat_statements 可能有 wal_fpi 列)
  if [ "$PG_MAJOR_VERSION" -ge 18 ]; then
    # 动态检测新列
    local has_wal_metrics
    has_wal_metrics=$(echo "SELECT 1 FROM pg_attribute WHERE attrelid = 'pg_stat_statements'::regclass AND attname = 'wal_fpi' LIMIT 1;" | $PSQL_CMD -t -A 2>/dev/null || echo "")
    HAS_WAL_METRICS=$([ -n "$has_wal_metrics" ] && echo true || echo false)
  else
    HAS_WAL_METRICS=false
  fi
}
```

- [ ] **Step 2: 修改主流程调用 init_version_features**

找到 `get_version` 调用位置，在其后添加 `init_version_features` 调用。在脚本中搜索调用 `get_version` 的地方，确保在其后调用 `init_version_features`。

- [ ] **Step 3: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 4: 提交**

```bash
git add pg
git commit -m "feat: add version compatibility detection for PG 9.6-18

- Add init_version_features() for comprehensive version feature detection
- Support PG 17+ pg_wait_events and pg_stat_checkpoints
- Support PG 18+ potential wal_fpi column in pg_stat_statements
- Support PG 14+ terminate_backend with timeout

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: 更新现有命令使用可靠性工具

**Files:**
- Modify: `pg:600-900` (基础命令区域)

- [ ] **Step 1: 更新 cmd_slow 使用空结果处理**

找到 `cmd_slow()` 函数，修改为使用 `handle_empty`：

```bash
cmd_slow()
{
  local threshold="${1:-5}"

  if ! require_extension pg_stat_statements; then
    return 1
  fi

  local result
  result=$(run_stat_statements "SELECT pid, now() - pg_stat_activity.query_start AS duration, query
    FROM pg_stat_activity
    WHERE (pg_stat_activity.state != 'idle' AND pg_stat_activity.state != 'idle in transaction')
      AND pg_stat_activity.query_start IS NOT NULL
      AND now() - pg_stat_activity.query_start > interval '$threshold seconds'
    ORDER BY duration DESC;" 2>&1)

  handle_empty "$result" "No queries running longer than $threshold seconds"
}
```

- [ ] **Step 2: 更新 cmd_blocking 使用空结果处理**

找到 `cmd_blocking()` 函数，在输出前添加空结果检查：

```bash
cmd_blocking()
{
  local result
  result=$(q "SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS current_statement_in_blocking_process,
    blocked_activity.application_name AS blocked_application
  FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
    JOIN pg_catalog.pg_locks blocking_locks
      ON blocking_locks.locktype = blocked_locks.locktype
      AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
      AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
      AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
      AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
      AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
      AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
      AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
      AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
      AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
      AND blocking_locks.pid != blocked_locks.pid
    JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
  WHERE NOT blocked_locks.GRANTED;")

  handle_empty "$result" "No blocking sessions detected"
}
```

- [ ] **Step 3: 更新 cmd_unused_indexes 使用空结果处理**

找到 `cmd_unused_indexes()` 函数，添加空结果处理：

```bash
cmd_unused_indexes()
{
  local limit="${1:-20}"

  local result
  result=$(q "SELECT
    schemaname || '.' || relname AS table,
    indexrelname AS index,
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
    idx_scan as index_scans
  FROM pg_stat_user_indexes ui
  JOIN pg_index i ON ui.indexrelid = i.indexrelid
  WHERE NOT i.indisunique
    AND idx_scan < 50
    AND pg_relation_size(i.indexrelid) > 1024 * 1024
  ORDER BY pg_relation_size(i.indexrelid) DESC
  LIMIT $limit;")

  handle_empty "$result" "No unused indexes found"
}
```

- [ ] **Step 4: 运行回归测试验证**

Run: `./pg_regression_test.sh`
Expected: 所有测试通过

- [ ] **Step 5: 提交**

```bash
git add pg
git commit -m "fix: update existing commands to use reliability utilities

- Add empty result handling to cmd_slow, cmd_blocking, cmd_unused_indexes
- Add extension requirement check to cmd_slow
- Improve user experience with clear messages when no results

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Phase 2: 输出深度增强 (P1)

### Task 5: 添加慢查询增强命令 slow_enhanced

**Files:**
- Modify: `pg:1500-1600` (在慢查询命令区域后添加)

- [ ] **Step 1: 添加 cmd_slow_enhanced 函数**

在 `cmd_slow()` 函数后添加新函数：

```bash

# ============================================
# ENHANCED SLOW QUERY DIAGNOSIS
# ============================================

cmd_slow_enhanced()
{
  local pid="$1"
  local threshold="${2:-5}"

  colorize blue "=== SLOW QUERY ENHANCED DIAGNOSIS ==="
  echo ""

  # 如果指定了 PID，分析特定查询
  if [ -n "$pid" ]; then
    analyze_specific_query "$pid"
    return
  fi

  # 否则列出所有慢查询供选择
  colorize yellow "CURRENT SLOW QUERIES (>${threshold}s):"
  echo ""

  local slow_queries
  slow_queries=$(q "SELECT pid,
    round(EXTRACT(EPOCH FROM (now() - query_start))::numeric, 2) as duration_sec,
    usename,
    application_name,
    state,
    wait_event_type || ':' || wait_event as wait_event,
    left(query, 100) || CASE WHEN length(query) > 100 THEN '...' ELSE '' END as query_preview
  FROM pg_stat_activity
  WHERE state IN ('active', 'idle in transaction')
    AND query_start IS NOT NULL
    AND now() - query_start > interval '$threshold seconds'
    AND query NOT LIKE '%pg_stat_activity%'
  ORDER BY now() - query_start DESC;")

  if [ -z "$slow_queries" ] || [ "$slow_queries" = " " ]; then
    msg_info "No slow queries found (running > ${threshold}s)"
    return 0
  fi

  echo "$slow_queries"
  echo ""
  msg_info "Run 'pg slow_enhanced <PID>' for detailed analysis of a specific query"
}

analyze_specific_query()
{
  local pid="$1"

  colorize blue "=== QUERY ANALYSIS FOR PID $pid ==="
  echo ""

  # 基本信息
  colorize yellow "BASIC INFO:"
  q "SELECT
    pid,
    usename as user,
    application_name as app,
    client_addr::text as client,
    round(EXTRACT(EPOCH FROM (now() - query_start))::numeric, 2) as duration_sec,
    state,
    wait_event_type || ':' || wait_event as wait_event
  FROM pg_stat_activity
  WHERE pid = $pid;"

  if [ $? -ne 0 ]; then
    msg_error "Process $pid not found or query error"
    return 1
  fi
  echo ""

  # 完整查询文本
  colorize yellow "QUERY TEXT:"
  local query_text
  query_text=$(q "SELECT query FROM pg_stat_activity WHERE pid = $pid;" 2>/dev/null)
  if [ -n "$query_text" ]; then
    echo "$query_text" | fold -s -w 80
  else
    msg_warn "Could not retrieve query text"
  fi
  echo ""

  # 等待事件分析
  colorize yellow "WAIT EVENT ANALYSIS:"
  local wait_info
  wait_info=$(q "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $pid;" 2>/dev/null)
  if [ -n "$wait_info" ] && [ "$wait_info" != " " ]; then
    echo "Current wait: $wait_info"
    # 等待事件解读
    local wait_type wait_event
    wait_type=$(echo "$wait_info" | cut -d'|' -f1)
    wait_event=$(echo "$wait_info" | cut -d'|' -f2)
    interpret_wait_event "$wait_type" "$wait_event"
  else
    echo "No active wait event"
  fi
  echo ""

  # 优化建议
  colorize yellow "OPTIMIZATION SUGGESTIONS:"
  generate_query_suggestions "$pid" "$query_text"
  echo ""

  # 可用操作
  colorize yellow "AVAILABLE ACTIONS:"
  echo "  pg cancel $pid     - Cancel the query"
  echo "  pg kill $pid       - Terminate the session"
  echo "  pg explain <sql>   - Get execution plan (copy query text)"
}

interpret_wait_event()
{
  local wait_type="$1"
  local wait_event="$2"

  case "$wait_type" in
    IO)
      case "$wait_event" in
        DataFileRead)   echo "  [!] IO bottleneck - reading from disk, consider increasing shared_buffers" ;;
        WALWrite)       echo "  [!] WAL write wait - disk bottleneck, check wal_sync_method" ;;
        *)              echo "  [i] IO wait: $wait_event" ;;
      esac
      ;;
    Lock)
      case "$wait_event" in
        relation)       echo "  [!] Table-level lock wait - check for blocking DDL/long transactions" ;;
        tuple)          echo "  [!] Row-level lock wait - concurrent updates on same rows" ;;
        transactionid)  echo "  [!] Transaction ID wait - long-running transaction blocking" ;;
        *)              echo "  [!] Lock wait: $wait_event - potential blocking issue" ;;
      esac
      ;;
    LwLock)
      case "$wait_event" in
        WALWriteLock)   echo "  [!] WAL lock contention - high write load" ;;
        BufferMapping)  echo "  [!] Buffer mapping contention - consider shared_buffers tuning" ;;
        *)              echo "  [i] Lightweight lock wait: $wait_event" ;;
      esac
      ;;
    Activity)
      echo "  [i] Waiting for: $wait_event"
      ;;
    *)
      echo "  [i] Wait type: $wait_type, event: $wait_event"
      ;;
  esac
}

generate_query_suggestions()
{
  local pid="$1"
  local query="$2"

  if [ -z "$query" ]; then
    echo "  - Cannot analyze empty query"
    return
  fi

  # 检测全表扫描特征
  if echo "$query" | grep -qiE "SELECT \*|SELECT .* FROM .* WHERE"; then
    echo "  - Consider adding specific columns instead of SELECT *"
  fi

  # 检测 LIKE '%...%' 模式
  if echo "$query" | grep -qiE "LIKE '%[^%]+%'"; then
    echo "  - Leading wildcard LIKE prevents index usage, consider pg_trgm extension"
  fi

  # 检测 OR 条件
  if echo "$query" | grep -qiE "\bOR\b"; then
    echo "  - OR conditions may prevent index usage, consider UNION or rewrite"
  fi

  # 检测子查询
  if echo "$query" | grep -qiE "\(SELECT"; then
    echo "  - Subquery detected, consider using JOINs or CTEs for better optimization"
  fi

  # 检测 DISTINCT
  if echo "$query" | grep -qiE "\bDISTINCT\b"; then
    echo "  - DISTINCT requires sorting/hashing, ensure proper indexes"
  fi

  # 通用建议
  echo "  - Run 'pg explain <query>' to analyze execution plan"
  echo "  - Check if table statistics are up to date (pg vacuum_status)"
}
```

- [ ] **Step 2: 在调度器中注册新命令**

在 `dispatch_command()` 函数中添加：

```bash
    slow_enhanced)          cmd_slow_enhanced "$@" ;;
```

- [ ] **Step 3: 在 usage() 中添加帮助文本**

在帮助文本的慢查询区域添加：

```bash
    slow_enhanced [pid] [sec]  Enhanced slow query analysis with suggestions
```

- [ ] **Step 4: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 5: 提交**

```bash
git add pg
git commit -m "feat: add slow_enhanced command for deep query analysis

- Show detailed query info: duration, wait events, full query text
- Add wait event interpretation with actionable insights
- Generate optimization suggestions based on query patterns
- Provide available actions (cancel/kill/explain)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: 添加锁问题增强命令 blocking_enhanced

**Files:**
- Modify: `pg:1600-1700` (在 blocking 命令区域后添加)

- [ ] **Step 1: 添加 cmd_blocking_enhanced 函数**

在 `cmd_blocking()` 函数后添加：

```bash

# ============================================
# ENHANCED LOCK CHAIN DIAGNOSIS
# ============================================

cmd_blocking_enhanced()
{
  colorize blue "=== BLOCKING CHAIN ENHANCED DIAGNOSIS ==="
  echo ""

  # 检查是否有阻塞
  local blocking_exists
  blocking_exists=$(q "SELECT count(*) FROM pg_locks bl1
    JOIN pg_locks bl2 ON bl1.locktype = bl2.locktype
      AND bl1.database IS NOT DISTINCT FROM bl2.database
      AND bl1.relation IS NOT DISTINCT FROM bl2.relation
      AND bl1.page IS NOT DISTINCT FROM bl2.page
      AND bl1.tuple IS NOT DISTINCT FROM bl2.tuple
      AND bl1.virtualxid IS NOT DISTINCT FROM bl2.virtualxid
      AND bl1.transactionid IS NOT DISTINCT FROM bl2.transactionid
      AND bl1.classid IS NOT DISTINCT FROM bl2.classid
      AND bl1.objid IS NOT DISTINCT FROM bl2.objid
      AND bl1.objsubid IS NOT DISTINCT FROM bl2.objsubid
      AND bl1.pid != bl2.pid
      AND NOT bl1.granted AND bl2.granted;")

  if [ "$blocking_exists" -eq 0 ]; then
    msg_info "No blocking sessions detected"
    return 0
  fi
  echo ""

  # 阻塞链分析
  colorize yellow "BLOCKING CHAIN:"
  echo ""
  q "WITH RECURSIVE lock_tree AS (
    -- 根节点：持有锁的会话
    SELECT
      bl.pid AS holder_pid,
      bl.granted AS holder_granted,
      NULL::integer AS waiter_pid,
      1 AS level,
      ARRAY[bl.pid] AS path
    FROM pg_locks bl
    WHERE bl.granted = true
      AND EXISTS (
        SELECT 1 FROM pg_locks wl
        WHERE wl.locktype = bl.locktype
          AND wl.database IS NOT DISTINCT FROM bl.database
          AND wl.relation IS NOT DISTINCT FROM bl.relation
          AND wl.page IS NOT DISTINCT FROM bl.page
          AND wl.tuple IS NOT DISTINCT FROM bl.tuple
          AND wl.virtualxid IS NOT DISTINCT FROM bl.virtualxid
          AND wl.transactionid IS NOT DISTINCT FROM bl.transactionid
          AND wl.classid IS NOT DISTINCT FROM bl.classid
          AND wl.objid IS NOT DISTINCT FROM bl.objid
          AND wl.objsubid IS NOT DISTINCT FROM bl.objsubid
          AND wl.pid != bl.pid
          AND NOT wl.granted
      )

    UNION ALL

    -- 递归：等待的会话
    SELECT
      lt.holder_pid,
      lt.holder_granted,
      wl.pid AS waiter_pid,
      lt.level + 1,
      lt.path || wl.pid
    FROM lock_tree lt
    JOIN pg_locks wl ON wl.locktype = (
        SELECT bl.locktype FROM pg_locks bl
        WHERE bl.pid = lt.holder_pid AND bl.granted = true
        LIMIT 1
      )
      AND wl.database IS NOT DISTINCT FROM (
        SELECT bl.database FROM pg_locks bl
        WHERE bl.pid = lt.holder_pid AND bl.granted = true LIMIT 1
      )
      AND wl.relation IS NOT DISTINCT FROM (
        SELECT bl.relation FROM pg_locks bl
        WHERE bl.pid = lt.holder_pid AND bl.granted = true LIMIT 1
      )
      AND NOT wl.granted
      AND wl.pid != ALL(lt.path)
  )
  SELECT
    level,
    COALESCE(waiter_pid, holder_pid) AS pid,
    CASE WHEN waiter_pid IS NULL THEN 'HOLDER' ELSE 'WAITER' END AS role
  FROM lock_tree
  ORDER BY path, level;"
 2>/dev/null | while read -r line; do
    local level pid role
    level=$(echo "$line" | awk '{print $1}')
    pid=$(echo "$line" | awk '{print $2}')
    role=$(echo "$line" | awk '{print $3}')

    if [ "$role" = "HOLDER" ]; then
      printf "%sPID %s (HOLDER)\n" "$(printf '%*s' $((level*2)) '')" "$pid"
    else
      printf "%s└─ PID %s (WAITER)\n" "$(printf '%*s' $((level*2)) '')" "$pid"
    fi
  done
  echo ""

  # 根因分析
  colorize yellow "ROOT CAUSE ANALYSIS:"
  local root_pid root_query root_duration
  root_pid=$(q "SELECT bl.pid
    FROM pg_locks bl
    WHERE bl.granted = true
      AND EXISTS (
        SELECT 1 FROM pg_locks wl
        WHERE wl.locktype = bl.locktype
          AND wl.database IS NOT DISTINCT FROM bl.database
          AND wl.relation IS NOT DISTINCT FROM bl.relation
          AND NOT wl.granted
          AND wl.pid != bl.pid
      )
    ORDER BY bl.pid
    LIMIT 1;" 2>/dev/null)

  if [ -n "$root_pid" ] && [ "$root_pid" != " " ]; then
    root_query=$(q "SELECT left(query, 80) FROM pg_stat_activity WHERE pid = $root_pid;" 2>/dev/null)
    root_duration=$(q "SELECT round(EXTRACT(EPOCH FROM (now() - query_start))::numeric, 2) FROM pg_stat_activity WHERE pid = $root_pid;" 2>/dev/null)

    echo "  Root blocker: PID $root_pid"
    echo "  Query: ${root_query:-N/A}"
    echo "  Duration: ${root_duration:-N/A} seconds"

    # 分析根因类型
    if echo "$root_query" | grep -qiE "ALTER|DROP|TRUNCATE|REINDEX|VACUUM FULL"; then
      echo "  Type: DDL operation blocking other sessions"
      echo "  Recommendation: Schedule DDL during maintenance window"
    elif echo "$root_query" | grep -qiE "BEGIN|START TRANSACTION" && [ "${root_duration:-0}" -gt 60 ]; then
      echo "  Type: Long-running transaction holding locks"
      echo "  Recommendation: Check for idle in transaction, consider terminating"
    fi
  fi
  echo ""

  # 影响范围
  colorize yellow "IMPACT ASSESSMENT:"
  local waiter_count total_wait_time
  waiter_count=$(q "SELECT count(DISTINCT pid) FROM pg_locks WHERE NOT granted;" 2>/dev/null)
  total_wait_time=$(q "SELECT coalesce(round(sum(EXTRACT(EPOCH FROM (now() - query_start)))::numeric, 0), 0)
    FROM pg_stat_activity a
    JOIN pg_locks l ON a.pid = l.pid
    WHERE NOT l.granted;" 2>/dev/null)

  echo "  Sessions waiting: ${waiter_count:-0}"
  echo "  Total wait time: ${total_wait_time:-0} seconds"
  echo ""

  # 建议操作
  colorize yellow "RECOMMENDED ACTIONS:"
  if [ -n "$root_pid" ] && [ "$root_pid" != " " ]; then
    echo "  1. pg cancel $root_pid    (Try cancel first - graceful)"
    echo "  2. pg kill $root_pid      (If cancel fails - forceful)"
    echo ""
    echo "  Prevention:"
    echo "  - Schedule DDL during maintenance windows"
    echo "  - Set idle_in_transaction_session_timeout"
    echo "  - Monitor long-running transactions"
  fi
}
```

- [ ] **Step 2: 在调度器中注册新命令**

在 `dispatch_command()` 函数中添加：

```bash
    blocking_enhanced)      cmd_blocking_enhanced "$@" ;;
```

- [ ] **Step 3: 在 usage() 中添加帮助文本**

在帮助文本的锁相关区域添加：

```bash
    blocking_enhanced       Enhanced blocking analysis with root cause and actions
```

- [ ] **Step 4: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 5: 提交**

```bash
git add pg
git commit -m "feat: add blocking_enhanced command for deep lock analysis

- Show blocking chain with visual tree structure
- Identify root cause with query and duration
- Assess impact (waiting sessions, total wait time)
- Provide recommended actions and prevention tips

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: 增强现有命令输出

**Files:**
- Modify: `pg:900-1200` (top_time, cache_hit 等命令区域)

- [ ] **Step 1: 增强 cmd_top_time 添加资源消耗列**

找到 `cmd_top_time()` 函数，修改查询添加资源消耗：

```bash
cmd_top_time()
{
  local limit="${1:-10}"

  if ! require_extension pg_stat_statements; then
    return 1
  fi

  q "SELECT
    calls,
    round(total_exec_time::numeric, 2) as total_time_ms,
    round(mean_exec_time::numeric, 2) as mean_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) over())::numeric, 2) as pct_total,
    rows,
    round((shared_blks_hit::float / nullif(shared_blks_hit + shared_blks_read, 0) * 100)::numeric, 1) as cache_hit_pct,
    shared_blks_read as blk_read,
    temp_blks_written as temp_write,
    left(query, 60) || '...' as query_preview
  FROM pg_stat_statements
  ORDER BY total_exec_time DESC
  LIMIT $limit;"
}
```

- [ ] **Step 2: 增强 cmd_cache_hit 添加阈值判断**

找到 `cmd_cache_hit()` 函数，添加阈值判断输出：

```bash
cmd_cache_hit()
{
  colorize yellow "CACHE HIT RATIO:"
  echo ""

  local result
  result=$(q "SELECT
    datname as database,
    round(blks_hit::numeric / nullif(blks_hit + blks_read, 0) * 100, 2) as hit_ratio_pct,
    CASE
      WHEN blks_hit::numeric / nullif(blks_hit + blks_read, 0) * 100 >= 99 THEN 'EXCELLENT'
      WHEN blks_hit::numeric / nullif(blks_hit + blks_read, 0) * 100 >= 95 THEN 'GOOD'
      WHEN blks_hit::numeric / nullif(blks_hit + blks_read, 0) * 100 >= 90 THEN 'FAIR'
      ELSE 'POOR - Consider tuning shared_buffers'
    END as status
  FROM pg_stat_database
  WHERE datname not in ('template0', 'template1')
  ORDER BY hit_ratio_pct DESC;")

  echo "$result"
  echo ""

  # 添加整体建议
  local overall_ratio
  overall_ratio=$(q "SELECT round(sum(blks_hit)::numeric / nullif(sum(blks_hit) + sum(blks_read), 0) * 100, 2)
    FROM pg_stat_database
    WHERE datname not in ('template0', 'template1');" 2>/dev/null)

  if [ -n "$overall_ratio" ]; then
    if (( $(echo "$overall_ratio < 90" | bc -l) )); then
      colorize red "Overall cache hit ratio: ${overall_ratio}% - NEEDS ATTENTION"
      echo "  Consider: increase shared_buffers, check query patterns"
    elif (( $(echo "$overall_ratio < 95" | bc -l) )); then
      colorize yellow "Overall cache hit ratio: ${overall_ratio}% - Room for improvement"
    else
      colorize green "Overall cache hit ratio: ${overall_ratio}% - Healthy"
    fi
  fi
}
```

- [ ] **Step 3: 增强 cmd_wait_events 添加解读**

找到 `cmd_wait_events()` 函数，添加事件解读：

```bash
cmd_wait_events()
{
  colorize yellow "WAIT EVENTS SUMMARY:"
  echo ""

  local query
  if [ "$PG_MAJOR_VERSION" -ge 10 ]; then
    query="SELECT wait_event_type, wait_event, count(*) as cnt,
      round(100.0 * count(*) / sum(count(*)) over(), 2) as pct
    FROM pg_stat_activity
    WHERE wait_event IS NOT NULL
      AND wait_event_type IS NOT NULL
      AND state != 'idle'
    GROUP BY wait_event_type, wait_event
    ORDER BY count(*) DESC
    LIMIT 15;"
  else
    query="SELECT wait_event, count(*) as cnt
    FROM pg_stat_activity
    WHERE wait_event IS NOT NULL
    GROUP BY wait_event
    ORDER BY count(*) DESC
    LIMIT 15;"
  fi

  q "$query"
  echo ""

  # TOP 等待事件解读
  colorize yellow "TOP WAIT EVENT INTERPRETATION:"
  local top_event top_type
  top_event=$(q "SELECT wait_event FROM pg_stat_activity
    WHERE wait_event IS NOT NULL AND state != 'idle'
    GROUP BY wait_event ORDER BY count(*) DESC LIMIT 1;" 2>/dev/null)
  top_type=$(q "SELECT wait_event_type FROM pg_stat_activity
    WHERE wait_event IS NOT NULL AND state != 'idle'
    GROUP BY wait_event_type, wait_event ORDER BY count(*) DESC LIMIT 1;" 2>/dev/null)

  if [ -n "$top_event" ]; then
    echo "  Most frequent: $top_type:$top_event"
    interpret_wait_event "$top_type" "$top_event"
  fi
}
```

- [ ] **Step 4: 增强 cmd_bloat 添加操作建议**

找到 `cmd_bloat()` 函数，修改添加建议列：

```bash
cmd_bloat()
{
  local limit="${1:-20}"

  colorize yellow "TABLE BLOAT ANALYSIS:"
  q "SELECT
    schemaname || '.' || relname as table,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    CASE
      WHEN n_live_tup > 0 THEN round(100.0 * n_dead_tup / n_live_tup, 2)
      ELSE 0
    END as dead_ratio_pct,
    CASE
      WHEN n_dead_tup > 100000 THEN 'VACUUM FULL recommended'
      WHEN n_dead_tup > 10000 THEN 'VACUUM suggested'
      ELSE 'OK'
    END as recommendation
  FROM pg_stat_user_tables
  WHERE n_dead_tup > 0
  ORDER BY n_dead_tup DESC
  LIMIT $limit;"
}
```

- [ ] **Step 5: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 6: 运行回归测试**

Run: `./pg_regression_test.sh`
Expected: 所有测试通过

- [ ] **Step 7: 提交**

```bash
git add pg
git commit -m "feat: enhance existing commands with deeper insights

- top_time: Add cache hit %, block read, temp write columns
- cache_hit: Add status column with threshold-based assessment
- wait_events: Add top wait event interpretation
- bloat: Add recommendation column based on dead tuple count

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Phase 3: 组合诊断命令 (P2)

### Task 8: 添加 diagnose 命令入口和分发器

**Files:**
- Modify: `pg:2200-2300` (在诊断命令区域添加)

- [ ] **Step 1: 添加 cmd_diagnose 命令入口和分发器**

在合适位置添加：

```bash

# ============================================
# COMBINED DIAGNOSIS COMMANDS
# ============================================

cmd_diagnose()
{
  local scenario="$1"
  shift

  case "$scenario" in
    slow_query|slow|query)    cmd_diagnose_slow_query "$@" ;;
    lock_issue|lock|blocking)  cmd_diagnose_lock_issue "$@" ;;
    connection|conn)           cmd_diagnose_connection "$@" ;;
    replication|repl)          cmd_diagnose_replication "$@" ;;
    performance|perf)          cmd_diagnose_performance "$@" ;;
    health|full)               cmd_diagnose_health "$@" ;;
    capacity|capacity_plan)    cmd_diagnose_capacity "$@" ;;
    *)
      echo "Usage: $EXEC_NAME diagnose <scenario> [options]"
      echo ""
      echo "Scenarios:"
      echo "  slow_query [pid]     - Slow query complete diagnosis"
      echo "  lock_issue           - Lock problem complete diagnosis"
      echo "  connection           - Connection pool problem diagnosis"
      echo "  replication          - Replication problem diagnosis"
      echo "  performance          - Performance degradation diagnosis"
      echo "  health               - Comprehensive health check"
      echo "  capacity             - Capacity planning analysis"
      ;;
  esac
}
```

- [ ] **Step 2: 在调度器中注册 diagnose 命令**

在 `dispatch_command()` 函数中添加：

```bash
    diagnose)              cmd_diagnose "$@" ;;
```

- [ ] **Step 3: 在 usage() 中添加帮助文本**

在帮助文本添加：

```bash
    diagnose <scenario>        Combined diagnosis for common DBA scenarios
```

- [ ] **Step 4: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 5: 提交**

```bash
git add pg
git commit -m "feat: add diagnose command entry point and dispatcher

- Support 7 diagnosis scenarios: slow_query, lock_issue, connection,
  replication, performance, health, capacity
- Route to specific diagnosis functions

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 9: 实现慢查询诊断场景

**Files:**
- Modify: `pg:2300-2400` (在 diagnose 函数后添加)

- [ ] **Step 1: 实现 cmd_diagnose_slow_query 函数**

添加完整的慢查询诊断函数：

```bash

cmd_diagnose_slow_query()
{
  local pid="$1"
  local threshold="${2:-5}"

  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║              SLOW QUERY DIAGNOSIS REPORT                        ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Database: $DBNAME @ $DBHOST:$DBPORT"
  echo ""

  # Section 1: 当前慢查询列表
  colorize yellow "═══ SECTION 1: CURRENT SLOW QUERIES ═══"
  echo ""
  cmd_slow_enhanced "$pid" "$threshold"
  echo ""

  # Section 2: 历史TOP查询
  colorize yellow "═══ SECTION 2: HISTORICAL TOP QUERIES ═══"
  echo ""
  if require_extension pg_stat_statements; then
    cmd_top_time 5
    echo ""
    cmd_top_io 5
  fi
  echo ""

  # Section 3: 系统状态
  colorize yellow "═══ SECTION 3: SYSTEM STATE ═══"
  echo ""
  cmd_cache_hit
  echo ""
  cmd_wait_events
  echo ""

  # Section 4: 总结和建议
  colorize yellow "═══ SECTION 4: SUMMARY AND RECOMMENDATIONS ═══"
  echo ""
  echo "Key findings:"
  echo "  - Run 'pg slow_enhanced <PID>' for detailed query analysis"
  echo "  - Check if indexes are properly configured (pg missing_indexes)"
  echo "  - Verify statistics are up to date (pg vacuum_status)"
  echo "  - Monitor for patterns in query execution times"
  echo ""

  colorize green "Diagnosis complete. Use specific commands for deeper analysis."
}
```

- [ ] **Step 2: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 3: 提交**

```bash
git add pg
git commit -m "feat: add diagnose slow_query scenario

- Combine slow_enhanced, top_time, top_io, cache_hit, wait_events
- Generate structured report with 4 sections
- Provide actionable recommendations

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 10: 实现锁问题诊断场景

**Files:**
- Modify: `pg:2400-2500`

- [ ] **Step 1: 实现 cmd_diagnose_lock_issue 函数**

```bash

cmd_diagnose_lock_issue()
{
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║              LOCK ISSUE DIAGNOSIS REPORT                        ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # Section 1: 阻塞链分析
  colorize yellow "═══ SECTION 1: BLOCKING CHAIN ANALYSIS ═══"
  echo ""
  cmd_blocking_enhanced
  echo ""

  # Section 2: 锁详情
  colorize yellow "═══ SECTION 2: CURRENT LOCKS ═══"
  echo ""
  cmd_locks
  echo ""

  # Section 3: 相关事务
  colorize yellow "═══ SECTION 3: IDLE IN TRANSACTION ═══"
  echo ""
  cmd_idle_tx
  echo ""

  colorize yellow "═══ SECTION 4: LONG TRANSACTIONS ═══"
  echo ""
  cmd_long_transactions 10
  echo ""

  # Section 5: 总结
  colorize yellow "═══ SECTION 5: RESOLUTION STEPS ═══"
  echo ""
  echo "1. Identify root blocker from Section 1"
  echo "2. Try: pg cancel <root_pid>"
  echo "3. If needed: pg kill <root_pid>"
  echo "4. For prevention:"
  echo "   - Set idle_in_transaction_session_timeout"
  echo "   - Schedule DDL during maintenance windows"
  echo "   - Monitor long-running transactions"
  echo ""

  colorize green "Lock diagnosis complete."
}
```

- [ ] **Step 2: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 3: 提交**

```bash
git add pg
git commit -m "feat: add diagnose lock_issue scenario

- Combine blocking_enhanced, locks, idle_tx, long_transactions
- Generate structured 5-section report
- Provide clear resolution steps

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 11: 实现连接、复制、性能、健康诊断场景

**Files:**
- Modify: `pg:2500-2800`

- [ ] **Step 1: 实现连接诊断函数**

```bash

cmd_diagnose_connection()
{
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║           CONNECTION POOL DIAGNOSIS REPORT                      ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # Section 1: 连接概览
  colorize yellow "═══ SECTION 1: CONNECTION OVERVIEW ═══"
  echo ""
  cmd_conn
  echo ""

  # Section 2: 连接限制
  colorize yellow "═══ SECTION 2: CONNECTION LIMITS ═══"
  echo ""
  cmd_conn_limit
  echo ""

  # Section 3: 连接来源分析
  colorize yellow "═══ SECTION 3: CONNECTION SOURCES ═══"
  echo ""
  q "SELECT
    application_name,
    client_addr::text,
    usename,
    state,
    count(*) as conn_count
  FROM pg_stat_activity
  GROUP BY application_name, client_addr, usename, state
  ORDER BY count(*) DESC
  LIMIT 15;"
  echo ""

  # Section 4: 问题连接
  colorize yellow "═══ SECTION 4: PROBLEMATIC CONNECTIONS ═══"
  echo ""
  colorize blue "Idle in transaction (>5 min):"
  cmd_idle_tx
  echo ""
  colorize blue "Long idle connections (>1 hour):"
  q "SELECT pid, usename, application_name,
    round(EXTRACT(EPOCH FROM (now() - query_start))/60) as idle_minutes,
    client_addr::text
  FROM pg_stat_activity
  WHERE state = 'idle'
    AND query_start < now() - interval '1 hour'
  ORDER BY idle_minutes DESC
  LIMIT 10;"
  echo ""

  # Section 5: 建议
  colorize yellow "═══ SECTION 5: RECOMMENDATIONS ═══"
  echo ""
  echo "Connection Pool Configuration:"
  local max_conn current_conn
  max_conn=$(q "SELECT setting FROM pg_settings WHERE name = 'max_connections';")
  current_conn=$(q "SELECT count(*) FROM pg_stat_activity;")

  echo "  max_connections: $max_conn"
  echo "  current connections: $current_conn"
  echo "  Utilization: $(( current_conn * 100 / max_conn ))%"
  echo ""
  echo "  Recommended pool size (per pgbouncer):"
  echo "    - Session pool: $(( max_conn / 2 )) - $(( max_conn * 3 / 4 ))"
  echo "    - Transaction pool: $(( max_conn / 4 )) - $(( max_conn / 2 ))"
  echo ""

  colorize green "Connection diagnosis complete."
}
```

- [ ] **Step 2: 实现复制诊断函数**

```bash

cmd_diagnose_replication()
{
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║            REPLICATION DIAGNOSIS REPORT                         ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # Section 1: 复制状态
  colorize yellow "═══ SECTION 1: REPLICATION STATUS ═══"
  echo ""
  cmd_repl
  echo ""

  # Section 2: 复制延迟
  colorize yellow "═══ SECTION 2: REPLICATION LAG ═══"
  echo ""
  cmd_repl_lag
  echo ""

  # Section 3: 复制槽
  colorize yellow "═══ SECTION 3: REPLICATION SLOTS ═══"
  echo ""
  cmd_slot
  echo ""
  cmd_slot_usage
  echo ""

  # Section 4: 延迟分析
  colorize yellow "═══ SECTION 4: LAG ANALYSIS ═══"
  echo ""

  if [ "$HAS_REPLICATION_SLOTS" = "true" ]; then
    q "SELECT
      client_addr,
      state,
      sync_state,
      round(EXTRACT(EPOCH FROM write_lag)) as write_lag_sec,
      round(EXTRACT(EPOCH FROM flush_lag)) as flush_lag_sec,
      round(EXTRACT(EPOCH FROM replay_lag)) as replay_lag_sec,
      CASE
        WHEN replay_lag > interval '1 hour' THEN 'CRITICAL: Very high lag'
        WHEN replay_lag > interval '5 minutes' THEN 'WARNING: High lag'
        ELSE 'OK'
      END as status
    FROM pg_stat_replication;" 2>/dev/null || msg_info "No replication configured or no access"
  else
    msg_info "Replication slots require PostgreSQL 10+"
  fi
  echo ""

  # Section 5: 建议
  colorize yellow "═══ SECTION 5: RECOMMENDATIONS ═══"
  echo ""
  echo "Monitoring:"
  echo "  - Monitor replication lag regularly"
  echo "  - Set up alerts for lag > 5 minutes"
  echo "  - Check WAL disk space on standby"
  echo ""
  echo "Troubleshooting:"
  echo "  - High write_lag: Network issue"
  echo "  - High flush_lag: Standby disk I/O issue"
  echo "  - High replay_lag: Standby CPU/load issue"
  echo ""

  colorize green "Replication diagnosis complete."
}
```

- [ ] **Step 3: 实现性能诊断函数**

```bash

cmd_diagnose_performance()
{
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║           PERFORMANCE DIAGNOSIS REPORT                          ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # Section 1: 快速健康检查
  colorize yellow "═══ SECTION 1: HEALTH CHECK ═══"
  echo ""
  cmd_health
  echo ""

  # Section 2: 缓存效率
  colorize yellow "═══ SECTION 2: CACHE EFFICIENCY ═══"
  echo ""
  cmd_cache_hit
  echo ""

  # Section 3: I/O 统计
  colorize yellow "═══ SECTION 3: I/O STATISTICS ═══"
  echo ""
  cmd_io_stats
  echo ""

  # Section 4: 等待事件
  colorize yellow "═══ SECTION 4: WAIT EVENTS ═══"
  echo ""
  cmd_wait_events
  echo ""

  # Section 5: TOP 查询
  colorize yellow "═══ SECTION 5: TOP QUERIES BY TIME ═══"
  echo ""
  if require_extension pg_stat_statements; then
    cmd_top_time 10
    echo ""
    colorize yellow "═══ SECTION 6: TOP QUERIES BY I/O ═══"
    echo ""
    cmd_top_io 10
  fi
  echo ""

  # Section 7: 建议
  colorize yellow "═══ SUMMARY: PERFORMANCE INSIGHTS ═══"
  echo ""
  echo "Check items:"
  echo "  1. Cache hit ratio should be > 95%"
  echo "  2. Top queries should not dominate total time"
  echo "  3. Wait events should not show sustained IO/Lock waits"
  echo ""
  echo "Actions:"
  echo "  - Run 'pg diagnose slow_query' for query analysis"
  echo "  - Run 'pg diagnose lock_issue' if locks are problematic"
  echo "  - Check 'pg missing_indexes' for index suggestions"
  echo ""

  colorize green "Performance diagnosis complete."
}
```

- [ ] **Step 4: 实现健康诊断函数**

```bash

cmd_diagnose_health()
{
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║              COMPREHENSIVE HEALTH REPORT                        ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Database: $DBNAME @ $DBHOST:$DBPORT"
  echo "PostgreSQL Version: $(cmd_version 2>/dev/null | head -1)"
  echo ""

  local issues=0

  # Section 1: 连接健康
  colorize yellow "═══ SECTION 1: CONNECTION HEALTH ═══"
  echo ""

  local current_conn max_conn
  current_conn=$(q "SELECT count(*) FROM pg_stat_activity;")
  max_conn=$(q "SELECT setting::int FROM pg_settings WHERE name = 'max_connections';")
  local conn_pct=$(( current_conn * 100 / max_conn ))

  echo "Connections: $current_conn / $max_conn ($conn_pct%)"

  if [ "$conn_pct" -gt 90 ]; then
    colorize red "CRITICAL: Connection usage > 90%"
    issues=$((issues + 1))
  elif [ "$conn_pct" -gt 75 ]; then
    colorize yellow "WARNING: Connection usage > 75%"
    issues=$((issues + 1))
  else
    colorize green "OK: Connection usage healthy"
  fi
  echo ""

  # 检查空闲事务
  local idle_count
  idle_count=$(q "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction';" 2>/dev/null || echo 0)
  echo "Idle in transaction: $idle_count"
  if [ "$idle_count" -gt 5 ]; then
    colorize yellow "WARNING: $idle_count sessions idle in transaction"
    issues=$((issues + 1))
  fi
  echo ""

  # Section 2: 缓存健康
  colorize yellow "═══ SECTION 2: CACHE HEALTH ═══"
  echo ""

  local cache_ratio
  cache_ratio=$(q "SELECT round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2)
    FROM pg_stat_database WHERE datname not in ('template0', 'template1');" 2>/dev/null)

  echo "Cache hit ratio: ${cache_ratio}%"

  if (( $(echo "${cache_ratio:-100} < 90" | bc -l) )); then
    colorize red "CRITICAL: Cache hit ratio < 90%"
    issues=$((issues + 1))
  elif (( $(echo "${cache_ratio:-100} < 95" | bc -l) )); then
    colorize yellow "WARNING: Cache hit ratio < 95%"
    issues=$((issues + 1))
  else
    colorize green "OK: Cache hit ratio healthy"
  fi
  echo ""

  # Section 3: 锁健康
  colorize yellow "═══ SECTION 3: LOCK HEALTH ═══"
  echo ""

  local blocking_count
  blocking_count=$(q "SELECT count(*) FROM pg_locks WHERE NOT granted;" 2>/dev/null || echo 0)
  echo "Blocked sessions: $blocking_count"

  if [ "$blocking_count" -gt 5 ]; then
    colorize red "CRITICAL: $blocking_count blocked sessions"
    issues=$((issues + 1))
  elif [ "$blocking_count" -gt 0 ]; then
    colorize yellow "WARNING: $blocking_count blocked sessions"
    issues=$((issues + 1))
  else
    colorize green "OK: No blocking sessions"
  fi
  echo ""

  # Section 4: 表膨胀
  colorize yellow "═══ SECTION 4: TABLE BLOAT ═══"
  echo ""

  local bloated_tables
  bloated_tables=$(q "SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > 10000;" 2>/dev/null || echo 0)
  echo "Tables with significant dead tuples: $bloated_tables"

  if [ "$bloated_tables" -gt 10 ]; then
    colorize yellow "WARNING: $bloated_tables tables need vacuum"
    issues=$((issues + 1))
  else
    colorize green "OK: Table bloat manageable"
  fi
  echo ""

  # Section 5: 复制健康
  colorize yellow "═══ SECTION 5: REPLICATION HEALTH ═══"
  echo ""

  local repl_count
  repl_count=$(q "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo 0)
  echo "Replication streams: $repl_count"

  if [ "$repl_count" -gt 0 ]; then
    local max_lag
    max_lag=$(q "SELECT round(EXTRACT(EPOCH FROM max(replay_lag))) FROM pg_stat_replication;" 2>/dev/null || echo 0)
    echo "Max replication lag: ${max_lag}s"

    if [ "${max_lag:-0}" -gt 300 ]; then
      colorize red "CRITICAL: Replication lag > 5 minutes"
      issues=$((issues + 1))
    elif [ "${max_lag:-0}" -gt 60 ]; then
      colorize yellow "WARNING: Replication lag > 1 minute"
      issues=$((issues + 1))
    else
      colorize green "OK: Replication lag acceptable"
    fi
  else
    echo "No replication configured"
  fi
  echo ""

  # 总结
  colorize yellow "═══ SUMMARY ═══"
  echo ""
  if [ "$issues" -eq 0 ]; then
    colorize green "Database health: EXCELLENT - No issues detected"
  else
    colorize yellow "Database health: $issues issue(s) detected"
    echo ""
    echo "Recommended actions:"
    echo "  - Run 'pg diagnose connection' if connection issues"
    echo "  - Run 'pg diagnose lock_issue' if blocking detected"
    echo "  - Run 'pg diagnose slow_query' if performance issues"
    echo "  - Run 'pg vacuum_status' to check maintenance"
  fi
  echo ""

  colorize green "Health check complete."
}
```

- [ ] **Step 5: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 6: 提交**

```bash
git add pg
git commit -m "feat: add diagnose scenarios for connection, replication, performance, health

- diagnose connection: Pool analysis, source distribution, problematic connections
- diagnose replication: Status, lag analysis, slot usage
- diagnose performance: Health check, cache, IO, wait events, top queries
- diagnose health: Comprehensive 5-section health report with issue counting

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 12: 实现容量规划诊断场景

**Files:**
- Modify: `pg:2800-2900`

- [ ] **Step 1: 实现容量规划诊断函数**

```bash

cmd_diagnose_capacity()
{
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║             CAPACITY PLANNING REPORT                            ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # Section 1: 数据库大小
  colorize yellow "═══ SECTION 1: DATABASE SIZES ═══"
  echo ""
  cmd_db_size
  echo ""

  # Section 2: 表空间大小
  colorize yellow "═══ SECTION 2: TABLESPACE SIZES ═══"
  echo ""
  cmd_ts_size
  echo ""

  # Section 3: 大表分析
  colorize yellow "═══ SECTION 3: TOP TABLES BY SIZE ═══"
  echo ""
  q "SELECT
    schemaname || '.' || relname as table,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    pg_size_pretty(pg_relation_size(relid)) as table_size,
    pg_size_pretty(pg_indexes_size(relid)) as index_size,
    n_live_tup as row_count,
    n_dead_tup as dead_tuples
  FROM pg_stat_user_tables
  ORDER BY pg_total_relation_size(relid) DESC
  LIMIT 20;"
  echo ""

  # Section 4: 表膨胀评估
  colorize yellow "═══ SECTION 4: TABLE BLOAT ASSESSMENT ═══"
  echo ""
  cmd_bloat 20
  echo ""

  # Section 5: 索引分析
  colorize yellow "═══ SECTION 5: INDEX SIZE ANALYSIS ═══"
  echo ""
  cmd_index_size
  echo ""

  colorize yellow "═══ SECTION 6: UNUSED INDEXES ═══"
  echo ""
  cmd_unused_indexes 10
  echo ""

  # Section 7: 增长趋势数据
  colorize yellow "═══ SECTION 7: GROWTH INDICATORS ═══"
  echo ""
  echo "Recent activity (approximate):"
  q "SELECT
    schemaname,
    count(*) as table_count,
    sum(n_tup_ins) as total_inserts,
    sum(n_tup_upd) as total_updates,
    sum(n_tup_del) as total_deletes,
    sum(n_tup_ins + n_tup_upd + n_tup_del) as total_writes
  FROM pg_stat_user_tables
  GROUP BY schemaname
  ORDER BY total_writes DESC;"
  echo ""

  # Section 8: 建议
  colorize yellow "═══ CAPACITY PLANNING RECOMMENDATIONS ═══"
  echo ""
  echo "1. Storage Growth:"
  echo "   - Monitor table sizes monthly"
  echo "   - Plan for 20-30% buffer on disk space"
  echo "   - Consider partitioning for tables > 100GB"
  echo ""
  echo "2. Index Optimization:"
  echo "   - Review unused indexes for removal"
  echo "   - Rebuild bloated indexes during maintenance"
  echo ""
  echo "3. Maintenance:"
  echo "   - Schedule regular VACUUM for high-update tables"
  echo "   - Monitor dead tuple accumulation"
  echo ""

  colorize green "Capacity analysis complete."
}
```

- [ ] **Step 2: 验证语法正确**

Run: `bash -n pg`
Expected: 无输出（语法正确）

- [ ] **Step 3: 提交**

```bash
git add pg
git commit -m "feat: add diagnose capacity scenario

- Analyze database and tablespace sizes
- Show top tables with size breakdown
- Assess table bloat and index efficiency
- Provide growth indicators and planning recommendations

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Phase 4: 测试和文档 (P3)

### Task 13: 更新回归测试脚本

**Files:**
- Modify: `pg_regression_test.sh`

- [ ] **Step 1: 添加新命令测试到回归脚本**

在 `pg_regression_test.sh` 中添加新命令测试：

```bash
# Test new enhanced commands
test_command "slow_enhanced" "pg slow_enhanced"
test_command "blocking_enhanced" "pg blocking_enhanced"
test_command "diagnose help" "pg diagnose"
test_command "diagnose health" "pg diagnose health"
```

- [ ] **Step 2: 运行完整回归测试**

Run: `./pg_regression_test.sh`
Expected: 所有测试通过

- [ ] **Step 3: 提交**

```bash
git add pg_regression_test.sh
git commit -m "test: add tests for new enhanced and diagnose commands

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 14: 更新版本号和帮助文档

**Files:**
- Modify: `pg:1-50` (版本信息区域)

- [ ] **Step 1: 更新版本号**

修改文件头部的版本信息：

```bash
#
# PostgreSQL Database Diagnostic Tool (pg)
# Production-ready for PostgreSQL 9.6-18
#
# Version: 4.0.0 (2026-03-26)
# Previous Version: 3.6.0 (2026-03-26)
# Author: Kevin
#
# Version History:
# 4.0.0 (2026-03-26) - Enterprise DBA Tool Enhancement:
#                       - Reliability infrastructure (error handling, version compatibility)
#                       - Enhanced commands (slow_enhanced, blocking_enhanced)
#                       - Combined diagnosis scenarios (7 diagnosis scenarios)
#                       - Improved output depth with insights and suggestions
```

- [ ] **Step 2: 更新 TOOL_VERSION 常量**

```bash
readonly TOOL_VERSION="4.0.0"
readonly TOOL_BUILD_DATE="2026-03-26"
```

- [ ] **Step 3: 验证最终版本**

Run: `./pg version`
Expected: 显示 "4.0.0"

- [ ] **Step 4: 最终提交**

```bash
git add pg
git commit -m "release: v4.0.0 - Enterprise DBA Tool Enhancement

Major release with:
- Reliability infrastructure for consistent error handling
- Enhanced commands with deeper insights
- 7 combined diagnosis scenarios
- PostgreSQL 9.6-18 support

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## 验收清单

- [ ] 所有语法检查通过 (`bash -n pg`)
- [ ] 回归测试通过 (`./pg_regression_test.sh`)
- [ ] 新命令可在无数据库连接时优雅报错
- [ ] 新命令在权限不足时给出清晰提示
- [ ] 版本兼容性检测正常工作 (PG 12/14/16/18)
- [ ] 输出格式一致且可读
- [ ] 所有新命令在帮助中可见

---

## 预估工时

| Phase | 任务数 | 预估时间 |
|-------|--------|----------|
| P0 可靠性 | 4 | 2h |
| P1 增强 | 3 | 3h |
| P2 组合诊断 | 5 | 3h |
| P3 测试文档 | 2 | 1h |
| **总计** | **14** | **9h** |