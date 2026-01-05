#!/bin/bash

# =================================================================
# 脚本名称: sys_monitor_enterprise_enhanced.sh
# 描述: 企业级系统 & Kingbase 数据库全面健康巡检脚本（增强版）
# 说明: 包含系统、网络、数据库、安全等全方位监控指标
# =================================================================

# ---------------- 配置区 ----------------
CPU_THRESHOLD=75
MEM_THRESHOLD=75
DISK_THRESHOLD=75
INODE_THRESHOLD=75
LOAD_THRESHOLD=4.0
CONN_THRESHOLD=1000
FILE_DESC_THRESHOLD=80

KINGBASE_PORT=54321
KINGBASE_USER="SYSTEM"
KINGBASE_DB="TEST"

# 日志匹配关键字
LOG_KEYWORDS="error|fail|panic|segfault|oom|killed"

# 报告输出文件（可选）
REPORT_FILE="/tmp/sys_monitor_$(date +%Y%m%d_%H%M%S).log"

# ---------------- 颜色 ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------- 辅助函数 ----------------
print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

compare_threshold() {
    local value=$1
    local threshold=$2
    if (( $(echo "$value > $threshold" | bc -l 2>/dev/null) )); then
        return 0
    else
        return 1
    fi
}

# ---------------- 开始巡检 ----------------
exec > >(tee -a "$REPORT_FILE")
exec 2>&1

echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     企业级系统 & Kingbase 数据库健康巡检报告          ║${NC}"
echo -e "${CYAN}║     检查时间: $(date '+%Y-%m-%d %H:%M:%S')                   ║${NC}"
echo -e "${CYAN}║     主机名称: $(hostname)                              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"

# =====================================================
# 1. 系统基本信息
# =====================================================
print_header "1. 系统基本信息"

echo "操作系统:        $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
echo "内核版本:        $(uname -r)"
echo "系统架构:        $(uname -m)"
echo "运行时长:        $(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')"
echo "当前用户:        $(whoami)"
echo "登录用户数:      $(who | wc -l)"

# =====================================================
# 2. CPU 监控
# =====================================================
print_header "2. CPU 使用监控"

cpu_idle=$(top -bn1 | awk -F',' '/Cpu\(s\)/ {print $4}' | awk '{print $1}')
cpu_usage=$(echo "scale=2; 100 - $cpu_idle" | bc 2>/dev/null)
cpu_status="${GREEN}[正常]${NC}"
if compare_threshold "$cpu_usage" "$CPU_THRESHOLD"; then
    cpu_status="${RED}[告警]${NC}"
fi
echo -e "CPU 使用率:      ${cpu_usage}%  ${cpu_status}"

# CPU 核心数
cpu_cores=$(nproc)
echo "CPU 核心数:      ${cpu_cores}"

# CPU 上下文切换和中断（显示速率更有意义）
echo -e "\nCPU 性能指标（每秒）:"
if [ -f /proc/stat ]; then
    ctx1=$(awk '/^ctxt/ {print $2}' /proc/stat)
    intr1=$(awk '/^intr/ {print $2}' /proc/stat)
    sleep 1
    ctx2=$(awk '/^ctxt/ {print $2}' /proc/stat)
    intr2=$(awk '/^intr/ {print $2}' /proc/stat)
    
    ctx_rate=$((ctx2 - ctx1))
    intr_rate=$((intr2 - intr1))
    
    echo "  上下文切换: ${ctx_rate}/秒"
    echo "  中断次数: ${intr_rate}/秒"
    
    # 上下文切换过高告警（根据CPU核心数调整）
    threshold=$((cpu_cores * 10000))
    if [ "$ctx_rate" -gt "$threshold" ]; then
        echo -e "  状态: ${RED}[告警] 上下文切换过高${NC}"
    else
        echo -e "  状态: ${GREEN}[正常]${NC}"
    fi
fi

echo -e "\nTop 5 CPU 占用进程:"
ps -eo pid,user,cmd,%cpu --sort=-%cpu | head -6

