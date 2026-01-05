import dpkt
import socket
import argparse
import sys
import struct
import math
from collections import defaultdict, Counter
from datetime import datetime
import statistics


# ==========================================
# CONSTANTS & HELPERS
# ==========================================

def inet_to_str(inet):
    """Convert inet object to a string."""
    try:
        return socket.inet_ntop(socket.AF_INET, inet)
    except ValueError:
        return socket.inet_ntop(socket.AF_INET6, inet)


def safe_div(n, d, default=0.0):
    return n / d if d != 0 else default


# ==========================================
# CLASS: TCP Flow State
# ==========================================
class TCPFlow:
    """
    Represents a bidirectional TCP connection.
    Stores state for analysis: Seq tracking, Window scaling, RTT.
    """

    def __init__(self, key):
        self.key = key  # (src_ip, src_port, dst_ip, dst_port)
        self.packets_count = 0
        self.bytes_count = 0
        self.start_ts = None
        self.end_ts = None

        # Handshake State
        self.syn_count = 0
        self.syn_ack_count = 0
        self.fin_count = 0
        self.rst_count = 0
        self.handshake_complete = False

        # RTT Tracking (Combined Handshake and Continuous RTT)
        self.syn_ts = None
        self.syn_ack_ts = None
        self.first_ack_ts = None
        self.rtt_samples = []

        # RTT Tracking for continuous RTT
        # Key: Next Expected Seq Number -> Timestamp (of last byte sent)
        # Dir 0: Forward (A->B), Dir 1: Reverse (B->A)
        self.sent_seqs = {0: {}, 1: {}}

        # Retransmission & Quality Logic (Directional)
        # Dir 0: Forward (key[0] -> key[2]), Dir 1: Reverse
        self.max_seq = {0: 0, 1: 0}
        self.retransmissions = 0
        self.zero_windows = 0
        self.window_sizes = []

        # Payload
        self.payload_bytes = 0

    @property
    def duration(self):
        if self.start_ts and self.end_ts:
            return self.end_ts - self.start_ts
        return 0.0

    def add_rtt_sample(self, rtt):
        if rtt > 0:
            self.rtt_samples.append(rtt)

    def check_retransmission(self, direction, seq, payload_len):
        """
        Simple single-pass retransmission detection.
        If SEQ < Max_SEQ_Seen and Payload > 0, it's a retransmission.
        """
        if payload_len == 0:
            return

        if seq < self.max_seq[direction]:
            self.retransmissions += 1
        else:
            self.max_seq[direction] = seq + payload_len


# ==========================================
# CLASS: Metric Analyzer Modules
# ==========================================

class TimeSeriesAnalyzer:
    def __init__(self):
        self.io_buckets = defaultdict(lambda: {'packets': 0, 'bytes': 0, 'retrans': 0})
        self.start_time = None
        self.end_time = None

    def update(self, ts, pkt_len, is_retrans=False):
        if self.start_time is None or ts < self.start_time: self.start_time = ts
        if self.end_time is None or ts > self.end_time: self.end_time = ts

        sec = int(ts)
        self.io_buckets[sec]['packets'] += 1
        self.io_buckets[sec]['bytes'] += pkt_len
        if is_retrans:
            self.io_buckets[sec]['retrans'] += 1


class StatsAnalyzer:
    def __init__(self):
        self.total_packets = 0
        self.total_bytes = 0
        self.malformed = 0
        self.ipv4_count = 0
        self.ipv6_count = 0
        self.tcp_count = 0
        self.udp_count = 0
        self.other_count = 0


# ==========================================
# CLASS: Core Processor
# ==========================================

