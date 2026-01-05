import argparse
import sys
import logging
import statistics
from collections import defaultdict, Counter
from datetime import datetime

# Scapy imports
try:
    from scapy.all import PcapReader, TCP, IP, IPv6, Ether
    from scapy.utils import PcapReader
except ImportError:
    print("Error: Scapy is not installed. Please run 'pip install scapy'")
    sys.exit(1)

# Configure logging
logging.basicConfig(format='%(levelname)s: %(message)s', level=logging.INFO)


class PcapAnalyzer:
    def __init__(self, pcap_file):
        self.pcap_file = pcap_file

        # Executive Summary Data
        self.start_time = None
        self.end_time = None
        self.total_packets = 0
        self.total_bytes = 0

        # IP/Stream Tracking
        self.unique_ips = set()
        self.tcp_streams = set()

        # Protocol Breakdown
        self.protocol_counts = Counter()
        self.top_talkers_ip = Counter()

        # IO Stats (Throughput)
        # Key: Timestamp (int second), Value: Bytes
        self.io_stats = defaultdict(int)

        # TCP Specific Metrics
        # Key: 4-tuple (src_ip, src_port, dst_ip, dst_port)
        self.tcp_flow_stats = defaultdict(lambda: {
            'syn': 0, 'syn_ack': 0, 'ack': 0, 'fin': 0, 'rst': 0,
            'retransmissions': 0,
            'zero_window': 0,
            'bytes': 0,
            'packets': 0,
            'rtt_samples': []
        })

        # TCP State / RTT Tracking Helpers
        # Key: (src_ip, src_port, dst_ip, dst_port, seq_next)
        # Value: Timestamp sent
        self.unacked_packets = {}

        # Retransmission Detection
        # Key: (src_ip, src_port, dst_ip, dst_port)
        # Value: Set of SEQs seen
        self.seen_seqs = defaultdict(set)

    def analyze(self):
        print(f"Analyzing {self.pcap_file}... (This may take time for large files)")

        try:
            # Use PcapReader for memory efficiency (iterator) instead of loading all at once
            with PcapReader(self.pcap_file) as pcap:
                for pkt in pcap:
                    self._process_packet(pkt)
        except FileNotFoundError:
            logging.error(f"File not found: {self.pcap_file}")
            sys.exit(1)
        except Exception as e:
            logging.error(f"An error occurred during processing: {e}")
            sys.exit(1)

        self._generate_report()

    def _process_packet(self, pkt):
        self.total_packets += 1
        pkt_len = len(pkt)
        self.total_bytes += pkt_len

        # Timing
        try:
            ts = float(pkt.time)
        except AttributeError:
            # Fallback if packet has no time attribute
            ts = datetime.now().timestamp()

        if self.start_time is None:
            self.start_time = ts
        self.end_time = ts

        # IO Stats (1s buckets)
        self.io_stats[int(ts)] += pkt_len

        # IP Layer Processing
        if IP in pkt or IPv6 in pkt:
            ip_layer = pkt[IP] if IP in pkt else pkt[IPv6]
            src_ip = ip_layer.src
            dst_ip = ip_layer.dst
            proto = ip_layer.proto

            self.unique_ips.add(src_ip)
            self.unique_ips.add(dst_ip)
            self.top_talkers_ip[src_ip] += pkt_len

            # Protocol counting (Simplified)
            if TCP in pkt:
                self.protocol_counts['TCP'] += 1
                self._analyze_tcp(pkt, ts, src_ip, dst_ip)
            elif pkt.haslayer('UDP'):
                self.protocol_counts['UDP'] += 1
            elif pkt.haslayer('ICMP'):
                self.protocol_counts['ICMP'] += 1
            else:
                self.protocol_counts['Other'] += 1
        else:
            self.protocol_counts['Non-IP'] += 1

    def _analyze_tcp(self, pkt, ts, src_ip, dst_ip):
        tcp = pkt[TCP]
        src_port = tcp.sport
        dst_port = tcp.dport
        flags = tcp.flags
        seq = tcp.seq
        ack = tcp.ack
        payload_len = len(tcp.payload)

        # Flow Key (Directional)
        flow_key = (src_ip, src_port, dst_ip, dst_port)
        # Stream ID (Bi-directional - sorted tuple)
        stream_id = tuple(sorted([(src_ip, src_port), (dst_ip, dst_port)]))
        self.tcp_streams.add(stream_id)

        stats = self.tcp_flow_stats[flow_key]
        stats['packets'] += 1
        stats['bytes'] += payload_len

        # --- Flag Analysis ---
        if 'S' in flags: stats['syn'] += 1
        if 'S' in flags and 'A' in flags: stats['syn_ack'] += 1
        if 'F' in flags: stats['fin'] += 1
        if 'R' in flags: stats['rst'] += 1
        if 'A' in flags: stats['ack'] += 1

        # --- Zero Window ---
        if tcp.window == 0 and 'S' not in flags and 'R' not in flags:
            stats['zero_window'] += 1

        # --- Retransmission Detection ---
        # Logic: If we've seen this SEQ and it has payload, it's likely a retrans.
        # Excluding Keep-Alives (usually len 0 or 1 with previous seq)
        if payload_len > 0:
            if seq in self.seen_seqs[flow_key]:
                stats['retransmissions'] += 1
            else:
                self.seen_seqs[flow_key].add(seq)

        # --- Latency / RTT Calculation ---
        # 1. If sending data (len > 0), store timestamp keyed by expected ACK (seq + len)
        if payload_len > 0:
            expected_ack = seq + payload_len
            # We map the ACK expectation to the reverse flow
            # Key format: (SenderIP, SenderPort, ReceiverIP, ReceiverPort, ExpectedAck)
            rtt_key = (src_ip, src_port, dst_ip, dst_port, expected_ack)
            if rtt_key not in self.unacked_packets:
                self.unacked_packets[rtt_key] = ts

        # 2. If ACK received, check if it matches an expected ACK from the reverse direction
        if 'A' in flags:
            # Reverse flow key to find who sent the data
            reverse_key = (dst_ip, dst_port, src_ip, src_port, ack)
            if reverse_key in self.unacked_packets:
                start_ts = self.unacked_packets.pop(reverse_key)
                rtt = (ts - start_ts) * 1000.0  # ms
                # Store RTT in the SENDER's stats (the one who sent the data)
                sender_flow_key = (dst_ip, dst_port, src_ip, src_port)
                self.tcp_flow_stats[sender_flow_key]['rtt_samples'].append(rtt)

    def _generate_report(self):
        duration = (self.end_time - self.start_time) if self.end_time and self.start_time else 0
        if duration == 0: duration = 1  # Avoid div by zero

        print("\n" + "=" * 60)
        print(" 1. === Executive Summary ===")
        print("=" * 60)
        print(f"{'Total Packets':<25}: {self.total_packets:,}")
        print(f"{'Duration':<25}: {duration:.2f} seconds")
        print(f"{'Total Data':<25}: {self.total_bytes / (1024 * 1024):.2f} MB")
        print(f"{'Avg Throughput':<25}: {(self.total_bytes * 8 / duration) / 1000000:.2f} Mbps")
        print(f"{'Unique IPs':<25}: {len(self.unique_ips)}")
        print(f"{'TCP Streams':<25}: {len(self.tcp_streams)}")

        print("\n" + "=" * 60)
        print(" 2. === Traffic Overview ===")
        print("=" * 60)
        print("--- Protocol Breakdown ---")
        for proto, count in self.protocol_counts.most_common():
            print(f"{proto:<10}: {count} ({count / self.total_packets * 100:.1f}%)")

        print("\n--- Top Talkers (Src IP by Volume) ---")
        for ip, bytes_count in self.top_talkers_ip.most_common(5):
            print(f"{ip:<20}: {bytes_count / (1024 * 1024):.2f} MB")

        # Aggregate TCP Stats
        total_syn = sum(s['syn'] for s in self.tcp_flow_stats.values())
        total_syn_ack = sum(s['syn_ack'] for s in self.tcp_flow_stats.values())
        total_rst = sum(s['rst'] for s in self.tcp_flow_stats.values())
        total_retrans = sum(s['retransmissions'] for s in self.tcp_flow_stats.values())
        total_zero_win = sum(s['zero_window'] for s in self.tcp_flow_stats.values())

        print("\n" + "=" * 60)
        print(" 3. === TCP Health & Connectivity ===")
        print("=" * 60)
        print(f"{'Total SYNs Sent':<25}: {total_syn}")
        print(f"{'Total SYN-ACKs':<25}: {total_syn_ack}")
        hs_rate = (total_syn_ack / total_syn * 100) if total_syn > 0 else 0
        print(f"{'Handshake Success Rate':<25}: {hs_rate:.2f}%")
        print(f"{'Total Resets (RST)':<25}: {total_rst}")

        print("\n" + "=" * 60)
        print(" 4. === Performance Metrics ===")
        print("=" * 60)

        # Throughput Analysis
        print("--- Throughput Peak (1s intervals) ---")
        if self.io_stats:
            max_sec = max(self.io_stats, key=self.io_stats.get)
            max_bytes = self.io_stats[max_sec]
            print(f"Peak Traffic at T+{max_sec - int(self.start_time)}s: {max_bytes * 8 / 1000000:.2f} Mbps")
        else:
            print("No IO stats available.")

        # Latency Stats
        all_rtts = []
        for s in self.tcp_flow_stats.values():
            all_rtts.extend(s['rtt_samples'])

        print("\n--- TCP Round Trip Time (RTT) ---")
        if all_rtts:
            print(f"{'Samples':<25}: {len(all_rtts)}")
            print(f"{'Min RTT':<25}: {min(all_rtts):.2f} ms")
            print(f"{'Avg RTT':<25}: {statistics.mean(all_rtts):.2f} ms")
            print(f"{'Max RTT':<25}: {max(all_rtts):.2f} ms")
        else:
            print("Insufficient data to calculate RTT (Need DATA + ACK pairs).")

        print("\n" + "=" * 60)
        print(" 5. === Anomalies & Errors ===")
        print("=" * 60)

        # Retransmissions
        tcp_pkts = self.protocol_counts['TCP']
        retrans_rate = (total_retrans / tcp_pkts * 100) if tcp_pkts > 0 else 0
        print(f"{'TCP Retransmissions':<25}: {total_retrans}")
        print(f"{'Retransmission Rate':<25}: {retrans_rate:.4f}%")

        # Window Issues
        print(f"{'Zero Window Events':<25}: {total_zero_win}")
        if total_zero_win > 0:
            print("  -> WARNING: Receivers are overwhelmed (Flow Control active).")

        # Worst offenders for retransmissions
        print("\n--- Top 3 Streams by Retransmissions ---")
        # Sort flows by retrans count
        sorted_flows = sorted(self.tcp_flow_stats.items(), key=lambda x: x[1]['retransmissions'], reverse=True)
        count = 0
        for flow, stats in sorted_flows:
            if stats['retransmissions'] > 0:
                src = f"{flow[0]}:{flow[1]}"
                dst = f"{flow[2]}:{flow[3]}"
                print(f"{src} -> {dst} : {stats['retransmissions']} retransmits")
                count += 1
                if count >= 3: break
        if count == 0:
            print("None detected.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Deep TCP Analysis Tool using Scapy")
    parser.add_argument("pcap", help="Path to the .pcap or .pcapng file")
    args = parser.parse_args()

    analyzer = PcapAnalyzer(args.pcap)
    analyzer.analyze()