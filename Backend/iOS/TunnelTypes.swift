// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Types shared by the iOS userspace tunnel: packet pump, TCP stack, UDP NAT,
// DNS resolver and SOCKS5 frontend. Foundation only so the pure parts can be
// built and tested off-device.

import Foundation

/// IPv4 address (host byte order) with a transport port.
struct IPv4Endpoint: Hashable, CustomStringConvertible {
    var address: UInt32
    var port: UInt16

    var description: String {
        "\(PacketCodec.ipv4String(address)):\(port)"
    }
}

/// Parsed IPv4 datagram. The current core only speaks IPv4; anything else is
/// dropped by `PacketCodec.parseIPv4`.
struct Ipv4Datagram {
    enum Transport {
        case tcp(TcpSegment)
        case udp(UdpDatagram)
        case other(UInt8)
    }

    var source: UInt32
    var destination: UInt32
    var ttl: UInt8
    var transport: Transport
}

struct UdpDatagram {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]

    var source: IPv4Endpoint { IPv4Endpoint(address: 0, port: sourcePort) }
}

struct TcpSegment {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10

    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequence: UInt32
    var acknowledgment: UInt32
    var flags: UInt8
    var window: UInt16
    var maxSegmentSize: UInt16?
    var windowScale: UInt8?
    var payload: [UInt8]

    func isSet(_ flag: UInt8) -> Bool { flags & flag == flag }

    var describesFin: Bool { isSet(TcpSegment.fin) }
    var describesSyn: Bool { isSet(TcpSegment.syn) }
    var describesRst: Bool { isSet(TcpSegment.rst) }
    var describesAck: Bool { isSet(TcpSegment.ack) }
    var describesPsh: Bool { isSet(TcpSegment.psh) }
}

// MARK: - Events

enum TunnelTcpEvent {
    case connected
    case data([UInt8])
    case closed
    case failed(String)
}

// MARK: - Pure stack contracts

protocol TunnelTcpConnection: AnyObject {
    var localPort: UInt16 { get }
    var remote: IPv4Endpoint { get }
    var bytesIn: UInt64 { get }
    var bytesOut: UInt64 { get }
    func send(_ bytes: [UInt8])
    func close()
    func abort()
}

protocol TunnelTcpStack: AnyObject {
    /// Reserves a local port and starts a handshake. The returned connection
    /// must be retained by the caller until it reports `.closed`/`.failed`.
    func open(remote: IPv4Endpoint, timeout: TimeInterval,
              onEvent: @escaping (TunnelTcpEvent) -> Void) -> TunnelTcpConnection
    func handle(_ datagram: Ipv4Datagram)
    /// Drives retransmission/close timers. Called by the platform layer.
    func tick()
    func closeAll()
    var connectionCount: Int { get }
}

protocol TunnelUdpFlow: AnyObject {
    var localPort: UInt16 { get }
    func send(_ payload: [UInt8])
    func close()
}

protocol TunnelUdpNat: AnyObject {
    func open(remote: IPv4Endpoint, onData: @escaping ([UInt8]) -> Void,
              onClosed: @escaping () -> Void) -> TunnelUdpFlow
    func handle(_ datagram: Ipv4Datagram)
    func closeAll()
    var flowCount: Int { get }
}

enum TunnelStackFactory {
    static func makeTcpStack(localAddress: UInt32, send: @escaping ([UInt8]) -> Void) -> TunnelTcpStack {
        TcpStack(localAddress: localAddress, send: send)
    }

    static func makeUdpNat(localAddress: UInt32, send: @escaping ([UInt8]) -> Void) -> TunnelUdpNat {
        UdpNat(localAddress: localAddress, send: send)
    }
}

// MARK: - DNS wire format

struct DnsResponse {
    var id: UInt16
    var rcode: UInt8
    var truncated: Bool
    var name: String
    var addresses: [UInt32]
    var ttl: UInt32
}

enum TunnelError: Error, LocalizedError {
    case invalidPacket(String)
    case tcpConnectionFailed(String)
    case tcpTimeout
    case resolverFailure(String)
    case proxyFailure(String)
    case tunnelNotReady

    var errorDescription: String? {
        switch self {
        case .invalidPacket(let detail): return "invalid packet: \(detail)"
        case .tcpConnectionFailed(let detail): return "connection failed: \(detail)"
        case .tcpTimeout: return "connection timed out"
        case .resolverFailure(let detail): return "DNS resolution failed: \(detail)"
        case .proxyFailure(let detail): return "SOCKS5 proxy error: \(detail)"
        case .tunnelNotReady: return "tunnel is not ready"
        }
    }
}
