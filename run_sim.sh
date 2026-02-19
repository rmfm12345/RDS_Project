#!/usr/bin/bash
set -e

p4c-bm2-ss --std p4-16  p4/hub.p4 -o json/hub.json
p4c-bm2-ss --std p4-16  p4/l3s.p4 -o json/l3s.json

sudo python3 mininet/my_topo.py