# =====================================================
# 3. 内存监控
# =====================================================
print_header "3. 内存使用监控"

mem_total=$(free -m | awk '/Mem:/ {print $2}')
mem_used=$(free -m | awk '/Mem:/ {print $3}')
mem_free=$(free -m | awk '/Mem:/ {print $4}')
mem_available=$(free -m | awk '/Mem:/ {print $7}')
mem_usage=$(echo "scale=2; $mem_used/$mem_total*100" | bc 2>/dev/null)
mem_buffers=$(free -m | awk '/Mem:/ {print $6}')
mem_cached=$(free -m | awk '/Mem:/ {print $6}')

mem_status="${GREEN}[正常]${NC}"
if compare_threshold "$mem_usage" "$MEM_THRESHOLD"; then
    mem_status="${RED}[告警]${NC}"
fi

echo -e "内存总量:        ${mem_total} MB"
echo -e "已用内存:        ${mem_used} MB"
echo -e "可用内存:        ${mem_available} MB"
echo -e "内存使用率:      ${mem_usage}%  ${mem_status}"

# Swap
swap_total=$(free -m | awk '/Swap:/ {print $2}')
swap_used=$(free -m | awk '/Swap:/ {print $3}')
if [ "$swap_total" -gt 0 ]; then
    swap_usage=$(echo "scale=2; $swap_used/$swap_total*100" | bc 2>/dev/null)
else
    swap_usage=0
fi
echo -e "Swap 使用率:     ${swap_usage}% (${swap_used}MB/${swap_total}MB)"

# 内存碎片化（简化显示）
echo -e "\n内存碎片化程度:"
if [ -f /proc/buddyinfo ]; then
    # 统计 order 0 (4KB) 的空闲页面数，页面少说明碎片化严重
    total_order0=$(awk '{sum+=$5} END {print sum}' /proc/buddyinfo)
    total_order3=$(awk '{sum+=$8} END {print sum}' /proc/buddyinfo)
    if [ "$total_order0" -gt 10000 ]; then
        echo -e "  4KB空闲页: ${GREEN}${total_order0} [正常]${NC}"
    else
        echo -e "  4KB空闲页: ${RED}${total_order0} [碎片化严重]${NC}"
    fi
    echo "  32KB空闲页: ${total_order3}"
else
    echo "  [buddyinfo 不可用]"
fi

echo -e "\nTop 5 内存占用进程:"
ps -eo pid,user,cmd,%mem --sort=-%mem | head -6

# =====================================================
# 4. 磁盘监控
# =====================================================
print_header "4. 磁盘使用监控"

echo "磁盘分区使用情况:"
df -h | awk 'NR>1 && /^\/dev/' | while read fs size used avail use mount; do
    usage=${use%\%}
    if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
        echo -e "  ${mount}: ${RED}${use} [告警]${NC} (已用: ${used}/${size})"
    else
        echo -e "  ${mount}: ${GREEN}${use} [正常]${NC} (已用: ${used}/${size})"
    fi
done

echo -e "\n磁盘 inode 使用率:"
df -i | awk 'NR>1 && /^\/dev/' | while read fs itot iused iavail iuse mount; do
    if [[ "$iuse" == "-" ]]; then
        iuse_num=0
    else
        iuse_num=${iuse%\%}
    fi
    if [ "$iuse_num" -ge "$INODE_THRESHOLD" ]; then
        echo -e "  ${mount}: ${RED}${iuse} [告警]${NC}"
    else
        echo -e "  ${mount}: ${GREEN}${iuse} [正常]${NC}"
    fi
done

echo -e "\n磁盘 I/O 统计（最近2秒平均值）:"
if command -v iostat >/dev/null 2>&1; then
    iostat -dx 1 2 | tail -n +4 | awk 'NF>0 && !/^$/ && !/Device/ {
        if(NR%2==0) printf "  %-10s  读: %6.2f MB/s  写: %6.2f MB/s  使用率: %5.1f%%\n", $1, $6/1024, $7/1024, $NF
    }'
