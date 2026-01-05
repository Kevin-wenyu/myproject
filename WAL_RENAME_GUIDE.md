# WAL 文件重命名工具 - v2.0 生产级改进指南

## 📋 核心改进点

### v1.0 vs v2.0 对比

| 功能 | v1.0 | v2.0 |
|------|------|------|
| 日志记录 | print 输出 | 结构化日志（JSON）+ 轮转 + 错误日志分离 |
| 错误处理 | 基础 try-catch | 详细错误分类 + 日志记录 |
| 备份恢复 | ❌ 无 | ✅ 完整备份 + 回滚机制 |
| 文件验证 | 基础大小检查 | 魔数检查 + 版本验证 + 完整性检查 |
| 操作原子性 | ❌ 无 | ✅ 状态文件 + 中断恢复 |
| 审计追踪 | ❌ 无 | ✅ JSON 格式操作记录 |
| 统计报告 | 基础 | 详细 JSON 报告 + 摘要 |

---

## 🚀 快速开始

### 基本使用

```bash
# 1. 预览模式（推荐首次使用）
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --dry-run

# 2. 实际执行
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal

# 3. 如果有问题，回滚
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --rollback

# 4. 调试模式查看详细信息
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --log-level DEBUG
```

### 输出目录结构

```
/var/lib/postgresql/pg_wal/
├── .wal_rename_backup/          # 备份目录
│   └── (备份文件存储位置)
├── .wal_rename_state/           # 状态管理
│   ├── in_progress.json         # 当前操作状态
│   └── report_20260102_120000.json  # 操作报告
├── wal_rename.log              # 日志（每天轮转）
├── wal_rename_error.log        # 错误日志
└── (WAL 文件)
```

---

## 🔍 日志系统详解

### 日志级别

- **DEBUG**: 详细的执行信息（调试时使用）
- **INFO**: 正常操作信息
- **WARNING**: 异常但可继续的情况
- **ERROR**: 严重错误

### 日志格式

**标准日志**（`wal_rename.log`）：
```
2026-01-02 12:00:00 [INFO] WAL 重命名工具启动
2026-01-02 12:00:01 [INFO] 开始扫描目录
```

**结构化日志**（包含详细信息）：
```json
{
  "timestamp": "2026-01-02T12:00:05.123456",
  "level": "INFO",
  "event": "重命名成功",
  "old": "000000010000000000000001",
  "new": "000000010000000000000001",
  "hash": "a1b2c3d4e5f6..."
}
```

**错误日志**（`wal_rename_error.log`）：
```
2026-01-02 12:00:10 [ERROR] 解析 WAL 文件异常: /path/to/file, error: xxx
```

---

## 🔄 备份和恢复机制

### 自动备份

每次重命名操作后，工具会：

1. **记录操作信息**（包括文件哈希）
2. **保存到状态文件** `.wal_rename_state/in_progress.json`
3. **生成操作报告** `.wal_rename_state/report_*.json`

### 回滚流程

```bash
# 发现问题后立即回滚
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --rollback
```

**回滚会**：
- ✅ 将所有重命名的文件恢复为原始名称
- ✅ 按照操作的逆序执行
- ✅ 记录回滚过程到日志

---

## ✅ 文件验证机制

### 三层验证

#### 1. 物理完整性检查
```python
- 文件是否存在
- 文件是否大于 24 字节
- 文件大小是否符合预期
```

#### 2. 头部验证
```python
- WAL 魔数检查（0xD061）
- 版本号检查（支持版本 3-15）
```

#### 3. 元数据验证
```python
- 时间线 ID (Timeline ID)
- LSN 地址有效性
- 逻辑段号一致性
```

### 验证结果示例

**通过验证**：
```json
{
  "new_name": "000000010000000000000001",
  "xlp_tli": 1,
  "xlp_pageaddr": 0,
  "valid": true,
  "issues": []
}
```

**有问题但继续**：
```json
{
  "new_name": "000000010000000000000001",
  "valid": false,
  "issues": ["完整性检查失败: 文件大小异常（期望 16777216，实际 16777215）"]
}
```

---

## 📊 操作报告

执行完成后，查看报告：

```bash
cat /var/lib/postgresql/pg_wal/.wal_rename_state/report_*.json
```

**报告内容**：
```json
{
  "timestamp": "2026-01-02T12:00:15.789123",
  "total_operations": 5,
  "operations": [
    {
      "timestamp": "2026-01-02T12:00:05.123456",
      "old_name": "000000010000000000000001",
      "new_name": "000000010000000000000001",
      "file_hash": "a1b2c3d4e5f6...",
      "status": "completed"
    },
    ...
  ]
}
```

