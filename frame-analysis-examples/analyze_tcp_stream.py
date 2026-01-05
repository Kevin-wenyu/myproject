import pandas as pd

# 读取 tshark 导出的 CSV
df = pd.read_csv("tcp_stream20.csv")

# 标记异常包：RTO 或 retransmission
df['is_rto'] = df['tcp.analysis.rto'].notna()
df['is_retransmission'] = df['tcp.analysis.retransmission'].notna()

# 按 IP 统计异常包数量
rto_counts = df[df['is_rto']].groupby('ip.src').size()
retrans_counts = df[df['is_retransmission']].groupby('ip.src').size()

print("=== RTO 包统计 ===")
print(rto_counts)
print("=== 重传包统计 ===")
print(retrans_counts)

# 计算每条异常包出现在哪端的概率
def compute_prob(row):
    prob_client = 0.0
    prob_server = 0.0
    prob_network = 0.0
    
    win = row['tcp.window_size_value']
    rto = row['is_rto']
    retrans = row['is_retransmission']
    
    # 客户端窗口过小 → 客户端可能是瓶颈
    if win < 200:
        prob_client += 0.6
        prob_network += 0.2
        prob_server += 0.2
    # RTO 重传包 → 网络或接收端问题
    elif rto:
        prob_network += 0.5
        prob_client += 0.3
        prob_server += 0.2
    # 普通重传 → 网络轻微丢包
    elif retrans:
        prob_network += 0.5
        prob_client += 0.25
        prob_server += 0.25
    else:
        # 正常包
        prob_client += 0.33
        prob_network += 0.34
        prob_server += 0.33
    
    return pd.Series({'prob_client': prob_client, 'prob_network': prob_network, 'prob_server': prob_server})

# 生成概率列
df[['prob_client','prob_network','prob_server']] = df.apply(compute_prob, axis=1)

# 输出结果
df.to_csv("tcp_stream20_analysis.csv", index=False)
print("分析完成，结果保存为 tcp_stream20_analysis.csv")