else
    echo "  [未安装 sysstat 工具包，建议安装: yum install sysstat]"
fi

# 磁盘读写统计（增量有意义，累计值参考价值有限）
echo -e "\n磁盘读写活动（实时）:"
if command -v iostat >/dev/null 2>&1; then
    echo "  [使用 iostat 查看详细 I/O 统计，见上方]"
elif [ -f /proc/diskstats ]; then
    echo "  磁盘设备当前队列情况:"
    awk '$3!~"loop|ram" && $3~"^[sv]d[a-z]$|^nvme" {printf "  %s: 进行中IO=%s\n", $3, $12}' /proc/diskstats | head -5
else
    echo "  [无法获取磁盘统计信息]"
fi

# =====================================================
# 5. 系统负载监控
# =====================================================
print_header "5. 系统负载监控"

load_1=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
load_5=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $2}' | xargs)
load_15=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $3}' | xargs)

echo -e "1分钟负载:       ${load_1}"
echo -e "5分钟负载:       ${load_5}"
echo -e "15分钟负载:      ${load_15}"

if compare_threshold "$load_5" "$LOAD_THRESHOLD"; then
    echo -e "负载状态:        ${RED}[告警] 5分钟负载超过阈值${NC}"
else
    echo -e "负载状态:        ${GREEN}[正常]${NC}"
fi

# 运行队列
run_queue=$(cat /proc/loadavg | awk '{print $4}')
echo "运行队列:        ${run_queue}"

# =====================================================
# 6. 网络监控
# =====================================================
print_header "6. 网络状态监控"

if command -v ss >/dev/null 2>&1; then
    echo "TCP 连接状态统计:"
    ss -s | grep -A 5 "TCP:"
    
    conn_est=$(ss -ant | grep ESTAB | wc -l)
    conn_timewait=$(ss -ant | grep TIME-WAIT | wc -l)
    conn_listen=$(ss -lnt | wc -l)
    
    echo -e "\nTCP 连接详情:"
    echo "  ESTABLISHED:   ${conn_est}"
    echo "  TIME-WAIT:     ${conn_timewait}"
    echo "  LISTEN:        ${conn_listen}"
    
    if [ "$conn_est" -ge "$CONN_THRESHOLD" ]; then
        echo -e "  状态: ${RED}[告警] 连接数过高${NC}"
    else
        echo -e "  状态: ${GREEN}[正常]${NC}"
    fi
fi

# 网络接口统计（关注错误和丢包）
echo -e "\n网络接口状态（错误和丢包）:"
if command -v ip >/dev/null 2>&1; then
    ip -s link show | awk '
        /^[0-9]+:/ {iface=$2; gsub(/:/, "", iface)}
        /RX:.*errors/ {getline; rx_err=$3; rx_drop=$4}
        /TX:.*errors/ {getline; tx_err=$3; tx_drop=$4; 
            if(iface!="lo") printf "  %s: RX丢包=%s RX错误=%s | TX丢包=%s TX错误=%s\n", iface, rx_drop, rx_err, tx_drop, tx_err
        }
    ' | head -5
else
    netstat -i 2>/dev/null | awk 'NR>2 && $1!="lo" {printf "  %s: RX-ERR=%s TX-ERR=%s\n", $1, $4, $8}' | head -5
fi

# 网络错误（聚焦于异常指标）
echo -e "\n网络异常统计:"
if command -v netstat >/dev/null 2>&1; then
    netstat -s 2>/dev/null | awk '
        /segments retransmitted/ {print "  TCP重传: " $1}
        /bad segments received/ {print "  TCP坏包: " $1}
        /packets received$/ && /UDP/ {udp_in=$1}
        /packet receive errors/ && /UDP/ {print "  UDP接收错误: " $1}
        /packets to unknown port received/ {print "  UDP未知端口: " $1}
    ' | head -8
