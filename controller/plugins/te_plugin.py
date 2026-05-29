#!/usr/bin/env python3
# SPDX-License-Identifier: ANCL-1.0
# Telemetry-Driven Traffic Engineering — Project B
# plugins/te_plugin.py
#
# Responsibilities:
#   1. Subscribe to PACKET_IN events
#   2. Identify reports coming from the cNF (UDP port 5001)
#   3. Parse the JSON report payload
#   4. Track path quality per flow
#   5. When degradation is detected, reroute via the alternative path
#   6. When quality recovers, restore the original path

import json
import struct
import time
from plugin_base import PluginBase

# UDP port the cNF sends reports to (must match cnf.py)
CNF_REPORT_PORT = 5001

# Subnet-2 hosts: (ip, host_mac) — must match setup_plugin._SUBNET2_HOSTS
SUBNET2_HOSTS = [
    ('10.0.2.4', 'aa:00:00:00:02:04'),
    ('10.0.2.5', 'aa:00:00:00:02:05'),
    ('10.0.2.6', 'aa:00:00:00:02:06'),
]

# Short path: s2 port 3 → s4 direct; nextHopMac is each host's real MAC
SHORT_PATH_EGRESS = 3
# Long path: s2 port 2 → s3 → s4; s3 carries the per-host knowledge
LONG_PATH_EGRESS   = 2
LONG_PATH_NEXTHOP  = 'cc:00:00:00:03:01'  # s3 port-1 MAC (facing s2)


class TEPlugin(PluginBase):

    def info(self):
        return {
            'name': 'te_plugin',
            'description': 'Receives cNF telemetry reports and reroutes degraded flows.'
        }

    def startup(self, ctrl, build_dir, config_dir):
        self.ctrl         = ctrl
        self.current_path = 'short'   # track which path is currently active
        self.last_reroute = 0         # timestamp of last reroute (avoid flapping)
        self.REROUTE_COOLDOWN = 10    # seconds between reroutes

        # Subscribe to all PacketIn events — filter to cNF reports only
        ctrl.subscribe(
            event_type=PluginBase.PACKET_IN,
            callback=self.on_packet_in,
            plugin_name=self.info()['name'],
            filter=self._is_cnf_report,
        )
        self.logger.info("TE plugin ready — listening for cNF reports")

    # ── Filter ───────────────────────────────────────────────────────────────

    def _is_cnf_report(self, event):
        """
        Fast pre-filter called by the dispatcher before queuing the event.
        Returns True only for UDP packets on port 5001 (cNF reports).
        Avoids waking the plugin thread for every PacketIn.
        """
        try:
            raw = bytes(event['packet'].payload)
            # Ethernet(14) + IP(20) + UDP(8) = 42 bytes minimum
            if len(raw) < 42:
                return False
            # EtherType at offset 12-13
            ethertype = struct.unpack_from('>H', raw, 12)[0]
            if ethertype != 0x0800:   # IPv4 only
                return False
            # UDP dst port at offset 14+20+2 = 36
            dst_port = struct.unpack_from('>H', raw, 36)[0]
            return dst_port == CNF_REPORT_PORT
        except Exception:
            return False

    # ── Handler ──────────────────────────────────────────────────────────────

    def on_packet_in(self, event):
        """
        Called for every PacketIn that passes _is_cnf_report.
        Parses the JSON report and decides whether to reroute.
        """
        try:
            raw = bytes(event['packet'].payload)
            report = self._parse_report(raw)
            if report is None:
                return

            self.logger.info(
                "report from cNF — flow=%s path=%s latency=%sus hops=%s degraded=%s",
                report['flow_id'], report['path_id'],
                report['total_latency'], report['hop_count'],
                report['degraded']
            )

            if report['degraded']:
                self._reroute(report)

        except Exception as e:
            self.logger.error("error handling cNF report: %s", e)

    # ── Parsing ───────────────────────────────────────────────────────────────

    def _parse_report(self, raw):
        """
        Extract JSON payload from a raw Ethernet+IP+UDP packet.
        Returns parsed dict or None on failure.
        """
        try:
            # Skip Ethernet(14) + IP(20) + UDP(8) = 42 bytes
            payload = raw[42:]
            return json.loads(payload.decode())
        except Exception as e:
            self.logger.warning("failed to parse cNF report: %s", e)
            return None

    # ── Rerouting ─────────────────────────────────────────────────────────────

    def _reroute(self, report):
        """
        Switch the active path on s2 to the alternative.
        Updates per-host /32 LPM entries (one per subnet-2 host) on s2.
        Cooldown prevents flapping when multiple degraded reports arrive.
        """
        now = time.time()
        if now - self.last_reroute < self.REROUTE_COOLDOWN:
            self.logger.info("reroute skipped — cooldown active")
            return

        if self.current_path == 'short':
            path_name = 'long'
            self.logger.warning(
                "DEGRADATION detected on short path — rerouting to LONG path"
            )
        else:
            path_name = 'short'
            self.logger.warning(
                "DEGRADATION detected on long path — rerouting to SHORT path"
            )

        # Update one /32 entry per subnet-2 host on s2.
        # Long path: all hosts share the same next-hop (s3 port-1 MAC).
        # Short path: each host gets its own MAC as next-hop.
        for host_ip, host_mac in SUBNET2_HOSTS:
            if path_name == 'long':
                egress_port = LONG_PATH_EGRESS
                next_hop    = LONG_PATH_NEXTHOP
            else:
                egress_port = SHORT_PATH_EGRESS
                next_hop    = host_mac
            self.ctrl.install_table_entry(
                's2',
                table_name='MyIngress.ipv4Lpm',
                match_fields={'hdr.ipv4.dstAddr': (host_ip, 32)},
                action_name='MyIngress.forward',
                action_params={'egressPort': egress_port, 'nextHopMac': next_hop},
                modify=True,
            )

        self.current_path = path_name
        self.last_reroute = now
        self.logger.info("rerouted to %s path — %d entries updated on s2",
                         path_name, len(SUBNET2_HOSTS))

        # Emit event so other plugins can react (e.g. logging, alerting)
        self.ctrl.emit(PluginBase.ENTRY_ADDED, {
            'device':    's2',
            'table':     'MyIngress.ipv4Lpm',
            'new_path':  path_name,
            'flow_id':   report['flow_id'],
            'latency':   report['total_latency'],
        })

    def shutdown(self):
        pass


plugin = TEPlugin
