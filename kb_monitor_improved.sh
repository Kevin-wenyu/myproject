#!/bin/bash

# =================================================================
# 脚本名称: kb_monitor_improved.sh
# 描述: 操作系统 & Kingbase 数据库健康巡检脚本 - 工程化版本
# 数据库版本：V008R007C003B0070
# 说明: 包含系统、网络、数据库、安全、备份、复制槽等监控
# 执行: 建议使用 root 用户执行以获取完整信息
# 版本: V1.0
# 日期：2025-12-26
# By Kevin
# =================================================================

# -----------------------------
# 全局变量定义
# -----------------------------
VERSION="1.0"
SCRIPT_NAME="kb_monitor_improved.sh"
CONFIG_FILE="/etc/kb_monitor.conf"

# 默认配置值
CPU_THRESHOLD=75
MEM_THRESHOLD=75
DISK_THRESHOLD=75
LOAD_THRESHOLD=4.0
CONN_THRESHOLD=1000

KINGBASE_PORT=54321
KINGBASE_USER="system"
KINGBASE_DB="TEST"
KINGBASE_PWD=""
RMAN_DATA="/data/rman"

LOG_KEYWORDS="error|fail|panic|segfault|oom"
REPORT_DIR="/opt/Kingbase/ES/V8/data/sys_log"
REPORT_FILE=""

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# 错误代码定义
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_PERMISSION=3

# -----------------------------
# 日志和报告函数
# -----------------------------

# 打印普通信息
info() {
    echo -e "${CYAN}[INFO]${NC} $1"
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$REPORT_FILE"
}

# 打印警告信息
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$REPORT_FILE"
}

# 打印错误信息
error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$REPORT_FILE"
}

# 打印成功信息
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [SUCCESS] $1" >> "$REPORT_FILE"
}

# 打印标题
print_header() {
    local title="$1"
    local line="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}  ${title}${NC}"
    echo -e "${BLUE}${line}${NC}"
    echo -e "\n${line}" >> "$REPORT_FILE"
    echo -e "  ${title}" >> "$REPORT_FILE"
    echo -e "${line}" >> "$REPORT_FILE"
}

# 打印小节标题
print_section() {
    local title="$1"
    echo -e "\n${YELLOW}【${title}】${NC}"
    echo -e "\n【${title}】" >> "$REPORT_FILE"
}

# -----------------------------
# 配置管理函数
# -----------------------------

# 加载配置文件
load_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        info "加载配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        info "配置文件不存在，使用默认配置"
    fi
}

# 解析命令行参数
parse_args() {
    while getopts "c:u:p:d:r:t:hV" opt; do
        case $opt in
            c) CONFIG_FILE="$OPTARG" ;;
            u) KINGBASE_USER="$OPTARG" ;;
            p) KINGBASE_PWD="$OPTARG" ;;
            d) KINGBASE_DB="$OPTARG" ;;
            r) REPORT_DIR="$OPTARG" ;;
            t) REPORT_FILE="$OPTARG" ;;
            h) show_help ; exit $EXIT_SUCCESS ;;
            V) show_version ; exit $EXIT_SUCCESS ;;
            *) show_help ; exit $EXIT_USAGE ;;
        esac
    done
}

# 初始化配置
init_config() {
    # 创建报告目录
    mkdir -p "$REPORT_DIR" 2>/dev/null
    
    # 设置报告文件名
    if [ -z "$REPORT_FILE" ]; then
        REPORT_FILE="$REPORT_DIR/kb_monitor_$(date +%Y%m%d_%H%M%S).log"
    fi
    
    # 如果密码未通过命令行提供，尝试交互式输入
    if [ -z "$KINGBASE_PWD" ]; then
        read -s -p "请输入 Kingbase 数据库密码: " KINGBASE_PWD
        echo
    fi
    
    # 验证报告目录写入权限
    if [ ! -w "$REPORT_DIR" ]; then
        error "没有写入报告目录的权限: $REPORT_DIR"
        exit $EXIT_PERMISSION
    fi
}

# -----------------------------
# 辅助函数
# -----------------------------

# 比较值与阈值
compare_threshold() {
    local value="$1"
    local threshold="$2"
    awk -v val="$value" -v thr="$threshold" 'BEGIN {if(val>thr) exit 0; else exit 1}'
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否为 root 用户
is_root() {
    [ "$EUID" -eq 0 ]
}

# -----------------------------
# 系统监控函数
# -----------------------------

# 检查系统基本信息
check_system_info() {
    print_header "1. 系统基本信息"
    
    echo "操作系统:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown")"
    echo "内核版本:        $(uname -r)"
    echo "系统架构:        $(uname -m)"
    echo "运行时长:        $(uptime -p 2>/dev/null || uptime | awk -F'up' '{print $2}' | awk -F',' '{print $1}')"
    
    echo "操作系统:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown")" >> "$REPORT_FILE"
    echo "内核版本:        $(uname -r)" >> "$REPORT_FILE"
    echo "系统架构:        $(uname -m)" >> "$REPORT_FILE"
    echo "运行时长:        $(uptime -p 2>/dev/null || uptime | awk -F'up' '{print $2}' | awk -F',' '{print $1}')" >> "$REPORT_FILE"
}

# 检查 CPU 使用率
check_cpu() {
    print_header "2. CPU 使用监控"
    
    local cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'%' -f1)
    local cpu_usage=$(awk "BEGIN {printf \"%.2f\", 100-$cpu_idle}")
    local cpu_status="${GREEN}[正常]${NC}"
    
    compare_threshold "$cpu_usage" "$CPU_THRESHOLD" && cpu_status="${RED}[告警]${NC}"
    
    echo -e "CPU 使用率:      ${cpu_usage}%  ${cpu_status}"
    echo "CPU 核心数:      $(nproc)"
    
    echo "CPU 使用率:      ${cpu_usage}%  $(echo $cpu_status | sed 's/\x1b\[[0-9;]*m//g')" >> "$REPORT_FILE"
    echo "CPU 核心数:      $(nproc)" >> "$REPORT_FILE"
    
    echo -e "\nTop 5 CPU 占用进程:"
    ps -eo pid,user,cmd,%cpu --sort=-%cpu | head -6
    
    echo -e "\nTop 5 CPU 占用进程:" >> "$REPORT_FILE"
    ps -eo pid,user,cmd,%cpu --sort=-%cpu | head -6 >> "$REPORT_FILE"
}