else
    echo "  [netstat 不可用，跳过详细统计]"
fi

# 防火墙状态（简化检查）
echo -e "\n防火墙状态:"
if command -v firewall-cmd >/dev/null 2>&1; then
    fw_status=$(firewall-cmd --state 2>/dev/null)
    if [ "$fw_status" = "running" ]; then
        echo -e "  firewalld: ${GREEN}运行中${NC}"
        active_zone=$(firewall-cmd --get-active-zones 2>/dev/null | head -1)
        [ -n "$active_zone" ] && echo "  活动区域: $active_zone"
    else
        echo -e "  firewalld: ${YELLOW}未运行${NC}"
    fi
elif command -v ufw >/dev/null 2>&1; then
    ufw_status=$(ufw status 2>/dev/null | head -1)
    if echo "$ufw_status" | grep -q "active"; then
        echo -e "  ufw: ${GREEN}已启用${NC}"
    else
        echo -e "  ufw: ${YELLOW}未启用${NC}"
    fi
elif command -v iptables >/dev/null 2>&1; then
    ipt_count=$(iptables -L -n 2>/dev/null | grep -c "^Chain" 2>/dev/null)
    if [ "$ipt_count" -gt 0 ]; then
        echo -e "  iptables: ${GREEN}已配置规则${NC} (链数: $ipt_count)"
    else
        echo "  iptables: [需要 root 权限查看]"
    fi
else
    echo "  [未检测到防火墙工具]"
fi

# =====================================================
# 7. 进程监控
# =====================================================
print_header "7. 进程状态监控"

total_processes=$(ps aux | wc -l)
running_processes=$(ps -eo stat | grep R | wc -l)
sleeping_processes=$(ps -eo stat | grep S | wc -l)
zombie_count=$(ps aux | awk '{if($8=="Z") print $0}' | wc -l)

echo "总进程数:        ${total_processes}"
echo "运行中进程:      ${running_processes}"
echo "睡眠进程:        ${sleeping_processes}"

if [ "$zombie_count" -gt 0 ]; then
    echo -e "僵尸进程数:      ${RED}${zombie_count} [告警]${NC}"
    echo "僵尸进程列表:"
    ps aux | awk '{if($8=="Z") print "  PID:"$2" PPID:"$3" CMD:"$11}'
else
    echo -e "僵尸进程数:      ${GREEN}${zombie_count} [正常]${NC}"
fi

# =====================================================
# 8. 文件描述符监控
# =====================================================
print_header "8. 文件描述符监控"

fd_allocated=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
fd_max=$(cat /proc/sys/fs/file-nr | awk '{print $3}')
fd_usage=$(echo "scale=2; $fd_allocated/$fd_max*100" | bc 2>/dev/null)

echo "已分配文件描述符: ${fd_allocated}"
echo "最大文件描述符:   ${fd_max}"
echo -e "文件描述符使用率: ${fd_usage}%"

if compare_threshold "$fd_usage" "$FILE_DESC_THRESHOLD"; then
    echo -e "状态:             ${RED}[告警]${NC}"
else
    echo -e "状态:             ${GREEN}[正常]${NC}"
fi

# 输出Top 5 打开文件描述符最多的进程
echo -e "\nTop 5 打开文件描述符最多的进程:"

# 检查lsof是否可用
if command -v lsof >/dev/null 2>&1; then
    # 获取所有进程的PID，并计算每个进程打开的文件数，按文件数降序排列，显示前5个进程
    lsof | awk '{print $2}' | sort | uniq -c | sort -nr | head -n 5
else
    echo "lsof 命令不可用，尝试使用其他方法"

    # 使用/proc目录中的信息来计算
    for pid in $(ls /proc | grep -E '^[0-9]+$'); do
        # 检查进程是否存在以及是否有打开的文件
        if [ -d "/proc/$pid/fd" ]; then
            open_files=$(ls /proc/$pid/fd | wc -l)
            echo "PID $pid 打开文件数: $open_files"
        fi
    done | sort -k3 -nr | head -n 5
