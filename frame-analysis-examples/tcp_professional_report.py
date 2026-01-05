#!/usr/bin/env python3
"""
Professional TCP PCAP Analysis Script
Usage:
    pip install dpkt matplotlib numpy
    python tcp_professional_report.py target.pcap

Output:
    tcp_analysis_report.html
"""
import sys
import dpkt
import socket
from collections import defaultdict
import numpy as np
import matplotlib.pyplot as plt
from io import BytesIO
import base64
import datetime
import html

TOP_N = 10
PLOT_MAX_POINTS = 200
RTT_JITTER_THRESH = 0.03

def inet_to_str(inet):
    try:
        return socket.inet_ntoa(inet)
    except:
        return str(inet)

def compute_flow_metrics(stats):
    """Compute professional flow metrics and probabilities"""
    wins = stats['wins']
    seq_ack_time = stats['seq_ack_time']
    avg_win = float(np.mean(wins)) if wins else 0.0

    rtt_list = [ack_ts - ts for ts, ack_ts in seq_ack_time] if seq_ack_time else []
    rtt_avg = float(np.mean(rtt_list)) if rtt_list else 0.0
    rtt_max = float(np.max(rtt_list)) if rtt_list else 0.0
    rtt_jitter = float(np.std(rtt_list)) if rtt_list else 0.0

    # probability model weights
    rto_w = 0.45
    cont_retrans_w = 0.2
    retrans_w = 0.15
    win_w = 0.1
    rtt_w = 0.1

    prob_client = prob_network = prob_server = 0.0

    if avg_win and avg_win < 200:
        prob_client += win_w
        prob_network += win_w * 0.4
        prob_server += win_w * 0.2

    prob_network += stats['rto'] * rto_w
    prob_client += stats['rto'] * rto_w * 0.4
    prob_server += stats['rto'] * rto_w * 0.2

    prob_network += stats['retrans'] * retrans_w
    prob_client += stats['retrans'] * retrans_w * 0.4
    prob_server += stats['retrans'] * retrans_w * 0.2

    prob_network += stats['cont_retrans'] * cont_retrans_w
    prob_client += stats['cont_retrans'] * cont_retrans_w * 0.3
    prob_server += stats['cont_retrans'] * cont_retrans_w * 0.1

    if rtt_jitter > RTT_JITTER_THRESH:
        prob_network += rtt_w
        prob_client += rtt_w * 0.4
        prob_server += rtt_w * 0.2

    total = prob_client + prob_network + prob_server
    if total > 0:
        prob_client /= total
        prob_network /= total
        prob_server /= total
    else:
        prob_client = prob_network = prob_server = 1.0/3.0

    return {
        'avg_win': avg_win,
        'rtt_avg': rtt_avg,
        'rtt_max': rtt_max,
        'rtt_jitter': rtt_jitter,
        'client': prob_client,
        'network': prob_network,
        'server': prob_server
    }

def safe_str(x):
    return html.escape(str(x))

def build_html(title, summary, img_base64, flow_rows, src_rows, dst_rows, gen_time, pcap_name):
    html_content = f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>{safe_str(title)}</title>
