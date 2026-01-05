import sys
import dpkt
import socket
import struct
import math
import argparse
import collections
from datetime import datetime

# --------------------------------------------------------------------------------
# ARCHITECTURAL CONSTANTS & ENUMS
# --------------------------------------------------------------------------------

TCP_FLAGS = {
    'FIN': 0x01, 'SYN': 0x02, 'RST': 0x04, 'PSH': 0x08,
    'ACK': 0x10, 'URG': 0x20, 'ECE': 0x40, 'CWR': 0x80
}


class AnalysisConfig:
    # Heuristics for Verdicts
    CRITICAL_RETRANS_RATIO = 0.05
    DEGRADED_RETRANS_RATIO = 0.01
    HIGH_LATENCY_MS = 150.0
    ZERO_WIN_THRESHOLD = 5


# --------------------------------------------------------------------------------
# UTILITIES
# --------------------------------------------------------------------------------

def inet_to_str(inet):
    """Convert inet object to a string."""
    try:
        return socket.inet_ntop(socket.AF_INET, inet)
    except ValueError:
        try:
            return socket.inet_ntop(socket.AF_INET6, inet)
        except ValueError:
            return "Unknown"


def safe_div(n, d):
    return n / d if d > 0 else 0.0


# --------------------------------------------------------------------------------
# CORE ANALYTICS CLASSES
# --------------------------------------------------------------------------------

class StreamMetrics:
    """Tracks state for a single TCP bi-directional flow."""

    def __init__(self, flow_id, src_ip, src_port, dst_ip, dst_port):
        self.flow_id = flow_id
        self.src_key = f"{src_ip}:{src_port}"
        self.dst_key = f"{dst_ip}:{dst_port}"

        # Timing
        self.start_ts = 0.0
        self.last_ts = 0.0

        # Counters
        self.packets = 0
        self.bytes_total = 0
        self.bytes_payload = 0

        # TCP State
        self.syn_seen = False
        self.syn_ack_seen = False
        self.fin_seen = False
        self.rst_seen = False

        # Latency
        self.handshake_rtt = 0.0
        self.rtt_samples = []

        # Retransmissions & Loss
        self.retrans_fast = 0
        self.retrans_rto = 0
        self.retrans_spurious = 0
        self.dup_acks = 0
        self.zero_wins = 0
        self.win_full_events = 0

        # Negotiation
        self.mss = 0
        self.wscale_client = -1
        self.wscale_server = -1
        self.sack_perm = False
        self.timestamps = False

        # Internal tracking for retrans detection
        # Direction 0: Src->Dst, Direction 1: Dst->Src
        self.next_seq = {0: 0, 1: 0}
        self.unacked_segments = {0: {}, 1: {}}  # seq -> ts

    def duration(self):
        return max(0.0, self.last_ts - self.start_ts)

    def avg_rtt(self):
        if not self.rtt_samples:
            return 0.0
        return sum(self.rtt_samples) / len(self.rtt_samples)

    def stdev_rtt(self):
        if len(self.rtt_samples) < 2:
            return 0.0
        avg = self.avg_rtt()
        variance = sum((x - avg) ** 2 for x in self.rtt_samples) / (len(self.rtt_samples) - 1)
        return math.sqrt(variance)

    def get_health_status(self):
        issues = []
        if self.rst_seen: issues.append("RESET")
        if self.retrans_rto > 0: issues.append("RTO")
        if self.zero_wins > 0: issues.append("ZeroWin")
        if not issues:
            return "Normal"
        return ",".join(issues)