fi

# =====================================================
# 9. OOM（内存溢出）历史检查
# =====================================================
print_header "9. OOM 内存溢出检查"

echo "检查最近的 OOM Killer 事件:"
if command -v journalctl >/dev/null 2>&1; then
    oom_count=$(journalctl -k --since "7 days ago" 2>/dev/null | grep -i "out of memory\|oom" | wc -l)
    if [ "$oom_count" -gt 0 ]; then
        echo -e "  最近7天 OOM 事件: ${RED}${oom_count} 次 [告警]${NC}"
        echo -e "\n  最近的 OOM 记录:"
        journalctl -k --since "7 days ago" 2>/dev/null | grep -i "out of memory\|oom" | tail -5 | while read line; do
            echo "    $line"
        done
    else
        echo -e "  最近7天 OOM 事件: ${GREEN}0 次 [正常]${NC}"
    fi
else
    # 从 dmesg 检查
    oom_dmesg=$(dmesg -T 2>/dev/null | grep -i "out of memory\|oom" | tail -5)
    if [ -n "$oom_dmesg" ]; then
        echo -e "  发现 OOM 记录: ${RED}[告警]${NC}"
        echo "$oom_dmesg" | while read line; do
            echo "    $line"
        done
    else
        echo -e "  OOM 记录: ${GREEN}未发现 [正常]${NC}"
    fi
fi

# 检查被 OOM Killer 杀掉的进程
echo -e "\n被 OOM Killer 终止的进程:"
if command -v journalctl >/dev/null 2>&1; then
    killed_procs=$(journalctl -k --since "7 days ago" 2>/dev/null | grep -i "killed process" | tail -5)
    if [ -n "$killed_procs" ]; then
        echo "$killed_procs" | while read line; do
            echo "  $line"
        done
    else
        echo "  无进程被终止"
    fi
else
    echo "  [journalctl 不可用]"
fi

# 当前内存压力
echo -e "\n当前内存压力指标:"
if [ -f /proc/pressure/memory ]; then
    echo "  内存压力信息:"
    cat /proc/pressure/memory | while read line; do
        echo "    $line"
    done
else
    # 替代方案：检查 vm.min_free_kbytes
    min_free=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
    [ -n "$min_free" ] && echo "  最小保留内存: $((min_free/1024)) MB"
fi

# =====================================================
# 10. 磁盘 SMART 健康检查
# =====================================================
print_header "10. 磁盘 SMART 健康状态"

if command -v smartctl >/dev/null 2>&1; then
    echo "扫描物理磁盘 SMART 信息:"
    # 查找所有物理磁盘
    for disk in $(lsblk -d -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}'); do
        echo -e "\n磁盘: ${disk}"
        
        # SMART 健康状态
        smart_health=$(smartctl -H "$disk" 2>/dev/null | grep "SMART overall-health" | awk -F': ' '{print $2}')
        if [ "$smart_health" = "PASSED" ]; then
            echo -e "  健康状态: ${GREEN}${smart_health}${NC}"
        else
            echo -e "  健康状态: ${RED}${smart_health}${NC}"
        fi
        
        # 关键 SMART 属性
        smartctl -A "$disk" 2>/dev/null | awk '
            /Reallocated_Sector_Ct/ {printf "  重新分配扇区数: %s\n", $10}
            /Current_Pending_Sector/ {printf "  待处理扇区数: %s\n", $10}
            /Offline_Uncorrectable/ {printf "  离线不可纠正: %s\n", $10}
            /Temperature_Celsius/ {printf "  温度: %s°C\n", $10}
            /Power_On_Hours/ {printf "  通电时间: %s 小时\n", $10}
            /Power_Cycle_Count/ {printf "  开机次数: %s\n", $10}
        '
        
        # SSD 专用指标
        if smartctl -i "$disk" 2>/dev/null | grep -qi "solid state"; then
            wear_level=$(smartctl -A "$disk" 2>/dev/null | grep -i "wear" | head -1 | awk '{print $4}')
            [ -n "$wear_level" ] && echo "  磨损程度: ${wear_level}%"
            
            total_writes=$(smartctl -A "$disk" 2>/dev/null | grep -i "Total_LBAs_Written" | awk '{print $10}')
            if [ -n "$total_writes" ]; then
                # LBA 转换为 GB (假设 512 字节/扇区)
                writes_gb=$((total_writes * 512 / 1024 / 1024 / 1024))
                echo "  总写入量: ${writes_gb} GB"
            fi
        fi
    done