# 检查内存使用率
check_memory() {
    print_header "3. 内存使用监控"
    
    local mem_total=$(free -m | awk '/Mem:/ {print $2}')
    local mem_used=$(free -m | awk '/Mem:/ {print $3}')
    local mem_available=$(free -m | awk '/Mem:/ {print $7}')
    local mem_usage=$(awk "BEGIN {printf \"%.2f\", $mem_used/$mem_total*100}")
    
    local mem_status="${GREEN}[正常]${NC}"
    compare_threshold "$mem_usage" "$MEM_THRESHOLD" && mem_status="${RED}[告警]${NC}"
    
    echo "内存总量:        ${mem_total} MB"
    echo "已用内存:        ${mem_used} MB"
    echo "可用内存:        ${mem_available} MB"
    echo -e "内存使用率:      ${mem_usage}%  ${mem_status}"
    
    echo "内存总量:        ${mem_total} MB" >> "$REPORT_FILE"
    echo "已用内存:        ${mem_used} MB" >> "$REPORT_FILE"
    echo "可用内存:        ${mem_available} MB" >> "$REPORT_FILE"
    echo "内存使用率:      ${mem_usage}%  $(echo $mem_status | sed 's/\x1b\[[0-9;]*m//g')" >> "$REPORT_FILE"
    
    local swap_total=$(free -m | awk '/Swap:/ {print $2}')
    local swap_used=$(free -m | awk '/Swap:/ {print $3}')
    if [ "$swap_total" -gt 0 ]; then
        local swap_usage=$(awk "BEGIN {printf \"%.2f\", $swap_used/$swap_total*100}")
        echo "Swap 使用:       ${swap_usage}% (${swap_used}/${swap_total}MB)"
        echo "Swap 使用:       ${swap_usage}% (${swap_used}/${swap_total}MB)" >> "$REPORT_FILE"
    fi
    
    echo -e "\nTop 5 内存占用进程:"
    ps -eo pid,user,cmd,%mem --sort=-%mem | head -6
    
    echo -e "\nTop 5 内存占用进程:" >> "$REPORT_FILE"
    ps -eo pid,user,cmd,%mem --sort=-%mem | head -6 >> "$REPORT_FILE"
}

# 检查磁盘使用率
check_disk() {
    print_header "4. 磁盘使用监控"
    
    echo "磁盘分区使用:"
    echo "磁盘分区使用:" >> "$REPORT_FILE"
    
    df -h | awk 'NR==1 || /^\/dev/' | while read line; do
        if echo "$line" | grep -q "^Filesystem\|^文件系统"; then
            continue
        fi
        local mount=$(echo "$line" | awk '{print $6}')
        local use=$(echo "$line" | awk '{print $5}')
        local used=$(echo "$line" | awk '{print $3}')
        local size=$(echo "$line" | awk '{print $2}')
        
        local usage=${use%\%}
        if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
            echo -e "  ${mount}: ${RED}${use} [告警]${NC} (${used}/${size})"
            echo -e "  ${mount}: ${use} [告警] (${used}/${size})" >> "$REPORT_FILE"
        else
            echo -e "  ${mount}: ${GREEN}${use} [正常]${NC} (${used}/${size})"
            echo -e "  ${mount}: ${use} [正常] (${used}/${size})" >> "$REPORT_FILE"
        fi
    done
    
    if command_exists iostat; then
        echo -e "\n磁盘 I/O 统计:"
        echo -e "\n磁盘 I/O 统计:" >> "$REPORT_FILE"
        iostat -xm 1 2 2>/dev/null | awk 'NF>=14 && NR>10 && !/^avg/ {printf "  %-10s 读:%.2fMB/s 写:%.2fMB/s 使用率:%.1f%%\n", $1, $6, $7, $NF}'
        iostat -xm 1 2 2>/dev/null | awk 'NF>=14 && NR>10 && !/^avg/ {printf "  %-10s 读:%.2fMB/s 写:%.2fMB/s 使用率:%.1f%%\n", $1, $6, $7, $NF}' >> "$REPORT_FILE"
    fi
}

# 检查系统负载
check_load() {
    print_header "5. 系统负载"
    
    local load_1=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    local load_5=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $2}' | xargs)
    local load_15=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $3}' | xargs)
    
    echo "1分钟负载:       ${load_1}"
    echo "5分钟负载:       ${load_5}"
    echo "15分钟负载:      ${load_15}"
    
    echo "1分钟负载:       ${load_1}" >> "$REPORT_FILE"
    echo "5分钟负载:       ${load_5}" >> "$REPORT_FILE"
    echo "15分钟负载:      ${load_15}" >> "$REPORT_FILE"
}

