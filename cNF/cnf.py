#!/usr/bin/env python3
# SPDX-License-Identifier: ANCL-1.0
# Telemetry-Driven Traffic Engineering — Project B
# cnf.py — INT telemetry analyser

import yaml
import struct
import time
import json
from collections import defaultdict
from scapy.all import Ether, IP, UDP, Raw, sendp, sniff

# ─────────────────────────────────────────────
#  Constants — must match headers.p4
# ─────────────────────────────────────────────

TYPE_INT      = 0x0900   # EtherType for INT packets
INT_SHIM_SIZE = 5        # bytes: 16+8+8+8 bits = 40 bits = 5 bytes
INT_HOP_SIZE  = 9        # bytes: 8+48+8+8 bits = 72 bits = 9 bytes

# ─────────────────────────────────────────────
#  Config
# ─────────────────────────────────────────────

def load_config(path="cnf.yaml"):
    with open(path) as f:
        return yaml.safe_load(f)

# ─────────────────────────────────────────────
#  INT parsing
# ─────────────────────────────────────────────

def parse_int_shim(payload):
    """
    Parse the INT shim header (6 bytes).
    Layout: ethertype_orig(2) hop_count(1) max_hops(1) padding(1) + 1 align = 6 bytes
    Struct: '>HBBBx'
    """
    if len(payload) < INT_SHIM_SIZE:
        return None, payload

    ethertype_orig, hop_count, max_hops, padding = struct.unpack_from('>HBBB', payload, 0)
    shim = {
        'ethertype_orig': ethertype_orig,
        'hop_count':      hop_count,
        'max_hops':       max_hops,
    }
    return shim, payload[INT_SHIM_SIZE:]


def parse_int_hops(payload, hop_count):
    """
    Parse hop_count int_hop_t entries (10 bytes each).
    Layout per hop:
      offset 0: switch_id     (1 byte)
      offset 1: ingress_ts    (6 bytes, big-endian uint48)
      offset 7: egress_port   (1 byte)
      offset 8: padding       (1 byte)
      offset 9: end
    """
    hops = []
    for i in range(hop_count):
        if len(payload) < INT_HOP_SIZE:
            break

        hop_bytes = payload[:INT_HOP_SIZE]
        switch_id  = hop_bytes[0]
        ts_bytes   = b'\x00\x00' + hop_bytes[1:7]   # pad to 8 bytes for struct unpack
        ingress_ts = struct.unpack('>Q', ts_bytes)[0]
        egress_port = hop_bytes[7]

        hops.append({
            'switch_id':         switch_id,
            'ingress_timestamp': ingress_ts,
            'egress_port':       egress_port,
        })
        payload = payload[INT_HOP_SIZE:]

    return hops, payload


def parse_int_packet(packet):
    """
    Extract the full INT stack from a cloned packet.
    Returns (shim, hops, flow_id) or None if packet is not INT.
    """
    if not packet.haslayer(Ether):
        return None

    eth = packet[Ether]
    if eth.type != TYPE_INT:
        return None

    payload = bytes(eth.payload)

    shim, payload = parse_int_shim(payload)
    if shim is None:
        return None

    hops, payload = parse_int_hops(payload, shim['hop_count'])
    if not hops:
        return None

    # Extract flow id from IPv4 header (what remains after INT stack)
    flow_id = None
    if len(payload) >= 20:
        src = '.'.join(str(b) for b in payload[12:16])
        dst = '.'.join(str(b) for b in payload[16:20])
        flow_id = f"{src}->{dst}"

    return shim, hops, flow_id

# ─────────────────────────────────────────────
#  Metrics calculation
# ─────────────────────────────────────────────

def calculate_metrics(shim, hops):
    """
    Calculate per-hop and total latency.
    Latency between hop i and hop i+1 = ingress_ts[i+1] - ingress_ts[i]
    Total = last_ts - first_ts
    """
    hop_latencies = []
    for i in range(len(hops) - 1):
        delta = abs(hops[i+1]['ingress_timestamp'] - hops[i]['ingress_timestamp'])
        hop_latencies.append(delta)

    total_latency = 0
    if len(hops) >= 2:
        total_latency = abs(hops[-1]['ingress_timestamp'] - hops[0]['ingress_timestamp'])

    path_id = '-'.join(f"s{h['switch_id']}" for h in hops)

    return {
        'hop_count':     shim['hop_count'],
        'path_id':       path_id,
        'hop_latencies': hop_latencies,
        'total_latency': total_latency,
        'switch_ids':    [h['switch_id'] for h in hops],
    }

# ─────────────────────────────────────────────
#  State aggregation
# ─────────────────────────────────────────────

