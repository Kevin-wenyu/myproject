#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import dpkt
import socket
import numpy as np
import matplotlib.pyplot as plt
import base64
import io
import datetime
import pandas as pd
import html

# -----------------------------
# 工具函数
# -----------------------------

def inet_to_str(inet):
    """Convert inet object to a string"""
    try:
        return socket.inet_ntop(socket.AF_INET, inet)
    except ValueError:
        return socket.inet_ntop(socket.AF_INET6, inet)

# -----------------------------
# TCP 数据结构
# -----------------------------
#
# streams[(src_ip, src_port, dst_ip, dst_port)] = {
#     'pkts': [],   # 每个包的数据
#     'win': [],    # 窗口大小
#     'ts': [],     # 时间戳
#     'seq': [],
#     'ack': [],
#     'rto': 0,
#     'retrans': 0,
#     'cont_retrans': 0,
#     'small_win': 0,
# }
#
# -----------------------------

def parse_pcap(pcap_file):
    streams = {}

    with open(pcap_file, "rb") as f:
        pcap = dpkt.pcap.Reader(f)

        for ts, buf in pcap:
            try:
                eth = dpkt.ethernet.Ethernet(buf)
                if not isinstance(eth.data, dpkt.ip.IP):
                    continue
                ip = eth.data

                if not isinstance(ip.data, dpkt.tcp.TCP):
                    continue
                tcp = ip.data

                src = inet_to_str(ip.src)
                dst = inet_to_str(ip.dst)
                key = (src, tcp.sport, dst, tcp.dport)

                if key not in streams:
                    streams[key] = {
                        'pkts': [],
                        'win': [],
                        'ts': [],
                        'seq': [],
                        'ack': [],
                        'rto': 0,
                        'retrans': 0,
                        'cont_retrans': 0,
                        'small_win': 0,
                    }

                # 保存包
                streams[key]['pkts'].append(tcp)
                streams[key]['win'].append(tcp.win)
                streams[key]['ts'].append(ts)
                streams[key]['seq'].append(tcp.seq)
                streams[key]['ack'].append(tcp.ack)

            except Exception:
                continue

    return streams
# ---------------------------------------------------------
# 第 2 部分：计算指标（RTO、重传、抖动、窗口趋势）
# ---------------------------------------------------------

def analyze_streams(streams):
    flow_results = {}
    src_stats = {}
    dst_stats = {}

    for key, st in streams.items():
        src, sport, dst, dport = key
        seq_list = st['seq']
        ts_list = st['ts']
        win_list = st['win']

        # 初始化
        rto = 0
        retrans = 0
        cont_re = 0
        current_cont = 0
        small_win = 0

        # RTT 计算（ACK 间隔法）
        rtt_samples = []

        # 遍历包
        seen_seq = set()
        last_seq = None
        last_ts = None

        for i in range(len(seq_list)):
            seq = seq_list[i]
            ts = ts_list[i]
            win = win_list[i]

            # 小窗口统计
            if win < 300:  # 可调整阈值
                small_win += 1

            # 重传判定（重复 seq）
            if seq in seen_seq:
                retrans += 1
                current_cont += 1
            else:
                seen_seq.add(seq)
                if current_cont > 1:
                    cont_re += 1
                current_cont = 0

            # RTT 采集
            if last_ts is not None:
                rtt_samples.append(ts - last_ts)

            last_ts = ts

            # RTO（粗略判定：RTT > 均值 + 异常阈值）
        if len(rtt_samples) > 5:
            rtt_mean = np.mean(rtt_samples)
            rtt_std = np.std(rtt_samples)
            for r in rtt_samples:
                if r > rtt_mean + 3 * rtt_std:
                    rto += 1
        else:
            rtt_mean = 0
            rtt_std = 0

        # 记录流结果
        flow_results[key] = {
            "src_ip": src,
            "src_port": sport,
            "dst_ip": dst,
            "dst_port": dport,
            "rto": rto,
            "retrans": retrans,
            "cont_re": cont_re,
            "small_win": small_win,
            "avg_win": np.mean(win_list),
            "rtt_avg": rtt_mean,
            "rtt_jitter": rtt_std,
        }

        # IP 统计
        if src not in src_stats:
            src_stats[src] = {"flows": 0, "rto": 0, "retrans": 0, "cont": 0}
        if dst not in dst_stats:
            dst_stats[dst] = {"flows": 0, "rto": 0, "retrans": 0, "cont": 0}

        src_stats[src]["flows"] += 1
        dst_stats[dst]["flows"] += 1
        src_stats[src]["rto"] += rto
        dst_stats[dst]["rto"] += rto
        src_stats[src]["retrans"] += retrans
        dst_stats[dst]["retrans"] += retrans
        src_stats[src]["cont"] += cont_re
        dst_stats[dst]["cont"] += cont_re

    return flow_results, src_stats, dst_stats


