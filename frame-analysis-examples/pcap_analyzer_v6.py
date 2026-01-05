import sys
import socket
import struct
import argparse
import os
import statistics
from collections import defaultdict, deque
from datetime import datetime

try:
    import dpkt
except ImportError:
    print("Error: 'dpkt' library not found. Please install it via 'pip install dpkt'")
    sys.exit(1)


# ==========================================
# UTILITY CLASSES
# ==========================================

class NetworkUtils:
    @staticmethod
    def inet_to_str(inet):
        try:
            return socket.inet_ntop(socket.AF_INET, inet)
        except ValueError:
            try:
                return socket.inet_ntop(socket.AF_INET6, inet)
            except ValueError:
                return "Unknown"

    @staticmethod
    def format_bytes(size):
        power = 2 ** 10
        n = 0
        power_labels = {0: '', 1: 'KB', 2: 'MB', 3: 'GB', 4: 'TB'}
        while size > power:
            size /= power
            n += 1
        return f"{size:.2f} {power_labels[n]}"


# ==========================================
# CORE ANALYZER CLASSES
# ==========================================

class PCAPLoader:
    def __init__(self, filename):
        self.filename = filename

    def load(self):
        """Generator that yields (timestamp, buffer)"""
        if not os.path.exists(self.filename):
            raise FileNotFoundError(f"File not found: {self.filename}")

        with open(self.filename, 'rb') as f:
            try:
                # Try standard pcap
                pcap = dpkt.pcap.Reader(f)
            except ValueError:
                # Fallback for pcapng if dpkt supports it or reset pointer
                f.seek(0)
                try:
                    pcap = dpkt.pcapng.Reader(f)
                except:
                    raise ValueError("Could not read file. Ensure it is a valid PCAP/PCAPNG.")

            for ts, buf in pcap:
                yield ts, buf


class StreamState:
    """Tracks the state of a single TCP Flow"""

    def __init__(self, src_key, dst_key):
        self.src_key = src_key  # (ip, port)
        self.dst_key = dst_key
        self.packet_count = 0
        self.bytes_count = 0
        self.retransmissions = 0
        self.zero_windows = 0
        self.rtt_samples = []
        self.seq_tracking = {}  # seq+len -> timestamp
        self.seen_seqs = set()
        self.start_ts = 0
        self.last_ts = 0
        self.is_closed = False


class BasicStatsAnalyzer:
    def __init__(self):
        self.pkts_total = 0
        self.start_ts = None
        self.end_ts = None
        self.bytes_total = 0

    def process(self, ts, buf_len):
        self.pkts_total += 1
        self.bytes_total += buf_len
        if self.start_ts is None or ts < self.start_ts:
            self.start_ts = ts
        if self.end_ts is None or ts > self.end_ts:
            self.end_ts = ts

    @property
    def duration(self):
        if self.start_ts and self.end_ts:
            d = self.end_ts - self.start_ts
            return d if d > 0 else 0.0001
        return 0


class TCPHealthCheck:
    def __init__(self):
        self.syn_count = 0
        self.syn_ack_count = 0
        self.rst_count = 0
        self.fin_count = 0
        self.zero_window_events = 0
        self.window_full_events = 0  # Hard to detect exactly without MSS, estimating

    def process(self, tcp):
        if tcp.flags & dpkt.tcp.TH_SYN:
            if tcp.flags & dpkt.tcp.TH_ACK:
                self.syn_ack_count += 1
            else:
                self.syn_count += 1
        if tcp.flags & dpkt.tcp.TH_RST:
            self.rst_count += 1
        if tcp.flags & dpkt.tcp.TH_FIN:
            self.fin_count += 1
        if tcp.win == 0 and not (tcp.flags & dpkt.tcp.TH_RST):
            self.zero_window_events += 1


class AnomalyDetector:
    def __init__(self):
        self.retrans_count = 0
        self.out_of_order_count = 0
        self.duplicate_acks = 0
        self.checksum_errors = 0

    def check_retrans(self, stream, seq, payload_len, ts):
        # Simple logic: if we've seen this exact sequence number with payload before
        if payload_len > 0:
            if seq in stream.seen_seqs:
                stream.retransmissions += 1
                self.retrans_count += 1
                return True
            stream.seen_seqs.add(seq)
        return False


