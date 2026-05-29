#!/bin/bash
# SPDX-License-Identifier: ANCL-1.0
# Telemetry-Driven Traffic Engineering — Project B
# run_sim.sh — single entry point to build and launch the full simulation

set -e

mkdir -p logs && chmod 777 logs
mkdir -p build
mkdir -p mininet/run-time

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ── 1. Compile P4 programs ────────────────────────────────────────────────────
echo "Compiling P4 programs..."

p4c-bm2-ss --std p4-16 p4/s1.p4 -o build/s1.json --p4runtime-files build/s1.p4info.txt
p4c-bm2-ss --std p4-16 p4/s2.p4 -o build/s2.json --p4runtime-files build/s2.p4info.txt
p4c-bm2-ss --std p4-16 p4/s3.p4 -o build/s3.json --p4runtime-files build/s3.p4info.txt
p4c-bm2-ss --std p4-16 p4/s4.p4 -o build/s4.json --p4runtime-files build/s4.p4info.txt

echo "Compilation done."

# ── 2. Build cNF Docker image ─────────────────────────────────────────────────
echo "Building INT analyser cNF image..."
docker build -t int-cnf -f ./cNF/Dockerfile.cnf ./cNF
echo "INT analyser image ready."

# ── 3. Launch Mininet in a new terminal ───────────────────────────────────────
echo "Starting Mininet..."
setsid xterm -T "Mininet" -hold -e bash -c "cd ${SCRIPT_DIR} && sudo python3 mininet/my_topo.py; sudo mn -c; docker stop int-cnf 2>/dev/null || true; pkill -f run_controller.py 2>/dev/null || true" &

# ── 4. Wait for all four switch gRPC ports to be ready ───────────────────────
wait_for_port() {
    local port=$1
    local name=$2
    until nc -z 127.0.0.1 "$port" 2>/dev/null; do
        sleep 0.5
    done
    echo "  $name ready (port $port)"
}

echo "Waiting for switches..."
wait_for_port 50051 "s1"
wait_for_port 50052 "s2"
wait_for_port 50053 "s3"
wait_for_port 50054 "s4"

# ── 5. Connect INT analyser cNF to s4 port 6 (Fix 4: was s3 port 3, caused clone loop)
echo "Setting up INT analyser cNF..."

# Clean up leftovers from a previous run
sudo ip link del veth-cnf0 2>/dev/null || true
docker rm -f int-cnf 2>/dev/null || true

# Create veth pair and bring both ends up
sudo ip link add veth-cnf0 type veth peer name veth-cnf1
sudo ip link set veth-cnf0 up
sudo ip link set veth-cnf1 up

# Add veth-cnf0 to s4 as port 6 via Thrift (s4 thrift port = 9093)
echo "port_add veth-cnf0 6" | simple_switch_CLI --thrift-port 9093

# Start the cNF container (no network — we wire the veth manually)
setsid xterm -T "INT cNF" -hold -e bash -c "docker run --name int-cnf --network none --sysctl net.ipv6.conf.all.disable_ipv6=1 --rm -it int-cnf" &

# Wait for the container to be running
until docker inspect -f '{{.State.Running}}' int-cnf 2>/dev/null | grep -q true; do
    sleep 0.2
done

# Move veth-cnf1 into the container's network namespace
CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' int-cnf)
sudo ip link set veth-cnf1 netns "$CONTAINER_PID"

# Rename to veth-cnf1 (matches cnf.yaml) and bring it up inside the container
sudo nsenter -t "$CONTAINER_PID" -n ip link set veth-cnf1 name veth-cnf1
sudo nsenter -t "$CONTAINER_PID" -n ip link set veth-cnf1 up

# Assign IP to the cNF interface (needed to send report packets)
sudo nsenter -t "$CONTAINER_PID" -n ip addr add 10.0.3.1/24 dev veth-cnf1

echo "INT analyser cNF ready on s4 port 6."

# ── 6. Launch the controller ──────────────────────────────────────────────────
echo "Starting controller..."
setsid xterm -T "Controller" -hold -e bash -c "cd ${SCRIPT_DIR} && sudo -u netsim python3 controller/run_controller.py --buildDir build --configDir controller/resources --plugins setup_plugin te_plugin" &

echo ""
echo "========================================"
echo "  Simulation running. Terminals open:"
echo "    - Mininet"
echo "    - INT cNF (analyser logs)"
echo "    - Controller (TE plugin logs)"
echo ""
echo "  To test:"
echo "    mininet> h1 ping h4"
echo "    mininet> h1 ping -f h4   # flood to trigger telemetry"
echo ""
echo "  To stop: Ctrl+C in Mininet terminal"
echo "========================================"