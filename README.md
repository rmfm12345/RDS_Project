# Tutorial 1: Introduction to P4 Programming and Software Defined Networks

Welcome to your first hands-on experience with P4 (Programming Protocol-independent Packet Processors)! This tutorial will introduce you to the fundamental concepts of Software Defined Networks (SDN) and data plane programmability.

## Learning Objectives

By the end of this tutorial, you will:
- Understand the basic architecture of P4-programmable switches
- Learn how to define forwarding behavior using P4
- Implement network devices (hubs and L3 switches) in software
- Work with the P4 toolchain: compiler, runtime, and testing tools
- Gain practical experience with Mininet for network emulation

## Network Topology

In this tutorial, we're working with the following topology:

```
h1 \              / h4
h2 - d1 - d2 - d3 - h5
h3 /              \ h6
```

**Legend:**
- **h1-h6**: Hosts (end devices with IP addresses)
- **d1**: Hub (broadcast device) - P4 implementation
- **d2**: L3 Switch (IP routing device) - P4 implementation
- **d3**: Hub (broadcast device) - P4 implementation

### Device Behavior

**Hubs (d1, d3):**
- Broadcast all incoming packets to all other ports
- Simple, but inefficient (creates unnecessary traffic)
- No learning mechanism
- Operates at Layer 2 (data link layer)

**L3 Switch (d2):**
- Routes packets based on IP addresses
- Makes forwarding decisions using routing tables
- Operates at Layer 3 (network layer)
- Decrements TTL and updates checksums

## Project Structure

```
.
├── Flows/          # Control plane rules for each device
├── json/           # Compiled P4 programs (output from p4c)
├── mininet/        # Network topology definition
│   ├── p4_mininet.py   # P4-Mininet integration (DO NOT MODIFY)
│   └── my_topo.py      # Our topology definition
├── p4/             # P4 source code for network devices
├── tools/          # Debugging and testing utilities
└── README.md       # This file
```

## Running the Tutorial

### Step 1: Compile the P4 Programs

The P4 source files in the `p4/` directory need to be compiled into JSON format that BMv2 can understand:

```bash
sudo sh run_sim.sh
```

This script will:
1. Compile all P4 programs using `p4c`
2. Generate JSON files in the `json/` directory
3. Start Mininet with the defined topology
4. Apply the control plane rules from `Flows/` to each device

### Step 2: Understanding the Code

During class, we'll walk through:

#### P4 Code Structure
- **Headers**: Defining packet structure (Ethernet, IPv4, etc.)
- **Parser**: Extracting fields from incoming packets
- **Actions**: Operations that modify packets or metadata
- **Tables**: Match-action rules for packet processing
- **Control**: The logical flow of packet processing
- **Deparser**: Reassembling packets after processing

#### Hub vs. L3 Switch
- **Hub P4 code**: Simple broadcast logic at Layer 2
- **L3 Switch P4 code**: IP routing tables, TTL decrement, checksum updates

#### Control Plane Rules
- How to populate P4 tables using `simple_switch_CLI`
- Static vs. dynamic rule installation
- The relationship between P4 programs and flow rules

### Step 3: Testing

Once the network is running:

```bash
# Test connectivity between hosts
mininet> h1 ping h4

# Check routing tables
mininet> sh simple_switch_CLI --thrift-port 9091 < l3s-flows.txt

# Verify packet forwarding
mininet> h1 ping -c 3 h6
```

## Homework Assignment

### Objective
Convert the **hub devices (d1 and d3)** to behave as **L2 learning switches**, implementing MAC address learning and selective forwarding.

### What You Need to Do

1. **Modify the P4 Code**
   - Edit the P4 programs for d1 and d3 (currently hubs)
   - Implement MAC address learning tables
   - Implement selective forwarding instead of broadcasting
   - Handle unknown destinations appropriately (flood)
   - Study the differences between L2 and L3 forwarding by comparing with d2

2. **Update Control Plane Rules**
   - Modify the flow files in `Flows/` for d1 and d3
   - Ensure proper table initialization
   - Consider default actions for table misses