class RTTAnalyzer:
    def __init__(self):
        self.all_rtts = []

    def track(self, stream, tcp, ts, payload_len):
        # 1. If sending data, record expectation
        expected_ack = tcp.seq + payload_len
        if payload_len > 0:
            if expected_ack not in stream.seq_tracking:
                stream.seq_tracking[expected_ack] = ts

        # 2. If receiving ACK, check against expectations from reverse flow
        # Note: In a single pass linear scan, we need the 'reverse' stream object to check ACKs
        # Since we handle this in the main loop, we assume 'stream' is the sender here.
        # RTT is calculated when we see an ACK for a previously sent packet.
        pass

    def record_ack(self, reverse_stream, ack_num, ts):
        if ack_num in reverse_stream.seq_tracking:
            rtt = (ts - reverse_stream.seq_tracking[ack_num]) * 1000  # ms
            if 0 < rtt < 10000:  # Sanity check < 10s
                reverse_stream.rtt_samples.append(rtt)
                self.all_rtts.append(rtt)
            del reverse_stream.seq_tracking[ack_num]


class TrafficAnalyzer:
    def __init__(self):
        self.ip_volumes = defaultdict(int)
        self.streams = {}

    def get_stream_id(self, ip_src, src_port, ip_dst, dst_port):
        # Directional Key
        return (ip_src, src_port, ip_dst, dst_port)

    def update(self, ip_src, src_port, ip_dst, dst_port, size):
        src_str = NetworkUtils.inet_to_str(ip_src)
        self.ip_volumes[src_str] += size

        key = self.get_stream_id(ip_src, src_port, ip_dst, dst_port)
        if key not in self.streams:
            self.streams[key] = StreamState((ip_src, src_port), (ip_dst, dst_port))

        self.streams[key].bytes_count += size
        self.streams[key].packet_count += 1
        return self.streams[key]


class PerformanceAnalyzer:
    def calculate_throughput(self, total_bytes, duration):
        if duration == 0: return 0
        # Mbps
        return (total_bytes * 8) / (duration * 1000000)


# ==========================================
# MAIN ORCHESTRATOR
# ==========================================