# ---------------------------------------------------------
# 综合评分（用于结论）
# ---------------------------------------------------------

def score_flow(flow):
    # RTO > 连续重传 > 重传 > RTT 抖动 > 小窗口
    return (
        flow["rto"] * 5 +
        flow["cont_re"] * 3 +
        flow["retrans"] * 1 +
        flow["rtt_jitter"] * 10 +
        flow["small_win"] * 0.5
    )


# ---------------------------------------------------------
# 绘制综合图（内存输出 Base64）
# ---------------------------------------------------------

def generate_summary_plot(flow_results):
    # 选前 10 个流
    top_flows = sorted(flow_results.values(), key=score_flow, reverse=True)[:10]

    plt.figure(figsize=(12, 6))
    plt.title("TCP Window / RTT / Score Overview")

    scores = [score_flow(f) for f in top_flows]
    labels = [f"{f['src_ip']}->{f['dst_ip']}" for f in top_flows]

    plt.bar(range(len(scores)), scores)
    plt.xticks(range(len(scores)), labels, rotation=45, ha="right")
    plt.ylabel("Severity Score")

    # 输出 Base64
    buf = io.BytesIO()
    plt.tight_layout()
    plt.savefig(buf, format='png')
    plt.close()
    img64 = base64.b64encode(buf.getvalue()).decode()
    return img64
# ---------------------------------------------------------
# 第 3 部分：HTML 报告生成器 + main()
# ---------------------------------------------------------

def build_html(img_b64, flow_results, src_stats, dst_stats, pcap_name):
    """
    根据传入的数据生成一个简单可读的 HTML 报告字符串
    """
    gen_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # prepare sorted flow table rows
    flows_sorted = sorted(flow_results.items(), key=lambda kv: score_flow(kv[1]), reverse=True)
    # build flow rows html
    flow_rows_html = ""
    idx = 1
    for k, v in flows_sorted:
        score = score_flow(v)
        flow_name = f"{k[0]}:{k[1]} → {k[2]}:{k[3]}"
        flow_rows_html += "<tr>"
        flow_rows_html += f"<td>{idx}</td>"
        flow_rows_html += f"<td>{html.escape(flow_name)}</td>"
        flow_rows_html += f"<td>{v['count'] if 'count' in v else '-'}</td>"
        flow_rows_html += f"<td>{v.get('rto',0)}</td>"
        flow_rows_html += f"<td>{v.get('retrans',0)}</td>"
        flow_rows_html += f"<td>{v.get('cont_re',0)}</td>"
        flow_rows_html += f"<td>{v.get('small_win',0)}</td>"
        flow_rows_html += f"<td>{v.get('avg_win',0):.1f}</td>"
        flow_rows_html += f"<td>{v.get('rtt_avg',0):.4f}</td>"
        flow_rows_html += f"<td>{v.get('rtt_jitter',0):.4f}</td>"
        flow_rows_html += f"<td>{v.get('client_prob',0):.3f}</td>"
        flow_rows_html += f"<td>{v.get('network_prob',0):.3f}</td>"
        flow_rows_html += f"<td>{v.get('server_prob',0):.3f}</td>"
        flow_rows_html += f"<td>{score:.2f}</td>"
        flow_rows_html += "</tr>\n"
        idx += 1

    # prepare IP tables (top by flow count)
    src_rows = ""
    for ip, s in sorted(src_stats.items(), key=lambda kv: kv[1].get('flows',0), reverse=True)[:50]:
        src_rows += "<tr>"
        src_rows += f"<td>{html.escape(ip)}</td>"
        src_rows += f"<td>{s.get('flows',0)}</td>"
        src_rows += f"<td>{s.get('rto',0)}</td>"
        src_rows += f"<td>{s.get('retrans',0)}</td>"
        src_rows += f"<td>{s.get('cont',0)}</td>"
        src_rows += "</tr>\n"

    dst_rows = ""
    for ip, s in sorted(dst_stats.items(), key=lambda kv: kv[1].get('flows',0), reverse=True)[:50]:
        dst_rows += "<tr>"
        dst_rows += f"<td>{html.escape(ip)}</td>"
        dst_rows += f"<td>{s.get('flows',0)}</td>"
        dst_rows += f"<td>{s.get('rto',0)}</td>"
        dst_rows += f"<td>{s.get('retrans',0)}</td>"
        dst_rows += f"<td>{s.get('cont',0)}</td>"
        dst_rows += "</tr>\n"

    # quick summary lines
    # pick top suspects
    top_flow = flows_sorted[0][0] if flows_sorted else ("-",)
    top_flow_score = score_flow(flows_sorted[0][1]) if flows_sorted else 0
    top_src = max(src_stats.items(), key=lambda kv: (kv[1].get('rto',0)*5 + kv[1].get('cont',0)*3), default=(None, None))[0]
    top_dst = max(dst_stats.items(), key=lambda kv: (kv[1].get('rto',0)*5 + kv[1].get('cont',0)*3), default=(None, None))[0]

    html_report = f"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>TCP Analysis Report</title>