else
    echo -e "${YELLOW}smartctl 未安装，跳过 SMART 检查${NC}"
    echo "安装方法: yum install smartmontools 或 apt install smartmontools"
fi

# =====================================================
# 11. Kingbase 数据库监控
# =====================================================
print_header "11. Kingbase 数据库监控"

KB_MAIN_PID=$(pgrep -u kingbase -f "bin/kingbase -D" | head -1)
if [ -z "$KB_MAIN_PID" ]; then
    echo -e "数据库进程:      ${RED}[异常] 未发现 kingbase 主进程${NC}"
    KINGBASE_DATA=""
else
    KINGBASE_DATA=$(ps -p $KB_MAIN_PID -o args= | awk -F'-D' '{print $2}' | awk '{print $1}')
    echo -e "数据库进程:      ${GREEN}运行中 (PID: $KB_MAIN_PID)${NC}"
    echo -e "数据目录:        ${GREEN}${KINGBASE_DATA}${NC}"
    
    # 数据库进程资源占用
    kb_cpu=$(ps -p $KB_MAIN_PID -o %cpu= 2>/dev/null)
    kb_mem=$(ps -p $KB_MAIN_PID -o %mem= 2>/dev/null)
    kb_vsz=$(ps -p $KB_MAIN_PID -o vsz= 2>/dev/null)
    kb_rss=$(ps -p $KB_MAIN_PID -o rss= 2>/dev/null)
    echo "  CPU 占用:      ${kb_cpu}%"
    echo "  内存占用:      ${kb_mem}%"
    echo "  虚拟内存:      $((kb_vsz/1024)) MB"
    echo "  物理内存:      $((kb_rss/1024)) MB"
fi

# 端口监听
if command -v ss >/dev/null 2>&1; then
    port_check=$(ss -lnt | awk '{print $4}' | grep -w ":$KINGBASE_PORT")
else
    port_check=""
fi

if [ -n "$port_check" ]; then
    echo -e "监听端口:        ${GREEN}正常 (${KINGBASE_PORT})${NC}"
else
    echo -e "监听端口:        ${RED}[异常] 未监听 ${KINGBASE_PORT}${NC}"
fi

