#!/bin/bash
# pg工具修复验证脚本

echo "=== pg工具修复验证 ==="

# 1. 验证帮助信息完整性
echo "1. 验证帮助命令数量..."
HELP_COUNT=$(./pg --help 2>&1 | grep -E '^\s+[a-z_]+' | wc -l | tr -d ' ')
echo "帮助信息中命令数: $HELP_COUNT"

# 2. 验证dispatch_command中的命令数
echo "2. 验证dispatch命令数量..."
DISPATCH_COUNT=$(grep -E '^\s+[a-z_\|]+\)' pg | wc -l | tr -d ' ')
echo "调度器中命令数: $DISPATCH_COUNT"

# 3. 检查别名冲突
echo "3. 检查别名冲突..."
echo "sessions别名:"
grep -n 'sessions' pg | head -5
echo "constraints别名:"
grep -n 'constraints' pg | head -5

# 4. 检查未实现函数
echo "4. 检查未实现函数..."
for func in cmd_health_plus cmd_advanced_explain cmd_top_wait_events cmd_find_blocking_chains cmd_safe_kill cmd_safe_cancel; do
  if grep -q "^${func}()" pg; then
    echo "函数已实现: $func"
  else
    # Check if it's still referenced in dispatch
    if grep -q "$func" pg; then
      echo "警告: 缺失函数但仍被引用: $func"
    else
      echo "OK: 已移除引用: $func"
    fi
  fi
done

# 5. 检查新增的帮助部分
echo "5. 检查新增帮助部分..."
./pg --help 2>&1 | grep -q "ADVANCED DIAGNOSTICS" && echo "OK: ADVANCED DIAGNOSTICS 存在" || echo "缺失: ADVANCED DIAGNOSTICS"
./pg --help 2>&1 | grep -q "QUERY OPTIMIZATION" && echo "OK: QUERY OPTIMIZATION 存在" || echo "缺失: QUERY OPTIMIZATION"

# 6. 检查版本号
echo "6. 检查版本号..."
grep "TOOL_VERSION=" pg | head -1

echo ""
echo "=== 验证完成 ==="