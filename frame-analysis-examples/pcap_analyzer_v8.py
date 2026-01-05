import dpkt
import socket
import argparse
import sys
import struct
from collections import defaultdict, Counter
from statistics import mean, stdev
import datetime


# ==========================================
# HELPER CLASSES & UTILS
# ==========================================

def inet_to_str(inet):
    """Convert inet object to a string based on address family."""
    try:
        return socket.inet_ntop(socket.AF_INET, inet)
    except ValueError:
        try:
            return socket.inet_ntop(socket.AF_INET6, inet)
        except ValueError:
            return "Unknown"


def safe_div(n, d, default=0.0):
    return n / d if d > 0 else default


class StreamMetrics:
    """Tracks metrics for a unidirectional stream of data within a TCP flow."""

    def __init__(self):
        self.packet_count = 0
        self.byte_count = 0
        self.payload_bytes = 0
        self.retransmissions = 0
        self.out_of_order = 0
        self.window_samples = []
        self.highest_seq = 0
        self.next_expected_seq = 0
        self.is_first_packet = True
        # RTT Tracking
        # Key: Expected ACK Number (Seq + Len), Value: Timestamp sent
        self.inflight_packets = {}

    def update(self, tcp_len, seq, ack, flags, payload_len, ts, win_size):
        self.packet_count += 1
        self.byte_count += tcp_len
        self.payload_bytes += payload_len
        self.window_samples.append(win_size)

        # Retransmission & Out-of-Order Logic
        if self.is_first_packet:
            self.highest_seq = seq
            self.next_expected_seq = seq + payload_len
            self.is_first_packet = False
        else:
            # If seq is lower than what we've already seen + len, it might be a retrans
            if seq < self.highest_seq:
                # Simplified heuristic: if we have seen this seq before
                self.retransmissions += 1
            elif seq > self.next_expected_seq:
                self.out_of_order += 1
                self.highest_seq = max(self.highest_seq, seq)
                self.next_expected_seq = max(self.next_expected_seq, seq + payload_len)
            else:
                # Normal order
                self.highest_seq = max(self.highest_seq, seq)
                self.next_expected_seq = max(self.next_expected_seq, seq + payload_len)


class TCPFlow:
    """Represents a bidirectional TCP connection."""

    def __init__(self, src_ip, src_port, dst_ip, dst_port, start_ts):
        self.src_ip = src_ip
        self.src_port = src_port
        self.dst_ip = dst_ip
        self.dst_port = dst_port
        self.start_ts = start_ts
        self.last_ts = start_ts

        # Connection State Flags
        self.syn_seen = False
        self.syn_ack_seen = False
        self.fin_count = 0
        self.rst_count = 0
        self.handshake_complete = False

        # Metrics
        self.rtt_samples = []
        self.zero_window_events = 0

        # Directional Streams
        # Forward: Src -> Dst
        self.fwd = StreamMetrics()
        # Backward: Dst -> Src
        self.bwd = StreamMetrics()

    def add_packet(self, ts, src_ip, seq, ack, flags, payload_len, win_size, total_len):
        self.last_ts = ts

        is_forward = (src_ip == self.src_ip)
        stream = self.fwd if is_forward else self.bwd
        other_stream = self.bwd if is_forward else self.fwd

        # 1. State Machine Updates
        if (flags & dpkt.tcp.TH_SYN):
            if (flags & dpkt.tcp.TH_ACK):
                self.syn_ack_seen = True
                # Calculate Handshake RTT if we saw the SYN
                if self.syn_seen and len(self.rtt_samples) == 0:
                    # Rough estimate: TS of SYN-ACK - TS of Flow Start (SYN)
                    # Note: This assumes Flow Start was the SYN
                    rtt = (ts - self.start_ts) * 1000.0  # to ms
                    if rtt > 0:
                        self.rtt_samples.append(rtt)
            else:
                self.syn_seen = True

        if (flags & dpkt.tcp.TH_FIN):
            self.fin_count += 1

        if (flags & dpkt.tcp.TH_RST):
            self.rst_count += 1

        if self.syn_seen and self.syn_ack_seen and not self.handshake_complete:
            # Technically need the 3rd ACK, but usually SYN+SYNACK implies connectivity
            self.handshake_complete = True

        # 2. RTT Calculation (Passive)
        # Logic: Match ACK in this packet to a previous packet in the other stream
        # If this packet is ACKing data sent by the other side
        if (flags & dpkt.tcp.TH_ACK):
            if ack in other_stream.inflight_packets:
                sent_ts = other_stream.inflight_packets.pop(ack)
                rtt = (ts - sent_ts) * 1000.0  # ms
                if rtt > 0 and rtt < 5000:  # Filter outliers > 5s
                    self.rtt_samples.append(rtt)

        # 3. Register this packet for future RTT calc (if it has payload)
        if payload_len > 0:
            expected_ack = seq + payload_len
            # Only track if not a retransmission
            if not (flags & dpkt.tcp.TH_RST) and not (flags & dpkt.tcp.TH_SYN):
                stream.inflight_packets[expected_ack] = ts

        # 4. Zero Window Check
        if win_size == 0 and not (flags & dpkt.tcp.TH_RST):
            self.zero_window_events += 1

        # 5. Update Stream Metrics
        stream.update(total_len, seq, ack, flags, payload_len, ts, win_size)


