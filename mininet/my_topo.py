#!/usr/bin/env python3
# Topology: 4 P4 devices, 2 subnets, 6 hosts, 2 alternative paths, 1 cNF

from mininet.net import Mininet
from mininet.topo import Topo
from mininet.log import setLogLevel, info
from mininet.cli import CLI
from mininet.link import TCLink

from p4_mininet import P4Host
from p4runtime_switch import P4RuntimeSwitch

import argparse
import subprocess
from time import sleep


def host_mac(net, n):
    return f"aa:00:00:00:{net:02x}:{n:02x}"

def host_ip(net, dev, mask):
    return f"10.0.{net}.{dev}/{mask}"

def device_mac(id, port):
    return f"cc:00:00:00:{id:02x}:{port:02x}"


# ─────────────────────────────────────────────
#  Topology
#
#  Subnet 10.0.1.0/24          Subnet 10.0.2.0/24
#
#  h1 ──┐                               ┌── h4
#  h2 ──┤── s1(L2) ──── s2(L3) ──────── s4(L2) ── h5
#  h3 ──┘         port4   port1 \  port3/           h6
#                                 \    /             │ port6
#                            port2 \  / port2       cNF (Docker, veth pair)
#                                  s3(L3)
#
#  Short path : s1 → s2 → s4          (2 L3 hops)
#  Long  path : s1 → s2 → s3 → s4    (3 L3 hops)
#  cNF on s4 port 6 — receives E2E clones of INT packets directly from s4
#
#  Port map
#  s1 : p1=h1  p2=h2  p3=h3  p4=s2
#  s2 : p1=s1  p2=s3  p3=s4
#  s3 : p1=s2  p2=s4
#  s4 : p1=h4  p2=h5  p3=h6  p4=s2  p5=s3  p6=cNF
# ─────────────────────────────────────────────

class MyTopo(Topo):
    def __init__(self, sw_path, thrift_port, grpc_port, **opts):
        super().__init__(**opts)

        # -------------- P4 devices --------------
        # s1 - L2 switch (hosts on subnet 1)
        s1 = self.addSwitch("s1",
                            sw_path=sw_path,
                            thrift_port=thrift_port,
                            grpc_port=grpc_port,
                            device_id=1,         
                            cpu_port=510)

        # s2 - L3 router (junction, connects both subnets + both paths)
        s2 = self.addSwitch("s2",
                            sw_path=sw_path,
                            thrift_port=thrift_port + 1,
                            grpc_port=grpc_port + 1,
                            device_id=2,
                            cpu_port=510)

        # s3 - L3 router (alternative / longer path, cNF attached here)
        s3 = self.addSwitch("s3",
                            sw_path=sw_path,
                            thrift_port=thrift_port + 2,
                            grpc_port=grpc_port + 2,
                            device_id=3,
                            cpu_port=510)

        # s4 - L2 switch (hosts on subnet 2)
        s4 = self.addSwitch("s4",
                            sw_path=sw_path,
                            thrift_port=thrift_port + 3,
                            grpc_port=grpc_port + 3,
                            device_id=4,
                            cpu_port=510)

        # -------------- Hosts --------------
        # Subnet 1 - static IPs
        h1 = self.addHost("h1", ip=host_ip(1, 1, 24), mac=host_mac(1, 1))
        h2 = self.addHost("h2", ip=host_ip(1, 2, 24), mac=host_mac(1, 2))
        h3 = self.addHost("h3", ip=host_ip(1, 3, 24), mac=host_mac(1, 3))

        # Subnet 2 - static IPs
        h4 = self.addHost("h4", ip=host_ip(2, 4, 24), mac=host_mac(2, 4))
        h5 = self.addHost("h5", ip=host_ip(2, 5, 24), mac=host_mac(2, 5))  # FIX: ip= estava errado
        h6 = self.addHost("h6", ip=host_ip(2, 6, 24), mac=host_mac(2, 6))

        # -------------- Links --------------
        # Subnet 1 hosts -> s1 (L2)
        self.addLink(h1, s1, port2=1, addr2=device_mac(1, 1))
        self.addLink(h2, s1, port2=2, addr2=device_mac(1, 2))
        self.addLink(h3, s1, port2=3, addr2=device_mac(1, 3))

        # Subnet 2 hosts -> s4 (L2)
        self.addLink(h4, s4, port2=1, addr2=device_mac(4, 1))
        self.addLink(h5, s4, port2=2, addr2=device_mac(4, 2))
        self.addLink(h6, s4, port2=3, addr2=device_mac(4, 3))

        # s1 (L2) <-> s2 (L3) - entry point into the routed core
        self.addLink(s1, s2,
                     port1=4, port2=1,
                     addr1=device_mac(1, 4), addr2=device_mac(2, 1))

        # s2 (L3) <-> s4 (L2) - SHORT path (direct, 2 hops)
        self.addLink(s2, s4,
                     port1=3, port2=4,
                     addr1=device_mac(2, 3), addr2=device_mac(4, 4),
                     delay='5ms')

        # s2 (L3) <-> s3 (L3) - first leg of LONG path
        self.addLink(s2, s3,
                     port1=2, port2=1,
                     addr1=device_mac(2, 2), addr2=device_mac(3, 1),
                     delay='5ms')

        # s3 (L3) <-> s4 (L2) - second leg of LONG path (3 hops total)
        self.addLink(s3, s4,
                     port1=2, port2=5,
                     addr1=device_mac(3, 2), addr2=device_mac(4, 5),
                     delay='5ms')

        # s3 port 3 is reserved for the cNF veth (created in main() below)