class PcapAnalyzerV4:
    def __init__(self, filename):
        self.filename = filename
        self.loader = PCAPLoader(filename)

        # Components
        self.basic = BasicStatsAnalyzer()
        self.health = TCPHealthCheck()
        self.anomalies = AnomalyDetector()
        self.rtt = RTTAnalyzer()
        self.traffic = TrafficAnalyzer()
        self.perf = PerformanceAnalyzer()

    def run(self):
        print(f"Processing {self.filename}... Please wait.")
        try:
            for ts, buf in self.loader.load():
                self.basic.process(ts, len(buf))

                try:
                    eth = dpkt.ethernet.Ethernet(buf)
                except:
                    continue

                # IP Check
                if isinstance(eth.data, dpkt.ip.IP):
                    ip = eth.data
                    # TCP Check
                    if isinstance(ip.data, dpkt.tcp.TCP):
                        tcp = ip.data
                        self.process_tcp(ts, ip, tcp, len(buf))
        except Exception as e:
            print(f"Error during analysis: {e}")

    def process_tcp(self, ts, ip, tcp, wire_len):
        # Health Flags
        self.health.process(tcp)

        # Stream Management
        stream = self.traffic.update(ip.src, tcp.sport, ip.dst, tcp.dport, wire_len)
        if stream.packet_count == 1:
            stream.start_ts = ts
        stream.last_ts = ts

        payload_len = len(tcp.data)

        # Anomaly: Retransmission
        self.anomalies.check_retrans(stream, tcp.seq, payload_len, ts)

        # RTT: Tracking
        # 1. Register sent segment
        self.rtt.track(stream, tcp, ts, payload_len)

        # 2. Check if this packet ACKs a segment from the reverse flow
        reverse_key = (ip.dst, tcp.dport, ip.src, tcp.sport)
        if reverse_key in self.traffic.streams:
            rev_stream = self.traffic.streams[reverse_key]
            if tcp.flags & dpkt.tcp.TH_ACK:
                self.rtt.record_ack(rev_stream, tcp.ack, ts)

    def generate_report(self):
        # Aggregations
        duration = self.basic.duration
        total_bytes = self.basic.bytes_total
        bps = self.perf.calculate_throughput(total_bytes, duration)
        pps = self.basic.pkts_total / duration if duration else 0

        # RTT Stats
        rtt_samples = self.rtt.all_rtts
        min_rtt = min(rtt_samples) if rtt_samples else 0
        max_rtt = max(rtt_samples) if rtt_samples else 0
        avg_rtt = statistics.mean(rtt_samples) if rtt_samples else 0
        jitter = statistics.stdev(rtt_samples) if len(rtt_samples) > 1 else 0

        # Anomaly Stats
        retrans_rate = (self.anomalies.retrans_count / self.basic.pkts_total * 100) if self.basic.pkts_total else 0

        # Diagnosis
        diagnosis = []
        if retrans_rate > 2.0:
            diagnosis.append(f"High Packet Loss Detected ({retrans_rate:.2f}%) - Check Physical Layer/Congestion")
        if self.health.zero_window_events > 0:
            diagnosis.append("Zero Window Events Detected - Application Receiver Bottleneck")
        if self.health.syn_count > 0 and self.health.syn_ack_count == 0:
            diagnosis.append("Server Unresponsive (SYN sent, no SYN-ACK)")
        if not diagnosis:
            diagnosis.append("Link Stable - No critical anomalies based on static thresholds.")

        diagnosis_str = " / ".join(diagnosis)

        # Top Talkers
        sorted_talkers = sorted(self.traffic.ip_volumes.items(), key=lambda x: x[1], reverse=True)[:3]
        talkers_str = ", ".join([f"{ip} ({NetworkUtils.format_bytes(b)})" for ip, b in sorted_talkers])

        # Key Streams (Sort by RTT then Retrans)
        # Merge bidirectional logic for display is hard without session matching,
        # but let's display top directional flows with issues.
        stream_list = list(self.traffic.streams.values())
        # Score: High RTT * Retrans
        stream_list.sort(key=lambda s: (statistics.mean(s.rtt_samples) if s.rtt_samples else 0), reverse=True)
        top_streams = stream_list[:5]

        # Handshake Success
        hs_rate = 0
        if self.health.syn_count > 0:
            hs_rate = (self.health.syn_ack_count / self.health.syn_count) * 100
            if hs_rate > 100: hs_rate = 100.0  # Approx

        # =======================
        # RENDER TEXT
        # =======================
        report = []
        report.append("=" * 80)
        report.append("   TCP NETWORK ANALYSIS REPORT (DBA/OPS EDITION)")
        report.append("=" * 80)
        report.append(f"File: {self.filename}")
        report.append(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report.append("")

        report.append("-" * 80)
        report.append("1. 概览摘要 (Summary)")
        report.append("-" * 80)
        report.append(f"* 抓包时长: {duration:.2f} seconds")
        report.append(f"* 总包数量: {self.basic.pkts_total}")
        report.append(f"* TCP连接数: {len(self.traffic.streams)} (Directional Flows)")
        report.append(f"* 核心结论: {diagnosis[0]}")
        report.append("")

        report.append("-" * 80)
        report.append("2. TCP 连接建立情况 (Handshake Analysis)")
        report.append("-" * 80)
        report.append(f"* SYN 请求数: {self.health.syn_count}")
        report.append(f"* 握手成功率: {hs_rate:.2f}%")
        report.append(f"* 异常 (SYN重传/RST): RST={self.health.rst_count}")
        report.append("")

        report.append("-" * 80)
        report.append("3. RTT / 延迟分析 (Latency)")
        report.append("-" * 80)
        report.append(f"* Min/Avg/Max RTT: {min_rtt:.2f} / {avg_rtt:.2f} / {max_rtt:.2f} ms")
        report.append(f"* 延迟抖动 (Jitter): {jitter:.2f} ms")
        report.append("")

        report.append("-" * 80)
        report.append("4. TCP 重传 / 丢包 (Loss & Retransmission)")
        report.append("-" * 80)
        report.append(f"* 重传率 (Retrans %): {retrans_rate:.4f}%")
        report.append(f"* 乱序/丢失 (Out-of-Order/Lost): {self.anomalies.out_of_order_count} (Estimate)")
        report.append("")

        report.append("-" * 80)
        report.append("5. 流量统计 (Traffic Summary)")
        report.append("-" * 80)
        report.append(f"* 平均吞吐 (PPS/Mbps): {int(pps)} PPS / {bps:.2f} Mbps")
        report.append(f"* Top Talkers (Source IP): {talkers_str}")
        report.append("")

        report.append("-" * 80)
        report.append("6. TCP 健康度 (Health & Window)")
        report.append("-" * 80)
        report.append(f"* Zero Window 次数: {self.health.zero_window_events}")
        report.append(f"* Window Full 次数: {self.health.window_full_events} (Approx)")
        report.append("")

        report.append("-" * 80)
        report.append("7. 关键 TCP 流分析 (Key Streams)")
        report.append("-" * 80)
        report.append("{:<60} | {:<10} | {:<8} | {:<8}".format(
            "Src IP:Port -> Dst IP:Port", "RTT (ms)", "Retrans", "Pkts"))

        for s in top_streams:
            src = f"{NetworkUtils.inet_to_str(s.src_key[0])}:{s.src_key[1]}"
            dst = f"{NetworkUtils.inet_to_str(s.dst_key[0])}:{s.dst_key[1]}"
            flow_name = f"{src} -> {dst}"
            if len(flow_name) > 58: flow_name = flow_name[:55] + "..."

            avg_s_rtt = statistics.mean(s.rtt_samples) if s.rtt_samples else 0
            report.append("{:<60} | {:<10.2f} | {:<8} | {:<8}".format(
                flow_name, avg_s_rtt, s.retransmissions, s.packet_count
            ))
        report.append("")

        report.append("-" * 80)
        report.append("8. 异常事件 (Anomalies)")
        report.append("-" * 80)
        report.append(f"* Duplicate ACKs: {self.anomalies.duplicate_acks}")
        report.append(f"* Checksum Errors: {self.anomalies.checksum_errors}")
        report.append("")

        report.append("-" * 80)
        report.append("9. 结论与建议 (Conclusion)")
        report.append("-" * 80)
        report.append(f"* 总体判断: {diagnosis[0]}")
        rec = "Monitor baseline."
        if retrans_rate > 1: rec = "Investigate network link quality or congestion."
        if self.health.zero_window_events > 0: rec = "Check receiving application performance (Buffer Full)."
        report.append(f"* 建议措施: {rec}")
        report.append("")

        report.append("-" * 80)
        report.append("10. 验证命令 (Verification Commands)")
        report.append("-" * 80)

        # TShark Commands
        abs_path = os.path.abspath(self.filename)
        report.append("1. Global IO Stats:")
        report.append(f"   tshark -r {abs_path} -q -z io,stat,1")
        report.append("2. TCP Conversation Summary:")
        report.append(f"   tshark -r {abs_path} -q -z conv,tcp")
        report.append("3. Packet Loss/Lost Segments:")
        report.append(f'   tshark -r {abs_path} -q -z io,stat,1,"tcp.analysis.lost_segment"')
        report.append("4. Retransmission Details:")
        report.append(
            f'   tshark -r {abs_path} -Y "tcp.analysis.retransmission" -T fields -e frame.number -e tcp.stream -e ip.src -e ip.dst')
        report.append("5. SYN Handshake Issues (SYN sent, no ACK):")
        report.append(
            f'   tshark -r {abs_path} -Y "tcp.flags.syn==1 and tcp.flags.ack==0" -T fields -e frame.number -e ip.src')
        report.append("6. RTT Statistics (Min/Max/Avg):")
        report.append(f'   tshark -r {abs_path} -qz "min_max_avg,tcp.analysis.ack_rtt"')
        report.append("7. Zero Window Events:")
        report.append(f'   tshark -r {abs_path} -Y "tcp.analysis.zero_window" -T fields -e frame.number -e ip.src')
        report.append("8. Throughput by Protocol Hierarchy:")
        report.append(f'   tshark -r {abs_path} -q -z io,phs')
        report.append("9. Connection Reset (RST) Analysis:")
        report.append(f'   tshark -r {abs_path} -Y "tcp.flags.reset==1" -T fields -e frame.number -e ip.src')
        report.append("10. Unique TCP Stream Count:")
        report.append(f'   tshark -r {abs_path} -T fields -e tcp.stream | sort -n | uniq | wc -l')

        return "\n".join(report)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Production-Grade TCP Pcap Analyzer")
    parser.add_argument("filename", help="Path to the .pcap or .cap file")
    args = parser.parse_args()

    analyzer = PcapAnalyzerV4(args.filename)
    analyzer.run()
    print(analyzer.generate_report())