3. **Test Your Implementation**
   - Verify that packets are forwarded correctly
   - Confirm that unnecessary broadcasts are eliminated
   - Test with ping and other traffic patterns
   - Verify MAC learning by checking table entries

### Expected Behavior After Your Changes

- **Before (Hub)**: When h1 sends a packet to h2, d1 floods it to all ports (including d2)
- **After (L2 Switch)**:
  - First packet: d1 learns h1's MAC on the ingress port and floods to find h2
  - Subsequent packets: d1 forwards directly to h2's port
  - No unnecessary traffic sent to d2

### Key Concepts to Implement

1. **MAC**: Store source MAC addresses with their ingress ports
2. **Forwarding Decision**: Look up destination MAC in learned table
3. **Unknown Unicast Handling**: Flood when destination is unknown
4. **Broadcast Handling**: Always flood broadcast frames (FF:FF:FF:FF:FF:FF)

### Deliverables

Submit via **GitHub Classroom** a repository containing:

1. **Modified P4 code** for d1 and d3
2. **Updated flow files** for d1 and d3

### Submission Details

- **Deadline**: **February 23, 2026, at 14:00**
- **Method**: Push your changes to the GitHub Classroom repository
- **Required files**:
  - Modified P4 source files
  - Modified flow files
  - Any test scripts you created

### Grading Criteria

- **Correctness** (50%): Does the implementation work as an L2 switch?
- **Code Quality** (50%): Is the code well-structured and commented?

## Hints and Tips

1. **Understand the OSI layers**: d1/d3 will work at L2 (MAC addresses), d2 works at L3 (IP addresses)
2. **MAC learning requires state**: You'll need a table to store learned MAC-to-port mappings
3. **Consider the learning process**: Learn from source, forward based on destination
4. **Test incrementally**: Make small changes and test frequently
5. **Use the tools/** directory for debugging - inspect packet headers and table entries
6. **P4 defines the data plane**: Your P4 code describes packet processing
7. **Control plane populates tables**: Flow rules initialize and manage table state

## Useful Commands

```bash
# Compile a P4 program manually
p4c-bm2-ss --std p4-16  p4/hub.p4 -o json/hub.json

# Connect to a switch's CLI
simple_switch_CLI --thrift-port <PORT>

# Inside switch CLI, show table entries
show_tables
table_dump <table_name>

# Mininet commands
mininet> nodes          # List all nodes
mininet> links          # Show all links
mininet> dump           # Show node details
mininet> pingall        # Test all-to-all connectivity
mininet> h1 ifconfig    # Check host interface configuration
```

## Common Pitfalls

- **Forgetting to recompile** after changing P4 code
- **Port numbering confusion** - remember ports in P4 start from 0
- **Not handling broadcast MAC** addresses (FF:FF:FF:FF:FF:FF) separately
- **Forgetting to set default actions** for tables
- **Confusing L2 and L3 forwarding** - MAC addresses vs. IP addresses
- **Not testing MAC learning** - verify that tables are populated correctly

## Understanding the Layers

This tutorial helps you understand the OSI networking model:

- **Layer 2 (Data Link)**: Your task - MAC-based forwarding, used within a single network segment
- **Layer 3 (Network)**: d2 example - IP-based routing, used between different networks
- **Separation of concerns**: Each layer has specific responsibilities

## Getting Help

- **email me**
- **Documentation**:
  - [P4 Language Spec](https://p4.org/specs/)
  - [P4 Tutorials](https://github.com/p4lang/tutorials)
  - [BMv2 Documentation](https://github.com/p4lang/behavioral-model)
  - [Mininet Documentation](http://mininet.org/)

## Learning Goals Alignment

This tutorial aligns with our course objectives:
- Understanding data plane programmability
- Separating control and data planes
- Implementing network protocols from scratch
- Distinguishing between L2 and L3 forwarding
- Hands-on experience with modern SDN tools

---

**Remember**: Understanding how network devices work at this low level will make you a better network engineer, regardless of whether you use P4 in the future.