# 检查网络状态
check_network() {
    print_header "6. 网络状态"
    
    if command_exists ss; then
        local conn_est=$(ss -ant | grep -c ESTAB)
        local conn_timewait=$(ss -ant | grep -c TIME-WAIT)
        
        echo "TCP 连接:"
        echo "  ESTABLISHED:   ${conn_est}"
        echo "  TIME-WAIT:     ${conn_timewait}"
        
        echo "TCP 连接:" >> "$REPORT_FILE"
        echo "  ESTABLISHED:   ${conn_est}" >> "$REPORT_FILE"
        echo "  TIME-WAIT:     ${conn_timewait}" >> "$REPORT_FILE"
        
        compare_threshold "$conn_est" "$CONN_THRESHOLD" && echo -e "  状态: ${RED}[告警]${NC}" || echo -e "  状态: ${GREEN}[正常]${NC}"
        compare_threshold "$conn_est" "$CONN_THRESHOLD" && echo -e "  状态: [告警]" >> "$REPORT_FILE" || echo -e "  状态: [正常]" >> "$REPORT_FILE"
    fi
    
    echo -e "\n防火墙状态:"
    echo -e "\n防火墙状态:" >> "$REPORT_FILE"
    
    if command_exists firewall-cmd; then
        local fw_status=$(firewall-cmd --state 2>/dev/null)
        [ "$fw_status" = "running" ] && echo -e "  firewalld: ${GREEN}运行中${NC}" || echo -e "  firewalld: ${YELLOW}未运行${NC}"
        [ "$fw_status" = "running" ] && echo -e "  firewalld: 运行中" >> "$REPORT_FILE" || echo -e "  firewalld: 未运行" >> "$REPORT_FILE"
    elif command_exists ufw; then
        ufw status 2>/dev/null | grep -q "Status: active" && echo -e "  ufw: ${GREEN}已启用${NC}" || echo -e "  ufw: ${YELLOW}未启用${NC}"
        ufw status 2>/dev/null | grep -q "Status: active" && echo -e "  ufw: 已启用" >> "$REPORT_FILE" || echo -e "  ufw: 未启用" >> "$REPORT_FILE"
    else
        echo "  [未检测到防火墙]"
        echo "  [未检测到防火墙]" >> "$REPORT_FILE"
    fi
}

# 检查进程状态
check_processes() {
    print_header "7. 进程状态"
    
    local total_proc=$(ps aux | wc -l)
    local zombie_count=$(ps aux | awk '$8=="Z"' | wc -l)
    
    echo "总进程数:        ${total_proc}"
    
    echo "总进程数:        ${total_proc}" >> "$REPORT_FILE"
    
    if [ "$zombie_count" -gt 0 ]; then
        echo -e "僵尸进程:        ${RED}${zombie_count} [告警]${NC}"
        echo -e "僵尸进程:        ${zombie_count} [告警]" >> "$REPORT_FILE"
        ps aux | awk '$8=="Z" {printf "  PID:%s CMD:%s\n", $2, $11}'
        ps aux | awk '$8=="Z" {printf "  PID:%s CMD:%s\n", $2, $11}' >> "$REPORT_FILE"
    else
        echo -e "僵尸进程:        ${GREEN}0 [正常]${NC}"
        echo -e "僵尸进程:        0 [正常]" >> "$REPORT_FILE"
    fi
}

# 检查 OOM 记录
check_oom() {
    print_header "8. OOM 内存溢出检查"
    
    if command_exists journalctl; then
        local oom_count=$(journalctl -k --since "7 days ago" 2>/dev/null | grep -ci "out of memory\|oom killer")
        if [ "$oom_count" -gt 0 ]; then
            echo -e "最近7天 OOM: ${RED}${oom_count} 次 [告警]${NC}"
            echo -e "最近7天 OOM: ${oom_count} 次 [告警]" >> "$REPORT_FILE"
            journalctl -k --since "7 days ago" 2>/dev/null | grep -i "killed process" | tail -3 | sed 's/^/  /'
            journalctl -k --since "7 days ago" 2>/dev/null | grep -i "killed process" | tail -3 | sed 's/^/  /' >> "$REPORT_FILE"
        else
            echo -e "最近7天 OOM: ${GREEN}0 次 [正常]${NC}"
            echo -e "最近7天 OOM: 0 次 [正常]" >> "$REPORT_FILE"
        fi
    else
        local oom_dmesg=$(dmesg -T 2>/dev/null | grep -i "out of memory" | tail -3)
        [ -n "$oom_dmesg" ] && echo -e "${RED}发现 OOM:${NC}\n$oom_dmesg" || echo -e "${GREEN}无 OOM 记录${NC}"
        [ -n "$oom_dmesg" ] && echo -e "发现 OOM:\n$oom_dmesg" >> "$REPORT_FILE" || echo -e "无 OOM 记录" >> "$REPORT_FILE"
    fi
}

# 检查磁盘 SMART 健康状态
check_smart() {
    print_header "9. 磁盘 SMART 健康"
    
    if command_exists smartctl && is_root; then
        for disk in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}'); do
            echo -e "\n磁盘: $disk"
            echo -e "\n磁盘: $disk" >> "$REPORT_FILE"
            
            if smartctl -i "$disk" 2>/dev/null | grep -q "SMART support is: Enabled"; then
                local health=$(smartctl -H "$disk" 2>/dev/null | grep "overall-health" | awk -F': ' '{print $2}')
                [ "$health" = "PASSED" ] && echo -e "  状态: ${GREEN}${health}${NC}" || echo -e "  状态: ${RED}${health}${NC}"
                [ "$health" = "PASSED" ] && echo -e "  状态: ${health}" >> "$REPORT_FILE" || echo -e "  状态: ${health}" >> "$REPORT_FILE"
                smartctl -A "$disk" 2>/dev/null | awk '/Reallocated_Sector|Temperature_Celsius|Power_On_Hours/ {print "  "$0}'
                smartctl -A "$disk" 2>/dev/null | awk '/Reallocated_Sector|Temperature_Celsius|Power_On_Hours/ {print "  "$0}' >> "$REPORT_FILE"
            else
                echo "  [SMART 不支持]"
                echo "  [SMART 不支持]" >> "$REPORT_FILE"
            fi
        done
    else
        if ! is_root; then
            warn "需要 root 权限才能运行 SMART 检查"
        else
            warn "未安装 smartmontools"
        fi
    fi
}

# -----------------------------
# 数据库监控函数
# -----------------------------