# SQL 检查
if command -v ksql >/dev/null 2>&1 && [ -n "$KINGBASE_DATA" ]; then
    echo -e "\n数据库连接信息:"
    conn_num=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select count(*) from sys_stat_activity;" 2>/dev/null)
    [[ "$conn_num" =~ ^[0-9]+$ ]] && echo "  当前连接数:    ${conn_num}" || echo "  当前连接数:    [获取失败]"
    
    # 最大连接数
    max_conn=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "show max_connections;" 2>/dev/null)
    [[ "$max_conn" =~ ^[0-9]+$ ]] && echo "  最大连接数:    ${max_conn}" || echo "  最大连接数:    [获取失败]"
    
    # 活跃连接
    active_conn=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select count(*) from sys_stat_activity where state='active';" 2>/dev/null)
    [[ "$active_conn" =~ ^[0-9]+$ ]] && echo "  活跃连接数:    ${active_conn}" || echo "  活跃连接数:    [获取失败]"
    
    # WAL 目录
    if [ -d "$KINGBASE_DATA/sys_wal" ]; then
        WAL_DIR="$KINGBASE_DATA/sys_wal"
    elif [ -d "$KINGBASE_DATA/pg_wal" ]; then
        WAL_DIR="$KINGBASE_DATA/pg_wal"
    else
        WAL_DIR=""
    fi
    
    if [ -n "$WAL_DIR" ]; then
        wal_size=$(du -sh "$WAL_DIR" 2>/dev/null | awk '{print $1}')
        wal_count=$(ls -1 "$WAL_DIR" 2>/dev/null | wc -l)
        echo -e "\nWAL 日志信息:"
        echo "  WAL 目录大小:  ${wal_size}"
        echo "  WAL 文件数:    ${wal_count}"
    fi
    
    # Checkpoint 信息
    echo -e "\nCheckpoint 统计:"
    ckpt_info=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select checkpoints_timed, checkpoints_req, buffers_checkpoint from sys_stat_bgwriter;" 2>/dev/null)
    if [ -n "$ckpt_info" ]; then
        timed=$(echo "$ckpt_info" | awk -F'|' '{print $1}')
        req=$(echo "$ckpt_info" | awk -F'|' '{print $2}')
        buffers=$(echo "$ckpt_info" | awk -F'|' '{print $3}')
        echo "  定时 Checkpoint:  ${timed}"
        echo "  请求 Checkpoint:  ${req}"
        echo "  写入缓冲区:       ${buffers}"
    fi
    
    # 数据库大小
    echo -e "\n数据库大小:"
    ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "SELECT datname, sys_size_pretty(sys_database_size(datname)) AS size FROM sys_database ORDER BY sys_database_size(datname) DESC LIMIT 5;" 2>/dev/null | while IFS='|' read dbname size; do
        echo "  $dbname: $size"
    done
    
    # 表大小 Top 5
    echo -e "\nTop 5 最大表:"
    ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "SELECT schemaname||'.'||tablename AS table, sys_size_pretty(sys_total_relation_size(schemaname||'.'||tablename)) AS size FROM sys_tables ORDER BY sys_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 5;" 2>/dev/null | while IFS='|' read tbl size; do
        echo "  $tbl: $size"
    done
    
    # 长时间运行的查询
    echo -e "\n长时间运行查询 (>5分钟):"
    long_queries=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select pid, usename, state, query_start, now()-query_start as duration, left(query,50) from sys_stat_activity where state='active' and now()-query_start > interval '5 minutes';" 2>/dev/null)
    if [ -n "$long_queries" ]; then
        echo "$long_queries"
    else
        echo "  无长时间运行查询"
    fi
    
    # 锁等待
    echo -e "\n锁等待情况:"
    # 方法1: 检查等待锁的会话（wait_event_type = 'Lock'）
    lock_wait=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select count(*) from sys_stat_activity where wait_event_type = 'Lock';" 2>/dev/null)
    [[ "$lock_wait" =~ ^[0-9]+$ ]] && echo "  等待锁的会话数: ${lock_wait}" || echo "  等待锁的会话数: [获取失败]"
    
    # 方法2: 查看当前持有的锁数量
    total_locks=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select count(*) from sys_locks;" 2>/dev/null)
    [[ "$total_locks" =~ ^[0-9]+$ ]] && echo "  当前持有锁数量: ${total_locks}" || echo "  当前持有锁数量: [获取失败]"
    
    # 方法3: 检查是否存在锁冲突（granted = false）
    blocked_locks=$(ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "select count(*) from sys_locks where not granted;" 2>/dev/null)
    if [[ "$blocked_locks" =~ ^[0-9]+$ ]]; then
        if [ "$blocked_locks" -gt 0 ]; then
            echo -e "  阻塞的锁请求:   ${RED}${blocked_locks} [告警]${NC}"
            echo -e "\n  锁冲突详情:"
            ksql -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -c "
                SELECT 
                    blocked_locks.pid AS blocked_pid,
                    blocked_activity.usename AS blocked_user,
                    blocking_locks.pid AS blocking_pid,
                    blocking_activity.usename AS blocking_user,
                    blocked_activity.query AS blocked_query
                FROM sys_catalog.sys_locks blocked_locks
                JOIN sys_catalog.sys_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
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
                JOIN sys_catalog.sys_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
                WHERE NOT blocked_locks.granted
                LIMIT 5;
            " 2>/dev/null | while IFS='|' read bpid buser kpid kuser query; do
                echo "    被阻塞PID: $bpid (用户: $buser)"
                echo "    阻塞者PID: $kpid (用户: $kuser)"
                echo "    查询: ${query:0:60}..."
                echo "    ---"
            done
        else
            echo -e "  阻塞的锁请求:   ${GREEN}${blocked_locks} [正常]${NC}"
        fi
    else
        echo "  阻塞的锁请求:   [获取失败]"
    fi
    