---

## 🐛 常见问题排查

### 问题 1: 某些文件无法解析

**查看日志**：
```bash
grep "ERROR\|WARNING" /var/lib/postgresql/pg_wal/wal_rename.log
```

**常见原因**：
- WAL 文件已损坏（魔数不匹配）
- 文件截断（小于 24 字节）
- PostgreSQL 版本不匹配

**解决方案**：
- 检查数据库日志查找磁盘故障
- 使用 `pg_waldump` 诊断
- 考虑从备份恢复

### 问题 2: 中断恢复

如果脚本执行中被中断：

```bash
# 1. 查看中断时的状态
cat /var/lib/postgresql/pg_wal/.wal_rename_state/in_progress.json

# 2. 选择：
#    - 继续执行（会跳过已处理的文件）
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal

#    - 回滚到初始状态
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --rollback
```

### 问题 3: 性能问题

如果处理大量文件很慢：

```bash
# 使用调试模式检查瓶颈
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --log-level DEBUG | tail -100
```

**常见原因**：
- 文件系统 I/O 缓慢
- 磁盘空间不足
- 权限问题导致操作重试

---

## 🔐 生产环境部署建议

### 1. 权限设置
```bash
# 赋予执行权限
chmod +x wal_rename_v2.py

# 使用 postgres 用户运行
sudo -u postgres python3 wal_rename_v2.py /var/lib/postgresql/pg_wal
```

### 2. 日志管理

在 crontab 中定期清理日志：
```bash
# 每月清理 30 天前的日志
0 0 1 * * find /var/lib/postgresql/pg_wal/ -name "wal_rename*.log.*" -mtime +30 -delete
```

### 3. 监控告警

监控以下条件：
```bash
# 检查错误日志大小（异常表明有大量失败）
ls -lh /var/lib/postgresql/pg_wal/wal_rename_error.log

# 检查操作报告（确保操作完成）
ls -lt /var/lib/postgresql/pg_wal/.wal_rename_state/report_*.json | head -1
```

### 4. 定期审计

定期检查操作记录：
```bash
# 查看最近 7 天的操作
find /var/lib/postgresql/pg_wal/.wal_rename_state -name "report_*.json" -mtime -7 -exec cat {} \; | jq '.total_operations, .operations[]'
```

---

## 📝 高级用法

### 自定义 WAL 段大小

如果使用非标准的 WAL 段大小：
```bash
# 32MB WAL 段
python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --segment-size 33554432
```

### 与脚本集成

```bash
#!/bin/bash
# maintenance.sh - 定期维护脚本

WAL_DIR="/var/lib/postgresql/pg_wal"
LOG_FILE="/var/log/pg_maintenance.log"

echo "[$(date)] 开始 WAL 重命名" >> $LOG_FILE

python3 /opt/scripts/wal_rename_v2.py $WAL_DIR \
    --log-level INFO \
    2>> $LOG_FILE

if [ $? -eq 0 ]; then
    echo "[$(date)] WAL 重命名成功" >> $LOG_FILE
else
    echo "[$(date)] WAL 重命名失败！" >> $LOG_FILE
    # 发送告警邮件
    # mail -s "WAL 重命名失败" admin@example.com < $LOG_FILE
fi
```

---

## ⚡ 性能优化建议

1. **限制处理频率**：不要频繁运行，建议周期性（如每周一次）
2. **选择合适时间**：在数据库低峰期运行
3. **监控磁盘空间**：确保有足够空间保存日志和备份
4. **定期清理状态文件**：旧的报告可以归档

---

## 🆘 获取帮助

### 查看完整日志
```bash
tail -f /var/lib/postgresql/pg_wal/wal_rename.log
tail -f /var/lib/postgresql/pg_wal/wal_rename_error.log
```

### 解析 JSON 日志
```bash
# 查看最近 10 条 ERROR 记录
cat /var/lib/postgresql/pg_wal/wal_rename.log | jq 'select(.level=="ERROR")'

# 统计重命名数量
cat /var/lib/postgresql/pg_wal/.wal_rename_state/report_*.json | jq '.total_operations'
```

### PostgreSQL 官方诊断
```bash
# 检查 PostgreSQL 控制文件
pg_controldata $PGDATA | grep TimeLineID

# 查看当前 LSN
psql -c "SELECT pg_current_wal_lsn();"

# 查看 WAL 文件信息
pg_waldump -p /var/lib/postgresql/pg_wal/000000010000000000000001
```

---

## 版本历史

- **v2.0** (2026-01-02): 生产级，增加日志、备份、验证、回滚
- **v1.0** (2025-04-17): 初始版本，基础功能