# 初始化数据库连接信息
init_db_connection() {
    local KB_PID=$(pgrep -f "kingbase.*-D" | head -1)
    if [ -z "$KB_PID" ]; then
        error "数据库进程未运行"
        return $EXIT_ERROR
    fi
    
    KINGBASE_DATA=$(ps -p "$KB_PID" -o args= 2>/dev/null | grep -oP '\-D\s+\K[^\s]+')
    KB_BIN=$(ps -p "$KB_PID" -o args= 2>/dev/null | awk '{print $1}' | xargs dirname)
    KSQL="${KB_BIN}/ksql"
    [ ! -f "$KSQL" ] && KSQL=$(command -v ksql 2>/dev/null)
    
    return $EXIT_SUCCESS
}

# 执行 SQL 查询
exec_sql() {
    local sql="$1"
    "$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "$sql" 2>/dev/null
}

# 检查数据库基本状态
check_db_status() {
    print_header "10. Kingbase 数据库监控"
    
    local KB_PID=$(pgrep -f "kingbase.*-D" | head -1)
    if [ -z "$KB_PID" ]; then
        error "数据库进程未运行"
        return $EXIT_ERROR
    fi
    
    echo -e "数据库进程:      ${GREEN}运行中 (PID: $KB_PID)${NC}"
    echo "数据库进程:      运行中 (PID: $KB_PID)" >> "$REPORT_FILE"
    
    # 初始化数据库连接信息
    init_db_connection
    
    echo "数据目录:        ${KINGBASE_DATA}"
    echo "数据目录:        ${KINGBASE_DATA}" >> "$REPORT_FILE"
    
    # 端口检查
    if ss -lnt 2>/dev/null | grep -q ":$KINGBASE_PORT "; then
        echo -e "监听端口:        ${GREEN}$KINGBASE_PORT [正常]${NC}"
        echo "监听端口:        $KINGBASE_PORT [正常]" >> "$REPORT_FILE"
    else
        echo -e "监听端口:        ${RED}未监听${NC}"
        echo "监听端口:        未监听" >> "$REPORT_FILE"
    fi
    
    # SQL 连接检查
    if [ -n "$KSQL" ] && [ -x "$KSQL" ]; then
        local conn=$(exec_sql "select count(*) from sys_stat_activity;")
        [[ "$conn" =~ ^[0-9]+$ ]] && echo "  当前连接数: $conn" || echo "  [连接失败]"
        [[ "$conn" =~ ^[0-9]+$ ]] && echo "  当前连接数: $conn" >> "$REPORT_FILE" || echo "  [连接失败]" >> "$REPORT_FILE"
        
        local active=$(exec_sql "select count(*) from sys_stat_activity where state='active';")
        [[ "$active" =~ ^[0-9]+$ ]] && echo "  活跃连接数: $active"
        [[ "$active" =~ ^[0-9]+$ ]] && echo "  活跃连接数: $active" >> "$REPORT_FILE"
    fi
    
    return $EXIT_SUCCESS
}

# 检查 WAL 日志状态
check_wal() {
    if [ -z "$KINGBASE_DATA" ]; then
        init_db_connection
    fi
    
    # WAL 检查
    for wal in sys_wal pg_wal sys_xlog; do
        if [ -d "$KINGBASE_DATA/$wal" ]; then
            WAL_DIR="$KINGBASE_DATA/$wal"
            break
        fi
    done
    
    if [ -n "$WAL_DIR" ]; then
        local wal_size=$(du -sh "$WAL_DIR" 2>/dev/null | awk '{print $1}')
        local wal_count=$(ls -1 "$WAL_DIR" 2>/dev/null | wc -l)
        echo -e "\nWAL 日志信息:"
        echo -e "\nWAL 日志信息:" >> "$REPORT_FILE"
        echo "  目录大小:      ${wal_size}"
        echo "  文件数量:      ${wal_count}"
        echo "  目录大小:      ${wal_size}" >> "$REPORT_FILE"
        echo "  文件数量:      ${wal_count}" >> "$REPORT_FILE"
        
        if [ "$wal_count" -gt 500 ]; then
            echo -e "  状态: ${RED}[告警] WAL 文件堆积${NC}"
            echo -e "  状态: [告警] WAL 文件堆积" >> "$REPORT_FILE"
        else
            echo -e "  状态: ${GREEN}[正常]${NC}"
            echo -e "  状态: [正常]" >> "$REPORT_FILE"
        fi
    fi
}

