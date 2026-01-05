#!/bin/bash

# =================================================================
# 脚本名称: kb_monitor.sh
# 描述: 操作系统 & Kingbase 数据库健康巡检脚本
# 数据库版本：V008R007C003B0070
# 说明: 包含系统、网络、数据库、安全、备份、复制槽等监控
# 执行: 建议使用 root 用户执行以获取完整信息
# 版本: V0.1
# 日期：2025-12-26
# By Kevin
# =================================================================

# ---------------- 配置区 ----------------
CPU_THRESHOLD=75
MEM_THRESHOLD=75
DISK_THRESHOLD=75
LOAD_THRESHOLD=4.0
CONN_THRESHOLD=1000

KINGBASE_PORT=54321
KINGBASE_USER="system"
KINGBASE_DB="TEST"
KINGBASE_PWD="12345678ab"
RMAN_DATA="/data/rman"

LOG_KEYWORDS="error|fail|panic|segfault|oom"
REPORT_FILE="/opt/Kingbase/ES/V8/data/sys_log/kb_monitor_$(date +%Y%m%d_%H%M%S).log"

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
    awk -v val="$1" -v thr="$2" 'BEGIN {if(val>thr) exit 0; else exit 1}'
}

# ---------------- 权限检查 ----------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}警告: 建议使用 root 执行以获取完整信息${NC}\n"
fi


{
# ---------------- 开始巡检 ----------------

echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}     企业级系统 & Kingbase 数据库健康巡检报告               ${NC}"
echo -e "${CYAN}     检查时间: $(date '+%Y-%m-%d %H:%M:%S')              ${NC}"
echo -e "${CYAN}     主机名称: $(hostname -i)                            ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"

# =====================================================
# 1. 系统基本信息
# =====================================================
print_header "1. 系统基本信息"

echo "操作系统:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown")"
echo "内核版本:        $(uname -r)"
echo "系统架构:        $(uname -m)"
echo "运行时长:        $(uptime -p 2>/dev/null || uptime | awk -F'up' '{print $2}' | awk -F',' '{print $1}')"

# =====================================================
# 2. CPU 监控
# =====================================================
print_header "2. CPU 使用监控"

cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'%' -f1)
cpu_usage=$(awk "BEGIN {printf \"%.2f\", 100-$cpu_idle}")
cpu_status="${GREEN}[正常]${NC}"
compare_threshold "$cpu_usage" "$CPU_THRESHOLD" && cpu_status="${RED}[告警]${NC}"
echo -e "CPU 使用率:      ${cpu_usage}%  ${cpu_status}"
echo "CPU 核心数:      $(nproc)"

echo -e "\nTop 5 CPU 占用进程:"
ps -eo pid,user,cmd,%cpu --sort=-%cpu | head -6

# =====================================================
# 3. 内存监控
# =====================================================
print_header "3. 内存使用监控"

mem_total=$(free -m | awk '/Mem:/ {print $2}')
mem_used=$(free -m | awk '/Mem:/ {print $3}')
mem_available=$(free -m | awk '/Mem:/ {print $7}')
mem_usage=$(awk "BEGIN {printf \"%.2f\", $mem_used/$mem_total*100}")

mem_status="${GREEN}[正常]${NC}"
compare_threshold "$mem_usage" "$MEM_THRESHOLD" && mem_status="${RED}[告警]${NC}"

echo "内存总量:        ${mem_total} MB"
echo "已用内存:        ${mem_used} MB"
echo "可用内存:        ${mem_available} MB"
echo -e "内存使用率:      ${mem_usage}%  ${mem_status}"

swap_total=$(free -m | awk '/Swap:/ {print $2}')
swap_used=$(free -m | awk '/Swap:/ {print $3}')
if [ "$swap_total" -gt 0 ]; then
    swap_usage=$(awk "BEGIN {printf \"%.2f\", $swap_used/$swap_total*100}")
    echo "Swap 使用:       ${swap_usage}% (${swap_used}/${swap_total}MB)"
