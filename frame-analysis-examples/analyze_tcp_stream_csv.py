import pandas as pd

# ------------------------
# 读取 CSV 文件
# ------------------------
if len(sys.argv) < 2:
    print("请提供 tshark 导出的 CSV 文件路径")
    print("用法: python analyze_tcp_csv.py tcp_stream20.csv")
    sys.exit(1)

# 统计各端累计概率
sum_client = df['prob_client'].sum()
sum_network = df['prob_network'].sum()
sum_server = df['prob_server'].sum()

total = sum_client + sum_network + sum_server

print("整体概率分布：")
print(f"客户端问题概率 ≈ {sum_client/total:.2%}")
print(f"网络问题概率 ≈ {sum_network/total:.2%}")
print(f"服务端问题概率 ≈ {sum_server/total:.2%}")