class PCAPAnalyzer:
    def __init__(self, filename):
        self.filename = filename
        self.stats = StatsAnalyzer()
        self.time_series = TimeSeriesAnalyzer()
        self.flows = {}  # Key: Canonical Tuple -> TCPFlow
        self.ip_byte_counts = defaultdict(int)

        # Global Counters for Executive Summary
        self.global_syn = 0
        self.global_syn_ack = 0
        self.global_fin = 0
        self.global_rst = 0
        self.global_window_full = 0
        self.global_zero_window = 0

    def _get_flow_key(self, ip_src, port_src, ip_dst, port_dst):
        """
        Returns a canonical key for the connection and the direction (0 or 1).
        Canonical key sorts IPs/Ports to ensure A->B and B->A map to same flow object.
        """
        endpoint_a = (ip_src, port_src)
        endpoint_b = (ip_dst, port_dst)

        if endpoint_a < endpoint_b:
            return (endpoint_a, endpoint_b), 0
        else:
            return (endpoint_b, endpoint_a), 1

    def process(self):
        try:
            f = open(self.filename, 'rb')
            pcap = dpkt.pcap.Reader(f)
        except Exception as e:
            print(f"[!] Error opening file: {e}")
            sys.exit(1)

        print(f"[*] Analyzing {self.filename} ...")

        for ts, buf in pcap:
            self.stats.total_packets += 1
            self.stats.total_bytes += len(buf)

            # 1. Ethernet Parsing
            try:
                eth = dpkt.ethernet.Ethernet(buf)
            except:
                self.stats.malformed += 1
                continue

            # 2. IP Parsing
            ip_pkt = eth.data
            if isinstance(ip_pkt, dpkt.ip.IP):
                self.stats.ipv4_count += 1
            elif isinstance(ip_pkt, dpkt.ip6.IP6):
                self.stats.ipv6_count += 1
            else:
                self.stats.other_count += 1
                continue

            # 3. TCP Analysis
            if isinstance(ip_pkt.data, dpkt.tcp.TCP):
                self.stats.tcp_count += 1
                self._analyze_tcp(ts, ip_pkt, ip_pkt.data)
            elif isinstance(ip_pkt.data, dpkt.udp.UDP):
                self.stats.udp_count += 1
            else:
                self.stats.other_count += 1

        f.close()

    def _analyze_tcp(self, ts, ip, tcp):
        # Extract Addresses
        src_ip = inet_to_str(ip.src)
        dst_ip = inet_to_str(ip.dst)

        # Track byte counts per original source IP
        self.ip_byte_counts[src_ip] += len(ip)

        key, direction = self._get_flow_key(src_ip, tcp.sport, dst_ip, tcp.dport)

        # Create Flow if not exists
        if key not in self.flows:
            self.flows[key] = TCPFlow(key)

        flow = self.flows[key]

        # Basic Stats
        flow.packets_count += 1
        flow.bytes_count += len(ip)
        if not flow.start_ts: flow.start_ts = ts
        flow.end_ts = ts

        payload_len = len(tcp.data)
        flow.payload_bytes += payload_len

        # Flags Extraction
        flags = tcp.flags
        is_syn = (flags & dpkt.tcp.TH_SYN) != 0
        is_ack = (flags & dpkt.tcp.TH_ACK) != 0
        is_fin = (flags & dpkt.tcp.TH_FIN) != 0
        is_rst = (flags & dpkt.tcp.TH_RST) != 0

        # --- Handshake RTT Logic ---

        if is_syn and is_ack:
            self.global_syn_ack += 1
            flow.syn_ack_count += 1
            flow.syn_ack_ts = ts
            if flow.syn_ts:
                rtt = (ts - flow.syn_ts) * 1000.0
                flow.add_rtt_sample(rtt)
        elif is_syn:
            self.global_syn += 1
            flow.syn_count += 1
            if not flow.syn_ts:
                flow.syn_ts = ts

        if is_fin:
            self.global_fin += 1
            flow.fin_count += 1
        if is_rst:
            self.global_rst += 1
            flow.rst_count += 1

        if is_ack and not is_syn and flow.syn_ack_ts and ts > flow.syn_ack_ts:
            if not flow.handshake_complete:
                flow.handshake_complete = True
                rtt = (ts - flow.syn_ack_ts) * 1000.0
                flow.add_rtt_sample(rtt)

        # 2. Window Analysis
        flow.window_sizes.append(tcp.win)
        if tcp.win == 0:
            self.global_zero_window += 1
            flow.zero_windows += 1

        # 3. Retransmission Detection
        prev_retrans = flow.retransmissions
        flow.check_retransmission(direction, tcp.seq, payload_len)
        is_retransmission = (flow.retransmissions > prev_retrans)

        # --- Continuous RTT Tracking Logic (DYNAMIC CALCULATION) ---
        opposite_direction = 1 if direction == 0 else 0

        # A. Store Sent Data Time (Key: Next Expected Seq Number)
        if payload_len > 0 or (is_syn and not is_ack) or is_fin:
            next_seq = tcp.seq + payload_len

            if is_syn and not is_ack: next_seq += 1
            if is_fin: next_seq += 1

            flow.sent_seqs[direction][next_seq] = ts

        # B. Check for Incoming ACK that completes the RTT measurement
        if is_ack and tcp.ack > 0:
            ack_num = tcp.ack

            # Find RTT from exact ACK
            if ack_num in flow.sent_seqs[opposite_direction]:
                sent_ts = flow.sent_seqs[opposite_direction][ack_num]
                rtt = (ts - sent_ts) * 1000.0

                if rtt > 0:
                    flow.add_rtt_sample(rtt)
                    del flow.sent_seqs[opposite_direction][ack_num]

            # Clean up: Remove any older, fully-acknowledged segments
            keys_to_delete = [
                seq_num for seq_num in flow.sent_seqs[opposite_direction]
                if seq_num < ack_num
            ]
            for seq_num in keys_to_delete:
                del flow.sent_seqs[opposite_direction][seq_num]

        # 4. Time Series Update
        self.time_series.update(ts, len(ip), is_retransmission)