else
    echo -e "SQL 巡检:        ${YELLOW}[跳过] 未安装 ksql 或未获取数据目录${NC}"
fi

# =====================================================
# 10. 安全检查
# =====================================================
print_header "10. 安全状态检查"

# SSH 登录失败
echo "SSH 登录失败尝试 (最近50条):"
if [ -f /var/log/secure ]; then
    grep "Failed password" /var/log/secure 2>/dev/null | tail -5 || echo "  无失败记录"
elif [ -f /var/log/auth.log ]; then
    grep "Failed password" /var/log/auth.log 2>/dev/null | tail -5 || echo "  无失败记录"
else
    echo "  [日志文件不存在]"
fi

# 最近登录用户
echo -e "\n最近登录用户:"
last -n 5 2>/dev/null || echo "  [last 命令不可用]"

# SELinux 状态
echo -e "\nSELinux 状态:"
if command -v getenforce >/dev/null 2>&1; then
    getenforce
else
    echo "  [SELinux 未安装]"
fi

# =====================================================
# 11. 系统日志检查
# =====================================================
print_header "11. 系统日志检查"

echo "系统日志关键错误 (最近100条):"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -n 100 -p err 2>/dev/null | tail -10 || echo "  无错误日志"
else
    tail -100 /var/log/messages 2>/dev/null | egrep -i "$LOG_KEYWORDS" | tail -10 || echo "  无匹配日志"
fi

# Kingbase 日志
if [ -n "$KINGBASE_DATA" ] && [ -d "$KINGBASE_DATA/sys_log" ]; then
    echo -e "\nKingbase 数据库日志 (最新):"
    latest_log=$(ls -t "$KINGBASE_DATA/sys_log/"*.log 2>/dev/null | head -1)
    if [ -n "$latest_log" ]; then
        echo "日志文件: $latest_log"
        tail -20 "$latest_log" | egrep -i "$LOG_KEYWORDS" || echo "  无关键错误"
    fi
fi

# =====================================================
# 12. 时间同步检查
# =====================================================
print_header "12. 时间同步检查"

echo "当前系统时间:    $(date '+%Y-%m-%d %H:%M:%S %Z')"

if command -v timedatectl >/dev/null 2>&1; then
    echo -e "\nNTP 同步状态:"
    timedatectl status | grep -E "NTP|synchronized"
elif command -v ntpq >/dev/null 2>&1; then
    echo -e "\nNTP 服务器状态:"
    ntpq -p 2>/dev/null | head -5
else
    echo "  [时间同步工具未安装]"
fi

# =====================================================
# 巡检总结
# =====================================================
print_header "巡检总结"

echo -e "${GREEN}✓ 巡检完成${NC}"
echo "报告已保存至: ${REPORT_FILE}"
echo -e "\n建议:"
echo "  1. 定期检查告警项目"
echo "  2. 监控磁盘和内存使用趋势"
echo "  3. 关注数据库连接数和慢查询"
echo "  4. 定期清理日志文件"
echo "  5. 保持系统和数据库补丁更新"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}            巡检报告生成完毕 - $(date '+%H:%M:%S')            ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
