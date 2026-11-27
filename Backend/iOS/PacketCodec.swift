// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// IPv4 / TCP / UDP wire format helpers for the userspace tunnel. Foundation
// only: this file is compiled and tested off-device as well as in the app.

import Foundation

enum PacketCodec {

    // MARK: - Addresses

    static func ipv4String(_ address: UInt32) -> String {
        "\(address >> 24 & 0xFF).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    static func ipv4Address(_ string: String) -> UInt32? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = prefix.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var address: UInt32 = 0
        for part in parts {
            guard let byte = UInt32(part), byte <= 255 else { return nil }
            address = address << 8 | byte
        }
        return address
    }

    // MARK: - Parsing

    /// Parses a raw IPv4 datagram. Returns nil for anything that is not a
    /// well-formed IPv4 packet with a sane header length and total length.
    static func parseIPv4(_ packet: [UInt8]) -> Ipv4Datagram? {
        guard packet.count >= 20 else { return nil }
        guard packet[0] >> 4 == 4 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        guard headerLength >= 20, packet.count >= headerLength else { return nil }
        let totalLength = Int(packet[2]) << 8 | Int(packet[3])
        guard totalLength >= headerLength, totalLength <= packet.count else { return nil }
        // Fragmentation is not handled: the core always sends whole datagrams.
        let fragmentOffset = (UInt16(packet[6] & 0x1F) << 8) | UInt16(packet[7])
        guard packet[6] & 0x3F == 0, fragmentOffset == 0 else { return nil }

        let source = readUInt32(packet, 12)
        let destination = readUInt32(packet, 16)
        let proto = packet[9]
        let body = Array(packet[headerLength..<totalLength])

        let transport: Ipv4Datagram.Transport
        switch proto {
        case 6:
            guard let segment = parseTcp(body) else { return nil }
            transport = .tcp(segment)
        case 17:
            guard let udp = parseUdp(body) else { return nil }
            transport = .udp(udp)
        default:
            transport = .other(proto)
        }
        return Ipv4Datagram(source: source, destination: destination,
                            ttl: packet[8], transport: transport)
    }

    static func parseTcp(_ body: [UInt8]) -> TcpSegment? {
        guard body.count >= 20 else { return nil }
        let headerLength = Int(body[12] >> 4) * 4
        guard headerLength >= 20, body.count >= headerLength else { return nil }
        let dataOffset = body[12] >> 4
        guard dataOffset >= 5 else { return nil }

        var mss: UInt16?
        var windowScale: UInt8?
        if headerLength > 20 {
            var index = 20
            while index < headerLength {
                let kind = body[index]
                if kind == 0 { break }
                if kind == 1 { index += 1; continue }
                guard index + 1 < headerLength else { break }
                let length = Int(body[index + 1])
                guard length >= 2, index + length <= headerLength else { break }
                if kind == 2, length == 4 {
                    mss = UInt16(body[index + 2]) << 8 | UInt16(body[index + 3])
                } else if kind == 3, length == 3 {
                    windowScale = body[index + 2]
                }
                index += length
            }
        }

        return TcpSegment(
            sourcePort: UInt16(body[0]) << 8 | UInt16(body[1]),
            destinationPort: UInt16(body[2]) << 8 | UInt16(body[3]),
            sequence: readUInt32(body, 4),
            acknowledgment: readUInt32(body, 8),
            flags: body[13],
            window: UInt16(body[14]) << 8 | UInt16(body[15]),
            maxSegmentSize: mss,
            windowScale: windowScale,
            payload: Array(body[headerLength...])
        )
    }

    static func parseUdp(_ body: [UInt8]) -> UdpDatagram? {
        guard body.count >= 8 else { return nil }
        let length = Int(body[4]) << 8 | Int(body[5])
        guard length >= 8, length <= body.count else { return nil }
        return UdpDatagram(
            sourcePort: UInt16(body[0]) << 8 | UInt16(body[1]),
            destinationPort: UInt16(body[2]) << 8 | UInt16(body[3]),
            payload: Array(body[8..<length])
        )
    }