class PathState:
    """
    Rolling window of latency samples per flow.
    Detects degradation when abs(avg - baseline) exceeds 5% of baseline.
    Works in both directions: adding delay to s1->s2 link decreases the
    measured value (due to unsynchronised bmv2 clocks), so we catch changes
    in either direction.  Baseline resets automatically on path change.
    """
    WINDOW_SIZE     = 10
    DEGRADATION_PCT = 0.02   # 2% change from baseline (increase or decrease)

    def __init__(self):
        self.samples   = defaultdict(list)   # flow_id -> [latency, ...]
        self.baselines = {}                  # flow_id -> baseline avg
        self.last_path = {}                  # flow_id -> last seen path_id

    def update(self, flow_id, metrics):
        path_id = metrics['path_id']

        # Reset when the active path changes so stale baseline doesn't linger
        if flow_id in self.last_path and self.last_path[flow_id] != path_id:
            self.samples[flow_id] = []
            self.baselines.pop(flow_id, None)
            print(f"[cNF] Path changed for {flow_id}: "
                  f"{self.last_path[flow_id]} -> {path_id}, resetting baseline")
        self.last_path[flow_id] = path_id

        samples = self.samples[flow_id]
        samples.append(metrics['total_latency'])
        if len(samples) > self.WINDOW_SIZE:
            samples.pop(0)

        # Set baseline once we have a full window
        if flow_id not in self.baselines and len(samples) >= self.WINDOW_SIZE:
            self.baselines[flow_id] = sum(samples) / len(samples)
            print(f"[cNF] Baseline set for {flow_id} path={path_id}: "
                  f"{self.baselines[flow_id]:.1f}us")

    def is_degraded(self, flow_id):
        if flow_id not in self.baselines:
            return False
        samples = self.samples[flow_id]
        if not samples:
            return False
        avg = sum(samples) / len(samples)
        baseline = self.baselines[flow_id]
        return abs(avg - baseline) > baseline * self.DEGRADATION_PCT

    def average_latency(self, flow_id):
        samples = self.samples[flow_id]
        return sum(samples) / len(samples) if samples else 0

# ─────────────────────────────────────────────
#  Report sending
# ─────────────────────────────────────────────

def send_report(interface, config, flow_id, metrics, degraded):
    """
    Send a JSON report to the controller as a UDP packet via the switch.
    No direct TCP — packet travels through s3 -> controller as PacketIn.
    """
    report = {
        'flow_id':       flow_id,
        'path_id':       metrics['path_id'],
        'hop_count':     metrics['hop_count'],
        'total_latency': metrics['total_latency'],
        'hop_latencies': metrics['hop_latencies'],
        'switch_ids':    metrics['switch_ids'],
        'degraded':      degraded,
        'timestamp':     time.time(),
    }

    pkt = (
        Ether(src=config['cnf_mac'], dst=config['controller_mac'])
        / IP(src=config['cnf_ip'], dst=config['controller_ip'])
        / UDP(sport=5000, dport=5001)
        / Raw(load=json.dumps(report).encode())
    )

    sendp(pkt, iface=interface, verbose=False)
    status = "DEGRADED" if degraded else "ok"
    print(f"[cNF] Report -- flow={flow_id} path={metrics['path_id']} "
          f"latency={metrics['total_latency']}us hops={metrics['hop_count']} [{status}]")

# ─────────────────────────────────────────────
#  Packet handler
# ─────────────────────────────────────────────

REPORT_INTERVAL = 5                      # send report every N packets per flow
packet_counter  = defaultdict(int)

def handle_packet(packet, interface, config, state):
    result = parse_int_packet(packet)
    if result is None:
        return

    shim, hops, flow_id = result
    if flow_id is None:
        return

    metrics  = calculate_metrics(shim, hops)
    state.update(flow_id, metrics)
    degraded = state.is_degraded(flow_id)

    print(f"[cNF] INT -- flow={flow_id} path={metrics['path_id']} "
          f"latency={metrics['total_latency']}us hops={metrics['hop_count']}")

    # Send report every REPORT_INTERVAL packets, or immediately if degraded
    packet_counter[flow_id] += 1
    if packet_counter[flow_id] % REPORT_INTERVAL == 0 or degraded:
        send_report(interface, config, flow_id, metrics, degraded)

# ─────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────

def main():
    config    = load_config("cnf.yaml")
    interface = config['interface']
    state     = PathState()

    print(f"[cNF] INT analyser listening on {interface}")
    print(f"[cNF] Sending reports to {config['controller_ip']}:5001")

    sniff(
        iface=interface,
        filter=f"ether proto 0x0900",
        prn=lambda pkt: handle_packet(pkt, interface, config, state),
        store=False,
    )

if __name__ == "__main__":
    main()