fi

echo -e "\nTop 5 内存占用进程:"
ps -eo pid,user,cmd,%mem --sort=-%mem | head -6

# =====================================================
# 4. 磁盘监控
# =====================================================
print_header "4. 磁盘使用监控"

echo "磁盘分区使用:"
df -h | awk 'NR==1 || /^\/dev/' | while read line; do
    if echo "$line" | grep -q "^Filesystem\|^文件系统"; then
        continue
    fi
    mount=$(echo "$line" | awk '{print $6}')
    use=$(echo "$line" | awk '{print $5}')
    used=$(echo "$line" | awk '{print $3}')
    size=$(echo "$line" | awk '{print $2}')
    
    usage=${use%\%}
    if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
        echo -e "  ${mount}: ${RED}${use} [告警]${NC} (${used}/${size})"
    else
        echo -e "  ${mount}: ${GREEN}${use} [正常]${NC} (${used}/${size})"
    fi
done

if command -v iostat >/dev/null 2>&1; then
    echo -e "\n磁盘 I/O 统计:"
    iostat -xm 1 2 2>/dev/null | awk 'NF>=14 && NR>10 && !/^avg/ {printf "  %-10s 读:%.2fMB/s 写:%.2fMB/s 使用率:%.1f%%\n", $1, $6, $7, $NF}'
fi

# =====================================================
# 5. 系统负载
# =====================================================
print_header "5. 系统负载"

load_1=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
load_5=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $2}' | xargs)
load_15=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $3}' | xargs)

echo "1分钟负载:       ${load_1}"
echo "5分钟负载:       ${load_5}"
echo "15分钟负载:      ${load_15}"

# =====================================================
# 6. 网络监控
# =====================================================
print_header "6. 网络状态"

if command -v ss >/dev/null 2>&1; then
    conn_est=$(ss -ant | grep -c ESTAB)
    conn_timewait=$(ss -ant | grep -c TIME-WAIT)
    
    echo "TCP 连接:"
    echo "  ESTABLISHED:   ${conn_est}"
    echo "  TIME-WAIT:     ${conn_timewait}"
    
    compare_threshold "$conn_est" "$CONN_THRESHOLD" && echo -e "  状态: ${RED}[告警]${NC}" || echo -e "  状态: ${GREEN}[正常]${NC}"
fi

echo -e "\n防火墙状态:"
if command -v firewall-cmd >/dev/null 2>&1; then
    fw_status=$(firewall-cmd --state 2>/dev/null)
    [ "$fw_status" = "running" ] && echo -e "  firewalld: ${GREEN}运行中${NC}" || echo -e "  firewalld: ${YELLOW}未运行${NC}"
elif command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -q "Status: active" && echo -e "  ufw: ${GREEN}已启用${NC}" || echo -e "  ufw: ${YELLOW}未启用${NC}"
else
    echo "  [未检测到防火墙]"
fi

# =====================================================
# 7. 进程监控
# =====================================================
print_header "7. 进程状态"

total_proc=$(ps aux | wc -l)
zombie_count=$(ps aux | awk '$8=="Z"' | wc -l)

echo "总进程数:        ${total_proc}"
if [ "$zombie_count" -gt 0 ]; then
    echo -e "僵尸进程:        ${RED}${zombie_count} [告警]${NC}"
    ps aux | awk '$8=="Z" {printf "  PID:%s CMD:%s\n", $2, $11}'
else
    echo -e "僵尸进程:        ${GREEN}0 [正常]${NC}"
fi

# =====================================================
# 8. OOM 检查
# =====================================================
print_header "8. OOM 内存溢出检查"

if command -v journalctl >/dev/null 2>&1; then
    oom_count=$(journalctl -k --since "7 days ago" 2>/dev/null | grep -ci "out of memory\|oom killer")
    if [ "$oom_count" -gt 0 ]; then
        echo -e "最近7天 OOM: ${RED}${oom_count} 次 [告警]${NC}"
        journalctl -k --since "7 days ago" 2>/dev/null | grep -i "killed process" | tail -3 | sed 's/^/  /'
    else
        echo -e "最近7天 OOM: ${GREEN}0 次 [正常]${NC}"
    fi
