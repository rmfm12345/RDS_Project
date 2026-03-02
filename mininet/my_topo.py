#!/usr/bin/env python3

from mininet.net import Mininet
from mininet.topo import Topo
from mininet.log import setLogLevel, info
from mininet.cli import CLI
from mininet.link import TCLink

from p4_mininet import P4Switch, P4Host

import argparse
from pathlib import Path
from time import sleep
from subprocess import call

def host_mac(net, n):
    return f"aa:00:00:00:{net:02x}:{n:02x}"

def host_ip(net, dev, mask):
    return f"10.0.{net}.{dev}/{mask}"

def device_mac(id, port):
    return f"cc:00:00:00:{id:02x}:{port:02x}"


class MyTopo(Topo):
    def __init__(self, 
                sw_path, 
                json_dir,
                thrift_port,
                **opts):

        # Initialize topology and default options
        super().__init__(self, **opts)

        json_p = (Path(__file__).resolve().parent.parent / json_dir)


        # ------------------- creating devices ------------------------
        d1 = self.addSwitch("d1", sw_path=sw_path, json_path=str(json_p / "hub.json"), thrift_port=thrift_port)
        d2 = self.addSwitch("d2", sw_path=sw_path, json_path=str(json_p / "l3s.json"), thrift_port=thrift_port+1)
        d3 = self.addSwitch("d3", sw_path=sw_path, json_path=str(json_p / "hub.json"), thrift_port=thrift_port+2)

        # -------------------- creating hosts -------------------------
        h1 = self.addHost("h1", ip=host_ip(1, 1, 24), mac=host_mac(1,1))
        h2 = self.addHost("h2", ip=host_ip(1, 2, 24), mac=host_mac(1,2))
        h3 = self.addHost("h3", ip=host_ip(1, 3, 24), mac=host_mac(1,3))
        h4 = self.addHost("h4", ip=host_ip(2, 4, 24), mac=host_mac(2,4))
        h5 = self.addHost("h5", ip=host_ip(2, 5, 24), mac=host_mac(2,5))
        h6 = self.addHost("h6", ip=host_ip(2, 6, 24), mac=host_mac(2,6))

        # -------------------- creating links -------------------------
        # --------------------- hosts to l2 switch -------------------
        self.addLink(h1, d1, port2=1, addr2=device_mac(1,1))
        self.addLink(h2, d1, port2=2, addr2=device_mac(1,2))
        self.addLink(h3, d1, port2=3, addr2=device_mac(1,3))

        self.addLink(h4, d3, port2=1, addr2=device_mac(3,1))
        self.addLink(h5, d3, port2=2, addr2=device_mac(3,2))
        self.addLink(h6, d3, port2=3, addr2=device_mac(3,3))

        # --------------------- l2-switch to l3-switch to l2-switch ------------
        self.addLink(d1, d2, port1=4, port2=1, addr1=device_mac(1,4), addr2=device_mac(2,1), delay='10ms', loss=1)
        self.addLink(d3, d2, port1=4, port2=2, addr1=device_mac(3,4), addr2=device_mac(2,2), delay='10ms', loss=1)

def main():
    parser = argparse.ArgumentParser(description='Mininet demo')
    parser.add_argument('--behavioral-exe', help='Path to behavioral executable',
                        type=str, action="store", default='simple_switch')
    parser.add_argument('--thrift-port', help='Thrift server port for table updates',
                        type=int, action="store", default=9090)
    parser.add_argument('--json-dir', help='Path to JSON config file',
                        type=str, action="store", default='json')
    args = parser.parse_args()



    topo = MyTopo(args.behavioral_exe,
                   args.json_dir,
                   args.thrift_port)

    # the host class is the P4Host
    # the switch class is the P4Switch
    net = Mininet(topo = topo,
                  host = P4Host,
                  switch = P4Switch,
                  controller = None,
                  link=TCLink)

    net.start()

    sleep(1)  # time for the host and switch confs to take effect

    # --------- host config in network 1 ---------
    GW_IP = "10.0.1.254"
    GW_MAC = device_mac(2, 1)
    
    host = net.get("h1")
    host.cmd(f"ip route replace default via {GW_IP}")
    host.cmd(f"arp -s {GW_IP} {GW_MAC}")
    
    host = net.get("h2")
    host.cmd(f"ip route replace default via {GW_IP}")
    host.cmd(f"arp -s {GW_IP} {GW_MAC}")

    host = net.get("h3")
    host.cmd(f"ip route replace default via {GW_IP}")
    host.cmd(f"arp -s {GW_IP} {GW_MAC}")

    # --------- host config in network 2 ---------
    GW_IP = "10.0.2.254"
    GW_MAC = device_mac(2, 2)
    
    host = net.get("h4")
    host.cmd(f"ip route replace default via {GW_IP}")
    host.cmd(f"arp -s {GW_IP} {GW_MAC}")
    
    host = net.get("h5")
    host.cmd(f"ip route replace default via {GW_IP}")
    host.cmd(f"arp -s {GW_IP} {GW_MAC}")

    host = net.get("h6")
    host.cmd(f"ip route replace default via {GW_IP}")
    host.cmd(f"arp -s {GW_IP} {GW_MAC}")



    # --------- inject the rules ----------------
    call("simple_switch_CLI --thrift-port 9090 < flows/switch-flows-d1.txt", shell=True)
    call("simple_switch_CLI --thrift-port 9091 < flows/l3s-flows.txt", shell=True)
    call("simple_switch_CLI --thrift-port 9092 < flows/switch-flows-d3.txt", shell=True)
  
    print("Ready !")


    CLI( net )
    net.stop()

if __name__ == '__main__':
    setLogLevel( 'info' )
    main()
