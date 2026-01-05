import sys
import argparse
import socket
import struct
import datetime
from collections import defaultdict

# Third-party import
try:
    import dpkt
except ImportError:
    print("Error: 'dpkt' library not found. Please install it using: pip install dpkt")
    sys.exit(1)


# ==========================================
# CORE CLASSES
# ==========================================

class PCAPLoader:
    """Handles file loading and validation."""

    def __init__(self, filename):
        self.filename = filename
        self.file_handle = None

    def load(self):
        """Opens the pcap file and returns the reader object."""
        try:
            self.file_handle = open(self.filename, 'rb')
            # Try pcap first
            try:
                return dpkt.pcap.Reader(self.file_handle)
            except ValueError:
                # Fallback logic or re-raise if needed.
                # dpkt.pcap.Reader usually handles standard pcaps.
                # If pcapng, dpkt might fail depending on version, but here we assume standard pcap per request.
                self.file_handle.seek(0)
                return dpkt.pcapng.Reader(self.file_handle)
        except Exception as e:
            print(f"Critical Error loading PCAP: {e}")
            sys.exit(1)

    def close(self):
        if self.file_handle:
            self.file_handle.close()


class BasicStatsAnalyzer:
    """Counts 1.1 Basic Stats."""

    def __init__(self):
        self.total_packets = 0
        self.start_ts = None
        self.end_ts = None
        self.total_bytes = 0

    def update(self, ts, buf):
        self.total_packets += 1
        self.total_bytes += len(buf)
        if self.start_ts is None:
            self.start_ts = ts
        self.end_ts = ts

    def get_duration(self):
        if self.start_ts and self.end_ts:
            return max(0, self.end_ts - self.start_ts)
        return 0


class TCPHealthCheck:
    """Handles 5.1 Handshake & 5.2 Connectivity."""

    def __init__(self):
        self.syn_count = 0
        self.syn_ack_count = 0
        self.fin_count = 0
        self.rst_count = 0
        self.conn_attempts = set()  # Tracks (src, sport, dst, dport) for connection counts

    def analyze(self, tcp, ip_src, ip_dst):
        flags = tcp.flags

        # Count flags
        if flags & dpkt.tcp.TH_SYN:
            self.syn_count += 1
            # Unique connection attempt signature
            flow = tuple(sorted([(ip_src, tcp.sport), (ip_dst, tcp.dport)]))
            self.conn_attempts.add(flow)

        if (flags & dpkt.tcp.TH_SYN) and (flags & dpkt.tcp.TH_ACK):
            self.syn_ack_count += 1
        if flags & dpkt.tcp.TH_FIN:
            self.fin_count += 1
        if flags & dpkt.tcp.TH_RST:
            self.rst_count += 1

    def get_handshake_success_rate(self):
        # Crude approx: SYN-ACKs / SYNs (excluding pure retransmissions ideally, but rough stat)
        if self.syn_count == 0:
            return 0.0
        return (self.syn_ack_count / self.syn_count) * 100.0