else
    oom_dmesg=$(dmesg -T 2>/dev/null | grep -i "out of memory" | tail -3)
    [ -n "$oom_dmesg" ] && echo -e "${RED}发现 OOM:${NC}\n$oom_dmesg" || echo -e "${GREEN}无 OOM 记录${NC}"
fi

# =====================================================
# 9. 磁盘 SMART 检查
# =====================================================
print_header "9. 磁盘 SMART 健康"

if command -v smartctl >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
    for disk in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}'); do
        echo -e "\n磁盘: $disk"
        if smartctl -i "$disk" 2>/dev/null | grep -q "SMART support is: Enabled"; then
            health=$(smartctl -H "$disk" 2>/dev/null | grep "overall-health" | awk -F': ' '{print $2}')
            [ "$health" = "PASSED" ] && echo -e "  状态: ${GREEN}${health}${NC}" || echo -e "  状态: ${RED}${health}${NC}"
            smartctl -A "$disk" 2>/dev/null | awk '/Reallocated_Sector|Temperature_Celsius|Power_On_Hours/ {print "  "$0}'
        else
            echo "  [SMART 不支持]"
        fi
    done
else
    echo "需要 root 权限或安装 smartmontools"
fi

# =====================================================
# 10. Kingbase 数据库监控
# =====================================================
print_header "10. Kingbase 数据库监控"

KB_PID=$(pgrep -f "kingbase.*-D" | head -1)
if [ -z "$KB_PID" ]; then
    echo -e "${RED}数据库进程未运行${NC}"
