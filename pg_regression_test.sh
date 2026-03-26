#!/bin/bash

# pg工具回归测试脚本
# 验证帮助信息与实际功能的一致性

echo "==============================="
echo "pg工具回归测试 - 功能一致性"
echo "==============================="

# 检查pg工具是否存在
if [ ! -f "pg" ]; then
    echo "错误: pg工具不存在"
    exit 1
fi

# 检查是否有psql（即使没有连接也可以测试命令结构）
if ! command -v psql &> /dev/null; then
    echo "警告: 未找到psql客户端，部分测试将无法连接数据库"
    echo "但可以测试命令结构和参数解析"
    echo ""
fi

echo "步骤1: 获取帮助信息中的命令列表"
HELP_OUTPUT=$(./pg --help 2>&1 || true)
ALL_COMMANDS=$(echo "$HELP_OUTPUT" | grep -E '^\s+[a-z_][a-z0-9_-]*' | awk '{print $1}' | sort -u | grep -v '^$')

echo "从帮助信息中提取到的命令:"
echo "$ALL_COMMANDS"
echo ""

echo "步骤2: 验证命令函数是否存在"
MISSING_FUNCTIONS=()
EXISTING_FUNCTIONS=()

for cmd in $ALL_COMMANDS; do
    # 跳过别名和特殊标记
    if [[ "$cmd" =~ ^(===|---|[A-Z_].*)$ ]]; then
        continue
    fi

    # 跳过工具本身的名称
    if [[ "$cmd" == "pg" ]]; then
        EXISTING_FUNCTIONS+=("$cmd")
        echo "✓ $cmd - 工具名称（非命令）"
        continue
    fi

    # 从 dispatch_command 函数中提取所有注册的命令
    # 首先获取 dispatch_command 函数的内容
    dispatch_content=$(awk '/^dispatch_command\(\)/,/^}/' pg)

    # 检查命令是否注册（考虑别名形式 command1|command2)）
    if echo "$dispatch_content" | grep -E "^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*\|)*$cmd(\|[a-zA-Z_][a-zA-Z0-9_-]*)*\)" > /dev/null; then
        EXISTING_FUNCTIONS+=("$cmd")
        echo "✓ $cmd - 已实现"
    else
        MISSING_FUNCTIONS+=("$cmd")
        echo "✗ $cmd - 未实现或注册"
    fi
done

echo ""
echo "==============================="
echo "测试结果汇总"
echo "==============================="
echo "总命令数: $(echo "$ALL_COMMANDS" | wc -w)"
echo "已实现命令: ${#EXISTING_FUNCTIONS[@]}"
echo "缺失命令: ${#MISSING_FUNCTIONS[@]}"

if [ ${#MISSING_FUNCTIONS[@]} -gt 0 ]; then
    echo ""
    echo "缺失的命令列表:"
    printf '%s\n' "${MISSING_FUNCTIONS[@]}"
    echo ""
    echo "⚠️  发现不一致: 帮助信息中列出了但实际未实现的命令"
else
    echo ""
    echo "✅ 帮助信息与实际实现一致"
fi

echo ""
echo "==============================="
echo "步骤3: 测试命令的基本调用"
echo "==============================="

# 对于部分命令，即使没有数据库连接也可以测试参数解析
TESTABLE_COMMANDS="version help"

for cmd in $TESTABLE_COMMANDS; do
    if echo "$ALL_COMMANDS" | grep -q "^$cmd$"; then
        echo "测试命令: $cmd"
        RESULT=$(timeout 10s ./pg "$cmd" 2>&1 || true)
        if [[ $? -ne 124 ]]; then  # 124是timeout返回码
            if [[ "$RESULT" == *"Error:"* ]] && [[ ! "$RESULT" == *"Could not connect"* ]]; then
                echo "  ⚠️  $cmd 产生错误: $(echo "$RESULT" | head -1)"
            else
                echo "  ✓ $cmd 调用成功（或因缺少数据库连接而正确失败）"
            fi
        else
            echo "  ⚠️  $cmd 调用超时"
        fi
    fi
done

echo ""
echo "==============================="
echo "步骤4: 测试新增增强命令"
echo "==============================="

# 测试新增的增强命令
echo "测试 slow_enhanced 命令..."
if ./pg slow_enhanced 2>&1 | grep -q "slow_enhanced\|Slow Query\|Enhanced\|running\|blocking"; then
    echo "  ✓ slow_enhanced 命令可用"
else
    # 可能因为没有数据库连接而失败，但命令应该存在
    RESULT=$(./pg slow_enhanced 2>&1 || true)
    if [[ "$RESULT" == *"Unknown command"* ]] || [[ "$RESULT" == *"unknown"* ]]; then
        echo "  ✗ slow_enhanced 命令未实现"
    else
        echo "  ✓ slow_enhanced 命令已注册（可能需要数据库连接）"
    fi
fi

echo ""
echo "测试 blocking_enhanced 命令..."
if ./pg blocking_enhanced 2>&1 | grep -q "blocking_enhanced\|Blocking\|Enhanced\|lock\|wait"; then
    echo "  ✓ blocking_enhanced 命令可用"
else
    RESULT=$(./pg blocking_enhanced 2>&1 || true)
    if [[ "$RESULT" == *"Unknown command"* ]] || [[ "$RESULT" == *"unknown"* ]]; then
        echo "  ✗ blocking_enhanced 命令未实现"
    else
        echo "  ✓ blocking_enhanced 命令已注册（可能需要数据库连接）"
    fi
fi

echo ""
echo "测试 diagnose 命令帮助..."
DIAGNOSE_HELP=$(./pg diagnose 2>&1 || true)
if [[ "$DIAGNOSE_HELP" == *"diagnose"* ]] && [[ "$DIAGNOSE_HELP" == *"scenario"* ]]; then
    echo "  ✓ diagnose 帮助信息正确显示"
elif [[ "$DIAGNOSE_HELP" == *"Unknown command"* ]] || [[ "$DIAGNOSE_HELP" == *"unknown"* ]]; then
    echo "  ✗ diagnose 命令未实现"
else
    echo "  ✓ diagnose 命令已注册"
fi

echo ""
echo "测试 diagnose health 场景..."
DIAGNOSE_HEALTH=$(./pg diagnose health 2>&1 || true)
if [[ "$DIAGNOSE_HEALTH" == *"health"* ]] || [[ "$DIAGNOSE_HEALTH" == *"Health"* ]] || [[ "$DIAGNOSE_HEALTH" == *"诊断"* ]]; then
    echo "  ✓ diagnose health 场景可用"
elif [[ "$DIAGNOSE_HEALTH" == *"Unknown scenario"* ]]; then
    echo "  ✗ diagnose health 场景未实现"
else
    # 可能因为数据库连接失败，但命令结构应该正确
    echo "  ✓ diagnose health 场景已注册（可能需要数据库连接）"
fi

echo ""
echo "测试 diagnose performance 场景..."
DIAGNOSE_PERF=$(./pg diagnose performance 2>&1 || true)
if [[ "$DIAGNOSE_PERF" == *"performance"* ]] || [[ "$DIAGNOSE_PERF" == *"Performance"* ]] || [[ "$DIAGNOSE_PERF" == *"性能"* ]]; then
    echo "  ✓ diagnose performance 场景可用"
elif [[ "$DIAGNOSE_PERF" == *"Unknown scenario"* ]]; then
    echo "  ✗ diagnose performance 场景未实现"
else
    echo "  ✓ diagnose performance 场景已注册（可能需要数据库连接）"
fi

echo ""
echo "回归测试完成"
echo "建议: 配置数据库连接后进行完整的功能测试"