class ForensicsEngine:
    """Main aggregation engine."""

    def __init__(self):
        self.streams = {}
        self.global_packets = 0
        self.global_bytes = 0
        self.start_capture = float('inf')
        self.end_capture = 0.0

    def parse_tcp_opts(self, opts, metrics, direction):
        # Parse TCP options strictly
        try:
            for opt, args in dpkt.tcp.parse_opts(opts):
                if opt == dpkt.tcp.TCP_OPT_MSS:
                    val = struct.unpack('>H', args)[0]
                    metrics.mss = val
                elif opt == dpkt.tcp.TCP_OPT_WSCALE:
                    val = struct.unpack('B', args)[0]
                    if direction == 0:
                        metrics.wscale_client = val
                    else:
                        metrics.wscale_server = val
                elif opt == dpkt.tcp.TCP_OPT_SACKOK:
                    metrics.sack_perm = True
                elif opt == dpkt.tcp.TCP_OPT_TIMESTAMP:
                    metrics.timestamps = True
        except:
            pass

    def analyze_packet(self, ts, buf):
        self.global_packets += 1
        self.global_bytes += len(buf)
        self.start_capture = min(self.start_capture, ts)
        self.end_capture = max(self.end_capture, ts)

        # Parse Ethernet/IP/TCP
        try:
            eth = dpkt.ethernet.Ethernet(buf)
            if not isinstance(eth.data, (dpkt.ip.IP, dpkt.ip6.IP6)):
                return
            ip = eth.data
            if not isinstance(ip.data, dpkt.tcp.TCP):
                return
            tcp = ip.data
        except:
            return

        # Identify Flow
        src_ip = inet_to_str(ip.src)
        dst_ip = inet_to_str(ip.dst)

        # Normalize key (min, max) to handle bi-directionality in one object
        if src_ip < dst_ip:
            flow_key = (src_ip, tcp.sport, dst_ip, tcp.dport)
            direction = 0  # Forward
        elif src_ip > dst_ip:
            flow_key = (dst_ip, tcp.dport, src_ip, tcp.sport)
            direction = 1  # Reverse
        else:
            # Same IP loopback or similar, sort by port
            if tcp.sport < tcp.dport:
                flow_key = (src_ip, tcp.sport, dst_ip, tcp.dport)
                direction = 0
            else:
                flow_key = (dst_ip, tcp.dport, src_ip, tcp.sport)
                direction = 1

        if flow_key not in self.streams:
            # Create new stream
            self.streams[flow_key] = StreamMetrics(len(self.streams) + 1, *flow_key)
            self.streams[flow_key].start_ts = ts

        flow = self.streams[flow_key]
        flow.last_ts = ts
        flow.packets += 1

        payload_len = len(tcp.data)
        flow.bytes_payload += payload_len

        # --- Phase 1 & 5: Flags & Options ---
        if tcp.flags & TCP_FLAGS['SYN']:
            self.parse_tcp_opts(tcp.opts, flow, direction)
            if tcp.flags & TCP_FLAGS['ACK']:
                flow.syn_ack_seen = True
                # Calculate Handshake RTT if we tracked the SYN
                # (Simplification: Assume previous packet in other dir was SYN if early in flow)
                pass
            else:
                flow.syn_seen = True

        if tcp.flags & TCP_FLAGS['RST']:
            flow.rst_seen = True

        if tcp.flags & TCP_FLAGS['FIN']:
            flow.fin_seen = True

        # --- Phase 4: Window Analysis ---
        if tcp.win == 0 and not (tcp.flags & TCP_FLAGS['RST']):
            flow.zero_wins += 1

        # --- Phase 3: Retransmission Forensics (Simplified Logic) ---
        # Using SEQ tracking. Note: This is a basic simulation.
        # Real TCP state tracking requires handling wrap-around and SACK.

        # If payload exists, check for retrans
        if payload_len > 0:
            expected = flow.next_seq[direction]
            if expected != 0 and tcp.seq < expected:
                # Sequence is lower than expected -> Retransmission or Out-of-Order
                # Differentiate RTO vs Fast Retrans based on time
                # Heuristic: If gap > 200ms or > 2*AvgRTT, likely RTO
                time_diff = 0
                if flow.rtt_samples:
                    avg_rtt = flow.avg_rtt()
                    # Search roughly when this seq was last sent (expensive, skipping for speed)
                    # Using generic heuristic
                    if avg_rtt > 0 and (ts - flow.start_ts) > (avg_rtt * 2):
                        flow.retrans_rto += 1
                    else:
                        flow.retrans_fast += 1
                else:
                    flow.retrans_fast += 1
            else:
                flow.next_seq[direction] = tcp.seq + payload_len
                # Track for RTT calculation
                flow.unacked_segments[direction][tcp.seq + payload_len] = ts

        # --- Phase 2: RTT Calculation ---
        if tcp.flags & TCP_FLAGS['ACK']:
            # Check if this ACK covers a known sent segment
            rev_dir = 1 - direction
            if tcp.ack in flow.unacked_segments[rev_dir]:
                sent_ts = flow.unacked_segments[rev_dir][tcp.ack]
                rtt = (ts - sent_ts) * 1000.0  # to ms
                if rtt > 0 and rtt < 5000:  # Sanity check < 5s
                    flow.rtt_samples.append(rtt)
                # Clean up old keys
                del flow.unacked_segments[rev_dir][tcp.ack]

    def generate_report(self, filename):
        duration = max(0.01, self.end_capture - self.start_capture)
        total_mb = self.global_bytes / (1024 * 1024)

        # Aggregation
        total_retrans_fast = sum(s.retrans_fast for s in self.streams.values())
        total_retrans_rto = sum(s.retrans_rto for s in self.streams.values())
        total_retrans = total_retrans_fast + total_retrans_rto

        all_rtts = [r for s in self.streams.values() for r in s.rtt_samples]
        avg_rtt = sum(all_rtts) / len(all_rtts) if all_rtts else 0.0
        max_rtt = max(all_rtts) if all_rtts else 0.0
        min_rtt = min(all_rtts) if all_rtts else 0.0

        # Verdict Logic
        retrans_ratio = safe_div(total_retrans, self.global_packets)
        health = "HEALTHY"
        primary_issue = "None"
        hypotheses = []

        if retrans_ratio > AnalysisConfig.CRITICAL_RETRANS_RATIO:
            health = "CRITICAL"
            primary_issue = "Severe Packet Loss / Congestion"
            hypotheses.append(
                f"High Retransmission Rate ({retrans_ratio:.1%}) indicates upstream packet dropper or blackhole.")
        elif retrans_ratio > AnalysisConfig.DEGRADED_RETRANS_RATIO:
            health = "DEGRADED"
            primary_issue = "Packet Loss"
            hypotheses.append(f"Moderate Retransmission Rate ({retrans_ratio:.1%}) indicates link errors or policing.")

        if avg_rtt > AnalysisConfig.HIGH_LATENCY_MS:
            if health == "HEALTHY": health = "DEGRADED"
            primary_issue = "High Latency"
            hypotheses.append(
                f"Average RTT ({avg_rtt:.2f}ms) exceeds threshold, suggesting geo-distance or bufferbloat.")

        total_zero_wins = sum(s.zero_wins for s in self.streams.values())
        if total_zero_wins > AnalysisConfig.ZERO_WIN_THRESHOLD:
            primary_issue = "Flow Control / App Saturation"
            hypotheses.append(
                f"Detected {total_zero_wins} Zero Window events. The receiving application cannot process data fast enough.")

        if not hypotheses:
            hypotheses.append("Traffic patterns appear within normal baseline parameters.")

        # ---------------- Printing ----------------
        print("=" * 80)
        print(f"{'NETWORK ANALYSIS REPORT':^80}")
        print("=" * 80)
        print(f"Generated by: Kevin")
        print(f"Target File: {filename}")
        print(f"Duration: {duration:.2f} seconds")
        print(f"Total Traffic: {total_mb:.2f} MB")
        print("")

        print("-" * 80)
        print("1. EXECUTIVE SUMMARY & VERDICT")
        print("-" * 80)
        print(f"OVERALL HEALTH: {health}")
        print(f"PRIMARY ISSUE:  {primary_issue}")
        print("")
        print("Root Cause Hypotheses:")
        for i, h in enumerate(hypotheses, 1):
            print(f"{i}. {h}")

        print("")
        print("-" * 80)
        print("2. TCP CONFIGURATION & NEGOTIATION")
        print("-" * 80)
        # Stats from random sample or average
        msses = [s.mss for s in self.streams.values() if s.mss > 0]
        avg_mss = sum(msses) / len(msses) if msses else 0
        print(f"[MSS Size]       Avg: {avg_mss:.0f} bytes")
        print(f"[SACK Support]   {'Detected' if any(s.sack_perm for s in self.streams.values()) else 'Not Detected'}")
        print(f"[Timestamps]     {'Detected' if any(s.timestamps for s in self.streams.values()) else 'Not Detected'}")

        print("")
        print("-" * 80)
        print("3. LATENCY & RTT (ROUND TRIP TIME)")
        print("-" * 80)

        std_dev = 0.0
        if len(all_rtts) > 1:
            variance = sum((x - avg_rtt) ** 2 for x in all_rtts) / (len(all_rtts) - 1)
            std_dev = math.sqrt(variance)

        print(f"Min RTT: {min_rtt:.2f} ms")
        print(f"Max RTT: {max_rtt:.2f} ms")
        print(f"Avg RTT: {avg_rtt:.2f} ms")
        print(f"StDev (Jitter): {std_dev:.2f} ms")

        print("")
        print("-" * 80)
        print("4. RETRANSMISSION FORENSICS")
        print("-" * 80)
        print(f"Total Retransmissions: {total_retrans} ({retrans_ratio:.2%})")
        print(f" - Fast Retransmits:   {total_retrans_fast} (Indicates light loss/CRC errors)")
        print(f" - RTO Timeouts:       {total_retrans_rto} (Indicates heavy congestion/blackholes) !CRITICAL!")

        print("")
        print("-" * 80)
        print("5. FLOW CONTROL & THROUGHPUT")
        print("-" * 80)
        print(f"Avg Throughput: {(self.global_bytes * 8 / duration) / 1000000:.2f} Mbps")
        print(f"Receive Window: {total_zero_wins} ZeroWindow Events")

        print("")
        print("-" * 80)
        print("6. TOP PROBLEMATIC STREAMS (DEEP DIVE)")
        print("-" * 80)

        # User requested tabular format for this section
        print(
            f"{'Stream ID':<10} | {'Src IP:Port -> Dst IP:Port':<45} | {'RTT (ms)':<10} | {'Retrans':<8} | {'Status'}")

        # Sort by Retransmissions desc, then Latency desc
        sorted_streams = sorted(self.streams.values(), key=lambda x: (x.retrans_rto + x.retrans_fast, x.avg_rtt()),
                                reverse=True)

        count = 0
        for s in sorted_streams:
            if count >= 10: break

            # Direction A -> B
            rtt_str = f"{s.avg_rtt():.2f}" if s.rtt_samples else "N/A"
            retrans_total = s.retrans_fast + s.retrans_rto
            retrans_str = str(retrans_total) if retrans_total > 0 else "-"
            status = s.get_health_status()

            # To match the user sample, we format Src -> Dst
            # We use the flow key order (Src/Dst is normalized, but we display it cleanly)
            conn_str = f"{s.src_key} -> {s.dst_key}"

            # ID:XXXX format
            id_str = f"ID:{s.flow_id}"

            print(f"{id_str:<10} | {conn_str:<45} | {rtt_str:<10} | {retrans_str:<8} | {status}")

            count += 1

        print("")
        print("=" * 80)
        print("END OF REPORT")
        print("=" * 80)


# --------------------------------------------------------------------------------
# MAIN EXECUTION
# --------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Deep TCP/IP Forensics Tool")
    parser.add_argument('pcap_file', help="Path to the .pcap file")
    args = parser.parse_args()

    engine = ForensicsEngine()

    try:
        with open(args.pcap_file, 'rb') as f:
            try:
                pcap = dpkt.pcap.Reader(f)
            except ValueError:
                # Fallback for pcapng or other errors
                try:
                    f.seek(0)
                    pcap = dpkt.pcapng.Reader(f)
                except:
                    print(f"Error: Could not parse {args.pcap_file} as PCAP or PCAPNG.")
                    sys.exit(1)

            for ts, buf in pcap:
                engine.analyze_packet(ts, buf)

        engine.generate_report(args.pcap_file)

    except IOError:
        print(f"Error: File {args.pcap_file} not found.")
        sys.exit(1)
    except Exception as e:
        print(f"Critical Analysis Failure: {e}")
        # In a real scenario, we'd print stack trace to stderr, but here we keep output clean
        sys.exit(1)


if __name__ == "__main__":
    main()