    // MARK: - Building

    static func buildUdp(source: UInt32, destination: UInt32,
                         sourcePort: UInt16, destinationPort: UInt16,
                         payload: [UInt8]) -> [UInt8] {
        var body = [UInt8]()
        body.reserveCapacity(8 + payload.count)
        appendUInt16(sourcePort, to: &body)
        appendUInt16(destinationPort, to: &body)
        appendUInt16(UInt16(8 + payload.count), to: &body)
        appendUInt16(0, to: &body)
        body.append(contentsOf: payload)
        // The core never validates the UDP checksum; zero means "not computed"
        // for IPv4 and is accepted by every implementation we bridge.
        return buildIPv4(source: source, destination: destination, proto: 17, body: body)
    }

    static func buildTcp(source: UInt32, destination: UInt32, segment: TcpSegment) -> [UInt8] {
        var body = [UInt8]()
        body.reserveCapacity(20 + segment.payload.count)
        appendUInt16(segment.sourcePort, to: &body)
        appendUInt16(segment.destinationPort, to: &body)
        appendUInt32(segment.sequence, to: &body)
        appendUInt32(segment.acknowledgment, to: &body)
        body.append(5 << 4)
        body.append(segment.flags)
        appendUInt16(segment.window, to: &body)
        appendUInt16(0, to: &body)  // checksum, filled below
        appendUInt16(0, to: &body)  // urgent pointer
        body.append(contentsOf: segment.payload)

        let sum = checksum(pseudoHeader(source: source, destination: destination,
                                        proto: 6, length: body.count), body)
        body[16] = UInt8(sum >> 8)
        body[17] = UInt8(sum & 0xFF)
        return buildIPv4(source: source, destination: destination, proto: 6, body: body)
    }

    static func buildIPv4(source: UInt32, destination: UInt32,
                          proto: UInt8, body: [UInt8]) -> [UInt8] {
        var packet = [UInt8]()
        packet.reserveCapacity(20 + body.count)
        packet.append(0x45)
        packet.append(0)                      // DSCP/ECN
        appendUInt16(UInt16(20 + body.count), to: &packet)
        appendUInt16(0, to: &packet)          // identification (only one sender)
        packet.append(0x40)                   // don't fragment
        packet.append(0)                      // fragment offset
        packet.append(64)                     // TTL
        packet.append(proto)
        appendUInt16(0, to: &packet)          // header checksum placeholder
        appendUInt32(source, to: &packet)
        appendUInt32(destination, to: &packet)
        let headerSum = checksum(packet, [])
        packet[10] = UInt8(headerSum >> 8)
        packet[11] = UInt8(headerSum & 0xFF)
        packet.append(contentsOf: body)
        return packet
    }

    // MARK: - Checksums

    /// Standard ones-complement checksum over an optional pseudo-header
    /// followed by the transport body.
    static func checksum(_ pseudo: [UInt8], _ body: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        let total = pseudo.count + body.count

        func word(_ i: Int) -> UInt32 {
            if i < pseudo.count { return UInt32(pseudo[i]) << 8 }
            return UInt32(body[i - pseudo.count]) << 8
        }
        func second(_ i: Int) -> UInt32 {
            if i + 1 >= total { return 0 }
            if i + 1 < pseudo.count { return UInt32(pseudo[i + 1]) }
            return UInt32(body[i + 1 - pseudo.count])
        }

        while index < total {
            sum &+= word(index) | second(index)
            index += 2
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        checksum([], Array(bytes))
    }

    private static func pseudoHeader(source: UInt32, destination: UInt32,
                                     proto: UInt8, length: Int) -> [UInt8] {
        var header = [UInt8]()
        header.reserveCapacity(12)
        appendUInt32(source, to: &header)
        appendUInt32(destination, to: &header)
        header.append(0)
        header.append(proto)
        appendUInt16(UInt16(length), to: &header)
        return header
    }

    // MARK: - Byte helpers

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24 & 0xFF))
        bytes.append(UInt8(value >> 16 & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8 & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}
