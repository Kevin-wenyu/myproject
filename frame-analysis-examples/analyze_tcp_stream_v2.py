import pandas as pd
import matplotlib.pyplot as plt
import sys

# ------------------------
# 读取 CSV 文件
# ------------------------
if len(sys.argv) < 2:
    print("请提供 tshark 导出的 CSV 文件路径")
    print("用法: python analyze_tcp.py tcp_stream20.csv")
    sys.exit(1)

csv_file = sys.argv[1]
df = pd.read_csv(csv_file)

# ------------------------
# 标记异常包
# ------------------------
df['is_rto'] = df['tcp.analysis.rto'].notna()
df['is_retransmission'] = df['tcp.analysis.retransmission'].notna()

# ------------------------
# 每条包概率计算函数
# ------------------------
def compute_prob(row):
    prob_client = 0.0
    prob_server = 0.0
    prob_network = 0.0
    
    win = row['tcp.window_size_value']
    rto = row['is_rto']
    retrans = row['is_retransmission']
    
    if win < 200:
        prob_client += 0.6
        prob_network += 0.2
        prob_server += 0.2
    elif rto:
        prob_network += 0.5
        prob_client += 0.3
        prob_server += 0.2
    elif retrans:
        prob_network += 0.5
        prob_client += 0.25
        prob_server += 0.25
    else:
        prob_client += 0.33
        prob_network += 0.34
        prob_server += 0.33
    
    return pd.Series({'prob_client': prob_client, 'prob_network': prob_network, 'prob_server': prob_server})

df[['prob_client','prob_network','prob_server']] = df.apply(compute_prob, axis=1)

# ------------------------
# 按流汇总概率
# ------------------------
stream_summary = df.groupby('tcp.stream')[['prob_client','prob_network','prob_server']].sum()

# ------------------------
# 计算整体概率
# ------------------------
total_prob = stream_summary.sum()
total_sum = total_prob.sum()
overall = {
    'client': total_prob['prob_client']/total_sum,
    'network': total_prob['prob_network']/total_sum,
    'server': total_prob['prob_server']/total_sum
}

print("=== 各流汇总概率 ===")
print(stream_summary)
print("\n=== 整体概率分布 ===")
print(overall)

# ------------------------
# 按 IP 节点统计概率
# ------------------------
# 计算每个 IP 的问题概率 = 所有发包的 prob_client/prob_server/prob_network 加权
df['prob_total'] = df['prob_client'] + df['prob_network'] + df['prob_server']

# 对源 IP
ip_src_summary = df.groupby('ip.src')[['prob_client','prob_network','prob_server']].sum()
ip_src_summary['prob_sum'] = ip_src_summary.sum(axis=1)
ip_src_summary[['prob_client','prob_network','prob_server']] = ip_src_summary[['prob_client','prob_network','prob_server']].div(ip_src_summary['prob_sum'], axis=0)

# 对目的 IP
ip_dst_summary = df.groupby('ip.dst')[['prob_client','prob_network','prob_server']].sum()
ip_dst_summary['prob_sum'] = ip_dst_summary.sum(axis=1)
ip_dst_summary[['prob_client','prob_network','prob_server']] = ip_dst_summary[['prob_client','prob_network','prob_server']].div(ip_dst_summary['prob_sum'], axis=0)

print("\n=== 源 IP 节点问题概率 ===")
print(ip_src_summary[['prob_client','prob_network','prob_server']])

print("\n=== 目的 IP 节点问题概率 ===")
print(ip_dst_summary[['prob_client','prob_network','prob_server']])

# ------------------------
# 可视化整体概率
# ------------------------
labels = ['Client', 'Network', 'Server']
values = [overall['client'], overall['network'], overall['server']]

plt.figure(figsize=(6,4))
plt.bar(labels, values, color=['skyblue','orange','green'])
plt.title('Overall Probability of Problem Node')
plt.ylabel('Probability')
plt.ylim(0,1)
plt.show()

# ------------------------
# 保存结果
# ------------------------
stream_summary.to_csv("tcp_stream_analysis_summary.csv")
ip_src_summary.to_csv("tcp_ip_src_analysis.csv")
ip_dst_summary.to_csv("tcp_ip_dst_analysis.csv")
print("分析完成，已保存各流汇总及 IP 节点分析结果")

