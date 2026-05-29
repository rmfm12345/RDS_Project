/* SPDX-License-Identifier: ANCL-1.0
 * Telemetry-Driven Traffic Engineering — Project B
 * s4.p4 — L2 egress switch
 *
 * Responsibilities:
 *   1. Self-learning L2 forwarding (same as lab 3)
 *   2. INT last hop: append own metadata to the stack
 *   3. Clone the full INT packet to the cNF (port 3 of s3, reached via s3)
 *   4. Strip the INT header and restore original EtherType before delivery
 *
 * This switch is the LAST HOP for traffic towards subnet 2.
 * The clone goes to the cNF; the original is delivered clean to the host.
 *
 * Mirror session IDs:
 *   100 → CPU port   (L2 learning, same as s1)
 *   200 → cNF port   (INT telemetry report)
 */

#include <core.p4>
#include <v1model.p4>
#include "headers.p4"

const bit<32> CPU_MIRROR_SESSION = 100;
const bit<32> CNF_MIRROR_SESSION = 200;   // E2E clone → cNF on s3 port 3

// ═══════════════════════════════════════════════════════
//  PARSER  (identical to s1 — must parse INT stack)
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
            TYPE_INT:  parse_int_shim;
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    state parse_int_shim {
        packet.extract(hdr.int_shim);
        transition parse_int_hops;
    }

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

    // ── L2 learning ───────────────────────────────────

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
        meta.l3_egress_port  = egress_port;
    }

    table dMacLookup {
        key     = { hdr.eth.dstAddr : exact; }
        actions = { forward; NoAction; }
        size    = 512;
        default_action = NoAction;
    }

    // ── Switch ID ─────────────────────────────────────

    action set_switch_id(bit<8> id) {
        meta.switch_id = id;
    }

    table switchIdTable {
        key     = { meta.constant : exact; }
        actions = { set_switch_id; NoAction; }
        size    = 1;
        default_action = NoAction;
    }

    // ── INT last hop: append own metadata ─────────────
    // bmv2 does not support setValid() inside a conditional within an action.
    // One action per hop slot; the apply block dispatches based on hop_count.

    action write_hop_0() {
        hdr.int_hop[0].setValid();
        hdr.int_hop[0].switch_id         = meta.switch_id;
        hdr.int_hop[0].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[0].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[0].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_1() {
        hdr.int_hop[1].setValid();
        hdr.int_hop[1].switch_id         = meta.switch_id;
        hdr.int_hop[1].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[1].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[1].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_2() {
        hdr.int_hop[2].setValid();
        hdr.int_hop[2].switch_id         = meta.switch_id;
        hdr.int_hop[2].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[2].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[2].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_3() {
        hdr.int_hop[3].setValid();
        hdr.int_hop[3].switch_id         = meta.switch_id;
        hdr.int_hop[3].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[3].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[3].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_4() {
        hdr.int_hop[4].setValid();
        hdr.int_hop[4].switch_id         = meta.switch_id;
        hdr.int_hop[4].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[4].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[4].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_5() {
        hdr.int_hop[5].setValid();
        hdr.int_hop[5].switch_id         = meta.switch_id;
        hdr.int_hop[5].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[5].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[5].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_6() {
        hdr.int_hop[6].setValid();
        hdr.int_hop[6].switch_id         = meta.switch_id;
        hdr.int_hop[6].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[6].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[6].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }
    action write_hop_7() {
        hdr.int_hop[7].setValid();
        hdr.int_hop[7].switch_id         = meta.switch_id;
        hdr.int_hop[7].ingress_timestamp = (bit<48>)std_meta.ingress_global_timestamp;
        hdr.int_hop[7].egress_port       = (bit<8>)meta.l3_egress_port;
        hdr.int_hop[7].padding           = 0;
        hdr.int_shim.hop_count           = hdr.int_shim.hop_count + 1;
    }

    apply {
        meta.constant = 1;
        switchIdTable.apply();   // Fix 2: populate meta.switch_id for INT hop entries

        if (hdr.eth.isValid()) {
            sMacLookup.apply();

            if (!dMacLookup.apply().hit) {
                std_meta.mcast_grp = 1;
            }

            // INT last-hop processing
            if (hdr.int_shim.isValid() &&
                hdr.int_shim.hop_count < hdr.int_shim.max_hops) {

                // 1. Append s4's own hop entry to the stack
                if      (hdr.int_shim.hop_count == 0) { write_hop_0(); }
                else if (hdr.int_shim.hop_count == 1) { write_hop_1(); }
                else if (hdr.int_shim.hop_count == 2) { write_hop_2(); }
                else if (hdr.int_shim.hop_count == 3) { write_hop_3(); }
                else if (hdr.int_shim.hop_count == 4) { write_hop_4(); }
                else if (hdr.int_shim.hop_count == 5) { write_hop_5(); }
                else if (hdr.int_shim.hop_count == 6) { write_hop_6(); }
                else if (hdr.int_shim.hop_count == 7) { write_hop_7(); }

                // 2. I2E clone to cNF with full INT stack (before any egress modification).
                //    field_list 0 preserves ingress_port (needed for CPU clone path on
                //    the same clone type).  The two clones are told apart in egress by
                //    std_meta.egress_port: CPU→510, cNF→6.
                clone_preserving_field_list(CloneType.I2E, CNF_MIRROR_SESSION, 0);

                // 3. Mark original for INT stripping in egress
                meta.int_active = 1;
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

    // Strip INT headers from the original packet and restore EtherType.
    // Called only on the original (instance_type == 0) when int_active == 1.
    action strip_int() {
        // INT headers sit between Ethernet and IPv4 — they are NOT inside the
        // IPv4 payload, so ipv4.totalLen was never increased when INT was added
        // and must NOT be decremented here.
        hdr.eth.type = hdr.int_shim.ethertype_orig;  // restore 0x0800

        hdr.int_shim.setInvalid();
        hdr.int_hop[0].setInvalid();
        hdr.int_hop[1].setInvalid();
        hdr.int_hop[2].setInvalid();
        hdr.int_hop[3].setInvalid();
        hdr.int_hop[4].setInvalid();
        hdr.int_hop[5].setInvalid();
        hdr.int_hop[6].setInvalid();
        hdr.int_hop[7].setInvalid();
    }

    apply {
        if (std_meta.instance_type == 1) {
            // ── I2E clone → cNF (port 6): send full INT packet as-is ──
            // Taken in ingress before any stripping; egress_port==6 because
            // CNF_MIRROR_SESSION (200) replicates to port 6.
            if (std_meta.egress_port == (bit<9>)6) {
                return;
            }
            // ── I2E clone → CPU port 510 (L2 learning) ──
            hdr.cpu.setValid();
            hdr.cpu.srcAddr      = hdr.eth.srcAddr;
            hdr.cpu.ingress_port = (bit<16>)meta.ingress_port;
            hdr.eth.type         = 0x1234;
            truncate((bit<32>)22);
            return;
        }

        // ── Original packet: strip INT before delivery to host ──
        if (meta.int_active == 1) {
            strip_int();
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
    apply {
        // Recompute IPv4 checksum after strip_int() modifies totalLen
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.eth);
        // INT stack — the deparser automatically skips invalid headers.
        // For the original packet after strip_int(), all int headers are
        // invalid so nothing is emitted. For the clone, all are valid.
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
