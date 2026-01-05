import sys
import dpkt
import socket
import argparse
import statistics
import datetime
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple


# ==========================================
# DATA STRUCTURES & CONFIGURATION
# ==========================================

@dataclass
class FlowMetrics:
    """Tracks state and metrics for a specific TCP 4-tuple flow."""
    src: str
    sport: int
    dst: str
    dport: int

    # Packet Counters
    packet_count: int = 0
    byte_count: int = 0

    # TCP Flags Counters
    syn_count: int = 0
    syn_ack_count: int = 0
    fin_count: int = 0
    rst_count: int = 0

    # RTT Calculation State
    # Map expected_ack -> timestamp of data packet sent
    unacked_packets: Dict[int, float] = field(default_factory=dict)
    rtt_samples: List[float] = field(default_factory=list)

    # Jitter / Inter-arrival
    last_packet_ts: float = 0.0
    jitter_samples: List[float] = field(default_factory=list)

    # Health
    retransmissions: int = 0
    out_of_order: int = 0
    zero_window_count: int = 0

    # Sequence Tracking for Retransmission Detection
    seen_seqs: set = field(default_factory=set)
    max_seq: int = 0


class GlobalState:
    """Holds global analysis data."""

    def __init__(self):
        self.start_ts = 0.0
        self.end_ts = 0.0
        self.total_packets = 0
        self.flows: Dict[tuple, FlowMetrics] = {}
        self.server_ips = set()


# ==========================================
# CORE CLASSES
# ==========================================

class PCAPLoader:
    """Handles file I/O and raw parsing."""

    @staticmethod
    def load_pcap(filename):
        try:
            f = open(filename, 'rb')
            # Try pcap
            try:
                return dpkt.pcap.Reader(f), f
            except:
                # Try pcapng
                f.seek(0)
                return dpkt.pcapng.Reader(f), f
        except Exception as e:
            print(f"[Error] Could not open pcap file: {e}")
            sys.exit(1)


class BasicStatsAnalyzer:
    """1.1 Basic Stats (Packets, Flows, Flags)."""

    def process(self, flow: FlowMetrics, tcp_flags: int, pkt_len: int, ts: float):
        flow.packet_count += 1
        flow.byte_count += pkt_len

        if tcp_flags & dpkt.tcp.TH_SYN:
            if tcp_flags & dpkt.tcp.TH_ACK:
                flow.syn_ack_count += 1
            else:
                flow.syn_count += 1
        if tcp_flags & dpkt.tcp.TH_FIN:
            flow.fin_count += 1
        if tcp_flags & dpkt.tcp.TH_RST:
            flow.rst_count += 1


class RTTAnalyzer:
    """2.1 & 2.2 RTT stats. Uses SEQ/ACK matching logic."""

    def process(self, flow: FlowMetrics, tcp, ts: float):
        seq = tcp.seq
        ack = tcp.ack
        flags = tcp.flags
        payload_len = len(tcp.data)

        # 1. Calculate RTT (Sender perspective)
        # If we are the sender (sending data), record timestamp expected to be ACKed
        if payload_len > 0:
            expected_ack = seq + payload_len
            # Only track if not a retransmission to avoid ambiguity (Karn's Algorithm)
            if seq not in flow.seen_seqs:
                flow.unacked_packets[expected_ack] = ts

        # 2. Calculate RTT (Receiver perspective - ACK processing)
        # If this is an ACK, check if it matches a pending packet from the REVERSE flow
        # NOTE: In this simplified single-pass architecture, we calculate RTT on the flow object
        # representing the SENDER of the ACK, looking up requests from the counter-flow.
        # However, easier logic: Check if 'ack' matches an entry in THIS flow's unacked list?
        # No, RTT is time between My_SEQ and Peer_ACK.

        # SIMPLIFIED ROBUST LOGIC:
        # We track RTT on the stream receiving the ACK.
        # To do this properly in one pass, we look at the `unacked_packets` of this flow.
        # Wait: unacked packets are stored on the flow that SENT them.
        # When we receive an ACK (incoming packet), we look up the flow that SENT data.

        if flags & dpkt.tcp.TH_ACK:
            # In this script, 'flow' is the direction Src->Dst.
            # So this packet is Src sending an ACK.
            # We need to check if Dst (reverse flow) was waiting for this ACK.
            pass

            # 3. Inter-arrival Jitter (simplified approximation of time_delta)
        if flow.last_packet_ts > 0:
            delta = ts - flow.last_packet_ts
            if delta < 1.0:  # Filter huge gaps (keepalives)
                flow.jitter_samples.append(delta)
        flow.last_packet_ts = ts


class AnomalyDetector:
    """6.1 Retransmissions, Out-of-Order, Windows."""

    def process(self, flow: FlowMetrics, tcp):
        seq = tcp.seq
        payload_len = len(tcp.data)

        # Zero Window
        if tcp.win == 0 and not (tcp.flags & dpkt.tcp.TH_RST):
            flow.zero_window_count += 1

        # Retransmission Detection
        if payload_len > 0:
            if seq in flow.seen_seqs:
                flow.retransmissions += 1
            else:
                flow.seen_seqs.add(seq)

            # Out of Order (Simple check)
            if seq < flow.max_seq and seq not in flow.seen_seqs:
                # This is a simplistic check, often indicates OoO
                flow.out_of_order += 1

            if seq > flow.max_seq:
                flow.max_seq = seq