# ==========================================
# ANALYSIS ENGINES
# ==========================================

class BasicStatsAnalyzer:
    def __init__(self):
        self.total_packets = 0
        self.total_bytes = 0
        self.start_time = None
        self.end_time = None
        self.protocols = Counter()
        self.src_ip_volume = defaultdict(int)

    def update(self, ts, ip_pkt, ip_len):
        self.total_packets += 1
        self.total_bytes += ip_len
        if self.start_time is None: self.start_time = ts
        self.end_time = ts

        self.protocols[type(ip_pkt.data)] += 1

        s_ip = inet_to_str(ip_pkt.src)
        self.src_ip_volume[s_ip] += ip_len


class TCPAnalyzer:
    def __init__(self):
        # Key: tuple(sorted((src, sport), (dst, dport)))
        self.flows = {}
        # Global Counters
        self.syn_count = 0
        self.syn_ack_count = 0
        self.fin_count = 0
        self.rst_count = 0
        self.pure_acks = 0
        self.time_series = defaultdict(lambda: {'pkts': 0, 'bytes': 0})

    def get_flow_key(self, sip, sport, dip, dport):
        # Canonical key for bidirectional flow
        s = (sip, sport)
        d = (dip, dport)
        return tuple(sorted([s, d]))

    def process_packet(self, ts, ip, tcp):
        sip = ip.src
        dip = ip.dst
        sport = tcp.sport
        dport = tcp.dport

        key = self.get_flow_key(sip, sport, dip, dport)

        if key not in self.flows:
            self.flows[key] = TCPFlow(sip, sport, dip, dport, ts)

        flow = self.flows[key]
        payload_len = len(tcp.data)

        # Global TCP Flags Counting (Strict)
        if (tcp.flags & dpkt.tcp.TH_SYN) and not (tcp.flags & dpkt.tcp.TH_ACK):
            self.syn_count += 1
        if (tcp.flags & dpkt.tcp.TH_SYN) and (tcp.flags & dpkt.tcp.TH_ACK):
            self.syn_ack_count += 1
        if (tcp.flags & dpkt.tcp.TH_FIN):
            self.fin_count += 1
        if (tcp.flags & dpkt.tcp.TH_RST):
            self.rst_count += 1

        # Time Series bucket (integer second)
        sec = int(ts)
        self.time_series[sec]['pkts'] += 1
        self.time_series[sec]['bytes'] += len(ip)

        # Pass to flow logic
        flow.add_packet(ts, sip, tcp.seq, tcp.ack, tcp.flags, payload_len, tcp.win, len(ip))


class IOManager:
    @staticmethod
    def load_pcap(filepath):
        print(f"[*] Loading pcap: {filepath} ...")
        try:
            f = open(filepath, 'rb')
            pcap = dpkt.pcap.Reader(f)
            return pcap, f
        except Exception as e:
            print(f"[!] Error loading pcap: {e}")
            sys.exit(1)


# ==========================================
# REPORT GENERATOR
# ==========================================

