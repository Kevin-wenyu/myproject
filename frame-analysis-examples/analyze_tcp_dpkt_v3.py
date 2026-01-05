import dpkt
import socket
import sys
from collections import defaultdict
import matplotlib.pyplot as plt
import numpy as np
import csv

# ------------------------
# 工具函数
# ------------------------
def inet_to_str(inet):
    return socket.inet_ntoa(inet)

def update_stats(stats, win, is_rto, is_retrans, seq, ts):
    stats['count'] += 1
    stats['wins'].append(win)
    stats['seqs'].append(seq)
    stats['timestamps'].append(ts)
    stats['retrans'] += int(is_retrans)
    stats['rto'] += int(is_rto)
    if is_retrans:
        if stats['last_seq'] == seq:
            stats['cont_retrans'] += 1
        stats['last_seq'] = seq
    stats['psh_small'] += int(win < 200 and win > 0)
    stats['win_ts'].append((ts,win))
    return stats

def compute_flow_prob(stats):
    rto_w = 0.4
    cont_retrans_w = 0.2
    retrans_w = 0.2
    win_w = 0.1
    rtt_w = 0.1

    avg_win = np.mean(stats['wins']) if stats['wins'] else 0
    if len(stats['timestamps'])>1:
        rtt_jitter = np.std(np.diff(stats['timestamps']))
    else:
        rtt_jitter = 0

    prob_client = 0.0
    prob_network = 0.0
    prob_server = 0.0

    if avg_win < 200:
        prob_client += win_w
        prob_network += win_w/2
        prob_server += win_w/2

    prob_network += stats['rto']*rto_w
    prob_client += stats['rto']*rto_w*0.5
    prob_server += stats['rto']*rto_w*0.5

    prob_network += stats['retrans']*retrans_w
    prob_client += stats['retrans']*retrans_w*0.5
    prob_server += stats['retrans']*retrans_w*0.5

    prob_network += stats['cont_retrans']*cont_retrans_w
    prob_client += stats['cont_retrans']*cont_retrans_w*0.5
    prob_server += stats['cont_retrans']*cont_retrans_w*0.5

    if rtt_jitter>0.03:
        prob_network += rtt_w
        prob_client += rtt_w*0.5
        prob_server += rtt_w*0.5

    total = prob_client+prob_network+prob_server
    if total>0:
        prob_client /= total
        prob_network /= total
        prob_server /= total
    else:
        prob_client = prob_network = prob_server = 0.33

    return prob_client, prob_network, prob_server, avg_win, rtt_jitter

# ------------------------
# 主程序
# ------------------------
if len(sys.argv)<2:
    print("用法: python analyze_tcp_dpkt_engineer_clean.py target.pcap")
    sys.exit(1)

pcap_file = sys.argv[1]

streams = defaultdict(lambda: {
    'count':0, 'wins':[], 'seqs':[], 'timestamps':[], 'retrans':0, 'rto':0,
    'cont_retrans':0, 'last_seq':None, 'psh_small':0,'win_ts':[]
})
ip_src_stats = defaultdict(lambda: {'prob':[0,0,0]})
ip_dst_stats = defaultdict(lambda: {'prob':[0,0,0]})
seen_seq = defaultdict(dict)

# ------------------------
# 解析 pcap
# ------------------------
with open(pcap_file,'rb') as f:
    pcap = dpkt.pcap.Reader(f)
    for ts, buf in pcap:
        try:
            eth = dpkt.ethernet.Ethernet(buf)
            if not isinstance(eth.data, dpkt.ip.IP): continue
            ip = eth.data
            if not isinstance(ip.data, dpkt.tcp.TCP): continue
            tcp = ip.data

            src_ip = inet_to_str(ip.src)
            dst_ip = inet_to_str(ip.dst)
            src_port = tcp.sport
            dst_port = tcp.dport
            stream_key = (src_ip, src_port, dst_ip, dst_port)

            seq = tcp.seq
            win = tcp.win
            payload_len = len(tcp.data)
            is_retrans = False
            if seq in seen_seq.get(stream_key,{}):
                is_retrans = True
            seen_seq.setdefault(stream_key,{})[seq]=True
            is_rto = is_retrans and payload_len>0

            streams[stream_key] = update_stats(streams[stream_key], win, is_rto, is_retrans, seq, ts)
        except:
            continue