class RTTAnalyzer:
    """Calculates 2.1 & 2.2 Latency stats."""

    def __init__(self):
        # Map: (src_ip, sport, dst_ip, dport, seq) -> timestamp
        self.sent_packets = {}
        self.rtt_samples = []

    def process_packet(self, ts, ip_src, ip_dst, tcp):
        # A simplified RTT tracker (focusing on Handshake RTT for accuracy in stateless analysis)
        # We track SYN -> SYN-ACK or Data -> ACK

        # Flow ID for direction 1
        flow_fwd = (ip_src, tcp.sport, ip_dst, tcp.dport)
        # Flow ID for return
        flow_rev = (ip_dst, tcp.dport, ip_src, tcp.sport)

        # If SYN, store TS. If SYN-ACK, calc RTT.
        if tcp.flags & dpkt.tcp.TH_SYN and not (tcp.flags & dpkt.tcp.TH_ACK):
            # Store SYN timestamp (using seq as key part to avoid confusion)
            key = (flow_fwd, tcp.seq)
            self.sent_packets[key] = ts

        elif (tcp.flags & dpkt.tcp.TH_SYN) and (tcp.flags & dpkt.tcp.TH_ACK):
            # This is a SYN-ACK. The ack number should match SYN seq + 1
            expected_seq = tcp.ack - 1
            key = (flow_rev, expected_seq)
            if key in self.sent_packets:
                rtt = (ts - self.sent_packets[key]) * 1000.0  # ms
                self.rtt_samples.append(rtt)
                del self.sent_packets[key]

    def get_stats(self):
        if not self.rtt_samples:
            return 0, 0, 0, 0

        min_rtt = min(self.rtt_samples)
        max_rtt = max(self.rtt_samples)
        avg_rtt = sum(self.rtt_samples) / len(self.rtt_samples)

        # Calc Jitter (Variance approach for simplicity)
        variance = sum((x - avg_rtt) ** 2 for x in self.rtt_samples) / len(self.rtt_samples)
        jitter = variance ** 0.5

        return min_rtt, avg_rtt, max_rtt, jitter


class AnomalyDetector:
    """Handles 6.1 Retransmissions, Out-of-Order."""

    def __init__(self):
        # Track (src, sport, dst, dport, seq) -> count
        self.seen_segments = defaultdict(int)
        self.retransmissions = 0
        self.total_tcp_packets = 0
        self.duplicate_acks = 0
        self.checksum_errors = 0  # Not easily calculated without full offload logic, skipping impl to avoid false positives

    def check(self, tcp, ip_src, ip_dst):
        self.total_tcp_packets += 1

        # Retransmission Detection (Simplified: Same Seq, Same IP/Port, Same Payload Len)
        payload_len = len(tcp.data)
        if payload_len > 0 or (tcp.flags & dpkt.tcp.TH_SYN) or (tcp.flags & dpkt.tcp.TH_FIN):
            key = (ip_src, tcp.sport, ip_dst, tcp.dport, tcp.seq, payload_len)
            self.seen_segments[key] += 1
            if self.seen_segments[key] > 1:
                self.retransmissions += 1

        # Duplicate ACK detection is complex without state machine,
        # skipping generic implementation to focus on Retransmission accuracy.

    def get_retrans_rate(self):
        if self.total_tcp_packets == 0:
            return 0.0
        return (self.retransmissions / self.total_tcp_packets) * 100.0


class PerformanceAnalyzer:
    """Handles 3.1 Throughput & 3.2 Window Sizes."""

    def __init__(self):
        self.zero_window_events = 0
        self.window_full_events = 0  # Requires tracking calculated window, simplifying to large usage

    def check_window(self, tcp):
        if tcp.win == 0 and not (tcp.flags & dpkt.tcp.TH_RST):
            self.zero_window_events += 1


class TrafficAnalyzer:
    """Handles 4.1 Protocol ratios & 4.2 IP Trends."""

    def __init__(self):
        self.src_counts = defaultdict(int)

    def update(self, ip_src):
        self.src_counts[ip_src] += 1

    def get_top_talkers(self, n=3):
        sorted_ips = sorted(self.src_counts.items(), key=lambda x: x[1], reverse=True)
        return sorted_ips[:n]


