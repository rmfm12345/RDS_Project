/* SPDX-License-Identifier: ANCL-1.0
 * Telemetry-Driven Traffic Engineering — Project B
 * headers.p4 — all header and metadata definitions
 */

// ═══════════════════════════════════════════════════════
//  TYPEDEFs
// ═══════════════════════════════════════════════════════

typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

// ═══════════════════════════════════════════════════════
//  CONSTs — EtherTypes
// ═══════════════════════════════════════════════════════

const bit<16> TYPE_IPV4 = 0x0800;
const bit<16> TYPE_ARP  = 0x0806;
const bit<16> TYPE_INT  = 0x0900;  // our custom INT EtherType

// ═══════════════════════════════════════════════════════
//  CONSTs — INT
// ═══════════════════════════════════════════════════════

const bit<8> INT_MAX_HOPS = 8;     // max hops we can record (fits 4-hop topology + margin)

// ═══════════════════════════════════════════════════════
//  STANDARD HEADERS
// ═══════════════════════════════════════════════════════

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr; 
    bit<16>   type;
}

header arp_t {
    bit<16>   htype;
    bit<16>   ptype;
    bit<8>    hlen;
    bit<8>    plen;
    bit<16>   oper;
    macAddr_t sha;
    ip4Addr_t spa;
    macAddr_t tha;
    ip4Addr_t tpa;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

// ═══════════════════════════════════════════════════════
//  INT HEADERS
// ═══════════════════════════════════════════════════════

// int_shim_t — inserted at the first hop, sits between Ethernet and IPv4.
//
// Wire layout (after Ethernet header, EtherType = 0x0900):
//
//   ┌────────────────┬────────────────┬───────────────┬───────────────┐
//   │  ethertype_orig│   hop_count    │   max_hops    │    padding    │
//   │    (16 bits)   │   (8 bits)     │   (8 bits)    │   (8 bits)    │
//   └────────────────┴────────────────┴───────────────┴───────────────┘
//   Total: 48 bits = 6 bytes
//
// ethertype_orig: the original EtherType (e.g. 0x0800 for IPv4) so the
//                 last hop can restore it when stripping the INT header.
// hop_count:      how many int_hop_t entries have been appended so far.
//                 Incremented by each transit switch.
// max_hops:       ceiling for hop_count (set to INT_MAX_HOPS at ingress).
//                 Prevents runaway accumulation on loops.
// padding:        reserved, set to 0.

header int_shim_t {
    bit<16> ethertype_orig; 
    bit<8>  hop_count;
    bit<8>  max_hops;
    bit<8>  padding;
}
// int_shim_t size: 16+8+8+8 = 48 bits = 6 bytes ✓

// int_hop_t — appended by each switch that processes the packet.
//
// Fixed size per hop:
//
//   ┌───────────┬──────────────────────────┬──────────────┬───────────┐
//   │ switch_id │    ingress_timestamp     │  egress_port │  padding  │
//   │  (8 bits) │       (48 bits)          │   (8 bits)   │  (8 bits) │
//   └───────────┴──────────────────────────┴──────────────┴───────────┘
//
// Design note: egress_timestamp is NOT included because in v1model the
// egress timestamp is only available in the egress pipeline, after the
// deparser has already run — we cannot write into already-emitted headers.
// Latency per hop is approximated as:
//   latency ≈ ingress_timestamp[hop+1] - ingress_timestamp[hop]

header int_hop_t {
    bit<8>  switch_id;
    bit<48> ingress_timestamp;
    bit<8>  egress_port;
    bit<8>  padding;
}
// int_hop_t size: 8+48+8+8 = 72 bits → + 8 padding = 80 bits = 10 bytes

// ═══════════════════════════════════════════════════════
//  CPU HEADER  (for PacketIn to controller)
// ═══════════════════════════════════════════════════════

header cpu_t {
    macAddr_t srcAddr;
    bit<16>   ingress_port;
}

// ═══════════════════════════════════════════════════════
//  STRUCT headers
// ═══════════════════════════════════════════════════════

struct headers {
    ethernet_t   eth;         
    int_shim_t   int_shim;
    int_hop_t[8] int_hop;
    ipv4_t       ipv4;
    arp_t        arp;
    cpu_t        cpu;
}

// ═══════════════════════════════════════════════════════
//  STRUCT metadata
// ═══════════════════════════════════════════════════════

struct metadata {
    @field_list(0)
    bit<9>    ingress_port;
    bit<8>    switch_id;
    bit<1>    int_active;
    bit<9>    l3_egress_port;
    macAddr_t nextHopMac;   // Fix 1: used by L3 forward() in s2/s3
    bit<8>    constant;     // Fix 2: key for switchIdTable (set to 1 at ingress)
    @field_list(1)
    bit<1>    is_cnf_clone; // set to 1 in s4 ingress before I2E clone to cNF
}