class StreamAnalyzer:
    """Orchestrates the analysis per packet."""

    def __init__(self):
        self.basic_stats = BasicStatsAnalyzer()
        self.rtt_analyzer = RTTAnalyzer()
        self.anomaly_detector = AnomalyDetector()

    def process_packet(self, state: GlobalState, timestamp, buf):
        try:
            eth = dpkt.ethernet.Ethernet(buf)
        except:
            return

        # Handle IP
        if isinstance(eth.data, dpkt.ip.IP):
            ip = eth.data
        elif isinstance(eth.data, dpkt.ip6.IP6):
            # Skip IPv6 for this simplified script or treat same, simplified to IPv4 logic mostly
            ip = eth.data
        else:
            return

        # Handle TCP
        if not isinstance(ip.data, dpkt.tcp.TCP):
            return

        tcp = ip.data

        # Extract flow tuple
        try:
            src_ip = socket.inet_ntop(socket.AF_INET, ip.src)
            dst_ip = socket.inet_ntop(socket.AF_INET, ip.dst)
        except ValueError:
            # IPv6 fallback
            src_ip = socket.inet_ntop(socket.AF_INET6, ip.src)
            dst_ip = socket.inet_ntop(socket.AF_INET6, ip.dst)

        # Canonical Key for Bi-directional linking could be sorted,
        # but we need directional flows for RTT tracking.
        flow_key = (src_ip, tcp.sport, dst_ip, tcp.dport)
        rev_flow_key = (dst_ip, tcp.dport, src_ip, tcp.sport)

        # Get or Create Flow
        if flow_key not in state.flows:
            state.flows[flow_key] = FlowMetrics(src_ip, tcp.sport, dst_ip, tcp.dport)
        if rev_flow_key not in state.flows:
            state.flows[rev_flow_key] = FlowMetrics(dst_ip, tcp.dport, src_ip, tcp.sport)

        flow = state.flows[flow_key]
        rev_flow = state.flows[rev_flow_key]

        # 1. Basic Stats
        self.basic_stats.process(flow, tcp.flags, len(buf), timestamp)

        # 2. RTT Logic (Cross-Flow)
        # A. If this packet ACKs data sent by the reverse flow
        if (tcp.flags & dpkt.tcp.TH_ACK) and tcp.ack in rev_flow.unacked_packets:
            sent_ts = rev_flow.unacked_packets.pop(tcp.ack)
            rtt = timestamp - sent_ts
            if 0 < rtt < 5.0:  # Filter insane values
                # We assign RTT to the sender of the data (rev_flow) or the sender of ACK?
                # Usually RTT is a property of the link observed by the sender.
                rev_flow.rtt_samples.append(rtt)

        # B. If this packet contains data, mark it for the future ACK
        self.rtt_analyzer.process(flow, tcp, timestamp)

        # 3. Anomalies
        self.anomaly_detector.process(flow, tcp)

        # Global stats
        state.total_packets += 1
        if state.start_ts == 0: state.start_ts = timestamp
        state.end_ts = timestamp