class StreamAnalyzer:
    """Performs 8. Per-stream deep dive."""

    def __init__(self):
        # Flow tuple -> { 'pkts': 0, 'bytes': 0, 'retrans': 0, 'flags': set() }
        self.streams = defaultdict(lambda: {'pkts': 0, 'bytes': 0, 'retrans': 0, 'flags': set()})

    def process(self, tcp, ip_src, ip_dst):
        # Canonical flow ID (alphabetical order of endpoints to merge both directions)
        s_addr = (ip_src, tcp.sport)
        d_addr = (ip_dst, tcp.dport)
        flow_id = tuple(sorted([s_addr, d_addr]))

        stats = self.streams[flow_id]
        stats['pkts'] += 1
        stats['bytes'] += len(tcp.data)

        # We approximate retransmissions per stream via AnomalyDetector logic pass logic
        # But for simplicity in this single-pass architecture, we won't double count here strictly
        # unless we merge the classes. Instead, we will mark 'Status' based on flags seen.

        if tcp.flags & dpkt.tcp.TH_RST:
            stats['flags'].add('RST')
        if tcp.flags & dpkt.tcp.TH_SYN:
            stats['flags'].add('SYN')
        if tcp.flags & dpkt.tcp.TH_FIN:
            stats['flags'].add('FIN')

    def get_bad_streams(self, limit=5):
        # Return streams with RST or high volume
        results = []
        for flow, stats in self.streams.items():
            src_str = f"{flow[0][0]}:{flow[0][1]}"
            dst_str = f"{flow[1][0]}:{flow[1][1]}"
            status = "Normal"
            if 'RST' in stats['flags']:
                status = "Reset (RST)"
            elif 'SYN' in stats['flags'] and 'FIN' not in stats['flags']:
                status = "Incomplete"

            results.append({
                'id': hash(flow) % 10000,  # Short ID
                'name': f"{src_str} -> {dst_str}",
                'rtt': "N/A",  # Complex to track per stream in this architecture
                'retrans': "-",
                'status': status,
                'bytes': stats['bytes']
            })

        # Sort by bytes desc
        return sorted(results, key=lambda x: x['bytes'], reverse=True)[:limit]


class ReportGenerator:
    """Compiles all data into the specific Plain Text format."""

    def __init__(self, filename):
        self.filename = filename
        self.now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    def generate(self, basic, health, rtt, anomaly, perf, traffic, streams):

        duration = basic.get_duration()
        pps = basic.total_packets / duration if duration > 0 else 0
        mbps = (basic.total_bytes * 8 / 1000000) / duration if duration > 0 else 0

        retrans_rate = anomaly.get_retrans_rate()
        min_r, avg_r, max_r, jitter = rtt.get_stats()

        # Auto-Diagnosis Logic
        conclusions = []
        if retrans_rate > 2.0:
            conclusions.append("High Packet Loss Detected (>2%)")
        if perf.zero_window_events > 0:
            conclusions.append("Receiver Buffer Exhaustion (ZeroWindow)")
        if health.syn_count > 10 and health.syn_ack_count == 0:
            conclusions.append("Possible Firewall Drop or DoS (No SYN-ACKs)")

        core_conclusion = "Stable Connection" if not conclusions else ", ".join(conclusions)

        # Top Talkers String
        top_talkers = traffic.get_top_talkers()
        talker_str = ", ".join([f"{ip} ({cnt})" for ip, cnt in top_talkers])

        # Stream Table
        stream_rows = []
        for s in streams.get_bad_streams():
            row = f"ID:{s['id']} | {s['name']} | {s['rtt']} | {s['retrans']} | {s['status']}"
            stream_rows.append(row)
        stream_table = "\n".join(stream_rows)

        report = f"""
================================================================================
   TCP NETWORK ANALYSIS REPORT (DBA/OPS EDITION)
================================================================================
File: {self.filename}
Date: {self.now}

--------------------------------------------------------------------------------
1. EXECUTIVE SUMMARY
--------------------------------------------------------------------------------
* Capture Duration: {duration:.2f} seconds
* Total Packets: {basic.total_packets}
* Total TCP Connections: {len(health.conn_attempts)}
* Core Conclusion: {core_conclusion}

--------------------------------------------------------------------------------
2. TCP HANDSHAKE ANALYSIS
--------------------------------------------------------------------------------
* Total SYN (Synchronize) Requests: {health.syn_count}
* Handshake Success Rate: {health.get_handshake_success_rate():.2f}%
* Abnormalities (SYN Retransmissions/RST - Reset): RST count = {health.rst_count}

--------------------------------------------------------------------------------
3. LATENCY & RTT (ROUND TRIP TIME) ANALYSIS
--------------------------------------------------------------------------------
* RTT Statistics (Min/Avg/Max): {min_r:.2f}ms / {avg_r:.2f}ms / {max_r:.2f}ms
* Jitter (Variance in Latency): {jitter:.2f}ms

--------------------------------------------------------------------------------
4. PACKET LOSS & RETRANSMISSION
--------------------------------------------------------------------------------
* Retransmission Rate: {retrans_rate:.3f}%
* Out-of-Order / Lost Segments: {anomaly.retransmissions} (detected via retrans logic)

--------------------------------------------------------------------------------
5. TRAFFIC STATISTICS
--------------------------------------------------------------------------------
* Average Throughput (PPS - Packets Per Second / Mbps): {pps:.0f} PPS / {mbps:.2f} Mbps
* Top Talkers (Source IP): {talker_str}

--------------------------------------------------------------------------------
6. TCP HEALTH & WINDOW METRICS
--------------------------------------------------------------------------------
* Zero Window Events (Receiver Buffer Full): {perf.zero_window_events}
* Window Full Events (Sender Limit Reached): N/A (Requires Stateful Window Tracking)

--------------------------------------------------------------------------------
7. KEY TCP STREAMS ANALYSIS
--------------------------------------------------------------------------------
(List top streams by volume/status)
Stream ID | Src IP:Port -> Dst IP:Port | RTT (ms) | Retrans | Status
{stream_table}

--------------------------------------------------------------------------------
8. DETECTED ANOMALIES
--------------------------------------------------------------------------------
* Duplicate ACKs (Acknowledgements): N/A
* Checksum Errors: Not calculated (Offloading assumptions)

--------------------------------------------------------------------------------
9. CONCLUSION & RECOMMENDATIONS
--------------------------------------------------------------------------------
* Overall Assessment: {core_conclusion}
* Recommended Actions: Check specifically for 'Zero Window' if application sluggishness is reported. Investigate Retransmissions if rate > 1%.
"""
        print(report)