def main():                                          
    parser = argparse.ArgumentParser(description='INT Telemetry Topology') 
    parser.add_argument('--behavioral-exe',
                        help='Path to behavioral executable',
                        type=str, action='store', default='simple_switch_grpc')
    parser.add_argument('--thrift-port',
                        help='Thrift server port for table updates',
                        type=int, action="store", default=9090)
    parser.add_argument('--grpc-port',
                        help='gRPC server port for controller comm',
                        type=int, action="store", default=50051)
    args = parser.parse_args()

    topo = MyTopo(args.behavioral_exe,
                  args.thrift_port,
                  args.grpc_port)

    net = Mininet(topo=topo,
                  host=P4Host,
                  switch=P4RuntimeSwitch,
                  controller=None,
                  link=TCLink)

    net.start()
    sleep(1)

    # ----------- Default routes - subnet 1 -----------
    # Gateway IP is virtual (no P4 device responds to ARP), so we pre-populate
    # the ARP cache with s2's port-1 MAC — s1's dMacLookup forwards that MAC
    # to port 4 (uplink to s2), which then does L3 routing.
    GW1 = "10.0.1.254"
    GW1_MAC = device_mac(2, 1)   # cc:00:00:00:02:01 — s2 port 1 (facing s1)
    for h in ["h1", "h2", "h3"]:
        net.get(h).cmd(f"ip route replace default via {GW1}")
        net.get(h).cmd(f"arp -s {GW1} {GW1_MAC}")

    # ----------- Default routes - subnet 2 -----------
    # Similarly: gateway ARP points to s2's port-3 MAC so s4's dMacLookup
    # forwards return traffic to port 4 (uplink to s2).
    GW2 = "10.0.2.254"
    GW2_MAC = device_mac(2, 3)   # cc:00:00:00:02:03 — s2 port 3 (facing s4)
    for h in ["h4", "h5", "h6"]:
        net.get(h).cmd(f"ip route replace default via {GW2}")
        net.get(h).cmd(f"arp -s {GW2} {GW2_MAC}")

    # ----------- cNF veth setup -----------
    # Creates veth-cnf0 (plugged into s3 port 3) <-> veth-cnf1 (container side)
    # The container is started separately by run_sim.sh
    info("*** Setting up cNF veth pair\n")
    subprocess.call("ip link add veth-cnf0 type veth peer name veth-cnf1", shell=True)
    subprocess.call("ip link set veth-cnf0 up", shell=True)
    subprocess.call("ip link set veth-cnf1 up", shell=True)

    # Attach veth-cnf0 to s3 as port 3
    # Note: with simple_switch_grpc the port is passed via CLI args in run_sim.sh
    # This subprocess call is a placeholder - adapt to your runner as needed
    subprocess.call("ovs-vsctl add-port s3 veth-cnf0 2>/dev/null || true", shell=True)

    info("*** Network is ready\n")
    print("\nTopology summary:")
    print("  Subnet 1 : h1/h2/h3  (10.0.1.0/24)  via s1(L2) -> s2(L3)")
    print("  Subnet 2 : h4/h5/h6  (10.0.2.0/24)  via s4(L2)")
    print("  Short path : s1 -> s2 -> s4           (2 hops)")
    print("  Long  path : s1 -> s2 -> s3 -> s4     (3 hops)")
    print("  cNF        : attached to s3 port 3\n")

    CLI(net)
    net.stop()


if __name__ == '__main__':
    setLogLevel('info')
    main()