else
    KINGBASE_DATA=$(ps -p "$KB_PID" -o args= 2>/dev/null | grep -oP '\-D\s+\K[^\s]+')
    KB_BIN=$(ps -p "$KB_PID" -o args= 2>/dev/null | awk '{print $1}' | xargs dirname)
    KSQL="${KB_BIN}/ksql"
    [ ! -f "$KSQL" ] && KSQL=$(command -v ksql 2>/dev/null)
    
    echo -e "数据库进程:      ${GREEN}运行中 (PID: $KB_PID)${NC}"
    echo "数据目录:        ${KINGBASE_DATA}"
    
    # 端口检查
    if ss -lnt 2>/dev/null | grep -q ":$KINGBASE_PORT "; then
        echo -e "监听端口:        ${GREEN}$KINGBASE_PORT [正常]${NC}"
    else
        echo -e "监听端口:        ${RED}未监听${NC}"
    fi
    
    # SQL 检查
    if [ -n "$KSQL" ] && [ -x "$KSQL" ]; then
        echo -e "\n数据库连接:"
        conn=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_stat_activity;" 2>/dev/null)
        [[ "$conn" =~ ^[0-9]+$ ]] && echo "  当前连接数: $conn" || echo "  [连接失败]"
        
        active=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_stat_activity where state='active';" 2>/dev/null)
        [[ "$active" =~ ^[0-9]+$ ]] && echo "  活跃连接数: $active"
        
        # WAL 检查
        for wal in sys_wal pg_wal sys_xlog; do
            if [ -d "$KINGBASE_DATA/$wal" ]; then
                WAL_DIR="$KINGBASE_DATA/$wal"
                break
            fi
        done
        
        if [ -n "$WAL_DIR" ]; then
            wal_size=$(du -sh "$WAL_DIR" 2>/dev/null | awk '{print $1}')
            wal_count=$(ls -1 "$WAL_DIR" 2>/dev/null | wc -l)
            echo -e "\nWAL 日志信息:"
            echo "  目录大小:      ${wal_size}"
            echo "  文件数量:      ${wal_count}"
            
            if [ "$wal_count" -gt 500 ]; then
                echo -e "  状态: ${RED}[告警] WAL 文件堆积${NC}"
            else
                echo -e "  状态: ${GREEN}[正常]${NC}"
            fi
        fi
        
        # =====================================================
        # 主备库状态判断
        # =====================================================
        echo -e "\n${YELLOW}【主备库状态检查】${NC}"
        
        # 检查当前节点是否为主库
        IS_MASTER=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "SELECT sys_is_in_recovery();" 2>/dev/null)
        
        # 如果 sys_is_in_recovery() 返回 'f'，则是主库；如果返回 't'，则是备库
        if [ "$IS_MASTER" == "f" ]; then
            # 当前为主库，显示绿色
            echo -e "${GREEN}  当前节点为主库${NC}"
        
            # 查询主库的复制状态，只显示关键字段
            REPLICATION_STATUS=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "
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
            WHERE state = 'streaming';" 2>/dev/null)
        
            if [ -n "$REPLICATION_STATUS" ]; then
                echo -e "\n  当前主库的复制状态:"
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
                done
            else
                echo -e "  当前没有连接的备库"
            fi
        else
            # 当前为备库，显示黄色
            echo -e "${YELLOW}  当前节点为备库${NC}"
        
            # 查询备库的复制接收状态
            WAL_RECEIVER_STATUS=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "
            SELECT 
                status, 
                receive_start_lsn, 
                received_lsn, 
                latest_end_lsn, 
                sender_host, 
                sender_port
            FROM sys_stat_wal_receiver
            WHERE status = 'streaming';" 2>/dev/null)
        
            if [ -n "$WAL_RECEIVER_STATUS" ]; then
                echo -e "\n  当前备库的复制状态:"
                # 输出字段并格式化显示
                echo "$WAL_RECEIVER_STATUS" | while IFS="|" read status receive_start_lsn received_lsn latest_end_lsn sender_host sender_port; do
                    echo -e "    复制状态: $status"
                    echo -e "    接收的起始 WAL LSN: $receive_start_lsn"
                    echo -e "    接收到的 WAL LSN: $received_lsn"
                    echo -e "    最新接收的 WAL LSN: $latest_end_lsn"
                    echo -e "    发送方地址: $sender_host"
                    echo -e "    发送方端口: $sender_port"
                    echo -e "    -------------------------------"
                done
            else
                echo -e "  当前备库没有连接主库，无法获取复制状态"
            fi
        fi


        # =====================================================
        # 复制槽检查 - 防止 WAL 堆积
        # =====================================================
        echo -e "\n${YELLOW}【复制槽检查】${NC}"
        slot_count=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_replication_slots;" 2>/dev/null)
        
        if [[ "$slot_count" =~ ^[0-9]+$ ]]; then
            echo "  复制槽数量: $slot_count"
            
            if [ "$slot_count" -gt 0 ]; then
                echo -e "\n  复制槽详情:"
                lock_num=0
                "$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "
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
                    ORDER BY wal_lag_bytes DESC;
                " 2>/dev/null | while IFS='|' read slot_name slot_type is_active xmin restart_lsn wal_lag; do
                    echo ""
                    echo "  ┌─────────────────────────────────────"
                    echo "  │ 槽名称: $slot_name"
                    echo "  │ 类型:   $slot_type"
                    
                    if [ "$is_active" = "t" ]; then
                        echo -e "  │ 状态:   ${GREEN}活跃${NC}"
                    else
                        if "$xmin" != "f" ]; then
                        echo -e "  │ 状态:   ${RED}非活跃 [告警]${NC}"
                    fi
                    fi
                    
                    if [[ "$wal_lag" =~ ^[0-9]+$ ]] && [ "$wal_lag" -gt 0 ]; then
                        if [ "$wal_lag" -gt 1073741824 ]; then
                            wal_lag_gb=$(awk "BEGIN {printf \"%.2f\", $wal_lag/1073741824}")
                            wal_lag_display="${wal_lag_gb} GB"
                        elif [ "$wal_lag" -gt 1048576 ]; then
                            wal_lag_mb=$(awk "BEGIN {printf \"%.2f\", $wal_lag/1048576}")
                            wal_lag_display="${wal_lag_mb} MB"
                        else
                            wal_lag_kb=$(awk "BEGIN {printf \"%.2f\", $wal_lag/1024}")
                            wal_lag_display="${wal_lag_kb} KB"
                        fi
                        
                        echo "  │ WAL滞后: $wal_lag_display"
                        
                        if [ "$wal_lag" -gt 1073741824 ]; then
                            echo -e "  │ ${RED}► 告警: WAL滞后量过大${NC}"
                        fi
                    fi
                    
                    echo "  │ LSN:    $restart_lsn"
                    echo "  └─────────────────────────────────────"
                done
                
                inactive_count=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_replication_slots where not active and xmin is not null;" 2>/dev/null)
                
                if [[ "$inactive_count" =~ ^[0-9]+$ ]] && [ "$inactive_count" -gt 0 ]; then
                    echo -e "\n  ${RED}发现 $inactive_count 个非活跃复制槽 [严重告警]${NC}"
                    echo -e "\n  ${YELLOW}【处理建议】${NC}"
                    echo "    1. 检查备库是否运行"
                    echo "    2. 删除废弃的复制槽:"
                    "$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select slot_name from sys_replication_slots where not active;" 2>/dev/null | while read slot; do
                        echo "       SELECT sys_drop_replication_slot('$slot');"
                    done
                else
                    echo -e "\n  ${GREEN}所有复制槽状态正常${NC}"
                fi
            else
                echo -e "  ${GREEN}未配置复制槽${NC}"
            fi
        fi
        
        # 锁检查
        echo -e "\n${YELLOW}【锁状态检查】${NC}"
        lock_wait=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_stat_activity where wait_event_type='Lock';" 2>/dev/null)
        [[ "$lock_wait" =~ ^[0-9]+$ ]] && echo "  等待锁的会话: $lock_wait"
        
        blocked=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_locks where not granted;" 2>/dev/null)
        if [[ "$blocked" =~ ^[0-9]+$ ]]; then
            if [ "$blocked" -gt 0 ]; then
                echo -e "  阻塞的锁请求: ${RED}$blocked 个 [告警]${NC}"
                
                echo -e "\n  ${YELLOW}锁冲突详情:${NC}"
                lock_detail_num=0
                "$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "
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
                    LIMIT 5;
                " 2>/dev/null | while IFS='|' read blocked_pid blocked_user blocking_pid blocking_user blocked_query; do
                    lock_detail_num=$((lock_detail_num + 1))
                    echo ""
                    echo -e "  ${RED}► 锁冲突 #${lock_detail_num}${NC}"
                    echo "    被阻塞进程: PID=$blocked_pid, 用户=$blocked_user"
                    echo "    阻塞者进程: PID=$blocking_pid, 用户=$blocking_user"
                    echo "    被阻塞SQL: $blocked_query..."
                    echo "    ────────────────────────────────"
                done
                
                echo -e "\n  ${YELLOW}【处理建议】${NC}"
                echo "    终止阻塞进程: SELECT sys_terminate_backend(<blocking_pid>);"
            else
                echo -e "  阻塞的锁请求: ${GREEN}0 个 [正常]${NC}"
            fi
        fi
        
        # 长查询
        echo -e "\n${YELLOW}【长查询检查】${NC}"
        long_count=$("$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "select count(*) from sys_stat_activity where state<>'idle' and now()-query_start > interval '60 minutes';" 2>/dev/null)
        
        if [[ "$long_count" =~ ^[0-9]+$ ]] && [ "$long_count" -gt 0 ]; then
            echo -e "  ${RED}发现 $long_count 个长查询 [告警]${NC}"
            
            query_num=0
            "$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "
                SELECT 
                    pid,
                    usename,
                    EXTRACT(EPOCH FROM (now()-query_start))::int AS duration_sec,
                    left(query, 60) AS query_preview
                FROM sys_stat_activity 
                WHERE state='active' 
                    AND now()-query_start > interval '5 minutes'
                ORDER BY query_start
                LIMIT 5;
            " 2>/dev/null | while IFS='|' read pid user duration query; do
                query_num=$((query_num + 1))
                duration_min=$((duration / 60))
                echo ""
                echo -e "  ${RED}► 长查询 #${query_num}${NC}"
                echo "    PID: $pid, 用户: $user"
                echo "    运行: ${duration_min}分钟"
                echo "    SQL: $query..."
            done
            
            echo -e "\n  ${YELLOW}【处理建议】${NC}"
            echo "    终止查询: SELECT sys_cancel_backend(<pid>);"
        else
            echo -e "  ${GREEN}无长查询 [正常]${NC}"
        fi
        
        # 数据库大小
        echo -e "\n${YELLOW}【数据库大小统计】${NC}"
        "$KSQL" -At -U "$KINGBASE_USER" -d "$KINGBASE_DB" -W "$KINGBASE_PWD" -c "
            SELECT 
                datname, 
                sys_size_pretty(sys_database_size(datname)) AS size
            FROM sys_database 
            WHERE datname NOT IN ('template0', 'template1')
            ORDER BY sys_database_size(datname) DESC 
            LIMIT 5;
        " 2>/dev/null | while IFS='|' read dbname size; do
            echo "  $dbname: $size"
        done
        
       # =====================================================
       # sys_rman 备份检查
       # =====================================================
       echo -e "\n${YELLOW}【sys_rman 备份检查】${NC}"
       RMAN_BIN="${KB_BIN}/sys_rman"
       [ ! -f "$RMAN_BIN" ] && RMAN_BIN=$(command -v sys_rman 2>/dev/null)
       
       # 检查 sys_rman 是否存在
       if [ -n "$RMAN_BIN" ] && [ -x "$RMAN_BIN" ]; then
           echo "sys_rman路径:    $RMAN_BIN"
           # 检查路径是否存在
           if [ -n "$RMAN_DATA" ] && [ -d "$RMAN_DATA" ]; then
               # 获取备份信息
               BACKUP_INFO=$($RMAN_BIN show -B $RMAN_DATA 2>/dev/null)
       
               if [ -n "$BACKUP_INFO" ]; then
                   echo -e "\n${YELLOW}【备份信息】${NC}"
                   echo -e "\n$BACKUP_INFO"
               else
                   echo -e "  ${YELLOW}未找到备份信息${NC}"
               fi
           fi
       else
           echo -e "sys_rman 工具未找到${YELLOW}${NC}"
       fi

    fi
fi

# =====================================================
# 11. 系统日志
# =====================================================
print_header "11. 系统日志检查"

echo "系统错误日志 (最近10条):"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -p err -n 10 --no-pager 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  无错误日志"
else
    grep -iE "$LOG_KEYWORDS" /var/log/messages 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  无匹配日志"
fi

# =====================================================
# 12. 安全检查
# =====================================================
print_header "12. 安全检查"

echo "SSH 失败登录 (最近5次):"
if [ -f /var/log/secure ]; then
    grep "Failed password" /var/log/secure 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  无记录"
elif [ -f /var/log/auth.log ]; then
    grep "Failed password" /var/log/auth.log 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  无记录"
else
    echo "  日志文件不存在"
fi

# =====================================================
# 巡检总结
# =====================================================
print_header "巡检总结"

echo -e "${GREEN}✓ 巡检完成${NC}"
echo "报告位置: ${REPORT_FILE}"
echo ""
echo "关键检查项:"
echo "  ✓ 系统资源 (CPU/内存/磁盘)"
echo "  ✓ 数据库状态 (连接/锁/WAL)"
echo "  ✓ 复制槽监控 (防止WAL堆积)"
echo "  ✓ sys_rman备份"
echo "  ✓ 安全日志"

echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"

} 2>&1 | tee -a "$REPORT_FILE"