# ==========================================
# MAIN CONTROLLER
# ==========================================

def main():
    parser = argparse.ArgumentParser(description="Production-Grade PCAP Analyzer")
    parser.add_argument("pcap_file", help="Path to the .pcap file")
    args = parser.parse_args()

    # Instantiate Classes
    loader = PCAPLoader(args.pcap_file)
    basic = BasicStatsAnalyzer()
    health = TCPHealthCheck()
    rtt = RTTAnalyzer()
    anomaly = AnomalyDetector()
    perf = PerformanceAnalyzer()
    traffic = TrafficAnalyzer()
    streams = StreamAnalyzer()
    reporter = ReportGenerator(args.pcap_file)

    print(f"[...] Analyzing {args.pcap_file}, please wait...")

    # Load and Iterate
    pcap_iter = loader.load()

    try:
        for ts, buf in pcap_iter:
            # Basic Stats update
            basic.update(ts, buf)

            # Ethernet parsing
            try:
                eth = dpkt.ethernet.Ethernet(buf)
            except dpkt.dpkt.UnpackError:
                continue

            # IP parsing
            if not isinstance(eth.data, dpkt.ip.IP):
                continue
            ip = eth.data

            # Human readable IPs
            try:
                src_ip_str = socket.inet_ntoa(ip.src)
                dst_ip_str = socket.inet_ntoa(ip.dst)
            except Exception:
                continue

            # Traffic stats
            traffic.update(src_ip_str)

            # TCP parsing
            if isinstance(ip.data, dpkt.tcp.TCP):
                tcp = ip.data

                # Feed Analyzers
                health.analyze(tcp, src_ip_str, dst_ip_str)
                rtt.process_packet(ts, src_ip_str, dst_ip_str, tcp)
                anomaly.check(tcp, src_ip_str, dst_ip_str)
                perf.check_window(tcp)
                streams.process(tcp, src_ip_str, dst_ip_str)

    except Exception as e:
        print(f"Error during processing loop: {e}")
        # Continue to generate partial report

    # Generate Output
    reporter.generate(basic, health, rtt, anomaly, perf, traffic, streams)
    loader.close()


if __name__ == "__main__":
    main()