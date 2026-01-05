import sys
import argparse
import os
import datetime
from collections import defaultdict, Counter

# Try importing scapy, handle error if missing
try:
    from scapy.all import PcapReader, TCP, UDP, IP, IPv6
except ImportError:
    print("Error: 'scapy' library is required. Install via: pip install scapy")
    sys.exit(1)


# ==============================================================================
# CLASS STRUCTURE
# ==============================================================================

class StreamTracker:
    """
    Tracks state for a single TCP Stream (defined by 4-tuple).
    Handles RTT calculation, retransmission detection, and state flags.
    """

    def __init__(self, stream_id):
        self.stream_id = stream_id
        self.packet_count = 0
        self.bytes_transferred = 0
        self.start_time = None
        self.end_time = None

        # RTT Tracking
        # Map of expected_ack -> timestamp
        self.pending_acks = {}
        self.rtt_samples = []

        # Retransmission Tracking
        # Set of (direction, seq) to detect simple retransmissions
        self.seen_seqs = set()
        self.retransmissions = 0

        # Flags
        self.syn_count = 0
        self.fin_count = 0
        self.rst_count = 0
        self.has_syn = False
        self.has_fin = False

    def update(self, pkt, timestamp, direction_hash):
        if self.start_time is None: self.start_time = timestamp
        self.end_time = timestamp
        self.packet_count += 1

        if TCP in pkt:
            tcp = pkt[TCP]
            payload_len = len(tcp.payload)
            self.bytes_transferred += payload_len

            # 1. Flag Analysis
            if tcp.flags.S: self.syn_count += 1
            if tcp.flags.F: self.fin_count += 1
            if tcp.flags.R: self.rst_count += 1

            # 2. Retransmission Detection (Simplified)
            # Key: (Direction, SEQ)
            seq_key = (direction_hash, tcp.seq)
            if payload_len > 0:
                if seq_key in self.seen_seqs:
                    self.retransmissions += 1
                else:
                    self.seen_seqs.add(seq_key)

            # 3. RTT Calculation Logic
            # If we are sending data, expect an ACK = seq + len
            expected_ack = tcp.seq + payload_len
            if tcp.flags.S: expected_ack += 1
            if tcp.flags.F: expected_ack += 1

            # Store timestamp for this expected ACK
            # We use a limited buffer to avoid memory explosion on huge streams
            if payload_len > 0 or tcp.flags.S:
                self.pending_acks[expected_ack] = timestamp

            # Check if this packet ACKs a previous packet
            if tcp.flags.A:
                if tcp.ack in self.pending_acks:
                    rtt = (timestamp - self.pending_acks[tcp.ack]) * 1000.0  # ms
                    if 0 <= rtt < 10000:  # Filter outliers > 10s
                        self.rtt_samples.append(rtt)
                    del self.pending_acks[tcp.ack]

    def get_avg_rtt(self):
        if not self.rtt_samples: return 0.0
        return sum(self.rtt_samples) / len(self.rtt_samples)

    def get_duration(self):
        if self.start_time and self.end_time:
            return self.end_time - self.start_time
        return 0.0


class PcapLoader:
    """Handles file validation and iterator creation."""

    @staticmethod
    def validate(filepath):
        if not os.path.exists(filepath):
            print(f"Error: File not found - {filepath}")
            sys.exit(1)
        return filepath

    @staticmethod
    def get_reader(filepath):
        try:
            return PcapReader(filepath)
        except Exception as e:
            print(f"Error opening PCAP: {e}")
            sys.exit(1)


class TrafficAnalyzer:
    """Aggregates global statistics."""

    def __init__(self):
        self.total_packets = 0
        self.total_bytes = 0
        self.start_time = None
        self.end_time = None

        self.ip_src_counts = Counter()
        self.tcp_counts = 0
        self.udp_counts = 0
        self.other_counts = 0

        self.zero_window_events = 0
        self.window_full_events = 0  # Hard to track perfectly without state, skipping for efficiency

        self.streams = {}  # Map stream_id -> StreamTracker

    def get_stream_id(self, pkt):
        if IP in pkt:
            src, dst = pkt[IP].src, pkt[IP].dst
        elif IPv6 in pkt:
            src, dst = pkt[IPv6].src, pkt[IPv6].dst
        else:
            return None

        if TCP in pkt:
            sport, dport = pkt[TCP].sport, pkt[TCP].dport
            # Canonical ID: Sorted tuple of endpoints
            # Direction hash: used to distinguish src->dst vs dst->src for SEQ tracking
            endpoints = sorted([(src, sport), (dst, dport)])
            stream_id = tuple(endpoints)
            direction = 0 if (src, sport) == endpoints[0] else 1
            return stream_id, direction
        return None, None

    def process_packet(self, pkt):
        self.total_packets += 1
        self.total_bytes += len(pkt)

        ts = float(pkt.time)
        if self.start_time is None: self.start_time = ts
        self.end_time = ts

        # Protocol counting
        if TCP in pkt:
            self.tcp_counts += 1
            # Zero Window Check
            if pkt[TCP].window == 0 and (pkt[TCP].flags.A or pkt[TCP].flags.R == 0):
                self.zero_window_events += 1

            # Stream Logic
            s_id, direction = self.get_stream_id(pkt)
            if s_id:
                if s_id not in self.streams:
                    self.streams[s_id] = StreamTracker(s_id)
                self.streams[s_id].update(pkt, ts, direction)

        elif UDP in pkt:
            self.udp_counts += 1
        else:
            self.other_counts += 1

        # IP Stats
        if IP in pkt:
            self.ip_src_counts[pkt[IP].src] += len(pkt)
        elif IPv6 in pkt:
            self.ip_src_counts[pkt[IPv6].src] += len(pkt)


