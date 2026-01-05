# WAL 重命名工具 - 生产运维检查清单

## ✅ 部署前检查

- [ ] Python 版本 >= 3.6
- [ ] 足够的磁盘空间（日志目录）
- [ ] WAL 目录权限检查：
  ```bash
  ls -ld /var/lib/postgresql/pg_wal
  # 应该是 postgres 用户可写
  ```
- [ ] 备份数据库完整且可恢复
- [ ] 测试环境验证完毕
- [ ] 团队成员通知（可能的停机时间）

---

## 🚀 首次执行流程

### 1. 预览模式验证（必须）
```bash
sudo -u postgres python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --dry-run

# 预期输出：
# [INFO] [预览] 重命名 000000010000000000000001 => 000000010000000000000001
# ============================================================
# WAL 文件重命名 - 操作摘要
# 扫描文件总数:     100
# 已重命名:         0
# 已跳过:           0
# 文件名正确:       100
# 处理错误:         0
# 模式:             预览
# ============================================================
```

### 2. 查看报告
```bash
# 检查是否有错误标记
grep "ERROR\|WARNING" /var/lib/postgresql/pg_wal/wal_rename.log

# 如果有大量错误，调查原因后再执行
```

### 3. 正式执行
```bash
sudo -u postgres python3 wal_rename_v2.py /var/lib/postgresql/pg_wal

# 等待完成，查看摘要
```

### 4. 验证结果
```bash
# 检查错误
tail -20 /var/lib/postgresql/pg_wal/wal_rename_error.log

# 查看操作统计
cat /var/lib/postgresql/pg_wal/.wal_rename_state/report_*.json | jq '.'

# 确保数据库仍然可用
psql -U postgres -c "SELECT pg_current_wal_lsn();"
```

---

## 🔍 日常监控

### 每周检查

```bash
#!/bin/bash
# weekly_check.sh

WAL_DIR="/var/lib/postgresql/pg_wal"
ALERT_EMAIL="dba@example.com"

echo "=== WAL 重命名工具健康检查 ===" > /tmp/wal_check.txt

# 1. 检查日志大小
LOG_SIZE=$(du -h "$WAL_DIR/wal_rename.log" 2>/dev/null | awk '{print $1}')
echo "日志大小: $LOG_SIZE" >> /tmp/wal_check.txt

# 2. 检查错误数量
ERROR_COUNT=$(grep -c ERROR "$WAL_DIR/wal_rename_error.log" 2>/dev/null || echo 0)
echo "错误数: $ERROR_COUNT" >> /tmp/wal_check.txt

if [ $ERROR_COUNT -gt 10 ]; then
    echo "⚠️  最近有很多错误，需要调查" >> /tmp/wal_check.txt
    mail -s "WAL 重命名工具告警" $ALERT_EMAIL < /tmp/wal_check.txt
fi

# 3. 检查最后一次执行时间
LAST_REPORT=$(ls -t "$WAL_DIR/.wal_rename_state/report_"*.json 2>/dev/null | head -1)
if [ -z "$LAST_REPORT" ]; then
    echo "⚠️  从未执行过" >> /tmp/wal_check.txt
else
    echo "最后执行: $(stat -f %Sm -t '%Y-%m-%d %H:%M:%S' "$LAST_REPORT")" >> /tmp/wal_check.txt
fi

cat /tmp/wal_check.txt
```

### 每月深度检查

```bash
#!/bin/bash
# monthly_audit.sh

WAL_DIR="/var/lib/postgresql/pg_wal"

echo "=== 月度审计报告 ===" 

# 1. 统计所有操作
echo "过去 30 天的操作统计:"
find "$WAL_DIR/.wal_rename_state" -name "report_*.json" -mtime -30 | while read report; do
    cat "$report" | jq '.total_operations'
done | awk '{sum+=$1} END {print "总操作数: " sum}'

# 2. 错误率
echo "错误趋势:"
grep ERROR "$WAL_DIR/wal_rename_error.log" | tail -100 | awk -F'[' '{print $2}' | sort | uniq -c

# 3. 检查磁盘空间
echo "磁盘使用:"
du -sh "$WAL_DIR/.wal_rename_backup" 2>/dev/null || echo "备份目录为空"
du -sh "$WAL_DIR/.wal_rename_state" 2>/dev/null || echo "状态目录为空"

# 4. 备份可恢复性检查
echo "最后一次完整备份:"
ls -lhtr "$WAL_DIR/.wal_rename_state/report_"*.json 2>/dev/null | tail -1
```

---

## ⚠️ 故障排查

### 问题：无法解析大量文件