# ==========================================
# CLASS: Reporter
# ==========================================

class ReportGenerator:
    def __init__(self, analyzer):
        self.an = analyzer
        self.flows = analyzer.flows.values()

    def print_report(self):
        # Calculate duration and avg_mbps once
        duration = 0
        if self.an.time_series.end_time and self.an.time_series.start_time:
            duration = self.an.time_series.end_time - self.an.time_series.start_time

        total_mb = self.an.stats.total_bytes / (1024 * 1024)
        avg_mbps = (self.an.stats.total_bytes * 8) / (duration * 1_000_000) if duration > 0 else 0

        # --- Section 1 ---
        self._print_header("1. EXECUTIVE SUMMARY")

        print(f"{'Total Packets':<25}: {self.an.stats.total_packets:,}")
        print(f"{'Duration':<25}: {duration:.2f} seconds")
        print(f"{'Total Data':<25}: {total_mb:.2f} MB")
        print(f"{'Avg Throughput':<25}: {avg_mbps:.2f} Mbps")
        print(f"{'Total TCP Flows':<25}: {len(self.an.flows)}")

        # --- Section 2 (Traffic Summary) ---
        self._print_header("2. TRAFFIC SUMMARY")

        # PPS Calculation (Only show PPS here, not Mbps)
        avg_pps = safe_div(self.an.stats.total_packets, duration)

        # MODIFIED: Updated label to include full PPS name and removed Mbps repetition
        print(f"{'Avg PPS (Packets Per Second)':<40}: {avg_pps:.2f} ")

        # Top Talkers (Source IP)
        sorted_ips = sorted(self.an.ip_byte_counts.items(), key=lambda item: item[1], reverse=True)[:3]

        print(f"{'Top Talkers (Source IP)':<40}:")
        # MODIFIED: Print each IP on a new line
        for ip, bytes_count in sorted_ips:
            mb = bytes_count / (1024 * 1024)
            print(f"  - {ip:<20} ({mb:.2f} MB)")

        # --- Section 3 (Traffic Overview) ---
        self._print_header("3. TRAFFIC OVERVIEW")
        print(
            f"{'TCP Packets':<25}: {self.an.stats.tcp_count} ({safe_div(self.an.stats.tcp_count, self.an.stats.total_packets) * 100:.1f}%)")

        if self.an.stats.udp_count > 0:
            print(f"{'UDP Packets':<25}: {self.an.stats.udp_count}")

        print(f"{'IPv4':<25}: {self.an.stats.ipv4_count}")
        print(f"{'IPv6':<25}: {self.an.stats.ipv6_count}")

        # --- Section 4 (TCP Health) ---
        self._print_header("4. TCP HEALTH & CONNECTIVITY")
        print(f"{'Total SYNs (Pure)':<25}: {self.an.global_syn}")
        print(f"{'Total SYN-ACKs':<25}: {self.an.global_syn_ack}")

        hs_rate = safe_div(self.an.global_syn_ack, self.an.global_syn) * 100
        print(f"{'Handshake Success Rate':<25}: {hs_rate:.2f}% (Approx based on SYN/SYN-ACK ratio)")
        print(f"{'Total Resets (RST)':<25}: {self.an.global_rst}")
        print(f"{'Total FINs':<25}: {self.an.global_fin}")

        # --- Section 5 (Performance Metrics) ---
        self._print_header("5. PERFORMANCE METRICS (LATENCY & WINDOW)")

        all_rtts = []
        for f in self.flows:
            all_rtts.extend(f.rtt_samples)

        if all_rtts:
            # DYNAMIC CALCULATION: Using Continuous RTT samples
            stdev_rtt = statistics.stdev(all_rtts) if len(all_rtts) > 1 else 0.0
            avg_rtt = sum(all_rtts) / len(all_rtts)

            print(f"{'RTT Samples':<25}: {len(all_rtts):,}")
            print(f"{'Min RTT':<25}: {min(all_rtts):.2f} ms")
            print(f"{'Avg RTT':<25}: {avg_rtt:.2f} ms")
            print(f"{'Max RTT':<25}: {max(all_rtts):.2f} ms")
            print(f"{'StDev (Jitter)':<25}: {stdev_rtt:.2f} ms")
        else:
            print("No RTT samples calculated (requires handshake and data-ack capture).")

        # --- Section 6 (Anomalies) ---
        self._print_header("6. ANOMALIES & ERRORS")
        total_retrans = sum(f.retransmissions for f in self.flows)
        retrans_rate = safe_div(total_retrans, self.an.stats.tcp_count) * 100

        print(f"{'TCP Retransmissions':<25}: {total_retrans}")
        print(f"{'Retransmission Rate':<25}: {retrans_rate:.4f}%")
        print(f"{'Zero Window Events':<25}: {self.an.global_zero_window}")

        # --- Section 7 (Auto-Diagnosis) ---
        self._print_header("7. AUTO-DIAGNOSIS / RCA")
        issues = []
        if retrans_rate > 2.0: issues.append(
            f"[CRITICAL] High Retransmission Rate ({retrans_rate:.2f}%). Check for packet loss or congestion.")
        if self.an.global_zero_window > 0: issues.append(
            f"[WARNING] Zero Window events detected ({self.an.global_zero_window}). Receivers are overwhelmed.")
        if hs_rate < 80.0 and self.an.global_syn > 10: issues.append(
            f"[WARNING] Low Handshake Success Rate ({hs_rate:.2f}%). Possible port scan or firewall drops.")
        if self.an.global_rst > self.an.global_fin: issues.append(
            "[NOTICE] High RST count relative to FIN. Connections are being forcibly closed.")

        if not issues:
            print("No critical anomalies detected based on static thresholds.")
        else:
            for i in issues:
                print(i)

        # --- Section 8 (Top Talkers & Streams) ---
        self._print_header("8. TOP TALKERS & STREAMS")
        sorted_flows = sorted(self.flows, key=lambda x: x.bytes_count, reverse=True)[:5]
        print(f"{'Source IP':<16} {'Dest IP':<16} {'Port':<6} {'Bytes (KB)':<12} {'Retrans':<8} {'Duration(s)':<10}")
        print("-" * 80)
        for f in sorted_flows:
            s_ip = f.key[0][0]
            d_ip = f.key[1][0]
            dport = f.key[1][1]
            kb = f.bytes_count / 1024
            print(f"{s_ip:<16} {d_ip:<16} {dport:<6} {kb:<12.1f} {f.retransmissions:<8} {f.duration:<10.2f}")

        # --- Section 9 (Time Series) ---
        self._print_header("9. TIME SERIES SPIKES (Top 3 Seconds)")
        sorted_io = sorted(self.an.time_series.io_buckets.items(), key=lambda x: x[1]['bytes'], reverse=True)[:3]
        for sec, data in sorted_io:
            mbps = (data['bytes'] * 8) / 1_000_000
            t_str = datetime.fromtimestamp(sec).strftime('%H:%M:%S')
            print(f"[{t_str}] Traffic: {mbps:.2f} Mbps | Pkts: {data['packets']} | Retrans: {data['retrans']}")

    def _print_header(self, title):
        print("\n" + "=" * 60)
        print(f" {title}")
        print("=" * 60)


# ==========================================
# MAIN ENTRY POINT
# ==========================================

def main():
    parser = argparse.ArgumentParser(description="Expert TCP Forensics Tool (dpkt)")
    parser.add_argument("pcap_file", help="Path to the .pcap/.cap file")
    args = parser.parse_args()

    analyzer = PCAPAnalyzer(args.pcap_file)
    analyzer.process()

    report = ReportGenerator(analyzer)
    report.print_report()


if __name__ == "__main__":
    main()