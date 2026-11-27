// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Linux-заглушки для типов, которые в приложении поставляют TcpStack.swift,
// UdpNat.swift и DnsMessage.swift (их пишет другой агент, мы их не трогаем).
//
// Нужны только для того, чтобы Foundation-only файлы (TunnelTypes.swift,
// PacketCodec.swift, Ipv4Routing.swift, IncyConfig.swift) собрались и
// протестировались вне Xcode. В продуктовую сборку этот файл не входит.

import Foundation

// MARK: - TcpStack / UdpNat

final class TcpStack: TunnelTcpStack {
    let localAddress: UInt32
    let send: ([UInt8]) -> Void

    init(localAddress: UInt32, send: @escaping ([UInt8]) -> Void) {
        self.localAddress = localAddress
        self.send = send
    }

    func open(remote: IPv4Endpoint, timeout: TimeInterval,
              onEvent: @escaping (TunnelTcpEvent) -> Void) -> TunnelTcpConnection {
        StubTcpConnection(remote: remote)
    }

    func handle(_ datagram: Ipv4Datagram) {}
    func tick() {}
    func closeAll() {}
    var connectionCount: Int { 0 }
}

final class StubTcpConnection: TunnelTcpConnection {
    let remote: IPv4Endpoint
    private(set) var bytesIn: UInt64 = 0
    private(set) var bytesOut: UInt64 = 0
    var localPort: UInt16 { 0 }

    init(remote: IPv4Endpoint) {
        self.remote = remote
    }

    func send(_ bytes: [UInt8]) {
        bytesOut += UInt64(bytes.count)
    }

    func close() {}
    func abort() {}
}

final class UdpNat: TunnelUdpNat {
    let localAddress: UInt32
    let send: ([UInt8]) -> Void

    init(localAddress: UInt32, send: @escaping ([UInt8]) -> Void) {
        self.localAddress = localAddress
        self.send = send
    }

    func open(remote: IPv4Endpoint, onData: @escaping ([UInt8]) -> Void,
              onClosed: @escaping () -> Void) -> TunnelUdpFlow {
        StubUdpFlow()
    }

    func handle(_ datagram: Ipv4Datagram) {}
    func closeAll() {}
    var flowCount: Int { 0 }
}

final class StubUdpFlow: TunnelUdpFlow {
    var localPort: UInt16 { 0 }
    func send(_ payload: [UInt8]) {}
    func close() {}
}

// MARK: - DnsMessage

/// Минимальная подделка DNS-кодера: собирает запрос и разбирает ответ ровно
/// настолько, насколько это нужно чистым тестам. Продуктовый DnsMessage
/// живёт в DnsMessage.swift и имеет тот же публичный вид.
enum DnsMessage {

    /// Собирает запрос. nil — для некорректного имени (как в продуктовом коде).
    static func query(id: UInt16, name: String, type: UInt16 = 1) -> [UInt8]? {
        guard let qname = encodeName(name) else { return nil }
        var packet: [UInt8] = []
        packet.append(UInt8(id >> 8))
        packet.append(UInt8(id & 0xFF))
        packet.append(0x01)  // RD
        packet.append(0x00)
        packet.append(0x00)  // QDCOUNT
        packet.append(0x01)
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0])
        packet.append(contentsOf: qname)
        packet.append(UInt8(type >> 8))
        packet.append(UInt8(type & 0xFF))
        packet.append(contentsOf: [0x00, 0x01])  // IN
        return packet
    }

    static func parse(_ packet: [UInt8]) -> DnsResponse? {
        guard packet.count >= 12 else { return nil }
        let id = UInt16(packet[0]) << 8 | UInt16(packet[1])
        let flags = UInt16(packet[2]) << 8 | UInt16(packet[3])
        let rcode = UInt8(flags & 0x0F)
        let truncated = flags & 0x0200 != 0
        let questions = Int(packet[4]) << 8 | Int(packet[5])
        let answers = Int(packet[6]) << 8 | Int(packet[7])

        var offset = 12
        var name = ""
        for _ in 0..<questions {
            guard let (parsed, next) = decodeName(packet, at: offset) else { return nil }
            name = parsed
            offset = next + 4  // QTYPE + QCLASS
            guard offset <= packet.count else { return nil }
        }

        var addresses: [UInt32] = []
        var ttl: UInt32 = 0
        for _ in 0..<answers {
            guard let (_, next) = decodeName(packet, at: offset) else { return nil }
            offset = next
            guard offset + 10 <= packet.count else { return nil }
            let type = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
            let recordTTL = PacketCodec.readUInt32(packet, offset + 4)
            let length = Int(packet[offset + 8]) << 8 | Int(packet[offset + 9])
            offset += 10
            guard offset + length <= packet.count else { return nil }
            if type == 1, length == 4 {
                addresses.append(PacketCodec.readUInt32(packet, offset))
                if ttl == 0 || recordTTL < ttl { ttl = recordTTL }
            }
            offset += length
        }
        return DnsResponse(id: id, rcode: rcode, truncated: truncated,
                           name: name, addresses: addresses, ttl: ttl)
    }

    static func encodeName(_ name: String) -> [UInt8]? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }
        var output: [UInt8] = []
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63 else { return nil }
            output.append(UInt8(label.utf8.count))
            output.append(contentsOf: Array(label.utf8))
        }
        guard output.count + 1 <= 255 else { return nil }
        output.append(0)
        return output
    }

    static func decodeName(_ packet: [UInt8], at start: Int) -> (String, Int)? {
        var offset = start
        var labels: [String] = []
        while true {
            guard offset < packet.count else { return nil }
            let length = Int(packet[offset])
            if length == 0 {
                offset += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < packet.count else { return nil }
                let pointer = (length & 0x3F) << 8 | Int(packet[offset + 1])
                guard let (suffix, _) = decodeName(packet, at: pointer) else { return nil }
                labels.append(suffix)
                offset += 2
                return (labels.joined(separator: "."), offset)
            }
            guard offset + 1 + length <= packet.count else { return nil }
            guard let label = String(bytes: packet[(offset + 1)..<(offset + 1 + length)],
                                     encoding: .utf8) else { return nil }
            labels.append(label)
            offset += 1 + length
        }
        return (labels.joined(separator: "."), offset)
    }
}
