/* SPDX-License-Identifier: ANCL-1.0
 * Telemetry-Driven Traffic Engineering — Project B
 * s1.p4 — L2 ingress switch
 *
 * Responsibilities:
 *   1. Self-learning L2 forwarding (same as lab 3)
 *   2. INT marking: if a flow is marked, insert int_shim + first int_hop
 *
 * This switch is the FIRST HOP for traffic from subnet 1.
 * It never strips INT — that is s4's job.
 */

#include <core.p4>
#include <v1model.p4>
#include "headers.p4"

// Clone session IDs
const bit<32> CPU_MIRROR_SESSION = 100;   // L2 learning clone → controller

// ═══════════════════════════════════════════════════════
//  PARSER
// ═══════════════════════════════════════════════════════

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.eth);
        transition select(hdr.eth.type) {
            TYPE_INT:  parse_int_shim;   // already an INT packet (loop or re-entry)
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    // Parse the INT shim to know hop_count — needed even on s1 in case
    // a packet arrives already marked (e.g. returning traffic or test injection)
    state parse_int_shim {
        packet.extract(hdr.int_shim);
        transition parse_int_hops;
    }

    // Parse exactly hop_count int_hop entries.
    // P4 does not support dynamic indexing, so we use a select ladder.
    // Each state extracts one hop and transitions to the next until done.
    state parse_int_hops {
        transition select(hdr.int_shim.hop_count) {
            0: parse_ipv4;
            default: parse_hop_0;
        }
    }

    state parse_hop_0 {
        packet.extract(hdr.int_hop[0]);
        transition select(hdr.int_shim.hop_count) {
            1: parse_ipv4; default: parse_hop_1;
        }
    }
    state parse_hop_1 {
        packet.extract(hdr.int_hop[1]);
        transition select(hdr.int_shim.hop_count) {
            2: parse_ipv4; default: parse_hop_2;
        }
    }
    state parse_hop_2 {
        packet.extract(hdr.int_hop[2]);
        transition select(hdr.int_shim.hop_count) {
            3: parse_ipv4; default: parse_hop_3;
        }
    }
    state parse_hop_3 {
        packet.extract(hdr.int_hop[3]);
        transition select(hdr.int_shim.hop_count) {
            4: parse_ipv4; default: parse_hop_4;
        }
    }
    state parse_hop_4 {
        packet.extract(hdr.int_hop[4]);
        transition select(hdr.int_shim.hop_count) {
            5: parse_ipv4; default: parse_hop_5;
        }
    }
    state parse_hop_5 {
        packet.extract(hdr.int_hop[5]);
        transition select(hdr.int_shim.hop_count) {
            6: parse_ipv4; default: parse_hop_6;
        }
    }
    state parse_hop_6 {
        packet.extract(hdr.int_hop[6]);
        transition select(hdr.int_shim.hop_count) {
            7: parse_ipv4; default: parse_hop_7;
        }
    }
    state parse_hop_7 {
        packet.extract(hdr.int_hop[7]);
        transition parse_ipv4;
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

// ═══════════════════════════════════════════════════════
//  CHECKSUM VERIFICATION
// ═══════════════════════════════════════════════════════

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

// ═══════════════════════════════════════════════════════
//  INGRESS
// ═══════════════════════════════════════════════════════

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t std_meta) {

    // ── L2 learning (identical to lab 3) ──────────────

    action clone_to_cpu() {
        meta.ingress_port = std_meta.ingress_port;
        clone_preserving_field_list(CloneType.I2E, CPU_MIRROR_SESSION, 0);
    }

    table sMacLookup {
        key     = { hdr.eth.srcAddr : exact; }
        actions = { clone_to_cpu; NoAction; }
        size    = 512;
        default_action = clone_to_cpu;
    }

    action forward(bit<9> egress_port) {
        std_meta.egress_spec = egress_port;
        meta.l3_egress_port  = egress_port;  // saved for INT hop entry
    }

    table dMacLookup {
        key     = { hdr.eth.dstAddr : exact; }
        actions = { forward; NoAction; }
        size    = 512;
        default_action = NoAction;
    }

    // ── Switch ID ─────────────────────────────────────
    // Controller installs a single entry (meta.constant=1) to set this
    // switch's ID so INT hop entries carry the correct device identifier.

    action set_switch_id(bit<8> id) {
        meta.switch_id = id;
    }

    table switchIdTable {
        key     = { meta.constant : exact; }
        actions = { set_switch_id; NoAction; }
        size    = 1;
        default_action = NoAction;
    }

    // ── INT marking ───────────────────────────────────
    //
    // The controller installs entries here at runtime to select which
    // flows carry telemetry. Key: (srcAddr, dstAddr) of the IPv4 packet.
    // This table is intentionally separate so the controller can add/remove
    // entries without touching any forwarding logic.

    action mark_int() {
        meta.int_active = 1;
    }

    table intMarkingTable {
        key = {
            hdr.ipv4.srcAddr : ternary;   // Fix 5: ternary supports subnet masks
            hdr.ipv4.dstAddr : ternary;
        }
        actions = { mark_int; NoAction; }
        size    = 256;
        default_action = NoAction;   // unmarked by default
    }

    // ── INT insertion (first hop) ──────────────────────
    //
    // Called only when meta.int_active == 1 and no INT shim exists yet.
    // Inserts int_shim + int_hop[0] between Ethernet and IPv4.

    action insert_int() {
        // Shim
        hdr.int_shim.setValid();
        hdr.int_shim.ethertype_orig = hdr.eth.type;  // save 0x0800
        hdr.int_shim.hop_count      = 1;
        hdr.int_shim.max_hops       = INT_MAX_HOPS;
        hdr.int_shim.padding        = 0;

        // First hop entry
        hdr.int_hop[0].setValid();
        hdr.int_hop[0].switch_id          = meta.switch_id;
        hdr.int_hop[0].ingress_timestamp  = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[0].egress_port        = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[0].padding            = 0;

        // Replace EtherType so downstream switches recognise the INT header
        hdr.eth.type = TYPE_INT;
    }

    apply {
        meta.constant = 1;
        switchIdTable.apply();   // Fix 2: populate meta.switch_id for INT hop entries

        if (hdr.eth.isValid()) {
            sMacLookup.apply();

            if (!dMacLookup.apply().hit) {
                std_meta.mcast_grp = 1;  // unknown dst: flood
            }

            // INT marking — only for IPv4, only if not already marked
            if (hdr.ipv4.isValid() && !hdr.int_shim.isValid()) {
                intMarkingTable.apply();
                if (meta.int_active == 1) {
                    insert_int();
                }
            }

        } else {
            mark_to_drop(std_meta);
        }
    }
}

// ═══════════════════════════════════════════════════════
//  EGRESS
// ═══════════════════════════════════════════════════════

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t std_meta) {

    action drop() {
        mark_to_drop(std_meta);
    }

    apply {
        // CPU clone for L2 learning (identical to lab 3)
        if (std_meta.instance_type == 1) {
            hdr.cpu.setValid();
            hdr.cpu.srcAddr      = hdr.eth.srcAddr;
            hdr.cpu.ingress_port = (bit<16>)meta.ingress_port;
            hdr.eth.type         = 0x1234;
            truncate((bit<32>)22);  // 14 (eth) + 8 (cpu)
        }

        // Drop multicast copies going back out the ingress port
        if (std_meta.egress_port == std_meta.ingress_port) {
            drop();
        }
    }
}

// ═══════════════════════════════════════════════════════
//  CHECKSUM  /  DEPARSER
// ═══════════════════════════════════════════════════════

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.eth);
        // INT headers — only emitted when setValid() was called
        packet.emit(hdr.int_shim);
        packet.emit(hdr.int_hop[0]);
        packet.emit(hdr.int_hop[1]);
        packet.emit(hdr.int_hop[2]);
        packet.emit(hdr.int_hop[3]);
        packet.emit(hdr.int_hop[4]);
        packet.emit(hdr.int_hop[5]);
        packet.emit(hdr.int_hop[6]);
        packet.emit(hdr.int_hop[7]);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.cpu);
    }
}

// ═══════════════════════════════════════════════════════
//  SWITCH
// ═══════════════════════════════════════════════════════

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
