#!/bin/bash

set -euo pipefail  # 错误时立即退出

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sys_monitor_lib.sh"
source "$SCRIPT_DIR/sys_monitor_config.sh"

# 初始化
init_logger "${LOG_LEVEL:-INFO}" "${REPORT_FILE}"

# 错误捕获
trap 'log_error "脚本异常中断"; exit 1' ERR

# ===== 模块化巡检函数 =====
check_cpu() {
    log_info "开始 CPU 检查"
    local cpu_usage=$(get_cpu_usage)
    check_threshold "$cpu_usage" "$CPU_THRESHOLD" "CPU使用率"
}

check_memory() {
    log_info "开始内存检查"
    local mem_usage=$(get_mem_usage)
    check_threshold "$mem_usage" "$MEM_THRESHOLD" "内存使用率"
}

check_disk() {
    log_info "开始磁盘检查"
    # 实现磁盘检查逻辑
}

# ===== 主流程 =====
main() {
    log_info "=== 系统巡检开始 ==="
    
    check_cpu
    check_memory
    check_disk
    
    log_info "=== 系统巡检完成 ==="
}

main "$@"