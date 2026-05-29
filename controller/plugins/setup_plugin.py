#!/usr/bin/env python3
# SPDX-License-Identifier: ANCL-1.0
# Telemetry-Driven Traffic Engineering — Project B
# plugins/setup_plugin.py
#
# Responsibilities:
#   1. Connect all 4 switches via P4Runtime
#   2. Push compiled P4 pipelines
#   3. Install multicast groups (flooding)
#   4. Install clone sessions (CPU learning + cNF mirror)
#   5. Install L2 forwarding rules (s1, s4)
#   6. Install L3 routing rules (s2, s3)
#   7. Install MAC rewrite rules (s2, s3)
#   8. Install switch_id in metadata table (all switches)
#   9. Install initial INT marking rules (s1)

import os
import yaml
from plugin_base import PluginBase


class SetupPlugin(PluginBase):

    def info(self):
        return {
            'name': 'setup_plugin',
            'description': 'Connects switches, pushes pipelines, installs all base rules.'
        }

    def startup(self, ctrl, build_dir, config_dir):
        self.ctrl = ctrl
        cfg = self._load_config(config_dir)

        # ── 1. Connect + push pipelines ──────────────────────────────
        devices = [
            ('s1', 50051, 1, 's1'),
            ('s2', 50052, 2, 's2'),
            ('s3', 50053, 3, 's3'),
            ('s4', 50054, 4, 's4'),
        ]
        for name, grpc_port, device_id, p4_name in devices:
            ctrl.connect(
                name=name,
                grpc_addr=f'127.0.0.1:{grpc_port}',
                device_id=device_id,
                p4info_path=os.path.join(build_dir, f'{p4_name}.p4info.txt'),
                json_path=os.path.join(build_dir, f'{p4_name}.json'),
            )
            ctrl.push_pipeline(name)
            self.logger.info("pipeline pushed to %s", name)

        # ── 2. Multicast groups (flood on all host ports) ─────────────
        # s1: ports 1,2,3,4  (hosts + uplink to s2)
        ctrl.install_multicast_group('s1', group_id=1,
            replicas=[{'egress_port': p, 'instance': 0} for p in [1, 2, 3, 4]])

        # s4: ports 1,2,3,4,5  (hosts + uplinks to s2 and s3)
        ctrl.install_multicast_group('s4', group_id=1,
            replicas=[{'egress_port': p, 'instance': 0} for p in [1, 2, 3, 4, 5]])

        # ── 3. Clone sessions ─────────────────────────────────────────
        # Session 100 → CPU port 510 (L2 learning on s1 and s4)
        for sw in ['s1', 's4']:
            ctrl.install_clone_session(sw, session_id=100,
                replicas=[{'egress_port': 510, 'instance': 0}])

        # Session 200 → port 6 on s4, which is directly the cNF veth (Fix 4)
        ctrl.install_clone_session('s4', session_id=200,
            replicas=[{'egress_port': 6, 'instance': 0}])

        # ── 4. L2 MAC tables (s1 and s4) ─────────────────────────────
        self._install_l2_rules(ctrl)

        # ── 5. L3 routing tables (s2 and s3) ─────────────────────────
        self._install_l3_rules(ctrl)

        # ── 6. Switch IDs (all switches) ──────────────────────────────
        # switch_id is stored in a one-entry table keyed on a constant
        # so the data plane can read meta.switch_id at runtime.
        # Simpler approach: install a default action with the ID hardcoded.
        self._install_switch_ids(ctrl)

        # ── 7. Initial INT marking rules (s1) ─────────────────────────
        # Mark all traffic from subnet 1 to subnet 2 for telemetry.
        # The TE plugin can add/remove entries here at runtime.
        self._install_int_marking(ctrl)

        self.logger.info("all rules installed — network ready")

    # ── Private helpers ───────────────────────────────────────────────────────

    def _load_config(self, config_dir):
        path = os.path.join(config_dir, 'topology.yaml')
        if os.path.exists(path):
            with open(path) as f:
                return yaml.safe_load(f)
        return {}

    def _install_l2_rules(self, ctrl):
        """
        Static MAC table entries for s1 and s4.

        s1 needs:
          - gateway MAC (cc:00:00:00:02:01) → uplink port 4
          - each subnet-1 host MAC → its access port (for return traffic from s2)

        s4 needs:
          - gateway MACs used by subnet-2 hosts for outbound traffic
          - each subnet-2 host MAC → its access port (for inbound traffic from s2/s3)
        """
        # s1: uplink (gateway MAC that subnet-1 hosts ARP for)
        ctrl.install_table_entry('s1',
            table_name='MyIngress.dMacLookup',
            match_fields={'hdr.eth.dstAddr': 'cc:00:00:00:02:01'},
            action_name='MyIngress.forward',
            action_params={'egress_port': 4})

        # s1: host entries — s2 sets dst MAC to the actual host MAC on return path
        for port, mac in [(1, 'aa:00:00:00:01:01'),
                          (2, 'aa:00:00:00:01:02'),
                          (3, 'aa:00:00:00:01:03')]:
            ctrl.install_table_entry('s1',
                table_name='MyIngress.dMacLookup',
                match_fields={'hdr.eth.dstAddr': mac},
                action_name='MyIngress.forward',
                action_params={'egress_port': port})

        # s4: gateway MACs used by subnet-2 hosts for outbound traffic
        ctrl.install_table_entry('s4',
            table_name='MyIngress.dMacLookup',
            match_fields={'hdr.eth.dstAddr': 'cc:00:00:00:02:03'},
            action_name='MyIngress.forward',
            action_params={'egress_port': 4})

        ctrl.install_table_entry('s4',
            table_name='MyIngress.dMacLookup',
            match_fields={'hdr.eth.dstAddr': 'cc:00:00:00:03:02'},
            action_name='MyIngress.forward',
            action_params={'egress_port': 5})

        # s4: host entries — s2/s3 sets dst MAC to the actual host MAC on inbound path
        for port, mac in [(1, 'aa:00:00:00:02:04'),
                          (2, 'aa:00:00:00:02:05'),
                          (3, 'aa:00:00:00:02:06')]:
            ctrl.install_table_entry('s4',
                table_name='MyIngress.dMacLookup',
                match_fields={'hdr.eth.dstAddr': mac},
                action_name='MyIngress.forward',
                action_params={'egress_port': port})

        # s4: controller MAC → CPU port 510 so cNF reports arrive as PacketIn
        ctrl.install_table_entry('s4',
            table_name='MyIngress.dMacLookup',
            match_fields={'hdr.eth.dstAddr': 'aa:00:00:00:05:02'},
            action_name='MyIngress.forward',
            action_params={'egress_port': 510})

        self.logger.info("L2 rules installed")

    # Hosts in each subnet — (ip, mac, access_port_on_edge_switch)
    _SUBNET1_HOSTS = [
        ('10.0.1.1', 'aa:00:00:00:01:01'),
        ('10.0.1.2', 'aa:00:00:00:01:02'),
        ('10.0.1.3', 'aa:00:00:00:01:03'),
    ]
    _SUBNET2_HOSTS = [
        ('10.0.2.4', 'aa:00:00:00:02:04'),
        ('10.0.2.5', 'aa:00:00:00:02:05'),
        ('10.0.2.6', 'aa:00:00:00:02:06'),
    ]

    def _install_l3_rules(self, ctrl):
        """
        Per-host /32 LPM routes + MAC rewrite for s2 and s3.

        Using /32 (not /24) so the router sets the destination MAC to the
        actual host MAC.  s4/s1 are pure L2 switches — they need the real
        host MAC to forward without flooding, which would otherwise loop
        via s3 back to s4.

        s2 short-path state: subnet-2 hosts via port 3 (direct to s4).
        The TE plugin updates these entries to switch to the long path.

        Port map:
          s2: p1=s1  p2=s3  p3=s4
          s3: p1=s2  p2=s4
        """
        # ── s2 routing ────────────────────────────────────────────────

        # Return to subnet 1 — per-host /32 with actual host MAC
        for host_ip, host_mac in self._SUBNET1_HOSTS:
            ctrl.install_table_entry('s2',
                table_name='MyIngress.ipv4Lpm',
                match_fields={'hdr.ipv4.dstAddr': (host_ip, 32)},
                action_name='MyIngress.forward',
                action_params={'egressPort': 1, 'nextHopMac': host_mac})

        # Forward to subnet 2 — SHORT path initially (direct to s4 via port 3)
        for host_ip, host_mac in self._SUBNET2_HOSTS:
            ctrl.install_table_entry('s2',
                table_name='MyIngress.ipv4Lpm',
                match_fields={'hdr.ipv4.dstAddr': (host_ip, 32)},
                action_name='MyIngress.forward',
                action_params={'egressPort': 3, 'nextHopMac': host_mac})

        # MAC rewrite for s2 (one entry per egress port)
        for port, src_mac in [(1, 'cc:00:00:00:02:01'),
                               (2, 'cc:00:00:00:02:02'),
                               (3, 'cc:00:00:00:02:03')]:
            ctrl.install_table_entry('s2',
                table_name='MyIngress.internalMacLookup',
                match_fields={'std_meta.egress_spec': port},
                action_name='MyIngress.rewriteMacs',
                action_params={'srcMac': src_mac})

        # ── s3 routing ────────────────────────────────────────────────

        # Return to subnet 1 — route via s2 (s2 carries the /32 knowledge)
        ctrl.install_table_entry('s3',
            table_name='MyIngress.ipv4Lpm',
            match_fields={'hdr.ipv4.dstAddr': ('10.0.1.0', 24)},
            action_name='MyIngress.forward',
            action_params={'egressPort': 1, 'nextHopMac': 'cc:00:00:00:02:02'})

        # Forward to subnet 2 (long path: s3 → s4) — per-host /32 with actual host MAC
        for host_ip, host_mac in self._SUBNET2_HOSTS:
            ctrl.install_table_entry('s3',
                table_name='MyIngress.ipv4Lpm',
                match_fields={'hdr.ipv4.dstAddr': (host_ip, 32)},
                action_name='MyIngress.forward',
                action_params={'egressPort': 2, 'nextHopMac': host_mac})

        # MAC rewrite for s3 (one entry per egress port)
        for port, src_mac in [(1, 'cc:00:00:00:03:01'),
                               (2, 'cc:00:00:00:03:02')]:
            ctrl.install_table_entry('s3',
                table_name='MyIngress.internalMacLookup',
                match_fields={'std_meta.egress_spec': port},
                action_name='MyIngress.rewriteMacs',
                action_params={'srcMac': src_mac})

        self.logger.info("L3 rules installed")

    def _install_switch_ids(self, ctrl):
        """
        Install switch_id into each switch's metadata table.
        This is a one-entry table with a const key so the data plane
        can always read its own ID from meta.switch_id.

        Implementation note: the simplest approach is a table keyed on
        a constant (e.g. 1w1) with action set_switch_id(id).
        The P4 program reads meta.switch_id after applying this table.
        """
        ids = {'s1': 1, 's2': 2, 's3': 3, 's4': 4}
        for sw, sw_id in ids.items():
            ctrl.install_table_entry(sw,
                table_name='MyIngress.switchIdTable',
                match_fields={'meta.constant': 1},
                action_name='MyIngress.set_switch_id',
                action_params={'id': sw_id})
        self.logger.info("switch IDs installed")

    def _install_int_marking(self, ctrl):
        """
        Mark all flows from subnet 1 to subnet 2 for INT telemetry.
        The TE plugin can add or remove entries here at runtime.
        """
        ctrl.install_table_entry('s1',
            table_name='MyIngress.intMarkingTable',
            match_fields={
                'hdr.ipv4.srcAddr': ('10.0.1.0', '255.255.255.0'),
                'hdr.ipv4.dstAddr': ('10.0.2.0', '255.255.255.0'),
            },
            action_name='MyIngress.mark_int',
            action_params={},
            priority=100)
        self.logger.info("INT marking rules installed")

    def shutdown(self):
        pass


plugin = SetupPlugin
