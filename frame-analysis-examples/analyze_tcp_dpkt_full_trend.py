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
    # PSH 小包统计
    stats['psh_small'] += int(win < 200 and win > 0)
    # 保存每包窗口和时间
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
    print("用法: python analyze_tcp_dpkt_full_trend.py target.pcap")
    sys.exit(1)

pcap_file = sys.argv[1]

streams = defaultdict(lambda: {
    'count':0, 'wins':[], 'seqs':[], 'timestamps':[], 'retrans':0, 'rto':0,
    'cont_retrans':0, 'last_seq':None, 'psh_small':0,'win_ts':[]
})
ip_src_stats = defaultdict(lambda: {'prob':[0,0,0]})
ip_dst_stats = defaultdict(lambda: {'prob':[0,0,0]})
seen_seq = defaultdict(dict)

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
# 计算概率 & 输出
# ------------------------
flow_results = {}
for k, stats in streams.items():
    prob_client, prob_network, prob_server, avg_win, rtt_jitter = compute_flow_prob(stats)
    flow_results[k] = {'client':prob_client,'network':prob_network,'server':prob_server,
                       'avg_win':avg_win,'rtt_jitter':rtt_jitter,'win_ts':stats['win_ts'],'timestamps':stats['timestamps']}

for k,v in flow_results.items():
    src_ip,dst_ip=k[0],k[2]
    for i,node in enumerate(['client','network','server']):
        ip_src_stats[src_ip]['prob'][i] += v[node]
        ip_dst_stats[dst_ip]['prob'][i] += v[node]

# ------------------------
# 可视化总体概率
# ------------------------
total_client = sum([p['client'] for p in flow_results.values()])
total_network = sum([p['network'] for p in flow_results.values()])
total_server = sum([p['server'] for p in flow_results.values()])
total_sum = total_client+total_network+total_server
labels=['Client','Network','Server']
values=[total_client/total_sum,total_network/total_sum,total_server/total_sum]

plt.figure(figsize=(6,4))
plt.bar(labels,values,color=['skyblue','orange','green'])
plt.title("Overall Problem Node Probability")
plt.ylabel("Probability")
plt.ylim(0,1)
plt.show()

# ------------------------
# 热力图
# ------------------------
def plot_ip_heatmap(ip_dict, title):
    ips = list(ip_dict.keys())
    clients = [ip_dict[ip]['prob'][0] for ip in ips]
    networks = [ip_dict[ip]['prob'][1] for ip in ips]
    servers = [ip_dict[ip]['prob'][2] for ip in ips]

    x = np.arange(len(ips))
    width=0.25
    plt.figure(figsize=(10,5))
    plt.bar(x-width, clients, width, label='Client',color='skyblue')
    plt.bar(x, networks, width, label='Network',color='orange')
    plt.bar(x+width, servers, width, label='Server',color='green')
    plt.xticks(x, ips, rotation=45)
    plt.title(title)
    plt.ylabel("Probability")
    plt.legend()
    plt.tight_layout()
    plt.show()

plot_ip_heatmap(ip_src_stats, "Source IP Problem Probability")
plot_ip_heatmap(ip_dst_stats, "Destination IP Problem Probability")

# ------------------------
# RTT & 窗口趋势折线图
# ------------------------
for k,v in flow_results.items():
    timestamps = v['timestamps']
    win_ts = v['win_ts']
    if not timestamps or not win_ts:
        continue
    times, wins = zip(*win_ts)
    plt.figure(figsize=(10,4))
    plt.plot(times, wins, label='Window size', color='blue')
    # RTT 用连续时间差作为近似
    rtts = [j-i for i,j in zip(timestamps[:-1],timestamps[1:])]
    if rtts:
        plt.plot(times[1:], rtts, label='Approx RTT', color='red')
    plt.title(f"TCP Stream {k[0]}:{k[1]} → {k[2]}:{k[3]} Trend")
    plt.xlabel("Time (s)")
    plt.ylabel("Window / RTT")
    plt.legend()
    plt.tight_layout()
    plt.show()

# ------------------------
# 保存 CSV
# ------------------------
with open('tcp_flow_analysis_full.csv','w',newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['src_ip','src_port','dst_ip','dst_port','client_prob','network_prob','server_prob','avg_win','rtt_jitter'])
    for k,v in flow_results.items():
        writer.writerow([k[0],k[1],k[2],k[3],v['client'],v['network'],v['server'],v['avg_win'],v['rtt_jitter']])

print("分析完成，已生成 tcp_flow_analysis_full.csv 并绘制趋势图和热力图")