<style>
body {{ font-family: Arial, sans-serif; margin:20px; }}
h1 {{ color:#2b6ea3; }}
.block {{ border-left:4px solid #2b6ea3; padding-left:10px; margin:15px 0; }}
table {{ border-collapse: collapse; width:100%; margin-top:8px; font-size:13px; }}
th, td {{ border:1px solid #ddd; padding:6px; text-align:left; }}
th {{ background:#f3f6fb; }}
.small {{ font-size:12px; color:#666; }}
</style>
</head>
<body>
<h1>{safe_str(title)}</h1>
<p class="small">Generated: {gen_time} | PCAP: {safe_str(pcap_name)}</p>
<div class="block"><h2>Summary</h2><p>{safe_str(summary)}</p></div>
<h2>Trend Chart</h2><img src="data:image/png;base64,{img_base64}" style="width:100%;border:1px solid #ddd;">
<h2>Flow Metrics</h2>
<table><thead><tr>
<th>#</th><th>Flow</th><th>Count</th><th>RTO</th><th>Retrans</th><th>Cont Retrans</th><th>SmallWin</th>
<th>AvgWin</th><th>RTT_avg</th><th>RTT_max</th><th>RTT_jitter</th><th>ClientProb</th><th>NetProb</th><th>ServerProb</th>
</tr></thead><tbody>
"""
    for i,row in enumerate(flow_rows,1):
        html_content += "<tr>"
        html_content += f"<td>{i}</td><td>{safe_str(row['flow'])}</td><td>{row['count']}</td>"
        html_content += f"<td>{row['rto']}</td><td>{row['retrans']}</td><td>{row['cont_retrans']}</td>"
        html_content += f"<td>{row['psh_small']}</td><td>{row['avg_win']:.1f}</td>"
        html_content += f"<td>{row['rtt_avg']:.4f}</td><td>{row['rtt_max']:.4f}</td><td>{row['rtt_jitter']:.4f}</td>"
        html_content += f"<td>{row['client']:.3f}</td><td>{row['network']:.3f}</td><td>{row['server']:.3f}</td>"
        html_content += "</tr>\n"
    html_content += "</tbody></table>"

    # IP tables
    for section_name, ip_rows in [('Source IP', src_rows), ('Destination IP', dst_rows)]:
        html_content += f"<h2>{section_name} Metrics</h2><table><thead><tr><th>IP</th><th>FlowCount</th><th>RTO</th><th>Retrans</th><th>Cont Retrans</th><th>SmallWin</th><th>ClientProb</th><th>NetProb</th><th>ServerProb</th></tr></thead><tbody>"
        for r in ip_rows:
            html_content += "<tr>"
            html_content += f"<td>{safe_str(r['ip'])}</td><td>{r['flow_count']}</td><td>{r['rto']}</td><td>{r['retrans']}</td><td>{r['cont_retrans']}</td><td>{r['psh_small']}</td>"
            html_content += f"<td>{r['client']:.3f}</td><td>{r['network']:.3f}</td><td>{r['server']:.3f}</td>"
            html_content += "</tr>"
        html_content += "</tbody></table>"
    html_content += f"<p class='small'>Generated by professional TCP analysis tool on {gen_time}</p></body></html>"
    return html_content

def main(pcap_path):
    streams = defaultdict(lambda:{
        'count':0,'wins':[],'seq_ack_time':[],'retrans':0,'rto':0,'cont_retrans':0,'last_seq':None,'psh_small':0,'seq_history':{},'last_ack_seen':{}
    })
    try:
        f = open(pcap_path,'rb')
        pcap = dpkt.pcap.Reader(f)
    except Exception as e:
        print("Failed to open PCAP:", e)
        return

    for ts, buf in pcap:
        try:
            eth = dpkt.ethernet.Ethernet(buf)
            if not isinstance(eth.data, dpkt.ip.IP): continue
            ip = eth.data
            if not isinstance(ip.data, dpkt.tcp.TCP): continue
            tcp = ip.data
            src_ip,dst_ip = inet_to_str(ip.src), inet_to_str(ip.dst)
            src_port,dst_port = tcp.sport, tcp.dport
            stream_key = (src_ip, src_port, dst_ip, dst_port)
            seq,len_payload = tcp.seq,len(tcp.data)
            ack = tcp.ack
            win = tcp.win
            s = streams[stream_key]
            # professional retrans / RTO tracking
            if seq in s['seq_history']:
                s['retrans'] +=1
                if s['last_seq'] == seq:
                    s['cont_retrans'] +=1
                s['rto'] +=1
            s['seq_history'][seq] = ts
            s['last_seq']=seq
            if ack in s['seq_history']:
                s['seq_ack_time'].append( (s['seq_history'][ack], ts) )
            s['wins'].append(win)
            s['count'] +=1
            s['psh_small'] += int(0<win<200)
        except Exception: continue
    f.close()

    flow_rows=[]
    src_rows_dict=defaultdict(lambda:{'flow_count':0,'rto':0,'retrans':0,'cont_retrans':0,'psh_small':0,'client':0,'network':0,'server':0})
    dst_rows_dict=defaultdict(lambda:{'flow_count':0,'rto':0,'retrans':0,'cont_retrans':0,'psh_small':0,'client':0,'network':0,'server':0})

    for k,s in streams.items():
        metrics = compute_flow_metrics(s)
        flow_rows.append({'flow':f"{k[0]}:{k[1]}->{k[2]}:{k[3]}",'count':s['count'],
                          'rto':s['rto'],'retrans':s['retrans'],'cont_retrans':s['cont_retrans'],
                          'psh_small':s['psh_small'],'avg_win':metrics['avg_win'],
                          'rtt_avg':metrics['rtt_avg'],'rtt_max':metrics['rtt_max'],'rtt_jitter':metrics['rtt_jitter'],
                          'client':metrics['client'],'network':metrics['network'],'server':metrics['server']})
        # IP aggregation
        for ip_dict, ip in [(src_rows_dict,k[0]),(dst_rows_dict,k[2])]:
            ip_dict[ip]['flow_count'] +=1
            ip_dict[ip]['rto'] += s['rto']
            ip_dict[ip]['retrans'] += s['retrans']
            ip_dict[ip]['cont_retrans'] += s['cont_retrans']
            ip_dict[ip]['psh_small'] += s['psh_small']
            ip_dict[ip]['client'] += metrics['client']
            ip_dict[ip]['network'] += metrics['network']
            ip_dict[ip]['server'] += metrics['server']

    # Fix: include IP in each row
    src_rows = []
    for ip,d in src_rows_dict.items():
        row = dict(d)
        row['ip'] = ip
        src_rows.append(row)
    dst_rows = []
    for ip,d in dst_rows_dict.items():
        row = dict(d)
        row['ip'] = ip
        dst_rows.append(row)

    gen_time=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # simple chart: single PNG in-memory
    fig,ax=plt.subplots(figsize=(10,5))
    flow_scores=[f['rto']+f['retrans']+f['cont_retrans'] for f in flow_rows]
    flow_names=[f['flow'] for f in flow_rows]
    ax.barh(flow_names[:TOP_N],flow_scores[:TOP_N])
    plt.tight_layout()
    buf=BytesIO()
    plt.savefig(buf,format='png',dpi=150)
    plt.close(fig)
    img_b64=base64.b64encode(buf.getvalue()).decode()
    buf.close()

    summary=f"Top flow RTO/重传统计: {flow_rows[0]['flow']} (RTO={flow_rows[0]['rto']}, cont_retrans={flow_rows[0]['cont_retrans']})" if flow_rows else "No flows"

    html_out=build_html("Professional TCP Analysis Report",summary,img_b64,flow_rows,src_rows,dst_rows,gen_time,pcap_path)
    with open("tcp_analysis_report.html","w",encoding="utf-8") as fh:
        fh.write(html_out)
    print("Generated tcp_analysis_report.html")

if __name__=="__main__":
    if len(sys.argv)<2:
        print("Usage: python tcp_professional_report.py target.pcap")
        sys.exit(1)
    main(sys.argv[1])