class ReportGenerator:
    def __init__(self, stats, tcp_engine):
        self.stats = stats
        self.tcp = tcp_engine

    def generate(self):
        self.print_header("1. TRAFFIC SUMMARY & IO STATS")
        duration = (self.stats.end_time - self.stats.start_time) if self.stats.end_time else 0
        print(f"{'Total Packets':<25} : {self.stats.total_packets}")
        print(f"{'Total Data':<25} : {self.stats.total_bytes / (1024 * 1024):.2f} MB")
        print(f"{'Capture Duration':<25} : {duration:.2f} seconds")
        print(
            f"{'Average Throughput':<25} : {((self.stats.total_bytes * 8) / duration) / 1000000:.2f} Mbps" if duration > 0 else "0 Mbps")

        print("\n--- Top Talkers (Src IP by Volume) ---")
        # Sort by volume desc
        sorted_talkers = sorted(self.stats.src_ip_volume.items(), key=lambda x: x[1], reverse=True)[:5]
        for ip, vol in sorted_talkers:
            print(f"{ip:<20} : {vol / (1024 * 1024):.2f} MB")

        self.print_header("2. TCP HEALTH & CONNECTIVITY")
        print(f"{'Total TCP Flows':<25} : {len(self.tcp.flows)}")
        print(f"{'Total SYNs (Pure)':<25} : {self.tcp.syn_count}")
        print(f"{'Total SYN-ACKs':<25} : {self.tcp.syn_ack_count}")

        # Handshake Success Rate
        # Method 1: Ratio of SYN-ACK to SYN
        hs_ratio = safe_div(self.tcp.syn_ack_count, self.tcp.syn_count) * 100
        print(f"{'Handshake Success Rate':<25} : {hs_ratio:.2f}% (Approx based on SYN/SYN-ACK ratio)")

        print(f"{'Total Resets (RST)':<25} : {self.tcp.rst_count}")
        print(f"{'Total FINs':<25} : {self.tcp.fin_count}")

        # Aggregate Flow Health
        total_retrans = sum(f.fwd.retransmissions + f.bwd.retransmissions for f in self.tcp.flows.values())
        total_tcp_bytes = sum(f.fwd.byte_count + f.bwd.byte_count for f in self.tcp.flows.values())
        retrans_rate = safe_div(total_retrans, self.stats.total_packets) * 100

        print(f"{'Global Retransmissions':<25} : {total_retrans} pkts ({retrans_rate:.2f}% of all pkts)")

        self.print_header("3. PERFORMANCE METRICS (LATENCY & WINDOW)")

        # RTT Stats
        all_rtts = []
        for f in self.tcp.flows.values():
            all_rtts.extend(f.rtt_samples)

        if all_rtts:
            print(f"{'RTT Samples':<25} : {len(all_rtts)}")
            print(f"{'Min RTT':<25} : {min(all_rtts):.2f} ms")
            print(f"{'Avg RTT':<25} : {mean(all_rtts):.2f} ms")
            print(f"{'Max RTT':<25} : {max(all_rtts):.2f} ms")
            if len(all_rtts) > 1:
                print(f"{'Jitter (Stdev)':<25} : {stdev(all_rtts):.2f} ms")
        else:
            print("No valid RTT samples found (lack of handshake or data/ack pairs).")

        # Window Stats
        zero_wins = sum(f.zero_window_events for f in self.tcp.flows.values())
        print(f"{'Zero Window Events':<25} : {zero_wins} (Indicates receiver buffer exhaustion)")

        self.print_header("4. ANOMALY DIAGNOSIS & CONCLUSIONS")
        self.run_diagnosis(retrans_rate, zero_wins, hs_ratio)

    def print_header(self, title):
        print("=" * 60)
        print(f" {title}")
        print("=" * 60)

    def run_diagnosis(self, retrans_rate, zero_wins, hs_ratio):
        issues = []

        if retrans_rate > 2.0:
            issues.append(
                f"[CRITICAL] High Retransmission Rate ({retrans_rate:.2f}%). Network congestion or packet loss detected.")
        elif retrans_rate > 0.5:
            issues.append(f"[WARNING] Moderate Retransmission Rate ({retrans_rate:.2f}%).")

        if zero_wins > 5:
            issues.append(f"[CRITICAL] Frequent Zero Window events ({zero_wins}). Receivers are overwhelmed.")

        if hs_ratio < 80.0 and self.tcp.syn_count > 10:
            issues.append(
                f"[WARNING] Low Handshake Success Rate ({hs_ratio:.2f}%). Possible port scanning or firewall drops.")

        if not issues:
            print("[PASS] No critical anomalies detected based on thresholds.")
        else:
            for i in issues:
                print(i)


# ==========================================
# MAIN EXECUTOR
# ==========================================

def main():
    parser = argparse.ArgumentParser(description="Expert TCP/PCAP Analysis Tool")
    parser.add_argument("pcap_file", help="Path to the .pcap file")
    args = parser.parse_args()

    pcap, f_obj = IOManager.load_pcap(args.pcap_file)

    # Init Engines
    stats_engine = BasicStatsAnalyzer()
    tcp_engine = TCPAnalyzer()

    packet_count = 0

    for ts, buf in pcap:
        packet_count += 1
        try:
            eth = dpkt.ethernet.Ethernet(buf)
        except Exception:
            continue

        # Handle IP
        if isinstance(eth.data, dpkt.ip.IP):
            ip = eth.data
            stats_engine.update(ts, ip, len(eth.data))

            # Handle TCP
            if isinstance(ip.data, dpkt.tcp.TCP):
                tcp_engine.process_packet(ts, ip, ip.data)

    f_obj.close()

    # Generate Report
    reporter = ReportGenerator(stats_engine, tcp_engine)
    reporter.generate()


if __name__ == "__main__":
    main()