<style>
body {{ font-family: Arial, Helvetica, sans-serif; margin: 20px; color:#222 }}
h1 {{ color:#2b6ea3 }}
table {{ border-collapse:collapse; width:100%; font-size:13px }}
th,td {{ border:1px solid #ddd; padding:6px; }}
th {{ background:#f3f6fb }}
.small {{ color:#666; font-size:12px }}
.block {{ border-left:4px solid #2b6ea3; padding-left:10px; margin:14px 0 }}
</style>
</head>
<body>
<h1>TCP 分析报告</h1>
<p class="small">Generated: {gen_time} | Source PCAP: {html.escape(pcap_name)}</p>

<div class="block">
<h2>简要结论</h2>
<p class="small">Top suspect flow: <b>{html.escape(str(top_flow))}</b> (score={top_flow_score:.2f})</p>
<p class="small">Top suspect source IP: <b>{html.escape(str(top_src))}</b></p>
<p class="small">Top suspect dest IP: <b>{html.escape(str(top_dst))}</b></p>
</div>

<h2>综合图（窗口/RTT/Severity）</h2>
<img src="data:image/png;base64,{img_b64}" style="width:100%; border:1px solid #ddd;">

<h2>每条流核心指标（按 score 排序）</h2>
<table>
<thead><tr><th>#</th><th>Flow</th><th>count</th><th>rto</th><th>retrans</th><th>cont_re</th><th>small_win</th><th>avg_win</th><th>rtt_avg</th><th>rtt_jitter</th><th>client_prob</th><th>network_prob</th><th>server_prob</th><th>score</th></tr></thead>
<tbody>
{flow_rows_html}
</tbody>
</table>

<h2>源 IP 汇总（按 flow count）</h2>
<table><thead><tr><th>ip</th><th>flows</th><th>total_rto</th><th>total_retrans</th><th>total_cont_retrans</th></tr></thead><tbody>
{src_rows}
</tbody></table>

<h2>目的 IP 汇总（按 flow count）</h2>
<table><thead><tr><th>ip</th><th>flows</th><th>total_rto</th><th>total_retrans</th><th>total_cont_retrans</th></tr></thead><tbody>
{dst_rows}
</tbody></table>

<p class="small">Report generated by automated analyzer.</p>
</body>
</html>
"""
    return html_report

def main_final(pcap_path):
    print("[*] Parsing pcap ...")
    streams = parse_pcap(pcap_path)
    print(f"[*] Parsed {len(streams)} directional flows")

    print("[*] Analyzing flows ...")
    flow_results, src_stats, dst_stats = analyze_streams(streams)

    # Enhance flow_results with probability fields (optional simple heuristic)
    # try to compute probabilities using compute_prob_from_stats if possible
    for k, v in list(flow_results.items()):
        # try to include fields required by compute_prob_from_stats if present
        stats_like = {
            'wins': [v.get('avg_win', 0)] if v.get('avg_win', None) is not None else [],
            'timestamps': streams.get(k, {}).get('ts', [])
        }
        try:
            (pc, pn, ps, avg_win, rtt_avg, rtt_max, rtt_jitter) = compute_prob_from_stats({
                'wins': streams.get(k, {}).get('win', streams.get(k, {}).get('wins', [])),
                'timestamps': streams.get(k, {}).get('ts', streams.get(k, {}).get('timestamps', [])),
                'rto': v.get('rto',0),
                'retrans': v.get('retrans',0),
                'cont_retrans': v.get('cont_re',0)
            })
            v['client_prob'] = pc
            v['network_prob'] = pn
            v['server_prob'] = ps
            v['avg_win'] = avg_win
            v['rtt_avg'] = rtt_avg
            v['rtt_jitter'] = rtt_jitter
        except Exception:
            v['client_prob'] = v['network_prob'] = v['server_prob'] = 1.0/3.0
            v['avg_win'] = v.get('avg_win', 0)
            v['rtt_avg'] = v.get('rtt_avg', 0)
            v['rtt_jitter'] = v.get('rtt_jitter', 0)

    print("[*] Generating visualization ...")
    img_b64 = generate_summary_plot(flow_results)

    print("[*] Building HTML report ...")
    html_report = build_html(img_b64, flow_results, src_stats, dst_stats, pcap_path)

    out_file = "tcp_analysis_report.html"
    with open(out_file, "w", encoding="utf-8") as fh:
        fh.write(html_report)

    print(f"[*] Report written to {out_file}. Open it in a browser to review.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyze_and_generate_report.py target.pcap")
        sys.exit(1)
    pcap_file = sys.argv[1]
    main_final(pcap_file)

