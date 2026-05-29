/* SPDX-License-Identifier: ANCL-1.0
 * Telemetry-Driven Traffic Engineering — Project B
 * s3.p4 — L3 transit router (alternative / long path)
 *
 * Responsibilities:
 *   1. IPv4 routing — LPM forwarding + MAC rewrite (same as lab L3 router)
 *   2. INT transit: if packet carries INT, append own hop entry to the stack
 *
 * This switch is a TRANSIT HOP on the LONG path (s1 → s2 → s3 → s4).
 * It never inserts INT (that is s1's job) and never strips or clones INT
 * (that is s4's job). It simply accumulates its own metadata.
 *
 * Port map:
 *   port 1 — uplink to s2
 *   port 2 — downlink to s4
 *   port 3 — cNF (Docker container via veth pair) ← reserved, not used in P4
 *
 * The cNF on port 3 receives cloned packets from s4 via the network,
 * not directly from s3. Port 3 exists at the topology level but s3's
 * P4 pipeline does not send anything there — that is s4's job via E2E clone.
 */

#include <core.p4>
#include <v1model.p4>
#include "headers.p4"

// ═══════════════════════════════════════════════════════
//  PARSER  (identical to s2)
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

    action drop() {
        mark_to_drop(std_meta);
    }

    // ── L3 forwarding (identical to lab router) ────────

    action forward(bit<9> egressPort, macAddr_t nextHopMac) {
        std_meta.egress_spec = egressPort;
        meta.nextHopMac      = nextHopMac;
        meta.l3_egress_port  = egressPort;  // saved for INT hop entry
        hdr.ipv4.ttl         = hdr.ipv4.ttl - 1;
    }

    table ipv4Lpm {
        key     = { hdr.ipv4.dstAddr : lpm; }
        actions = { forward; drop; }
        size    = 256;
        default_action = drop;
    }

    action rewriteMacs(macAddr_t srcMac) {
        hdr.eth.srcAddr = srcMac;
        hdr.eth.dstAddr = meta.nextHopMac;
    }

    table internalMacLookup {
        key     = { std_meta.egress_spec : exact; }
        actions = { rewriteMacs; drop; }
        size    = 256;
        default_action = drop;
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

    // ── INT accumulation ──────────────────────────────
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

        if (hdr.ipv4.isValid()) {
            // 1. L3 forwarding
            if (ipv4Lpm.apply().hit) {
                internalMacLookup.apply();
            }

            // 2. INT accumulation — after forwarding so l3_egress_port is set
            if (hdr.int_shim.isValid() &&
                hdr.int_shim.hop_count < hdr.int_shim.max_hops) {
                if      (hdr.int_shim.hop_count == 0) { write_hop_0(); }
                else if (hdr.int_shim.hop_count == 1) { write_hop_1(); }
                else if (hdr.int_shim.hop_count == 2) { write_hop_2(); }
                else if (hdr.int_shim.hop_count == 3) { write_hop_3(); }
                else if (hdr.int_shim.hop_count == 4) { write_hop_4(); }
                else if (hdr.int_shim.hop_count == 5) { write_hop_5(); }
                else if (hdr.int_shim.hop_count == 6) { write_hop_6(); }
                else if (hdr.int_shim.hop_count == 7) { write_hop_7(); }
            }

        } else {
            drop();
        }
    }
}

// ═══════════════════════════════════════════════════════
//  EGRESS
// ═══════════════════════════════════════════════════════

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t std_meta) {
    apply { }  // nothing to do — s3 does not clone or strip INT
}

// ═══════════════════════════════════════════════════════
//  CHECKSUM COMPUTATION
// ═══════════════════════════════════════════════════════

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
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

// ═══════════════════════════════════════════════════════
//  DEPARSER
// ═══════════════════════════════════════════════════════

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.eth);
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