class ReportGenerator:
    """Compiles the final Markdown report."""

    @staticmethod
    def generate(filename, state: GlobalState):
        duration = state.end_ts - state.start_ts
        duration = max(duration, 0.000001)

        # Aggregate Data
        total_flows = len(state.flows) // 2  # Approx bidirectional
        total_bytes = sum(f.byte_count for f in state.flows.values())

        all_rtt = []
        total_retrans = 0
        total_pkts_tcp = 0
        total_syn = 0
        total_syn_ack = 0
        total_fin = 0
        total_rst = 0
        zero_win = 0

        for f in state.flows.values():
            all_rtt.extend(f.rtt_samples)
            total_retrans += f.retransmissions
            total_pkts_tcp += f.packet_count
            total_syn += f.syn_count
            total_syn_ack += f.syn_ack_count
            total_fin += f.fin_count
            total_rst += f.rst_count
            zero_win += f.zero_window_count

        # Calc Metrics
        avg_rtt = statistics.mean(all_rtt) if all_rtt else 0.0
        min_rtt = min(all_rtt) if all_rtt else 0.0
        max_rtt = max(all_rtt) if all_rtt else 0.0

        retrans_rate = (total_retrans / total_pkts_tcp * 100) if total_pkts_tcp else 0
        handshake_success = (total_syn_ack / total_syn * 100) if total_syn else 0

        pps = state.total_packets / duration
        mbps = (total_bytes * 8) / duration / 1_000_000

        # Diagnosis
        health_msgs = []
        if retrans_rate > 2.0:
            health_msgs.append(f"CRITICAL: High Retransmission Rate ({retrans_rate:.2f}%) > 2%")
        if zero_win > 0:
            health_msgs.append(f"WARNING: Zero Window detected ({zero_win} events) - Application Stalls")
        if total_syn > 10 and total_syn_ack == 0:
            health_msgs.append("CRITICAL: No Handshakes completed (Possible Firewall/Down)")
        elif total_syn > (total_syn_ack * 10):
            health_msgs.append("WARNING: SYN Flood or Unresponsive Server detected")

        health_status = "Stable" if not health_msgs else "Issues Detected"

        print("# 📘 TCP Network Analysis Report")
        print(f"**File:** {filename}")
        print(f"**Date:** {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print("")

        print("## 1. 概览摘要 (Summary)")
        print(f"- **Traffic**: {state.total_packets} Packets, ~{total_flows} TCP Flows, {duration:.2f}s Duration.")
        print(f"- **Health Conclusion**: {health_status}")
        for msg in health_msgs:
            print(f"  - ⚠️ {msg}")
        print("")

        print("## 2. TCP 连接建立情况 (Handshake)")
        print(f"- **Stats**: SYN: {total_syn}, SYN/ACK: {total_syn_ack}, FIN: {total_fin}.")
        print(f"- **Handshake Success**: {handshake_success:.1f}%")
        print(f"- **Resets (RST)**: {total_rst}")
        print("")

        print("## 3. RTT / 延迟分析 (Latency)")
        print(f"- **Global**: Min: {min_rtt * 1000:.2f}ms | Max: {max_rtt * 1000:.2f}ms | Avg: {avg_rtt * 1000:.2f}ms")
        print(f"- **Sample Count**: {len(all_rtt)} valid RTT samples")
        print("")

        print("## 4. TCP 重传 / 丢包 (Loss & Retransmission)")
        print(f"- **Retransmission Rate**: {retrans_rate:.3f}%")
        print(f"- **Total Retransmissions**: {total_retrans}")
        print("")

        print("## 5. 流量统计 (Traffic)")
        print(f"- **Throughput**: {pps:.0f} PPS | {mbps:.2f} Mbps")
        print("")

        print("## 6. TCP 健康度 (Health)")
        print(f"- **Window Issues**: {zero_win} Zero Window events.")
        print(f"- **Closure**: {total_fin} Normal Closures vs {total_rst} Aborts.")
        print("")

        print("## 7. 关键会话分析 (Key Streams)")
        # Sort flows by retransmissions then bytes
        sorted_flows = sorted(state.flows.values(), key=lambda x: (x.retransmissions, x.byte_count), reverse=True)
        print("| Source IP:Port | Dest IP:Port | Pkts | Loss | RTT (Avg) |")
        print("|---|---|---|---|---|")
        for i, f in enumerate(sorted_flows[:5]):
            f_avg_rtt = (statistics.mean(f.rtt_samples) * 1000) if f.rtt_samples else 0
            print(
                f"| {f.src}:{f.sport} | {f.dst}:{f.dport} | {f.packet_count} | {f.retransmissions} | {f_avg_rtt:.2f}ms |")
        print("")

        print("## 8. 结论与建议 (Conclusion)")
        if retrans_rate > 1.0:
            print("- **Diagnosis**: Packet loss detected above standard thresholds.")
            print("- **Recommendations**: Check physical cabling, switch errors (FCS), or WAN congestion.")
        elif max_rtt > 0.200:
            print("- **Diagnosis**: High Latency peaks detected (>200ms).")
            print("- **Recommendations**: Investigate bufferbloat or routing path changes.")
        else:
            print("- **Diagnosis**: Network appears healthy with low loss and stable latency.")
            print("- **Recommendations**: Continue monitoring baseline.")
        print("")

        print("## 9. 附录: 验证命令 (Verification)")
        print("Run these commands in your terminal to cross-check results:")
        print("```bash")
        print(f"# 1. Check Lost Segments")
        print(f"tshark -r {filename} -q -z io,stat,1,\"tcp.analysis.lost_segment\"")
        print(f"# 2. Check Retransmissions")
        print(f"tshark -r {filename} -Y \"tcp.analysis.retransmission\"")
        print(f"# 3. TCP Conversation Stats")
        print(f"tshark -r {filename} -q -z conv,tcp")
        print(f"# 4. Min/Max/Avg RTT (Time Delta)")
        print(f"tshark -r {filename} -qz \"min_max_avg,tcp.time_delta\"")
        print("```")


# ==========================================
# MAIN EXECUTION
# ==========================================

def main():
    parser = argparse.ArgumentParser(description="Production-Grade TCP Analyzer")
    parser.add_argument("pcap_file", help="Path to the .pcap or .pcapng file")
    args = parser.parse_args()

    print(f"Processing {args.pcap_file}... Please wait.")

    reader, file_handle = PCAPLoader.load_pcap(args.pcap_file)
    state = GlobalState()
    stream_analyzer = StreamAnalyzer()

    try:
        for ts, buf in reader:
            stream_analyzer.process_packet(state, ts, buf)
    except KeyboardInterrupt:
        print("Analysis interrupted by user.")
    except Exception as e:
        print(f"Error during processing: {e}")
    finally:
        file_handle.close()

    ReportGenerator.generate(args.pcap_file, state)


if __name__ == "__main__":
    main()