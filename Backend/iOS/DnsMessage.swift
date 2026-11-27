// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Minimal DNS wire-format encoder/decoder for the userspace resolver.
//
// Only what the tunnel needs: build a single-question query (A or AAAA) and
// parse a response well enough to pull IPv4 addresses and the smallest TTL.
// Name compression pointers are followed with strict bounds and loop checks.
// Foundation only so this file is also compiled by the off-device test harness.

import Foundation

enum DnsMessage {

    // MARK: - Query

    /// Builds a standard recursive query (RD=1, one question, QCLASS=IN).
    /// Returns nil when `name` cannot be encoded as a DNS name.
    static func query(id: UInt16, name: String, type: UInt16 = 1) -> [UInt8]? {
        guard let qname = encodeName(name) else { return nil }

        var packet: [UInt8] = []
        packet.reserveCapacity(12 + qname.count + 4)
        PacketCodec.appendUInt16(id, to: &packet)   // ID
        PacketCodec.appendUInt16(0x0100, to: &packet) // RD
        PacketCodec.appendUInt16(1, to: &packet)    // QDCOUNT
        PacketCodec.appendUInt16(0, to: &packet)    // ANCOUNT
        PacketCodec.appendUInt16(0, to: &packet)    // NSCOUNT
        PacketCodec.appendUInt16(0, to: &packet)    // ARCOUNT
        packet.append(contentsOf: qname)
        PacketCodec.appendUInt16(type, to: &packet)
        PacketCodec.appendUInt16(1, to: &packet)    // QCLASS = IN
        return packet
    }

    /// Encodes a dotted name as a sequence of length-prefixed labels plus the
    /// root terminator. A single trailing dot is accepted, empty labels are not.
    static func encodeName(_ name: String) -> [UInt8]? {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        var encoded: [UInt8] = []
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(String(label).utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            encoded.append(UInt8(bytes.count))
            encoded.append(contentsOf: bytes)
        }
        encoded.append(0)
        // The whole QNAME is limited to 255 bytes including length octets.
        guard encoded.count <= 255 else { return nil }
        return encoded
    }

    // MARK: - Response

    /// Parses a DNS response. Returns nil only for malformed packets; a valid
    /// packet carrying an error rcode comes back with an empty `addresses`.
    static func parse(_ packet: [UInt8]) -> DnsResponse? {
        guard packet.count >= 12 else { return nil }

        let id = PacketCodec.readUInt16(packet, 0)
        let flags = PacketCodec.readUInt16(packet, 2)
        let rcode = UInt8(flags & 0x000F)
        let truncated = flags & 0x0200 != 0
        let questionCount = Int(PacketCodec.readUInt16(packet, 4))
        let answerCount = Int(PacketCodec.readUInt16(packet, 6))
        let authorityCount = Int(PacketCodec.readUInt16(packet, 8))

        var offset = 12
        var questionName = ""
        for index in 0..<questionCount {
            guard let (name, next) = decodeName(packet, at: offset) else { return nil }
            if index == 0 { questionName = name }
            offset = next
            guard offset + 4 <= packet.count else { return nil }
            offset += 4 // QTYPE + QCLASS
        }

        var addresses: [UInt32] = []
        var minimumTTL: UInt32 = 0

        // Answers first, then authority records: both sections use the same
        // resource-record layout and both may contain compressed names.
        for section in 0..<2 {
            let count = section == 0 ? answerCount : authorityCount
            for _ in 0..<count {
                guard let (_, afterName) = decodeName(packet, at: offset) else { return nil }
                offset = afterName
                guard offset + 10 <= packet.count else { return nil }
                let type = PacketCodec.readUInt16(packet, offset)
                let klass = PacketCodec.readUInt16(packet, offset + 2)
                let ttl = PacketCodec.readUInt32(packet, offset + 4)
                let length = Int(PacketCodec.readUInt16(packet, offset + 8))
                offset += 10
                guard length <= packet.count - offset else { return nil }

                if section == 0, type == 1, klass == 1, length == 4 {
                    addresses.append(PacketCodec.readUInt32(packet, offset))
                    minimumTTL = addresses.count == 1 ? ttl : min(minimumTTL, ttl)
                }
                offset += length
            }
        }

        return DnsResponse(id: id, rcode: rcode, truncated: truncated,
                           name: questionName, addresses: addresses, ttl: minimumTTL)
    }

    /// Decodes a (possibly compressed) name. Pointers must point strictly
    /// backwards, which both prevents loops and bounds the work per name.
    static func decodeName(_ packet: [UInt8], at start: Int) -> (name: String, next: Int)? {
        guard start >= 0, start < packet.count else { return nil }

        var labels: [String] = []
        var offset = start
        var next = start
        var jumped = false
        var jumps = 0
        var nameLength = 0

        while true {
            guard offset < packet.count else { return nil }
            let length = packet[offset]

            if length == 0 {
                if !jumped { next = offset + 1 }
                break
            }

            if length & 0xC0 == 0xC0 {
                guard offset + 1 < packet.count else { return nil }
                let pointer = Int(length & 0x3F) << 8 | Int(packet[offset + 1])
                guard pointer < packet.count, pointer < offset else { return nil }
                if !jumped { next = offset + 2 }
                jumped = true
                jumps += 1
                guard jumps <= 64 else { return nil }
                offset = pointer
                continue
            }

            // 0x40 and 0x80 are reserved label types.
            guard length & 0xC0 == 0 else { return nil }
            let labelLength = Int(length)
            guard labelLength <= 63, offset + 1 + labelLength <= packet.count else { return nil }
            guard let label = String(bytes: packet[(offset + 1)..<(offset + 1 + labelLength)],
                                     encoding: .utf8) else { return nil }
            nameLength += labelLength + 1
            guard nameLength <= 255 else { return nil }
            labels.append(label)
            offset += 1 + labelLength
        }

        return (labels.joined(separator: "."), next)
    }
}