```bash
# 1. 检查错误日志
tail -50 /var/lib/postgresql/pg_wal/wal_rename_error.log

# 2. 检查特定错误类型
grep -o "魔数不匹配\|版本不支持\|文件太小" \
    /var/lib/postgresql/pg_wal/wal_rename_error.log | sort | uniq -c

# 3. 样本分析
ls -la /var/lib/postgresql/pg_wal | head -20 | tail -5
```

**可能的原因和解决方案**：

| 错误 | 原因 | 解决方案 |
|------|------|--------|
| 魔数不匹配 | WAL 文件损坏 | 检查磁盘健康，考虑恢复备份 |
| 版本不支持 | PostgreSQL 版本不匹配 | 确认 PostgreSQL 版本 |
| 文件太小 | 不完整的写入 | 检查是否有正在进行的 WAL 归档 |

---

### 问题：性能下降

```bash
# 1. 监控磁盘 I/O
iostat -x 1 10

# 2. 检查负载
top -bn1 | head -20

# 3. 如果是 I/O 繁忙，尝试：
#    - 减少日志详细度
#    - 在低峰期运行
#    - 检查是否有其他进程竞争
```

---

### 问题：需要回滚

```bash
# 1. 确认当前状态
cat /var/lib/postgresql/pg_wal/.wal_rename_state/in_progress.json | jq '.operations | length'

# 2. 执行回滚
sudo -u postgres python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --rollback

# 3. 验证回滚
ls /var/lib/postgresql/pg_wal | grep -E "^[0-9A-F]{24}$" | wc -l

# 4. 检查日志
tail -30 /var/lib/postgresql/pg_wal/wal_rename.log | grep "已回滚"
```

---

## 📊 性能基准

在不同场景下的预期性能：

| 文件数 | 典型耗时 | CPU 使用 | 磁盘 I/O |
|--------|---------|---------|---------|
| 100 | < 1s | < 1% | 低 |
| 1,000 | 5-10s | 2-5% | 中 |
| 10,000 | 30-60s | 5-10% | 中高 |
| 100,000 | 5-10 min | 10-20% | 高 |

**优化建议**：
- 如果超过预期，检查磁盘性能
- 避免在高峰期运行
- 增加日志级别到 WARNING 以降低开销

---

## 🔐 安全最佳实践

### 1. 权限管理
```bash
# 确保只有数据库管理员能运行
chmod 750 /opt/scripts/wal_rename_v2.py
sudo chown postgres:postgres /opt/scripts/wal_rename_v2.py

# 限制日志访问
chmod 700 /var/lib/postgresql/pg_wal/.wal_rename_state
chmod 700 /var/lib/postgresql/pg_wal/.wal_rename_backup
```

### 2. 日志保留
```bash
# 定期归档日志（保留 90 天）
tar czf /backup/wal_logs_$(date +%Y%m%d).tar.gz \
    /var/lib/postgresql/pg_wal/wal_rename*.log*

# 删除旧日志
find /var/lib/postgresql/pg_wal/ -name "wal_rename*.log.*" -mtime +90 -delete
```

### 3. 审计追踪
```bash
# 启用审计（可选）
cat >> /var/lib/postgresql/pg_wal/.wal_rename_state/audit.log << EOF
$(date): 执行者: $(whoami), 主机: $(hostname), 操作: 重命名
EOF

# 定期检查审计
tail -100 /var/lib/postgresql/pg_wal/.wal_rename_state/audit.log
```

---

## 📞 应急联系

如遇严重问题：

1. **立即停止**脚本执行
2. **备份现场**：
   ```bash
   tar czf /tmp/wal_state_backup_$(date +%s).tar.gz \
       /var/lib/postgresql/pg_wal/.wal_rename_state/
   ```
3. **查看日志**：分析错误类型
4. **考虑回滚**：`python3 wal_rename_v2.py /path --rollback`
5. **联系专家**：提供日志文件和出错信息

---

## 📝 更新日志

### v2.0 更新

- ✅ 添加结构化日志系统
- ✅ 实现完整的备份和回滚机制
- ✅ 强化文件验证和错误检测
- ✅ 支持中断恢复
- ✅ 生成详细的操作报告
- ✅ 添加完整的单元测试

---

## 🙋 常见问题

**Q: 脚本可以并发运行吗？**
A: 不建议。如果需要，应该使用文件锁。当前版本是单进程的。

**Q: 如何处理正在运行的 PostgreSQL？**
A: 脚本只在文件系统级别操作，不会影响运行中的数据库。但建议在低峰期运行。

**Q: WAL 文件在处理时被删除了怎么办？**
A: 脚本会跳过已删除的文件，这是正常的（WAL 可能被归档）。

**Q: 多久运行一次？**
A: 取决于你的 WAL 命名问题频率。建议每周一次定期检查。

---

生成日期: 2026-01-02
最后更新: 2026-01-02