# 检查主备库状态
check_replication_status() {
    if [ -z "$KSQL" ]; then
        init_db_connection
    fi
    
    print_section "主备库状态检查"
    
    # 检查当前节点是否为主库
    local IS_MASTER=$(exec_sql "SELECT sys_is_in_recovery();")
    
    # 如果 sys_is_in_recovery() 返回 'f'，则是主库；如果返回 't'，则是备库
    if [ "$IS_MASTER" == "f" ]; then
        # 当前为主库，显示绿色
        echo -e "${GREEN}  当前节点为主库${NC}"
        echo -e "  当前节点为主库" >> "$REPORT_FILE"
    
        # 查询主库的复制状态，只显示关键字段
        local REPLICATION_STATUS=$(exec_sql "
        SELECT 
            pid, 
            application_name, 
            client_addr, 
            state, 
            sent_lsn, 
            write_lsn, 
            flush_lsn, 
            replay_lsn
        FROM sys_stat_replication
        WHERE state = 'streaming';")
    
        if [ -n "$REPLICATION_STATUS" ]; then
            echo -e "\n  当前主库的复制状态:"
            echo -e "\n  当前主库的复制状态:" >> "$REPORT_FILE"
            # 输出字段并格式化显示
            echo "$REPLICATION_STATUS" | while IFS="|" read pid app_name client_addr state sent_lsn write_lsn flush_lsn replay_lsn; do
                echo -e "    备库应用: $app_name"
                echo -e "    备库地址: $client_addr"
                echo -e "    复制状态: $state"
                echo -e "    发送的 WAL LSN: $sent_lsn"
                echo -e "    写入的 WAL LSN: $write_lsn"
                echo -e "    刷新的 WAL LSN: $flush_lsn"
                echo -e "    回放的 WAL LSN: $replay_lsn"
                echo -e "    -------------------------------"
                
                echo -e "    备库应用: $app_name" >> "$REPORT_FILE"
                echo -e "    备库地址: $client_addr" >> "$REPORT_FILE"
                echo -e "    复制状态: $state" >> "$REPORT_FILE"
                echo -e "    发送的 WAL LSN: $sent_lsn" >> "$REPORT_FILE"
                echo -e "    写入的 WAL LSN: $write_lsn" >> "$REPORT_FILE"
                echo -e "    刷新的 WAL LSN: $flush_lsn" >> "$REPORT_FILE"
                echo -e "    回放的 WAL LSN: $replay_lsn" >> "$REPORT_FILE"
                echo -e "    -------------------------------" >> "$REPORT_FILE"
            done
        else
            echo -e "  当前没有连接的备库"
            echo -e "  当前没有连接的备库" >> "$REPORT_FILE"
        fi
    else
        # 当前为备库，显示黄色
        echo -e "${YELLOW}  当前节点为备库${NC}"
        echo -e "  当前节点为备库" >> "$REPORT_FILE"
    
        # 查询备库的复制接收状态
        local WAL_RECEIVER_STATUS=$(exec_sql "
        SELECT 
            status, 
            receive_start_lsn, 
            received_lsn, 
            latest_end_lsn, 
            sender_host, 
            sender_port
        FROM sys_stat_wal_receiver
        WHERE status = 'streaming';")
    
        if [ -n "$WAL_RECEIVER_STATUS" ]; then
            echo -e "\n  当前备库的复制状态:"
            echo -e "\n  当前备库的复制状态:" >> "$REPORT_FILE"
            # 输出字段并格式化显示
            echo "$WAL_RECEIVER_STATUS" | while IFS="|" read status receive_start_lsn received_lsn latest_end_lsn sender_host sender_port; do
                echo -e "    复制状态: $status"
                echo -e "    接收的起始 WAL LSN: $receive_start_lsn"
                echo -e "    接收到的 WAL LSN: $received_lsn"
                echo -e "    最新接收的 WAL LSN: $latest_end_lsn"
                echo -e "    发送方地址: $sender_host"
                echo -e "    发送方端口: $sender_port"
                echo -e "    -------------------------------"
                
                echo -e "    复制状态: $status" >> "$REPORT_FILE"
                echo -e "    接收的起始 WAL LSN: $receive_start_lsn" >> "$REPORT_FILE"
                echo -e "    接收到的 WAL LSN: $received_lsn" >> "$REPORT_FILE"
                echo -e "    最新接收的 WAL LSN: $latest_end_lsn" >> "$REPORT_FILE"
                echo -e "    发送方地址: $sender_host" >> "$REPORT_FILE"
                echo -e "    发送方端口: $sender_port" >> "$REPORT_FILE"
                echo -e "    -------------------------------" >> "$REPORT_FILE"
            done
        else
            echo -e "  当前备库没有连接主库，无法获取复制状态"
            echo -e "  当前备库没有连接主库，无法获取复制状态" >> "$REPORT_FILE"
        fi
    fi
}

# 检查复制槽状态
check_replication_slots() {
    if [ -z "$KSQL" ]; then
        init_db_connection
    fi
    
    print_section "复制槽检查"
    
    local slot_count=$(exec_sql "select count(*) from sys_replication_slots;")
    
    if [[ "$slot_count" =~ ^[0-9]+$ ]]; then
        echo "  复制槽数量: $slot_count"
        echo "  复制槽数量: $slot_count" >> "$REPORT_FILE"
        
        if [ "$slot_count" -gt 0 ]; then
            echo -e "\n  复制槽详情:"
            echo -e "\n  复制槽详情:" >> "$REPORT_FILE"
            
            local lock_num=0
            local SLOT_DETAILS=$(exec_sql "
                SELECT 
                    slot_name,
                    slot_type,
                    active,
                    xmin,
                    restart_lsn,
                    CASE 
                        WHEN sys_current_wal_lsn() IS NOT NULL AND restart_lsn IS NOT NULL 
                        THEN sys_wal_lsn_diff(sys_current_wal_lsn(), restart_lsn)
                        ELSE 0 
                    END AS wal_lag_bytes
                FROM sys_replication_slots
                ORDER BY wal_lag_bytes DESC;")
            
            echo "$SLOT_DETAILS" | while IFS='|' read slot_name slot_type is_active xmin restart_lsn wal_lag; do
                echo ""
                echo "  ┌─────────────────────────────────────"
                echo "  │ 槽名称: $slot_name"
                echo "  │ 类型:   $slot_type"
                
                echo "" >> "$REPORT_FILE"
                echo "  ┌─────────────────────────────────────" >> "$REPORT_FILE"
                echo "  │ 槽名称: $slot_name" >> "$REPORT_FILE"
                echo "  │ 类型:   $slot_type" >> "$REPORT_FILE"
                
                if [ "$is_active" = "t" ]; then
                    echo -e "  │ 状态:   ${GREEN}活跃${NC}"
                    echo -e "  │ 状态:   活跃" >> "$REPORT_FILE"
                else
                    if [[ "$xmin" != "f" ]]; then
                        echo -e "  │ 状态:   ${RED}非活跃 [告警]${NC}"
                        echo -e "  │ 状态:   非活跃 [告警]" >> "$REPORT_FILE"
                    fi
                fi
                
                if [[ "$wal_lag" =~ ^[0-9]+$ ]] && [ "$wal_lag" -gt 0 ]; then
                    if [ "$wal_lag" -gt 1073741824 ]; then
                        local wal_lag_gb=$(awk "BEGIN {printf \"%.2f\", $wal_lag/1073741824}")
                        local wal_lag_display="${wal_lag_gb} GB"
                    elif [ "$wal_lag" -gt 1048576 ]; then
                        local wal_lag_mb=$(awk "BEGIN {printf \"%.2f\", $wal_lag/1048576}")
                        local wal_lag_display="${wal_lag_mb} MB"
                    else
                        local wal_lag_kb=$(awk "BEGIN {printf \"%.2f\", $wal_lag/1024}")
                        local wal_lag_display="${wal_lag_kb} KB"
                    fi
                    
                    echo "  │ WAL滞后: $wal_lag_display"
                    echo "  │ WAL滞后: $wal_lag_display" >> "$REPORT_FILE"
                    
                    if [ "$wal_lag" -gt 1073741824 ]; then
                        echo -e "  │ ${RED}► 告警: WAL滞后量过大${NC}"
                        echo -e "  │ ► 告警: WAL滞后量过大" >> "$REPORT_FILE"
                    fi
                fi
                
                echo "  │ LSN:    $restart_lsn"
                echo "  └─────────────────────────────────────"
                
                echo "  │ LSN:    $restart_lsn" >> "$REPORT_FILE"
                echo "  └─────────────────────────────────────" >> "$REPORT_FILE"
            done
            
            local inactive_count=$(exec_sql "select count(*) from sys_replication_slots where not active and xmin is not null;")
            
            if [[ "$inactive_count" =~ ^[0-9]+$ ]] && [ "$inactive_count" -gt 0 ]; then
                echo -e "\n  ${RED}发现 $inactive_count 个非活跃复制槽 [严重告警]${NC}"
                echo -e "\n  ${YELLOW}【处理建议】${NC}"
                echo "    1. 检查备库是否运行"
                echo "    2. 删除废弃的复制槽:"
                
                echo -e "\n  发现 $inactive_count 个非活跃复制槽 [严重告警]" >> "$REPORT_FILE"
                echo -e "\n  【处理建议】" >> "$REPORT_FILE"
                echo "    1. 检查备库是否运行" >> "$REPORT_FILE"
                echo "    2. 删除废弃的复制槽:" >> "$REPORT_FILE"
                
                local INACTIVE_SLOTS=$(exec_sql "select slot_name from sys_replication_slots where not active;")
                echo "$INACTIVE_SLOTS" | while read slot; do
                    echo "       SELECT sys_drop_replication_slot('$slot');"
                    echo "       SELECT sys_drop_replication_slot('$slot');" >> "$REPORT_FILE"
                done
            else
                echo -e "\n  ${GREEN}所有复制槽状态正常${NC}"
                echo -e "\n  所有复制槽状态正常" >> "$REPORT_FILE"
            fi
        else
            echo -e "  ${GREEN}未配置复制槽${NC}"
            echo -e "  未配置复制槽" >> "$REPORT_FILE"
        fi
    fi
}

# 检查锁状态
check_locks() {
    if [ -z "$KSQL" ]; then
        init_db_connection
    fi
    
    print_section "锁状态检查"
    
    local lock_wait=$(exec_sql "select count(*) from sys_stat_activity where wait_event_type='Lock';")
    [[ "$lock_wait" =~ ^[0-9]+$ ]] && echo "  等待锁的会话: $lock_wait"
    [[ "$lock_wait" =~ ^[0-9]+$ ]] && echo "  等待锁的会话: $lock_wait" >> "$REPORT_FILE"
    
    local blocked=$(exec_sql "select count(*) from sys_locks where not granted;")
    if [[ "$blocked" =~ ^[0-9]+$ ]]; then
        if [ "$blocked" -gt 0 ]; then
            echo -e "  阻塞的锁请求: ${RED}$blocked 个 [告警]${NC}"
            
            echo -e "  阻塞的锁请求: $blocked 个 [告警]" >> "$REPORT_FILE"
            
            echo -e "\n  ${YELLOW}锁冲突详情:${NC}"
            echo -e "\n  锁冲突详情:" >> "$REPORT_FILE"
            
            local lock_detail_num=0
            local LOCK_DETAILS=$(exec_sql "
                SELECT 
                    blocked_locks.pid AS blocked_pid,
                    blocked_activity.usename AS blocked_user,
                    blocking_locks.pid AS blocking_pid,
                    blocking_activity.usename AS blocking_user,
                    left(blocked_activity.query, 60) AS blocked_query
                FROM sys_catalog.sys_locks blocked_locks
                JOIN sys_catalog.sys_stat_activity blocked_activity 
                    ON blocked_activity.pid = blocked_locks.pid
                JOIN sys_catalog.sys_locks blocking_locks 
                    ON blocking_locks.locktype = blocked_locks.locktype
                    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
                    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
                    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
                    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
                    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
                    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
                    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
                    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
                    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
                    AND blocking_locks.pid != blocked_locks.pid
                JOIN sys_catalog.sys_stat_activity blocking_activity 
                    ON blocking_activity.pid = blocking_locks.pid
                WHERE NOT blocked_locks.granted
                LIMIT 5;")
            
            echo "$LOCK_DETAILS" | while IFS='|' read blocked_pid blocked_user blocking_pid blocking_user blocked_query; do
                lock_detail_num=$((lock_detail_num + 1))
                echo ""
                echo -e "  ${RED}► 锁冲突 #${lock_detail_num}${NC}"
                echo "    被阻塞进程: PID=$blocked_pid, 用户=$blocked_user"
                echo "    阻塞者进程: PID=$blocking_pid, 用户=$blocking_user"
                echo "    被阻塞SQL: $blocked_query..."
                echo "    ────────────────────────────────"
                
                echo "" >> "$REPORT_FILE"
                echo "  ► 锁冲突 #${lock_detail_num}" >> "$REPORT_FILE"
                echo "    被阻塞进程: PID=$blocked_pid, 用户=$blocked_user" >> "$REPORT_FILE"
                echo "    阻塞者进程: PID=$blocking_pid, 用户=$blocking_user" >> "$REPORT_FILE"
                echo "    被阻塞SQL: $blocked_query..." >> "$REPORT_FILE"
                echo "    ────────────────────────────────" >> "$REPORT_FILE"
            done
            
            echo -e "\n  ${YELLOW}【处理建议】${NC}"
            echo "    终止阻塞进程: SELECT sys_terminate_backend(<blocking_pid>);"
            
            echo -e "\n  【处理建议】" >> "$REPORT_FILE"
            echo "    终止阻塞进程: SELECT sys_terminate_backend(<blocking_pid>);" >> "$REPORT_FILE"
        else
            echo -e "  阻塞的锁请求: ${GREEN}0 个 [正常]${NC}"
            echo -e "  阻塞的锁请求: 0 个 [正常]" >> "$REPORT_FILE"
        fi
    fi
}

# 检查长查询
check_long_queries() {
    if [ -z "$KSQL" ]; then
        init_db_connection
    fi
    
    print_section "长查询检查"
    
    local long_count=$(exec_sql "select count(*) from sys_stat_activity where state<>'idle' and now()-query_start > interval '60 minutes';")
    
    if [[ "$long_count" =~ ^[0-9]+$ ]] && [ "$long_count" -gt 0 ]; then
        echo -e "  ${RED}发现 $long_count 个长查询 [告警]${NC}"
        
        echo -e "  发现 $long_count 个长查询 [告警]" >> "$REPORT_FILE"
        
        local query_num=0
        local LONG_QUERIES=$(exec_sql "
            SELECT 
                pid,
                usename,
                EXTRACT(EPOCH FROM (now()-query_start))::int AS duration_sec,
                left(query, 60) AS query_preview
            FROM sys_stat_activity 
            WHERE state='active' 
                AND now()-query_start > interval '5 minutes'
            ORDER BY query_start
            LIMIT 5;")
        
        echo "$LONG_QUERIES" | while IFS='|' read pid user duration query; do
            query_num=$((query_num + 1))
            local duration_min=$((duration / 60))
            echo ""
            echo -e "  ${RED}► 长查询 #${query_num}${NC}"
            echo "    PID: $pid, 用户: $user"
            echo "    运行: ${duration_min}分钟"
            echo "    SQL: $query..."
            
            echo "" >> "$REPORT_FILE"
            echo "  ► 长查询 #${query_num}" >> "$REPORT_FILE"
            echo "    PID: $pid, 用户: $user" >> "$REPORT_FILE"
            echo "    运行: ${duration_min}分钟" >> "$REPORT_FILE"
            echo "    SQL: $query..." >> "$REPORT_FILE"
        done
        
        echo -e "\n  ${YELLOW}【处理建议】${NC}"
        echo "    终止查询: SELECT sys_cancel_backend(<pid>);"
        
        echo -e "\n  【处理建议】" >> "$REPORT_FILE"
        echo "    终止查询: SELECT sys_cancel_backend(<pid>);" >> "$REPORT_FILE"
    else
        echo -e "  ${GREEN}无长查询 [正常]${NC}"
        echo -e "  无长查询 [正常]" >> "$REPORT_FILE"
    fi
}

# 检查数据库大小
check_db_size() {
    if [ -z "$KSQL" ]; then
        init_db_connection
    fi
    
    print_section "数据库大小统计"
    
    local DB_SIZES=$(exec_sql "
        SELECT 
            datname, 
            sys_size_pretty(sys_database_size(datname)) AS size
        FROM sys_database 
        WHERE datname NOT IN ('template0', 'template1')
        ORDER BY sys_database_size(datname) DESC 
        LIMIT 5;")
    
    echo "$DB_SIZES" | while IFS='|' read dbname size; do
        echo "  $dbname: $size"
        echo "  $dbname: $size" >> "$REPORT_FILE"
    done
}

# 检查 RMAN 备份
check_rman_backup() {
    if [ -z "$KB_BIN" ]; then
        init_db_connection
    fi
    
    print_section "sys_rman 备份检查"
    
    local RMAN_BIN="${KB_BIN}/sys_rman"
    [ ! -f "$RMAN_BIN" ] && RMAN_BIN=$(command -v sys_rman 2>/dev/null)
    
    # 检查 sys_rman 是否存在
    if [ -n "$RMAN_BIN" ] && [ -x "$RMAN_BIN" ]; then
        echo "sys_rman路径:    $RMAN_BIN"
        echo "sys_rman路径:    $RMAN_BIN" >> "$REPORT_FILE"
        
        # 检查路径是否存在
        if [ -n "$RMAN_DATA" ] && [ -d "$RMAN_DATA" ]; then
            # 获取备份信息
            local BACKUP_INFO=$($RMAN_BIN show -B "$RMAN_DATA" 2>/dev/null)
        
            if [ -n "$BACKUP_INFO" ]; then
                echo -e "\n${YELLOW}【备份信息】${NC}"
                echo -e "\n$BACKUP_INFO"
                
                echo -e "\n【备份信息】" >> "$REPORT_FILE"
                echo -e "\n$BACKUP_INFO" >> "$REPORT_FILE"
            else
                echo -e "  ${YELLOW}未找到备份信息${NC}"
                echo -e "  未找到备份信息" >> "$REPORT_FILE"
            fi
        fi
    else
        echo -e "sys_rman 工具未找到${YELLOW}${NC}"
        echo -e "sys_rman 工具未找到" >> "$REPORT_FILE"
    fi
}

# -----------------------------
# 安全监控函数
# -----------------------------

# 检查系统日志
check_system_logs() {
    print_header "11. 系统日志检查"
    
    echo "系统错误日志 (最近10条):"
    echo "系统错误日志 (最近10条):" >> "$REPORT_FILE"
    
    if command_exists journalctl; then
        journalctl -p err -n 10 --no-pager 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  无错误日志"
        journalctl -p err -n 10 --no-pager 2>/dev/null | tail -10 | sed 's/^/  /' >> "$REPORT_FILE" 2>/dev/null || echo "  无错误日志" >> "$REPORT_FILE"
    else
        grep -iE "$LOG_KEYWORDS" /var/log/messages 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  无匹配日志"
        grep -iE "$LOG_KEYWORDS" /var/log/messages 2>/dev/null | tail -10 | sed 's/^/  /' >> "$REPORT_FILE" 2>/dev/null || echo "  无匹配日志" >> "$REPORT_FILE"
    fi
}

# 检查安全相关事件
check_security_events() {
    print_header "12. 安全检查"
    
    echo "SSH 失败登录 (最近5次):"
    echo "SSH 失败登录 (最近5次):" >> "$REPORT_FILE"
    
    if [ -f /var/log/secure ]; then
        grep "Failed password" /var/log/secure 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  无记录"
        grep "Failed password" /var/log/secure 2>/dev/null | tail -5 | sed 's/^/  /' >> "$REPORT_FILE" 2>/dev/null || echo "  无记录" >> "$REPORT_FILE"
    elif [ -f /var/log/auth.log ]; then
        grep "Failed password" /var/log/auth.log 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  无记录"
        grep "Failed password" /var/log/auth.log 2>/dev/null | tail -5 | sed 's/^/  /' >> "$REPORT_FILE" 2>/dev/null || echo "  无记录" >> "$REPORT_FILE"
    else
        echo "  日志文件不存在"
        echo "  日志文件不存在" >> "$REPORT_FILE"
    fi
}

# -----------------------------
# 主函数
# -----------------------------

# 显示帮助信息
show_help() {
    echo -e "${MAGENTA}$SCRIPT_NAME${NC} - Kingbase 数据库健康巡检脚本\n"
    echo -e "${BLUE}用法:${NC} $SCRIPT_NAME [选项]\n"
    echo -e "${BLUE}选项:${NC}"
    echo -e "  -c <配置文件>    指定配置文件路径 (默认: /etc/kb_monitor.conf)"
    echo -e "  -u <用户名>      Kingbase 数据库用户名 (默认: system)"
    echo -e "  -p <密码>        Kingbase 数据库密码"
    echo -e "  -d <数据库>      数据库名称 (默认: TEST)"
    echo -e "  -r <报告目录>    报告输出目录 (默认: /opt/Kingbase/ES/V8/data/sys_log)"
    echo -e "  -t <报告文件>    报告文件名 (默认: kb_monitor_YYYYMMDD_HHMMSS.log)"
    echo -e "  -h               显示帮助信息"
    echo -e "  -V               显示版本信息\n"
    echo -e "${BLUE}示例:${NC}"
    echo -e "  $SCRIPT_NAME -u system -p password123 -d TEST"
    echo -e "  $SCRIPT_NAME -c /path/to/config.conf -r /tmp/reports\n"
}

# 显示版本信息
show_version() {
    echo -e "${MAGENTA}$SCRIPT_NAME${NC} 版本 ${VERSION}\n"
    echo "Kingbase 数据库健康巡检脚本 - 工程化版本"
    echo "© 2025 Kevin"
}

# 打印巡检总结
print_summary() {
    print_header "巡检总结"
    
    success "巡检完成"
    echo "报告位置: ${REPORT_FILE}"
    echo "报告位置: ${REPORT_FILE}" >> "$REPORT_FILE"
    
    echo -e "\n关键检查项:"
    echo -e "\n关键检查项:" >> "$REPORT_FILE"
    
    echo "  ✓ 系统资源 (CPU/内存/磁盘)"
    echo "  ✓ 数据库状态 (连接/锁/WAL)"
    echo "  ✓ 复制槽监控 (防止WAL堆积)"
    echo "  ✓ sys_rman备份"
    echo "  ✓ 安全日志"
    
    echo "  ✓ 系统资源 (CPU/内存/磁盘)" >> "$REPORT_FILE"
    echo "  ✓ 数据库状态 (连接/锁/WAL)" >> "$REPORT_FILE"
    echo "  ✓ 复制槽监控 (防止WAL堆积)" >> "$REPORT_FILE"
    echo "  ✓ sys_rman备份" >> "$REPORT_FILE"
    echo "  ✓ 安全日志" >> "$REPORT_FILE"
    
    echo -e "\n${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "\n═══════════════════════════════════════════════════════" >> "$REPORT_FILE"
}

# 主执行函数
main() {
    # 解析命令行参数
    parse_args "$@"
    
    # 加载配置文件
    load_config_file
    
    # 初始化配置
    init_config
    
    # 权限检查
    if [ "$EUID" -ne 0 ]; then
        warn "建议使用 root 执行以获取完整信息"
    fi
    
    # 打印报告头部
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}" > "$REPORT_FILE"
    echo -e "${CYAN}     企业级系统 & Kingbase 数据库健康巡检报告               ${NC}" >> "$REPORT_FILE"
    echo -e "${CYAN}     检查时间: $(date '+%Y-%m-%d %H:%M:%S')              ${NC}" >> "$REPORT_FILE"
    echo -e "${CYAN}     主机名称: $(hostname -i)                            ${NC}" >> "$REPORT_FILE"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}" >> "$REPORT_FILE"
    
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}     企业级系统 & Kingbase 数据库健康巡检报告               ${NC}"
    echo -e "${CYAN}     检查时间: $(date '+%Y-%m-%d %H:%M:%S')              ${NC}"
    echo -e "${CYAN}     主机名称: $(hostname -i)                            ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    
    # 执行系统监控
    check_system_info
    check_cpu
    check_memory
    check_disk
    check_load
    check_network
    check_processes
    check_oom
    check_smart
    
    # 执行数据库监控
    check_db_status
    if [ $? -eq $EXIT_SUCCESS ]; then
        check_wal
        check_replication_status
        check_replication_slots
        check_locks
        check_long_queries
        check_db_size
        check_rman_backup
    fi
    
    # 执行安全监控
    check_system_logs
    check_security_events
    
    # 打印总结
    print_summary
    
    exit $EXIT_SUCCESS
}

# -----------------------------
# 脚本入口
# -----------------------------

# 执行主函数
main "$@"