# ------------------------
# 计算概率 & 汇总
# ------------------------
flow_results = {}
for k, stats in streams.items():
    prob_client, prob_network, prob_server, avg_win, rtt_jitter = compute_flow_prob(stats)
    flow_results[k] = {'client':prob_client,'network':prob_network,'server':prob_server,
                       'avg_win':avg_win,'rtt_jitter':rtt_jitter,'win_ts':stats['win_ts'],'timestamps':stats['timestamps'],'count':stats['count']}

for k,v in flow_results.items():
    src_ip,dst_ip=k[0],k[2]
    for i,node in enumerate(['client','network','server']):
        ip_src_stats[src_ip]['prob'][i] += v[node]
        ip_dst_stats[dst_ip]['prob'][i] += v[node]

# ------------------------
# 选择绘制关键流（Top N 流）避免杂乱
# ------------------------
top_n = 10
top_flows = sorted(flow_results.items(), key=lambda x: x[1]['count'], reverse=True)[:top_n]

# ------------------------
# 绘制综合图表
# ------------------------
fig, axes = plt.subplots(3,1, figsize=(14,12), gridspec_kw={'height_ratios':[1,3,2]})

# 1) 总体节点概率柱状图
total_client = sum([p['client'] for p in flow_results.values()])
total_network = sum([p['network'] for p in flow_results.values()])
total_server = sum([p['server'] for p in flow_results.values()])
total_sum = total_client+total_network+total_server
labels=['Client','Network','Server']
values=[total_client/total_sum,total_network/total_sum,total_server/total_sum]
axes[0].bar(labels,values,color=['skyblue','orange','green'])
axes[0].set_title("Overall Problem Node Probability")
axes[0].set_ylim(0,1)
axes[0].set_ylabel("Probability")

# 2) TCP 流窗口和 RTT 趋势（只显示Top N流）
ax1 = axes[1]
ax2 = ax1.twinx()
colors = plt.cm.tab20.colors
for i,(k,v) in enumerate(top_flows):
    times, wins = zip(*v['win_ts']) if v['win_ts'] else ([],[])
    if times and wins:
        # 采样减少点数
        sample_rate = max(1, len(times)//200)
        ax1.plot(times[::sample_rate], wins[::sample_rate], color=colors[i%20], alpha=0.7, label=f"{k[0]}->{k[2]}")
    if v['timestamps']:
        rtts = [j-i for i,j in zip(v['timestamps'][:-1],v['timestamps'][1:])]
        if rtts:
            ax2.plot(v['timestamps'][1:][::sample_rate], rtts[::sample_rate], color=colors[i%20], linestyle='--', alpha=0.3)
ax1.set_xlabel("Time (s)")
ax1.set_ylabel("Window size", color='blue')
ax2.set_ylabel("Approx RTT", color='red')
ax1.set_title(f"Top {top_n} TCP Flows Window & RTT Trend")
ax1.legend(fontsize='small', ncol=2)

# 3) 源/目的 IP 热力图
def plot_ip_heatmap(ip_dict, title, ax):
    ips = list(ip_dict.keys())
    clients = [ip_dict[ip]['prob'][0] for ip in ips]
    networks = [ip_dict[ip]['prob'][1] for ip in ips]
    servers = [ip_dict[ip]['prob'][2] for ip in ips]
    x = np.arange(len(ips))
    width=0.25
    ax.bar(x-width, clients, width, label='Client',color='skyblue')
    ax.bar(x, networks, width, label='Network',color='orange')
    ax.bar(x+width, servers, width, label='Server',color='green')
    ax.set_xticks(x)
    ax.set_xticklabels(ips, rotation=45, fontsize=8)
    ax.set_ylabel("Probability")
    ax.set_title(title)
    ax.legend(fontsize='small')
plot_ip_heatmap(ip_src_stats, "Source IP Problem Probability", axes[2])
plt.tight_layout()
plt.savefig("tcp_comprehensive_clean.png")
plt.show()

# ------------------------
# 输出 CSV
# ------------------------
with open('tcp_flow_analysis_engineer_clean.csv','w',newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['src_ip','src_port','dst_ip','dst_port','client_prob','network_prob','server_prob','avg_win','rtt_jitter','count'])
    for k,v in flow_results.items():
        writer.writerow([k[0],k[1],k[2],k[3],v['client'],v['network'],v['server'],v['avg_win'],v['rtt_jitter'],v['count']])

print("分析完成，已生成 tcp_flow_analysis_engineer_clean.csv 和综合图 tcp_comprehensive_clean.png")

