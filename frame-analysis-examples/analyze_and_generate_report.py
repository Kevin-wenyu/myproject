#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze_and_generate_report.py

功能：
    解析 PCAP 文件，进行 TCP 深度分析（RTT、重传、窗口、RTO）。
    生成包含图表和详细数据表的 HTML 报告。

依赖：
    pip install dpkt matplotlib numpy

用法：
    python analyze_and_generate_report.py target.pcap

优化说明：
1. TCP 会话统计：修正了主函数，使其统计双向 TCP 会话数 (Tshark Equivalent)。
2. 重传检测：在有载荷重传判定中，增加了对极小包 (payload_len <= 1) 的过滤，减少 Keep-Alive 误判。
3. RTO 判定：将 RTO 判定阈值设为可配置参数 RTO_HEURISTIC_THRESH。
"""

import sys
import socket
import struct
import datetime
import base64
import html
from io import BytesIO
from collections import defaultdict

# 第三方库检查
try:
    import dpkt
    import numpy as np
    import matplotlib.pyplot as plt
except ImportError as e:
    print(f"Error: Missing dependency. {e}")
    print("Please run: pip install dpkt matplotlib numpy")
    sys.exit(1)

# ---------- 配置参数 ----------
TOP_N_FLOWS = 10            # 图表中展示的关键流数量
PLOT_MAX_POINTS = 300       # 绘图采样点上限
RTT_JITTER_THRESH = 0.05    # RTT 抖动阈值 (秒)
MIN_RTT_SAMPLES = 3         # 计算 RTT 统计所需的最小样本数
RTO_HEURISTIC_THRESH = 1.0  # RTO 启发式判定阈值 (秒). 低延迟网络建议 0.2-0.5
# -----------------------------

def inet_to_str(inet):
    """将二进制 IP 地址转换为字符串"""
    try:
        # 尝试 IPv4
        return socket.inet_ntoa(inet)
    except ValueError:
        # 处理 IPv6
        if len(inet) == 16:
            return socket.inet_ntop(socket.AF_INET6, inet)
        return "0.0.0.0"
    except Exception:
        return "0.0.0.0"

class FlowMetrics:
    """存储单向流的统计指标"""
    def __init__(self):
        self.count = 0
        self.payload_bytes = 0
        self.retrans = 0
        self.rto_cnt = 0
        self.cont_retrans = 0
        self.small_win_cnt = 0  # Window < 200

        self.wins = []          # 窗口大小样本
        self.timestamps = []    # 包到达时间样本
        self.rtt_samples = []   # 计算出的 RTT 样本 (秒)
        self.win_ts = []        # (ts, win) 用于绘图

        # 内部状态用于重传检测
        self.seen_seqs = set()
        self.last_seq = None
        self.max_seq = 0

def analyze_pcap(pcap_path):
    """
    核心分析逻辑
    返回: (flows)
    """
    print(f"[*] Analyzing: {pcap_path} ...")

    try:
        f = open(pcap_path, 'rb')
        pcap = dpkt.pcap.Reader(f)
    except Exception:
        # 尝试使用 UniversalReader (处理 pcapng 等)
        try:
            f = open(pcap_path, 'rb')
            pcap = dpkt.pcap.UniversalReader(f)
        except Exception as e2:
            print(f"[!] Failed to open pcap: {e2}")
            return {}

    # flows: Key=(src_ip, sport, dst_ip, dport), Value=FlowMetrics
    flows = defaultdict(FlowMetrics)

    # unacked_packets: 用于计算 RTT
    # Key = (src_ip, sport, dst_ip, dport) -> 指向"发送者"
    # Value = { expected_ack_seq: timestamp }
    unacked_packets = defaultdict(dict)

    packet_count = 0

    for ts, buf in pcap:
        packet_count += 1
        try:
            # 解析以太网
            eth = dpkt.ethernet.Ethernet(buf)

            # 解析 IP
            ip = None
            if isinstance(eth.data, dpkt.ip.IP):
                ip = eth.data
            elif isinstance(eth.data, dpkt.ip6.IP6):
                ip = eth.data
            else:
                continue # 非 IP 包

            # 解析 TCP
            if not isinstance(ip.data, dpkt.tcp.TCP):
                continue
            tcp = ip.data

            # 提取四元组
            src_ip = inet_to_str(ip.src)
            dst_ip = inet_to_str(ip.dst)
            sport = tcp.sport
            dport = tcp.dport

            # 定义流的方向 Key
            flow_key = (src_ip, sport, dst_ip, dport)
            rev_flow_key = (dst_ip, dport, src_ip, sport) # 反向流 Key

            fm = flows[flow_key]
            fm.count += 1
            fm.timestamps.append(ts)
            fm.wins.append(tcp.win)
            fm.win_ts.append((ts, tcp.win))

            payload_len = len(tcp.data)
            fm.payload_bytes += payload_len

            seq = tcp.seq
            ack = tcp.ack
            flags = tcp.flags

            # --- 1. RTT 计算 (SEQ/ACK 匹配) ---
            # 如果当前包是 ACK，检查反向流是否有等待该 ACK 的包
            if (flags & dpkt.tcp.TH_ACK):
                pending = unacked_packets.get(rev_flow_key, {})
                if ack in pending:
                    sent_ts = pending.pop(ack)
                    rtt = ts - sent_ts
                    # RTT 样本只归属给发送数据的那一方（即反向流）
                    if 0 < rtt < 10.0: 
                        flows[rev_flow_key].rtt_samples.append(rtt)

            # 如果当前包有数据，记录期待的 ACK 以便计算 RTT
            if payload_len > 0:
                expected_ack = seq + payload_len
                unacked_packets[flow_key][expected_ack] = ts


            # --- 2. 重传与 RTO 检测 (优化: 过滤 Keep-Alive 和 RTO 阈值参数化) ---
            if payload_len > 0:
                # 优化点：过滤掉极小载荷的包，通常是 Keep-Alive 或 Zero Window Probe
                if payload_len <= 1 and (flags & dpkt.tcp.TH_ACK):
                    # 这是一个有 ACK 的极小包，可能是 Keep-Alive，不计入重传
                    pass 
                elif seq in fm.seen_seqs:
                    # 判定为重传
                    fm.retrans += 1

                    # 连续重传判定
                    if fm.last_seq == seq:
                        fm.cont_retrans += 1

                    # RTO 判定 (粗略): 使用可配置的启发式阈值
                    if len(fm.timestamps) > 1:
                        dt = ts - fm.timestamps[-2]
                        if dt > RTO_HEURISTIC_THRESH:
                            fm.rto_cnt += 1

                # 更新序列号状态
                fm.seen_seqs.add(seq)
                fm.last_seq = seq
                fm.max_seq = max(fm.max_seq, seq)

            # --- 3. 窗口分析 ---
            # 排除 SYN/RST 包
            if tcp.win < 200 and (flags & dpkt.tcp.TH_SYN) == 0 and (flags & dpkt.tcp.TH_RST) == 0:
                fm.small_win_cnt += 1

        except Exception:
            continue

    f.close()
    print(f"[*] Parsing complete. Processed {packet_count} packets.")
    return flows

def calculate_probabilities(fm):
    """
    根据流指标计算 Client/Network/Server 故障概率
    返回: (prob_client, prob_network, prob_server, metrics_dict)
    """
    # 基础指标计算
    avg_win = float(np.mean(fm.wins)) if fm.wins else 0.0

    if len(fm.rtt_samples) >= MIN_RTT_SAMPLES:
        rtt_avg = float(np.mean(fm.rtt_samples))
        rtt_max = float(np.max(fm.rtt_samples))
        rtt_std = float(np.std(fm.rtt_samples))
    else:
        rtt_avg = rtt_max = rtt_std = 0.0

    # 评分权重
    score_client = 0.0
    score_network = 0.0
    score_server = 0.0

    # 1. 窗口极小 -> 接收端处理不过来 (Server/Client 自身问题)
    if avg_win < 500 and fm.count > 10:
        score_server += 0.6  # 假设接收方是 Server
        score_client += 0.2  # 或者是 Client 接收窗口小

    # 2. 重传 -> 主要是网络丢包
    if fm.retrans > 0:
        ratio = fm.retrans / fm.count
        score_network += ratio * 10.0
        score_server += ratio * 2.0 # 可能是服务器没回 ACK

    # 3. RTO (超时重传) -> 严重网络拥塞或中断
    if fm.rto_cnt > 0:
        score_network += fm.rto_cnt * 0.5

    # 4. RTT 抖动大 -> 网络不稳定
    if rtt_std > RTT_JITTER_THRESH:
        score_network += 1.0

    # 归一化概率
    total = score_client + score_network + score_server
    if total < 0.001:
        return 0.33, 0.33, 0.34, rtt_avg, rtt_max, rtt_std, avg_win

    p_c = score_client / total
    p_n = score_network / total
    p_s = score_server / total

    return p_c, p_n, p_s, rtt_avg, rtt_max, rtt_std, avg_win

def generate_plot(flow_rows):
    """生成 Base64 编码的图片"""
    print("[*] Generating visualization...")

    # 准备数据
    top_flows = [r for r in flow_rows if r['score'] > 0][:TOP_N_FLOWS] 

    # 创建画布
    fig = plt.figure(figsize=(12, 10))
    gs = fig.add_gridspec(3, 1, height_ratios=[1, 2, 2], hspace=0.5)

    # 子图 1: 总体概率分布
    ax0 = fig.add_subplot(gs[0, 0])
    if flow_rows:
        avg_c = np.mean([r['p_client'] for r in flow_rows])
        avg_n = np.mean([r['p_network'] for r in flow_rows])
        avg_s = np.mean([r['p_server'] for r in flow_rows])
    else:
        avg_c, avg_n, avg_s = 0, 0, 0

    ax0.bar(['Client Issue', 'Network Issue', 'Server Issue'], [avg_c, avg_n, avg_s],
            color=['#4e79a7', '#f28e2b', '#e15759'], alpha=0.8)
    ax0.set_ylim(0, 1.0)
    ax0.set_title('Overall Diagnosis Probability')
    ax0.grid(axis='y', linestyle='--', alpha=0.5)

    # 子图 2: 关键流的窗口变化 (左轴) 和 RTT (右轴)
    ax1 = fig.add_subplot(gs[1, 0])
    ax2 = ax1.twinx()  # 双 Y 轴

    colors = plt.cm.tab10.colors
    has_data = False

    for idx, row in enumerate(top_flows):
        fm = row['obj']
        if not fm.win_ts:
            continue

        has_data = True
        c = colors[idx % len(colors)]

        # 降采样绘图
        ts_raw, win_raw = zip(*fm.win_ts)
        step = max(1, len(ts_raw) // PLOT_MAX_POINTS)

        # 相对时间 (从 0 开始)
        start_time = ts_raw[0]
        t_axis = [t - start_time for t in ts_raw[::step]]
        w_axis = win_raw[::step]

        ax1.plot(t_axis, w_axis, color=c, label=f"Flow {idx+1} ({row['flow_short']})", alpha=0.8)

        # 绘制 RTT (如果有)
        if fm.rtt_samples:
            rtt_val = np.mean(fm.rtt_samples)
            ax2.axhline(y=rtt_val, color=c, linestyle=':', alpha=0.5, linewidth=1)

    ax1.set_xlabel('Time (seconds from start of flow)')
    ax1.set_ylabel('TCP Window Size', color='#4e79a7')
    ax2.set_ylabel('Avg RTT (s) [Dotted Lines]', color='#59a14f')
    ax1.set_title(f'Top {len(top_flows)} Flows: Window Size Trend')
    if has_data:
        ax1.legend(loc='upper right', fontsize='small', ncol=2)

    # 子图 3: IP 问题热力图 (Top Source IPs)
    ax3 = fig.add_subplot(gs[2, 0])

    # 聚合 IP 数据
    ip_stats = defaultdict(lambda: {'c':0, 'n':0, 's':0, 'count':0})
    for row in flow_rows:
        src_ip = row['src_ip']
        ip_stats[src_ip]['c'] += row['p_client']
        ip_stats[src_ip]['n'] += row['p_network']
        ip_stats[src_ip]['s'] += row['p_server']
        ip_stats[src_ip]['count'] += 1

    # 排序取 Top 10
    sorted_ips = sorted(ip_stats.items(), key=lambda x: x[1]['count'], reverse=True)[:12]

    if sorted_ips:
        ips = [x[0] for x in sorted_ips]
        x_pos = np.arange(len(ips))
        width = 0.25

        vals_c = [x[1]['c']/x[1]['count'] for x in sorted_ips]
        vals_n = [x[1]['n']/x[1]['count'] for x in sorted_ips]
        vals_s = [x[1]['s']/x[1]['count'] for x in sorted_ips]

        ax3.bar(x_pos - width, vals_c, width, label='Client Prob', color='#4e79a7')
        ax3.bar(x_pos, vals_n, width, label='Network Prob', color='#f28e2b')
        ax3.bar(x_pos + width, vals_s, width, label='Server Prob', color='#e15759')

        ax3.set_xticks(x_pos)
        ax3.set_xticklabels(ips, rotation=45, ha='right')
        ax3.legend()
        ax3.set_title('Problem Probability by Source IP')

    # 保存到内存
    buf = BytesIO()
    fig.savefig(buf, format='png', dpi=120, bbox_inches='tight')
    plt.close(fig)
    buf.seek(0)
    return base64.b64encode(buf.read()).decode('ascii')

def main(pcap_path):
    # 1. 分析
    flows = analyze_pcap(pcap_path)
    if not flows:
        print("No flows found or file error.")
        return

    # --- 优化点 1: 计算双向 TCP 会话数 (Tshark Equivalent) ---
    unique_sessions = set()
    for k in flows.keys():
        src_ip, sport, dst_ip, dport = k
        # 创建一个规范化的四元组
        key_tuple_1 = (src_ip, sport)
        key_tuple_2 = (dst_ip, dport)
        
        if key_tuple_1 < key_tuple_2:
            session_key = (src_ip, sport, dst_ip, dport)
        else:
            session_key = (dst_ip, dport, src_ip, sport)
            
        unique_sessions.add(session_key)
        
    total_tcp_sessions = len(unique_sessions)
    # --------------------------------------------------------

    # 2. 计算指标并列表
    flow_rows = []
    for k, fm in flows.items():
        src_ip, sport, dst_ip, dport = k

        p_c, p_n, p_s, rtt_avg, rtt_max, rtt_std, avg_win = calculate_probabilities(fm)

        # 评分用于排序 (重传和 RTT 抖动优先)
        score = (fm.retrans * 5) + (fm.rto_cnt * 10) + (rtt_std * 100) + (fm.count * 0.01)

        flow_rows.append({
            'flow_str': f"{src_ip}:{sport} -> {dst_ip}:{dport}",
            'flow_short': f"{sport} -> {dport}", 
            'src_ip': src_ip,
            'dst_ip': dst_ip,
            'count': fm.count,
            'retrans': fm.retrans,
            'rto': fm.rto_cnt,
            'cont_retrans': fm.cont_retrans,
            'small_win': fm.small_win_cnt,
            'avg_win': avg_win,
            'rtt_avg': rtt_avg,
            'rtt_max': rtt_max,
            'rtt_std': rtt_std,
            'p_client': p_c,
            'p_network': p_n,
            'p_server': p_s,
            'score': score,
            'obj': fm
        })

    # 按问题严重程度排序
    flow_rows.sort(key=lambda x: x['score'], reverse=True)

    # 3. 生成图表
    img_b64 = generate_plot(flow_rows)

    # 4. 生成 HTML
    html_content = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>TCP Analysis Report</title>
<style>
    body {{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 20px; background: #f4f4f9; color: #333; }}
    .container {{ max-width: 1200px; margin: 0 auto; background: #fff; padding: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }}
    h1 {{ color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }}
    h2 {{ color: #34495e; margin-top: 30px; }}
    .summary {{ background: #fff3e0; padding: 15px; border-left: 5px solid #ff9800; margin-bottom: 20px; }}
    table {{ width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 13px; }}
    th, td {{ padding: 8px 12px; border: 1px solid #ddd; text-align: left; }}
    th {{ background-color: #f8f9fa; font-weight: 600; }}
    tr:nth-child(even) {{ background-color: #f9f9f9; }}
    .bar-container {{ width: 100px; height: 6px; background: #eee; display: inline-block; }}
    .bar-fill {{ height: 100%; }}
    .red {{ color: #e74c3c; font-weight: bold; }}
    .img-box {{ text-align: center; margin: 20px 0; border: 1px solid #eee; padding: 10px; }}
    .footer {{ margin-top: 40px; font-size: 12px; color: #777; text-align: center; }}
</style>
</head>
<body>
<div class="container">
    <h1>TCP Traffic Analysis Report</h1>
    <p><strong>File:</strong> {html.escape(pcap_path)} | <strong>Generated:</strong> {datetime.datetime.now()}</p>

    <div class="summary">
        <h3>Analysis Summary</h3>
        <p>Total TCP Sessions (Tshark Equivalent): {total_tcp_sessions} | Total Unidirectional Flows: {len(flow_rows)}</p>
        <p><strong>Note on RTO:</strong> RTO is heuristically detected using a minimum delay of {RTO_HEURISTIC_THRESH}s. Adjusting <code>RTO_HEURISTIC_THRESH</code> in the script config can improve accuracy in high/low latency networks.</p>
    </div>

    <h2>Visualization Dashboard</h2>
    <div class="img-box">
        <img src="data:image/png;base64,{img_b64}" style="max-width:100%; height:auto;">
    </div>

    <h2>Detailed Flow Metrics (Top 100 by Score)</h2>
    <table>
        <thead>
            <tr>
                <th>Rank</th>
                <th>Flow (Src -> Dst)</th>
                <th>Pkts</th>
                <th>Retrans</th>
                <th>RTO</th>
                <th>Avg Win</th>
                <th>Avg RTT (s)</th>
                <th>RTT Jitter</th>
                <th>Diagnosis Prob (C/N/S)</th>
            </tr>
        </thead>
        <tbody>
"""

    for i, row in enumerate(flow_rows[:100], 1):
        # 格式化概率颜色
        pc, pn, ps = row['p_client'], row['p_network'], row['p_server']
        prob_str = f"C:{pc:.2f} / N:{pn:.2f} / S:{ps:.2f}"

        # 高亮严重问题
        rtt_cls = "red" if row['rtt_std'] > RTT_JITTER_THRESH else ""
        ret_cls = "red" if row['retrans'] > 0 else ""

        html_content += f"""
            <tr>
                <td>{i}</td>
                <td style="font-family:monospace">{html.escape(row['flow_str'])}</td>
                <td>{row['count']}</td>
                <td class="{ret_cls}">{row['retrans']}</td>
                <td>{row['rto']}</td>
                <td>{int(row['avg_win'])}</td>
                <td>{row['rtt_avg']:.4f}</td>
                <td class="{rtt_cls}">{row['rtt_std']:.4f}</td>
                <td>{prob_str}</td>
            </tr>
        """

    html_content += """
        </tbody>
    </table>
    <div class="footer">Generated by Python TCP Analyzer</div>
</div>
</body>
</html>
"""

    out_file = "tcp_analysis_report.html"
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html_content)

    print(f"[*] Report generated successfully: {out_file}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyze_and_generate_report.py <pcap_file>")
    else:
        main(sys.argv[1])