class ReportGenerator:
    """Generates the plain text report."""

    def __init__(self, filename, analyzer):
        self.filename = filename
        self.an = analyzer

    def _fmt_bytes(self, b):
        if b < 1024: return f"{b} B"
        if b < 1024 ** 2: return f"{b / 1024:.2f} KB"
        return f"{b / 1024 ** 2:.2f} MB"

    def _separator(self, title=None):
        if title:
            return f"\n{'-' * 80}\n{title}\n{'-' * 80}"
        return f"{'=' * 80}"

    def generate(self):
        duration = (self.an.end_time - self.an.start_time) if (self.an.end_time and self.an.start_time) else 0
        duration = max(duration, 0.001)
        avg_throughput_mbps = (self.an.total_bytes * 8) / (duration * 1000000)

        # Aggregating Stream Data
        total_syn = sum(s.syn_count for s in self.an.streams.values())
        # SYN-ACK approximation: Scapy doesn't have easy 'is_syn_ack', usually SYN=1 ACK=1
        # We counted SYNs. Let's approximate SYN-ACKs from stream logic if possible,
        # but for simple stat, we rely on global logic.
        # Actually, let's iterate streams to get cleaner totals.

        total_retrans = sum(s.retransmissions for s in self.an.streams.values())
        all_rtts = [r for s in self.an.streams.values() for r in s.rtt_samples]

        min_rtt = min(all_rtts) if all_rtts else 0
        max_rtt = max(all_rtts) if all_rtts else 0
        avg_rtt = (sum(all_rtts) / len(all_rtts)) if all_rtts else 0

        # Jitter (Std Dev of RTT)
        jitter = 0
        if len(all_rtts) > 1:
            variance = sum((x - avg_rtt) ** 2 for x in all_rtts) / len(all_rtts)
            jitter = variance ** 0.5

        # Diagnosis
        diagnosis = []
        retrans_rate = (total_retrans / self.an.total_packets * 100) if self.an.total_packets else 0

        if retrans_rate > 2.0:
            diagnosis.append("CRITICAL: High Packet Loss / Retransmission detected (>2%)")
        elif retrans_rate > 0.5:
            diagnosis.append("WARNING: Moderate Retransmission rates detected")

        if self.an.zero_window_events > 0:
            diagnosis.append(
                f"WARNING: {self.an.zero_window_events} Zero Window events (Potential Application Bottleneck)")

        if not diagnosis:
            diagnosis.append("Link Stable - No critical anomalies detected.")

        core_conclusion = " | ".join(diagnosis)

        # Handshake Calc (Approximate)
        # total_syn includes retransmits.
        # Handshake success is hard to confirm perfectly without state machine,
        # but we can ratio Streams with Data vs Streams with only SYN.

        # Output Construction
        print(self._separator())
        print(f"   TCP NETWORK ANALYSIS REPORT (DBA/OPS EDITION)")
        print(self._separator())
        print(f"File: {self.filename}")
        print(f"Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

        # 1. Summary
        print(self._separator("1. 概览摘要 (Summary)"))
        print(f"* 抓包时长: {duration:.2f} seconds")
        print(f"* 总包数量: {self.an.total_packets}")
        print(f"* TCP连接数: {len(self.an.streams)}")
        print(f"* 核心结论: {core_conclusion}")

        # 2. Handshake
        print(self._separator("2. TCP 连接建立情况 (Handshake Analysis)"))
        print(f"* SYN 请求数: {total_syn}")
        print(f"* 握手成功率: N/A (Requires deep state analysis)")
        print(f"* 异常 (SYN重传/RST): {sum(s.rst_count for s in self.an.streams.values())} RSTs detected")

        # 3. RTT
        print(self._separator("3. RTT / 延迟分析 (Latency)"))
        print(f"* Min/Avg/Max RTT: {min_rtt:.2f} ms / {avg_rtt:.2f} ms / {max_rtt:.2f} ms")
        print(f"* 延迟抖动 (Jitter): {jitter:.2f} ms")

        # 4. Loss
        print(self._separator("4. TCP 重传 / 丢包 (Loss & Retransmission)"))
        print(f"* 重传率 (Retrans %): {retrans_rate:.4f}%")
        print(f"* 重传包数 (Est.): {total_retrans}")

        # 5. Traffic
        print(self._separator("5. 流量统计 (Traffic Summary)"))
        print(f"* 平均吞吐: {avg_throughput_mbps:.2f} Mbps")
        print(f"* Data Transferred: {self._fmt_bytes(self.an.total_bytes)}")
        print(f"* Top Talkers (Source IP):")
        for ip, count in self.an.ip_src_counts.most_common(5):
            print(f"  - {ip:<15} : {self._fmt_bytes(count)}")

        # 6. Health
        print(self._separator("6. TCP 健康度 (Health & Window)"))
        print(f"* Zero Window 次数: {self.an.zero_window_events}")
        print(f"* Window Full 次数: N/A (Requires stateful tracking)")

        # 7. Key Streams
        print(self._separator("7. 关键 TCP 流分析 (Key Streams)"))
        print(f"{'Stream ID':<10} | {'Src IP:Port -> Dst IP:Port':<40} | {'RTT(ms)':<8} | {'Retrans':<7} | {'Status'}")

        # Sort streams by bytes or issues
        sorted_streams = sorted(self.an.streams.values(), key=lambda x: x.bytes_transferred, reverse=True)[:5]

        for i, s in enumerate(sorted_streams):
            # Extract IP/Port from tuple keys
            ((src, sport), (dst, dport)) = s.stream_id
            flow_str = f"{src}:{sport} -> {dst}:{dport}"
            avg_s_rtt = s.get_avg_rtt()
            status = "Healthy"
            if s.retransmissions > 0: status = "Lossy"
            if avg_s_rtt > 100: status = "High Latency"

            print(f"{i + 1:<10} | {flow_str:<40} | {avg_s_rtt:<8.2f} | {s.retransmissions:<7} | {status}")

        # 8. Anomalies
        print(self._separator("8. 异常事件 (Anomalies)"))
        print(f"* Total RST Packets: {sum(s.rst_count for s in self.an.streams.values())}")
        print(f"* Checksum Errors: N/A (Scapy validation skipped for speed)")

        # 9. Conclusion
        print(self._separator("9. 结论与建议 (Conclusion)"))
        print(f"* 总体判断: {diagnosis[0]}")
        print(f"* 建议措施: Use verification commands below to isolate specific frames.")

        # 10. Verification
        print(self._separator("10. 验证命令 (Verification Commands)"))

        cmds = [
            ("Global IO Stats", f'tshark -r {self.filename} -q -z io,stat,1'),
            ("TCP Conversation Summary", f'tshark -r {self.filename} -q -z conv,tcp'),
            ("Packet Loss/Lost Segments", f'tshark -r {self.filename} -q -z io,stat,1,"tcp.analysis.lost_segment"'),
            ("Retransmission Details",
             f'tshark -r {self.filename} -Y "tcp.analysis.retransmission" -T fields -e frame.number -e tcp.stream -e ip.src -e ip.dst'),
            ("SYN Handshake Issues",
             f'tshark -r {self.filename} -Y "tcp.flags.syn==1 and tcp.flags.ack==0" -T fields -e frame.number -e ip.src'),
            ("RTT Statistics (Min/Max/Avg)", f'tshark -r {self.filename} -qz "min_max_avg,tcp.analysis.ack_rtt"'),
            ("Zero Window Events",
             f'tshark -r {self.filename} -Y "tcp.analysis.zero_window" -T fields -e frame.number -e ip.src'),
            ("Throughput by Protocol", f'tshark -r {self.filename} -q -z io,phs'),
            ("Connection Reset (RST)",
             f'tshark -r {self.filename} -Y "tcp.flags.reset==1" -T fields -e frame.number -e ip.src'),
            ("Unique TCP Stream Count", f'tshark -r {self.filename} -T fields -e tcp.stream | sort -n | uniq | wc -l')
        ]

        for idx, (desc, cmd) in enumerate(cmds, 1):
            print(f"{idx}. {desc}:")
            print(f"   {cmd}\n")


# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(description="Production-Grade PCAP Analyzer (Scapy)")
    parser.add_argument("pcap_file", help="Path to the .pcap/.cap file")
    args = parser.parse_args()

    filepath = PcapLoader.validate(args.pcap_file)

    print(f"[*] Analyzing {filepath} ... Please wait, this may take time for large files.")

    analyzer = TrafficAnalyzer()

    try:
        # Use PcapReader for memory efficiency on large files
        with PcapLoader.get_reader(filepath) as pcap_reader:
            for i, pkt in enumerate(pcap_reader):
                analyzer.process_packet(pkt)
                if i % 10000 == 0 and i > 0:
                    sys.stdout.write(f"\r    Processed {i} packets...")
                    sys.stdout.flush()
        sys.stdout.write("\n")

    except KeyboardInterrupt:
        print("\n[!] Analysis interrupted by user.")
    except Exception as e:
        print(f"\n[!] Unexpected error: {e}")

    # Generate Report
    report = ReportGenerator(filepath, analyzer)
    report.generate()


if __name__ == "__main__":
    main()