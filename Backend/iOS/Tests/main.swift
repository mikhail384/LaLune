// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Self-contained test suite for the userspace tunnel data plane.
// No XCTest: the script `run-tests.sh` compiles the production sources with
// this file as the entry point and runs the resulting binary on Linux.
//
// The harness plays the remote peer: it collects every datagram the stack
// emits, validates its IPv4/TCP encoding independently and feeds crafted
// segments back through `stack.handle`. Time is a manual clock, so timeout
// scenarios run instantly and deterministically.

import Foundation

// MARK: - Test plumbing

var checkCount = 0
var failureCount = 0
var currentTest = ""

func check(_ condition: Bool, _ label: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("  FAIL [\(currentTest)] \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("  FAIL [\(currentTest)] \(label): got \(actual), expected \(expected)")
    }
}

func run(_ name: String, _ body: () -> Void) {
    currentTest = name
    print("• \(name)")
    body()
}

let testLocalIP = PacketCodec.ipv4Address("10.66.67.12")!
let testPeerIP = PacketCodec.ipv4Address("93.184.216.34")!
let testRemoteDNS = PacketCodec.ipv4Address("8.8.8.8")!
let testOtherDNS = PacketCodec.ipv4Address("9.9.9.9")!

// MARK: - Independent wire validation

/// One's complement sum used to verify checksums without touching PacketCodec's
/// own checksum helper.
func onesComplementSum(_ bytes: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < bytes.count {
        sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
        index += 2
    }
    if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16)
    }
    return sum
}

func ipv4HeaderChecksumValid(_ packet: [UInt8]) -> Bool {
    guard packet.count >= 20, packet[0] >> 4 == 4 else { return false }
    let headerLength = Int(packet[0] & 0x0F) * 4
    guard headerLength >= 20, headerLength <= packet.count else { return false }
    return onesComplementSum(Array(packet[0..<headerLength])) == 0xFFFF
}

func tcpChecksumValid(_ packet: [UInt8]) -> Bool {
    guard packet.count >= 40, packet[0] >> 4 == 4, packet[9] == 6 else { return false }
    let headerLength = Int(packet[0] & 0x0F) * 4
    let totalLength = Int(packet[2]) << 8 | Int(packet[3])
    guard headerLength >= 20, totalLength >= headerLength + 20,
          totalLength <= packet.count else { return false }

    var pseudo: [UInt8] = Array(packet[12..<20])
    pseudo.append(0)
    pseudo.append(6)
    let tcpLength = totalLength - headerLength
    pseudo.append(UInt8((tcpLength >> 8) & 0xFF))
    pseudo.append(UInt8(tcpLength & 0xFF))
    let segment = Array(packet[headerLength..<totalLength])
    return onesComplementSum(pseudo + segment) == 0xFFFF
}

// MARK: - Simulation harness

final class Outbox {
    var raw: [[UInt8]] = []
    var clock: TimeInterval = 1000
}

struct SentPacket {
    let raw: [UInt8]
    let datagram: Ipv4Datagram
    let segment: TcpSegment
}

/// Plays the remote TCP peer and owns one `TcpStack`.
final class Sim {
    let outbox: Outbox
    let stack: TcpStack
    let configuration: TcpStack.Configuration

    var localPort: UInt16 = 0
    var peerPort: UInt16 = 443
    private(set) var localISN: UInt32 = 0

    private(set) var events: [String] = []
    private(set) var received: [UInt8] = []
    private(set) var dataChunks: [[UInt8]] = []

    static func testConfiguration() -> TcpStack.Configuration {
        var config = TcpStack.Configuration()
        config.initialRTO = 0.2
        config.maximumRTO = 0.8
        config.connectTimeout = 2.0
        config.halfOpenTimeout = 2.0
        config.idleTimeout = 5.0
        config.timeWaitTimeout = 1.0
        config.zeroWindowProbeInterval = 0.1
        config.maximumZeroWindowProbeInterval = 0.4
        return config
    }

    init(configuration: TcpStack.Configuration = Sim.testConfiguration()) {
        let box = Outbox()
        self.outbox = box
        self.configuration = configuration
        self.stack = TcpStack(localAddress: testLocalIP,
                              send: { packet in box.raw.append(packet) },
                              configuration: configuration,
                              clock: { box.clock })
    }

    // MARK: Events

    private func record(_ event: TunnelTcpEvent) {
        switch event {
        case .connected:
            events.append("connected")
        case .data(let bytes):
            events.append("data(\(bytes.count))")
            received.append(contentsOf: bytes)
            dataChunks.append(bytes)
        case .closed:
            events.append("closed")
        case .failed(let reason):
            events.append("failed(\(reason))")
        }
    }

    // MARK: Stack access

    @discardableResult
    func open(remotePort: UInt16 = 443, timeout: TimeInterval = 2.0,
              remoteAddress: UInt32 = testPeerIP) -> TunnelTcpConnection {
        peerPort = remotePort
        return stack.open(remote: IPv4Endpoint(address: remoteAddress, port: remotePort),
                          timeout: timeout) { [weak self] event in
            self?.record(event)
        }
    }

    func advance(_ seconds: TimeInterval) { outbox.clock += seconds }
    func tick() { stack.tick() }

    // MARK: Outbound inspection

    func peek() -> [SentPacket] {
        outbox.raw.compactMap { raw in
            guard let datagram = PacketCodec.parseIPv4(raw),
                  case .tcp(let segment) = datagram.transport else { return nil }
            return SentPacket(raw: raw, datagram: datagram, segment: segment)
        }
    }

    func take() -> [SentPacket] {
        let rawPackets = outbox.raw
        outbox.raw.removeAll()
        var packets: [SentPacket] = []
        for raw in rawPackets {
            guard let datagram = PacketCodec.parseIPv4(raw),
                  case .tcp(let segment) = datagram.transport else {
                check(false, "emitted packet is not a valid IPv4/TCP datagram")
                continue
            }
            check(ipv4HeaderChecksumValid(raw), "ipv4 header checksum")
            check(tcpChecksumValid(raw), "tcp checksum")
            check(datagram.source == testLocalIP, "source is the tunnel address")
            check(datagram.destination == testPeerIP, "destination is the peer")
            packets.append(SentPacket(raw: raw, datagram: datagram, segment: segment))
        }
        return packets
    }

    func takeData() -> [SentPacket] {
        take().filter { !$0.segment.payload.isEmpty }
    }

    // MARK: Peer injection

    /// Encodes a peer segment, optionally with MSS/window-scale options.
    func encodePeerSegment(_ segment: TcpSegment, mss: UInt16?, windowScale: UInt8?) -> [UInt8] {
        var options: [UInt8] = []
        if let mss = mss {
            options += [2, 4, UInt8(mss >> 8), UInt8(mss & 0xFF)]
        }
        if let scale = windowScale {
            options += [3, 3, scale]
        }
        while options.count % 4 != 0 { options.append(1) }

        if options.isEmpty {
            return PacketCodec.buildTcp(source: testPeerIP, destination: testLocalIP, segment: segment)
        }

        var body: [UInt8] = []
        PacketCodec.appendUInt16(segment.sourcePort, to: &body)
        PacketCodec.appendUInt16(segment.destinationPort, to: &body)
        PacketCodec.appendUInt32(segment.sequence, to: &body)
        PacketCodec.appendUInt32(segment.acknowledgment, to: &body)
        body.append(UInt8((20 + options.count) / 4) << 4)
        body.append(segment.flags)
        PacketCodec.appendUInt16(segment.window, to: &body)
        PacketCodec.appendUInt16(0, to: &body)
        PacketCodec.appendUInt16(0, to: &body)
        body.append(contentsOf: options)
        body.append(contentsOf: segment.payload)

        var pseudo: [UInt8] = []
        PacketCodec.appendUInt32(testPeerIP, to: &pseudo)
        PacketCodec.appendUInt32(testLocalIP, to: &pseudo)
        pseudo.append(0)
        pseudo.append(6)
        PacketCodec.appendUInt16(UInt16(body.count), to: &pseudo)
        let sum = PacketCodec.checksum(pseudo, body)
        body[16] = UInt8(sum >> 8)
        body[17] = UInt8(sum & 0xFF)
        return PacketCodec.buildIPv4(source: testPeerIP, destination: testLocalIP, proto: 6, body: body)
    }

    func peerPacket(seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16 = 65535,
                    payload: [UInt8] = [], mss: UInt16? = nil, windowScale: UInt8? = nil,
                    sourcePort: UInt16? = nil, destinationPort: UInt16? = nil) -> [UInt8] {
        let segment = TcpSegment(sourcePort: sourcePort ?? peerPort,
                                 destinationPort: destinationPort ?? localPort,
                                 sequence: seq,
                                 acknowledgment: ack,
                                 flags: flags,
                                 window: window,
                                 maxSegmentSize: nil,
                                 windowScale: nil,
                                 payload: payload)
        return encodePeerSegment(segment, mss: mss, windowScale: windowScale)
    }

    func inject(_ packet: [UInt8]) {
        guard let datagram = PacketCodec.parseIPv4(packet) else {
            check(false, "peer packet failed to parse")
            return
        }
        stack.handle(datagram)
    }

    func injectPeer(seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16 = 65535,
                    payload: [UInt8] = [], mss: UInt16? = nil, windowScale: UInt8? = nil) {
        inject(peerPacket(seq: seq, ack: ack, flags: flags, window: window,
                          payload: payload, mss: mss, windowScale: windowScale))
    }

    // MARK: Handshake

    struct Handshake {
        let connection: TunnelTcpConnection
        let syn: SentPacket
        let ack: SentPacket
        let localISN: UInt32
        let peerISN: UInt32
        var firstDataSeq: UInt32 { localISN &+ 1 }
    }

    func handshake(remotePort: UInt16 = 443, peerMSS: UInt16 = 1300,
                   peerWindowScale: UInt8? = nil, peerWindow: UInt16 = 65535,
                   timeout: TimeInterval = 2.0) -> Handshake? {
        let connection = open(remotePort: remotePort, timeout: timeout)
        let synPackets = take()
        guard synPackets.count == 1 else {
            check(false, "handshake expected one SYN, got \(synPackets.count)")
            return nil
        }
        let syn = synPackets[0]
        localPort = syn.segment.sourcePort
        localISN = syn.segment.sequence

        let peerISN: UInt32 = 0x7F3A_0001
        injectPeer(seq: peerISN, ack: localISN &+ 1,
                   flags: TcpSegment.syn | TcpSegment.ack,
                   window: peerWindow, mss: peerMSS, windowScale: peerWindowScale)
        let ackPackets = take()
        guard let ack = ackPackets.first else {
            check(false, "handshake expected an ACK after SYN-ACK")
            return nil
        }
        return Handshake(connection: connection, syn: syn, ack: ack,
                         localISN: localISN, peerISN: peerISN)
    }
}

// MARK: - TCP: handshake

func testHandshake() {
    let sim = Sim()
    let connection = sim.open(remotePort: 443, timeout: 2.0)
    let synPackets = sim.take()
    checkEqual(synPackets.count, 1, "exactly one SYN")
    guard let syn = synPackets.first else { return }

    check(syn.segment.describesSyn, "SYN flag set")
    check(!syn.segment.describesAck, "SYN carries no ACK")
    check(syn.segment.payload.isEmpty, "SYN carries no payload")
    checkEqual(syn.segment.maxSegmentSize, 1300, "MSS option present")
    checkEqual(syn.segment.windowScale, 4, "window scale option present")
    checkEqual(syn.segment.window, 16384, "SYN advertises unscaled window")
    checkEqual(syn.segment.destinationPort, 443, "destination port")
    check((49152...65535).contains(syn.segment.sourcePort), "ephemeral local port")

    sim.localPort = syn.segment.sourcePort
    let localISN = syn.segment.sequence
    let peerISN: UInt32 = 0x4455_6677
    sim.injectPeer(seq: peerISN, ack: localISN &+ 1,
                   flags: TcpSegment.syn | TcpSegment.ack,
                   window: 65535, mss: 536, windowScale: 7)

    let ackPackets = sim.take()
    checkEqual(ackPackets.count, 1, "exactly one handshake ACK")
    guard let ack = ackPackets.first else { return }
    check(ack.segment.describesAck, "handshake ACK flag")
    check(!ack.segment.describesSyn, "handshake packet is not a SYN")
    checkEqual(ack.segment.sequence, localISN &+ 1, "ACK sequence")
    checkEqual(ack.segment.acknowledgment, peerISN &+ 1, "ACK number")
    checkEqual(sim.events, ["connected"], "connected event delivered once")
    checkEqual(sim.stack.connectionCount, 1, "connection registered")
    _ = connection

    // A stale duplicate SYN-ACK must not break the established connection.
    sim.injectPeer(seq: peerISN, ack: localISN &+ 1,
                   flags: TcpSegment.syn | TcpSegment.ack, window: 65535)
    _ = sim.take()
    checkEqual(sim.stack.connectionCount, 1, "duplicate SYN-ACK ignored")
    checkEqual(sim.events, ["connected"], "no duplicate connected event")
}

// MARK: - TCP: outbound data

func testOutboundDataSlicing() {
    let sim = Sim()
    guard let hs = sim.handshake(peerMSS: 536) else { return }

    var payload: [UInt8] = []
    for index in 0..<2000 { payload.append(UInt8(index & 0xFF)) }
    hs.connection.send(payload)

    let packets = sim.take()
    checkEqual(packets.count, 4, "2000 bytes split by peer MSS 536")
    checkEqual(packets.map { $0.segment.payload.count }, [536, 536, 536, 392], "segment sizes")
    checkEqual(packets.map { $0.segment.sequence },
               [hs.firstDataSeq,
                hs.firstDataSeq &+ 536,
                hs.firstDataSeq &+ 1072,
                hs.firstDataSeq &+ 1608],
               "segment sequence numbers")
    for packet in packets {
        check(packet.segment.describesPsh, "data segments set PSH")
        check(packet.segment.describesAck, "data segments set ACK")
    }
    checkEqual(packets.flatMap { $0.segment.payload }, payload, "payload is intact")
    checkEqual(hs.connection.bytesOut, 2000, "bytesOut accounting")

    // Acknowledge everything: no retransmission may follow.
    let lastEnd = hs.firstDataSeq &+ 2000
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: lastEnd, flags: TcpSegment.ack, window: 65535)
    _ = sim.take()
    sim.advance(2.0)
    sim.tick()
    checkEqual(sim.take().count, 0, "no retransmission after full ACK")

    // Peer MSS larger than ours is capped at 1300.
    let sim2 = Sim()
    guard let hs2 = sim2.handshake(peerMSS: 9000) else { return }
    hs2.connection.send([UInt8](repeating: 0x5A, count: 2600))
    let capped = sim2.take()
    checkEqual(capped.map { $0.segment.payload.count }, [1300, 1300], "peer MSS capped at 1300")
    checkEqual(capped.map { $0.segment.sequence },
               [hs2.firstDataSeq, hs2.firstDataSeq &+ 1300], "capped sequence numbers")
}

func testWindowScaleOnData() {
    let sim = Sim()
    guard let hs = sim.handshake(peerMSS: 1300, peerWindowScale: 3, peerWindow: 100) else { return }
    // 100 << 3 = 800 bytes of window.
    hs.connection.send([UInt8](repeating: 1, count: 1000))
    let packets = sim.take()
    checkEqual(packets.map { $0.segment.payload.count }, [800], "scaled peer window respected")
}

// MARK: - TCP: inbound data

func testInboundData() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    let first = [UInt8](repeating: 0xAA, count: 100)
    let second = [UInt8](repeating: 0xBB, count: 50)
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: first)
    sim.injectPeer(seq: hs.peerISN &+ 101, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: second)

    checkEqual(sim.received, first + second, "in-order payload delivered")
    checkEqual(sim.events, ["connected", "data(100)", "data(50)"], "data events")
    checkEqual(hs.connection.bytesIn, 150, "bytesIn accounting")

    let acks = sim.take()
    checkEqual(acks.count, 2, "one ACK per inbound segment")
    checkEqual(acks[0].segment.acknowledgment, hs.peerISN &+ 101, "first ACK number")
    checkEqual(acks[1].segment.acknowledgment, hs.peerISN &+ 151, "second ACK number")
    check(acks.allSatisfy { $0.segment.describesAck }, "ACKs carry the ACK flag")
    check(acks.allSatisfy { $0.segment.payload.isEmpty }, "ACKs carry no payload")
}

func testOutOfOrderReassembly() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    let partA = [UInt8](repeating: 0x11, count: 100)
    let partB = [UInt8](repeating: 0x22, count: 50)

    // Deliver the second half first.
    sim.injectPeer(seq: hs.peerISN &+ 101, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: partB)
    check(sim.received.isEmpty, "out-of-order segment is not delivered")
    let gapAck = sim.take()
    checkEqual(gapAck.first?.segment.acknowledgment, hs.peerISN &+ 1, "gap ACK repeats rcv_nxt")

    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: partA)
    checkEqual(sim.received, partA + partB, "reassembly delivers in sequence order")
    checkEqual(sim.dataChunks.count, 2, "delivery is split at the reassembly boundary")

    // Duplicate of the first segment must not be delivered twice.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: partA)
    checkEqual(sim.received, partA + partB, "duplicate segment discarded")

    // Overlapping retransmission: the part below rcv_nxt is dropped, the tail
    // that extends past it is delivered.
    let overlapStart = hs.peerISN &+ 120
    let overlap = [UInt8](repeating: 0x33, count: 40)
    sim.injectPeer(seq: overlapStart, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: overlap)
    let alreadyDelivered = 151 - 120   // rcv_nxt was peerISN + 151
    checkEqual(sim.received, partA + partB + Array(overlap[alreadyDelivered...]),
               "only the new tail of an overlapping segment is delivered")
    _ = sim.take()

    // A segment entirely below rcv_nxt is dropped outright.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh,
                   payload: [UInt8](repeating: 0x99, count: 20))
    checkEqual(sim.received.count, partA.count + partB.count + overlap.count - alreadyDelivered,
               "segment below rcv_nxt is dropped")
}

func testReceiveWindowLimit() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    // Far outside the 256 KiB receive window.
    sim.injectPeer(seq: hs.peerISN &+ 1 &+ 400_000, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh,
                   payload: [UInt8](repeating: 0x44, count: 10))
    check(sim.received.isEmpty, "data beyond the receive window is dropped")
    let acks = sim.take()
    checkEqual(acks.count, 1, "out-of-window data is acknowledged")
    checkEqual(acks.first?.segment.acknowledgment, hs.peerISN &+ 1, "out-of-window ACK number")
    check(acks.first.map { $0.segment.window == 16384 } ?? false,
          "advertised window scaled to 256 KiB")
}

// MARK: - TCP: retransmission

func testRetransmissionOnRTO() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    let payload = [UInt8](repeating: 0x77, count: 100)
    hs.connection.send(payload)
    let first = sim.takeData()
    checkEqual(first.count, 1, "initial transmission")
    guard let original = first.first else { return }
    checkEqual(original.segment.sequence, hs.firstDataSeq, "initial sequence")

    sim.advance(0.25)
    sim.tick()
    let retx1 = sim.takeData()
    checkEqual(retx1.count, 1, "retransmission after initial RTO")
    checkEqual(retx1.first?.segment.sequence, original.segment.sequence, "same sequence")
    checkEqual(retx1.first?.segment.payload, payload, "same payload")

    sim.advance(0.45) // RTO doubled to 0.4
    sim.tick()
    let retx2 = sim.takeData()
    checkEqual(retx2.count, 1, "second retransmission after backoff")

    sim.advance(0.85) // RTO doubled to 0.8
    sim.tick()
    let retx3 = sim.takeData()
    checkEqual(retx3.count, 1, "third retransmission after backoff")

    // ACK everything; the retransmission timer must go quiet.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq &+ 100,
                   flags: TcpSegment.ack, window: 65535)
    _ = sim.take()
    sim.advance(2.0)
    sim.tick()
    checkEqual(sim.take().count, 0, "no retransmission after ACK")
    checkEqual(sim.events, ["connected"], "connection stays open")
}

func testFastRetransmit() {
    let sim = Sim()
    guard let hs = sim.handshake(peerMSS: 536) else { return }

    hs.connection.send([UInt8](repeating: 0x21, count: 1200))
    let sent = sim.takeData()
    checkEqual(sent.count, 3, "three segments in flight")

    for _ in 0..<3 {
        sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                       flags: TcpSegment.ack, window: 65535)
    }

    let afterDup = sim.takeData()
    checkEqual(afterDup.count, 1, "fast retransmit after three duplicate ACKs")
    checkEqual(afterDup.first?.segment.sequence, hs.firstDataSeq, "fast retransmit sequence")
    checkEqual(afterDup.first?.segment.payload.count, 536, "fast retransmit length")
}

func testZeroWindowRecovery() {
    let sim = Sim()
    guard let hs = sim.handshake(peerMSS: 536, peerWindow: 0) else { return }

    let payload = [UInt8](repeating: 0x66, count: 100)
    hs.connection.send(payload)
    checkEqual(sim.takeData().count, 0, "no data while the peer window is zero")

    sim.advance(0.15)
    sim.tick()
    let probes = sim.takeData()
    checkEqual(probes.count, 1, "zero-window probe emitted")
    checkEqual(probes.first?.segment.payload.count, 1, "probe carries a single byte")
    checkEqual(probes.first?.segment.sequence, hs.firstDataSeq, "probe starts at snd_nxt")

    // Window update: queued data must flow without waiting for a retransmit.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack, window: 65535)
    let resumed = sim.takeData()
    checkEqual(resumed.count, 1, "data sent after window update")
    checkEqual(resumed.first?.segment.payload, payload, "full payload after window update")
}

// MARK: - TCP: close

func testCloseFromBothSides() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    hs.connection.close()
    let finPackets = sim.take()
    checkEqual(finPackets.count, 1, "close sends a single FIN")
    guard let fin = finPackets.first else { return }
    check(fin.segment.describesFin, "FIN flag")
    check(fin.segment.describesAck, "FIN carries ACK")
    checkEqual(fin.segment.sequence, hs.firstDataSeq, "FIN sequence")

    // Peer acknowledges our FIN: connection stays half-closed.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: fin.segment.sequence &+ 1,
                   flags: TcpSegment.ack, window: 65535)
    _ = sim.take()
    checkEqual(sim.events, ["connected"], "no closed event before peer FIN")
    checkEqual(sim.stack.connectionCount, 1, "connection retained in FIN_WAIT_2")

    // Peer FIN completes the close.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: fin.segment.sequence &+ 1,
                   flags: TcpSegment.fin | TcpSegment.ack, window: 65535)
    _ = sim.take()
    checkEqual(sim.events, ["connected", "closed"], "closed event after peer FIN")
    checkEqual(sim.stack.connectionCount, 1, "TIME_WAIT keeps the port reserved")

    sim.advance(1.1)
    sim.tick()
    checkEqual(sim.stack.connectionCount, 0, "TIME_WAIT expiry removes the connection")
}

func testPeerInitiatedClose() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.fin | TcpSegment.ack, window: 65535)
    _ = sim.take()
    checkEqual(sim.events, ["connected", "closed"], "EOF signalled on peer FIN")
    checkEqual(sim.stack.connectionCount, 1, "half-closed connection is kept")

    // Half-close: the application may still send after the peer's FIN.
    hs.connection.send([1, 2, 3])
    let tail = sim.takeData()
    checkEqual(tail.count, 1, "data allowed after peer FIN")
    checkEqual(tail.first?.segment.payload, [1, 2, 3], "tail payload")

    hs.connection.close()
    let finPackets = sim.take()
    checkEqual(finPackets.count, 1, "FIN after half-close")
    guard let fin = finPackets.first else { return }
    check(fin.segment.describesFin, "FIN flag after half-close")

    sim.injectPeer(seq: hs.peerISN &+ 2, ack: fin.segment.sequence &+ 1,
                   flags: TcpSegment.ack, window: 65535)
    _ = sim.take()
    checkEqual(sim.stack.connectionCount, 0, "LAST_ACK completes the close")
    checkEqual(sim.events, ["connected", "closed"], "closed event delivered only once")
}

func testAbortAndReset() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }
    hs.connection.abort()
    let reset = sim.take()
    checkEqual(reset.count, 1, "abort sends one RST")
    check(reset.first?.segment.describesRst ?? false, "abort uses the RST flag")
    checkEqual(sim.stack.connectionCount, 0, "aborted connection removed")
    checkEqual(sim.events, ["connected", "closed"], "abort reports closed")

    // RST from the peer fails an established connection.
    let sim2 = Sim()
    guard let hs2 = sim2.handshake() else { return }
    sim2.injectPeer(seq: hs2.peerISN &+ 1, ack: hs2.firstDataSeq,
                    flags: TcpSegment.rst | TcpSegment.ack, window: 0)
    checkEqual(sim2.stack.connectionCount, 0, "reset connection removed")
    checkEqual(sim2.events, ["connected", "failed(connection reset by peer)"],
               "reset reported as failure")

    // RST during the handshake means "connection refused".
    let sim3 = Sim()
    _ = sim3.open(remotePort: 22)
    guard let syn = sim3.take().first else { return }
    sim3.localPort = syn.segment.sourcePort
    sim3.injectPeer(seq: 0, ack: syn.segment.sequence &+ 1,
                    flags: TcpSegment.rst | TcpSegment.ack, window: 0)
    checkEqual(sim3.events, ["failed(connection refused)"], "refused during handshake")
    checkEqual(sim3.stack.connectionCount, 0, "refused connection removed")
}

// MARK: - TCP: timeouts and limits

func testConnectTimeout() {
    let sim = Sim()
    _ = sim.open(remotePort: 80, timeout: 0.5)
    let synPackets = sim.take()
    guard let firstSyn = synPackets.first else { return }
    sim.localPort = firstSyn.segment.sourcePort

    sim.advance(0.25)
    sim.tick()
    let retransmitted = sim.take()
    checkEqual(retransmitted.count, 1, "SYN retransmitted before the deadline")
    checkEqual(retransmitted.first?.segment.sequence, firstSyn.segment.sequence,
               "SYN retransmit keeps the ISN")

    sim.advance(0.2)
    sim.tick()
    checkEqual(sim.take().count, 0, "no retransmit before the backed-off timer")

    sim.advance(0.1) // total 0.55 > 0.5 timeout
    sim.tick()
    checkEqual(sim.events, ["failed(connection timed out)"], "open timeout reported")
    checkEqual(sim.stack.connectionCount, 0, "timed-out connection removed")
}

func testConnectionLimit() {
    var config = Sim.testConfiguration()
    config.maximumConnections = 3
    let sim = Sim(configuration: config)

    for port in UInt16(1000)...UInt16(1002) {
        _ = sim.open(remotePort: port)
    }
    checkEqual(sim.stack.connectionCount, 3, "three connections registered")
    _ = sim.take()

    _ = sim.open(remotePort: 1003)
    checkEqual(sim.stack.connectionCount, 3, "limit is enforced")
    check(sim.events.last == "failed(connection limit reached)", "over-limit open fails")
}

func testIdleTimeout() {
    let sim = Sim()
    guard sim.handshake() != nil else { return }
    sim.advance(5.5)
    sim.tick()
    checkEqual(sim.events, ["connected", "failed(connection idle timeout)"],
               "idle timeout reported")
    checkEqual(sim.stack.connectionCount, 0, "idle connection removed")
}

func testCloseAllStopsTraffic() {
    let sim = Sim()
    let first = sim.open(remotePort: 80)
    let second = sim.open(remotePort: 443)
    _ = sim.take()
    sim.stack.closeAll()
    checkEqual(sim.stack.connectionCount, 0, "closeAll empties the table")

    first.send([1, 2, 3])
    second.close()
    sim.advance(10)
    sim.tick()
    checkEqual(sim.take().count, 0, "no packets after closeAll")

    // A stack that was shut down refuses new work without crashing.
    _ = sim.open(remotePort: 8080)
    check(sim.events.last == "failed(tcp stack is shut down)", "open after closeAll fails")
    checkEqual(sim.stack.connectionCount, 0, "no connection registered after closeAll")
}

func testUnknownPortReset() {
    let sim = Sim()
    sim.localPort = 40000
    sim.peerPort = 1234
    sim.injectPeer(seq: 100, ack: 0, flags: TcpSegment.syn, window: 65535)
    let packets = sim.take()
    checkEqual(packets.count, 1, "unknown port answered with RST")
    guard let reset = packets.first else { return }
    check(reset.segment.describesRst, "RST flag")
    check(reset.segment.describesAck, "RST acknowledges the SYN")
    checkEqual(reset.segment.sequence, 0, "RST sequence for a bare SYN")
    checkEqual(reset.segment.acknowledgment, 101, "RST acknowledges SYN sequence + 1")
    checkEqual(reset.segment.sourcePort, 40000, "RST source port")
    checkEqual(reset.segment.destinationPort, 1234, "RST destination port")
}

func testMultipleConnections() {
    let sim = Sim()
    let first = sim.open(remotePort: 80)
    let second = sim.open(remotePort: 443)
    let syns = sim.take()
    checkEqual(syns.count, 2, "one SYN per connection")
    checkEqual(Set(syns.map { $0.segment.sourcePort }).count, 2, "local ports are unique")
    checkEqual(sim.stack.connectionCount, 2, "two connections registered")

    // Complete both handshakes with distinct peer ISNs.
    var states: [UInt16: (localISN: UInt32, peerISN: UInt32)] = [:]
    for (index, syn) in syns.enumerated() {
        let peerISN = UInt32(0x1000_0000 + index)
        states[syn.segment.sourcePort] = (syn.segment.sequence, peerISN)
        sim.inject(sim.peerPacket(seq: peerISN, ack: syn.segment.sequence &+ 1,
                                  flags: TcpSegment.syn | TcpSegment.ack, window: 65535,
                                  mss: 536, sourcePort: syn.segment.destinationPort,
                                  destinationPort: syn.segment.sourcePort))
    }
    _ = sim.take()
    checkEqual(sim.events.filter { $0 == "connected" }.count, 2, "both connections established")

    // Each connection delivers only its own data.
    var perConnection: [UInt16: [UInt8]] = [:]
    for (port, tuple) in states {
        let payload = [UInt8(truncatingIfNeeded: port)]
        sim.inject(sim.peerPacket(seq: tuple.peerISN &+ 1, ack: tuple.localISN &+ 1,
                                  flags: TcpSegment.ack | TcpSegment.psh, window: 65535,
                                  payload: payload,
                                  sourcePort: port == syns[0].segment.sourcePort ? 80 : 443,
                                  destinationPort: port))
        perConnection[port] = payload
    }
    checkEqual(sim.received.count, 2, "both payloads delivered once")

    first.close()
    second.abort()
    _ = sim.take()
    checkEqual(sim.stack.connectionCount, 1, "only the aborted connection is gone")
    check(sim.events.contains("closed"), "abort reported")
}

func testOutOfOrderFin() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    let payload = [UInt8](repeating: 0x5B, count: 40)
    // FIN arrives before the data that precedes it.
    sim.injectPeer(seq: hs.peerISN &+ 1 &+ 40, ack: hs.firstDataSeq,
                   flags: TcpSegment.fin | TcpSegment.ack, window: 65535)
    checkEqual(sim.events, ["connected"], "FIN with a gap does not close the connection")
    let gapAcks = sim.take()
    checkEqual(gapAcks.first?.segment.acknowledgment, hs.peerISN &+ 1,
               "ACK does not advance past the gap")

    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                   flags: TcpSegment.ack | TcpSegment.psh, payload: payload)
    checkEqual(sim.received, payload, "gap filled and delivered")
    checkEqual(sim.events, ["connected", "data(40)", "closed"], "pending FIN applied")
    let finalAcks = sim.take()
    checkEqual(finalAcks.last?.segment.acknowledgment, hs.peerISN &+ 1 &+ 41,
               "ACK covers data plus FIN")
}

func testPartialAcknowledgement() {
    let sim = Sim()
    guard let hs = sim.handshake(peerMSS: 536) else { return }

    hs.connection.send([UInt8](repeating: 0x10, count: 1200))
    let sent = sim.takeData()
    checkEqual(sent.count, 3, "three segments sent")

    // Acknowledge only the first segment, then send more data.
    sim.injectPeer(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq &+ 536,
                   flags: TcpSegment.ack, window: 65535)
    _ = sim.take()
    hs.connection.send([UInt8](repeating: 0x20, count: 100))
    let tail = sim.takeData()
    checkEqual(tail.count, 1, "new data after a partial ACK")
    checkEqual(tail.first?.segment.sequence, hs.firstDataSeq &+ 1200,
               "sequence continues after the queued data")

    // A timeout retransmits from snd_una, not from the newest segment.
    sim.advance(0.25)
    sim.tick()
    let retx = sim.takeData()
    checkEqual(retx.count, 1, "one segment retransmitted")
    checkEqual(retx.first?.segment.sequence, hs.firstDataSeq &+ 536, "retransmit starts at snd_una")
}

func testTupleValidation() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    // A datagram addressed to another local address is ignored.
    let foreign = PacketCodec.buildTcp(source: testPeerIP,
                                       destination: PacketCodec.ipv4Address("10.0.0.1")!,
                                       segment: TcpSegment(sourcePort: 443,
                                                           destinationPort: sim.localPort,
                                                           sequence: hs.peerISN &+ 1,
                                                           acknowledgment: hs.firstDataSeq,
                                                           flags: TcpSegment.ack | TcpSegment.psh,
                                                           window: 65535,
                                                           maxSegmentSize: nil,
                                                           windowScale: nil,
                                                           payload: [1, 2, 3]))
    sim.inject(foreign)
    check(sim.received.isEmpty, "datagram for another address is ignored")
    checkEqual(sim.take().count, 0, "no reply for a foreign address")

    // A wrong 4-tuple for an owned port is answered with RST and its payload
    // is not delivered.
    sim.inject(sim.peerPacket(seq: hs.peerISN &+ 1, ack: hs.firstDataSeq,
                              flags: TcpSegment.ack | TcpSegment.psh,
                              window: 65535, payload: [9], sourcePort: 444))
    check(sim.received.isEmpty, "payload from a foreign source port is ignored")
    let reset = sim.take()
    checkEqual(reset.count, 1, "wrong 4-tuple answered with RST")
    check(reset.first?.segment.describesRst ?? false, "RST flag on tuple mismatch")
    checkEqual(reset.first?.segment.sourcePort, sim.localPort, "RST uses the local port")

    // Data after close() is refused and never reaches the wire.
    hs.connection.close()
    _ = sim.take()
    hs.connection.send([1, 2, 3])
    checkEqual(sim.takeData().count, 0, "no data accepted after close")
}

func testDefaultConfiguration() {
    let tcp = TcpStack.Configuration()
    checkEqual(tcp.maxSegmentSize, 1300, "default MSS")
    checkEqual(tcp.receiveWindow, 256 * 1024, "default receive window")
    checkEqual(tcp.initialRTO, 1.0, "default initial RTO")
    checkEqual(tcp.maximumRTO, 8.0, "default maximum RTO")
    checkEqual(tcp.connectTimeout, 20.0, "default connect timeout")
    checkEqual(tcp.halfOpenTimeout, 20.0, "default half-open timeout")
    checkEqual(tcp.idleTimeout, 600.0, "default idle timeout")
    checkEqual(tcp.timeWaitTimeout, 30.0, "default TIME_WAIT")
    checkEqual(tcp.maximumConnections, 512, "default connection limit")
    checkEqual(tcp.portRange, 49152...65535, "default ephemeral port range")

    let udp = UdpNat.Configuration()
    checkEqual(udp.idleTimeout, 120.0, "default UDP idle timeout")
    checkEqual(udp.maximumFlows, 512, "default UDP flow limit")
}

func testDefaultTimeouts() {
    // Real defaults driven by the manual clock: SYN backoff 1s, 2s, 4s, 8s
    // and a hard 20s deadline.
    let sim = Sim(configuration: TcpStack.Configuration())
    _ = sim.open(remotePort: 80, timeout: 20)
    guard let syn = sim.take().first else { return }
    sim.localPort = syn.segment.sourcePort

    sim.advance(1.0)
    sim.tick()
    checkEqual(sim.take().count, 1, "SYN retransmit at 1s")

    sim.advance(1.5)
    sim.tick()
    checkEqual(sim.take().count, 0, "no retransmit before 2s backoff elapses")

    sim.advance(0.5)
    sim.tick()
    checkEqual(sim.take().count, 1, "SYN retransmit at 3s")

    sim.advance(4.0)
    sim.tick()
    checkEqual(sim.take().count, 1, "SYN retransmit at 7s")

    sim.advance(8.0)
    sim.tick()
    checkEqual(sim.take().count, 1, "SYN retransmit at 15s")

    sim.advance(5.0)
    sim.tick()
    checkEqual(sim.events, ["failed(connection timed out)"], "20s connect timeout")
    checkEqual(sim.stack.connectionCount, 0, "connection dropped after timeout")
}

/// Deterministic pseudo-random generator for the fuzz scenarios.
struct LCG {
    var state: UInt64
    mutating func next() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(truncatingIfNeeded: state >> 33)
    }
    mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt32(upper)) }
}

func testRobustness() {
    let sim = Sim()
    guard let hs = sim.handshake() else { return }

    var rng = LCG(state: 0xDEAD_BEEF_CAFE)
    let flagsPool: [UInt8] = [TcpSegment.ack, TcpSegment.psh, TcpSegment.fin,
                              TcpSegment.syn, TcpSegment.rst,
                              TcpSegment.ack | TcpSegment.psh,
                              TcpSegment.fin | TcpSegment.ack]

    for _ in 0..<600 {
        let flags = flagsPool[rng.int(flagsPool.count)]
        var payload = [UInt8]()
        for _ in 0..<rng.int(24) { payload.append(UInt8(truncatingIfNeeded: rng.next())) }
        let segment = TcpSegment(sourcePort: rng.int(4) == 0 ? UInt16(rng.int(65535)) : 443,
                                 destinationPort: rng.int(5) == 0 ? UInt16(rng.int(65535)) : sim.localPort,
                                 sequence: rng.next(),
                                 acknowledgment: rng.int(2) == 0 ? hs.firstDataSeq : rng.next(),
                                 flags: flags,
                                 window: UInt16(truncatingIfNeeded: rng.next()),
                                 maxSegmentSize: nil,
                                 windowScale: nil,
                                 payload: payload)
        let datagram = Ipv4Datagram(source: testPeerIP, destination: testLocalIP,
                                    ttl: 64, transport: .tcp(segment))
        sim.stack.handle(datagram)
        sim.take()
        if rng.int(3) == 0 {
            sim.advance(0.05)
            sim.tick()
            sim.take()
        }
    }

    check(true, "random segments processed without crashing")
    check(sim.stack.connectionCount <= 512, "connection table stays bounded")

    // The stack still works after the fuzzing.
    let survivor = Sim()
    guard let fresh = survivor.handshake() else {
        check(false, "stack still usable after fuzzing")
        return
    }
    survivor.injectPeer(seq: fresh.peerISN &+ 1, ack: fresh.firstDataSeq,
                        flags: TcpSegment.ack | TcpSegment.psh, payload: [1, 2, 3])
    checkEqual(survivor.received, [1, 2, 3], "clean handshake after fuzzing")
}

func testConnectionChurn() {
    var config = Sim.testConfiguration()
    config.maximumConnections = 32
    let sim = Sim(configuration: config)

    for round in 0..<200 {
        let connection = sim.open(remotePort: UInt16(1000 + round % 50))
        _ = sim.take()
        if round % 2 == 0 {
            connection.abort()
        } else {
            connection.close()
        }
        _ = sim.take()
        sim.tick()
        _ = sim.take()
    }

    checkEqual(sim.stack.connectionCount, 0, "all connections released after churn")
    check(sim.stack.connectionCount < config.maximumConnections, "table never leaks past the limit")
}

// MARK: - UDP NAT

final class NatSim {
    let outbox: Outbox
    let nat: UdpNat
    let configuration: UdpNat.Configuration

    init(configuration: UdpNat.Configuration) {
        let box = Outbox()
        self.outbox = box
        self.configuration = configuration
        self.nat = UdpNat(localAddress: testLocalIP,
                          send: { packet in box.raw.append(packet) },
                          configuration: configuration,
                          clock: { box.clock })
    }

    func advance(_ seconds: TimeInterval) { outbox.clock += seconds }

    func takeUDP() -> [(raw: [UInt8], datagram: Ipv4Datagram, udp: UdpDatagram)] {
        let packets = outbox.raw
        outbox.raw.removeAll()
        var result: [(raw: [UInt8], datagram: Ipv4Datagram, udp: UdpDatagram)] = []
        for raw in packets {
            guard let datagram = PacketCodec.parseIPv4(raw),
                  case .udp(let udp) = datagram.transport else {
                check(false, "emitted packet is not a valid IPv4/UDP datagram")
                continue
            }
            check(ipv4HeaderChecksumValid(raw), "udp ipv4 header checksum")
            check(datagram.source == testLocalIP, "udp source is the tunnel address")
            result.append((raw, datagram, udp))
        }
        return result
    }

    func injectUDP(source: UInt32, sourcePort: UInt16,
                   destinationPort: UInt16, payload: [UInt8]) {
        let raw = PacketCodec.buildUdp(source: source, destination: testLocalIP,
                                       sourcePort: sourcePort,
                                       destinationPort: destinationPort,
                                       payload: payload)
        guard let datagram = PacketCodec.parseIPv4(raw) else {
            check(false, "injected udp datagram failed to parse")
            return
        }
        nat.handle(datagram)
    }
}

func testUDPFlowDelivery() {
    var config = UdpNat.Configuration()
    config.idleTimeout = 5
    let sim = NatSim(configuration: config)

    var received: [UInt8] = []
    var closedCount = 0
    let flow = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                            onData: { received += $0 },
                            onClosed: { closedCount += 1 })
    check((49152...65535).contains(flow.localPort), "udp ephemeral local port")
    checkEqual(sim.nat.flowCount, 1, "flow registered")

    flow.send([1, 2, 3])
    let packets = sim.takeUDP()
    checkEqual(packets.count, 1, "one udp datagram emitted")
    guard let packet = packets.first else { return }
    checkEqual(packet.udp.sourcePort, flow.localPort, "udp source port is the local port")
    checkEqual(packet.udp.destinationPort, 53, "udp destination port")
    checkEqual(packet.udp.payload, [1, 2, 3], "udp payload")
    check(packet.datagram.destination == testRemoteDNS, "udp destination address")

    sim.injectUDP(source: testRemoteDNS, sourcePort: 53,
                  destinationPort: flow.localPort, payload: [9, 8, 7])
    checkEqual(received, [9, 8, 7], "response delivered to the flow")

    sim.injectUDP(source: testRemoteDNS, sourcePort: 54,
                  destinationPort: flow.localPort, payload: [0])
    checkEqual(received, [9, 8, 7], "wrong source port ignored")

    sim.injectUDP(source: testOtherDNS, sourcePort: 53,
                  destinationPort: flow.localPort, payload: [0])
    checkEqual(received, [9, 8, 7], "wrong source address ignored")

    sim.injectUDP(source: testRemoteDNS, sourcePort: 53,
                  destinationPort: flow.localPort &+ 1, payload: [0])
    checkEqual(received, [9, 8, 7], "wrong local port ignored")

    flow.close()
    checkEqual(closedCount, 1, "close reports onClosed")
    checkEqual(sim.nat.flowCount, 0, "closed flow unregistered")
    flow.send([4])
    checkEqual(sim.takeUDP().count, 0, "closed flow emits nothing")
}

func testUDPIdleEviction() {
    var config = UdpNat.Configuration()
    config.idleTimeout = 5
    let sim = NatSim(configuration: config)

    var firstClosed = 0
    var secondClosed = 0
    let first = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                             onData: { _ in }, onClosed: { firstClosed += 1 })
    sim.injectUDP(source: testRemoteDNS, sourcePort: 53,
                  destinationPort: first.localPort, payload: [1])
    checkEqual(sim.nat.flowCount, 1, "flow active")

    sim.advance(6)
    let second = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                              onData: { _ in }, onClosed: { secondClosed += 1 })
    checkEqual(firstClosed, 1, "idle flow evicted on open")
    checkEqual(sim.nat.flowCount, 1, "only the fresh flow remains")

    first.send([2])
    checkEqual(sim.takeUDP().count, 0, "evicted flow emits nothing")

    // Traffic keeps a flow alive; idle eviction is also checked on handle().
    sim.injectUDP(source: testRemoteDNS, sourcePort: 53,
                  destinationPort: second.localPort, payload: [3])
    sim.advance(4)
    sim.injectUDP(source: testRemoteDNS, sourcePort: 53,
                  destinationPort: second.localPort, payload: [4])
    checkEqual(secondClosed, 0, "active flow is not evicted")

    second.close()
    checkEqual(secondClosed, 1, "explicit close reports onClosed")
    checkEqual(sim.nat.flowCount, 0, "no flows left")
}

func testUDPFlowLimitAndCloseAll() {
    var config = UdpNat.Configuration()
    config.maximumFlows = 2
    let sim = NatSim(configuration: config)

    var closed = 0
    let first = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                             onData: { _ in }, onClosed: { closed += 1 })
    let second = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                              onData: { _ in }, onClosed: { closed += 1 })
    checkEqual(sim.nat.flowCount, 2, "flow limit reached")
    _ = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                     onData: { _ in }, onClosed: { closed += 1 })
    checkEqual(closed, 1, "over-limit open reports onClosed")
    checkEqual(sim.nat.flowCount, 2, "flow limit enforced")

    sim.nat.closeAll()
    checkEqual(closed, 3, "closeAll reports every flow")
    checkEqual(sim.nat.flowCount, 0, "closeAll unregisters flows")
    first.send([1])
    second.send([2])
    checkEqual(sim.takeUDP().count, 0, "no datagrams after closeAll")

    _ = sim.nat.open(remote: IPv4Endpoint(address: testRemoteDNS, port: 53),
                     onData: { _ in }, onClosed: { closed += 1 })
    checkEqual(closed, 4, "open after closeAll reports onClosed")
}

// MARK: - DNS

func dnsHeader(id: UInt16, flags: UInt16, qd: UInt16, an: UInt16,
               ns: UInt16, ar: UInt16 = 0) -> [UInt8] {
    var bytes: [UInt8] = []
    PacketCodec.appendUInt16(id, to: &bytes)
    PacketCodec.appendUInt16(flags, to: &bytes)
    PacketCodec.appendUInt16(qd, to: &bytes)
    PacketCodec.appendUInt16(an, to: &bytes)
    PacketCodec.appendUInt16(ns, to: &bytes)
    PacketCodec.appendUInt16(ar, to: &bytes)
    return bytes
}

func dnsQuestion(_ name: String, type: UInt16 = 1) -> [UInt8] {
    guard let encoded = DnsMessage.encodeName(name) else { return [] }
    var bytes = encoded
    PacketCodec.appendUInt16(type, to: &bytes)
    PacketCodec.appendUInt16(1, to: &bytes)
    return bytes
}

func dnsRecord(name: [UInt8], type: UInt16, ttl: UInt32, rdata: [UInt8]) -> [UInt8] {
    var bytes = name
    PacketCodec.appendUInt16(type, to: &bytes)
    PacketCodec.appendUInt16(1, to: &bytes)
    PacketCodec.appendUInt32(ttl, to: &bytes)
    PacketCodec.appendUInt16(UInt16(rdata.count), to: &bytes)
    bytes.append(contentsOf: rdata)
    return bytes
}

let compressedExample: [UInt8] = [0xC0, 0x0C]

func testDNSQuery() {
    guard let query = DnsMessage.query(id: 0x1234, name: "example.com", type: 1) else {
        check(false, "query built")
        return
    }
    checkEqual(query.count, 29, "query length")
    checkEqual(PacketCodec.readUInt16(query, 0), 0x1234, "query id")
    checkEqual(PacketCodec.readUInt16(query, 2), 0x0100, "RD flag set")
    checkEqual(PacketCodec.readUInt16(query, 4), 1, "QDCOUNT")
    checkEqual(PacketCodec.readUInt16(query, 6), 0, "ANCOUNT")
    checkEqual(PacketCodec.readUInt16(query, 8), 0, "NSCOUNT")
    checkEqual(PacketCodec.readUInt16(query, 10), 0, "ARCOUNT")
    checkEqual(Array(query[12..<25]),
               [7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0],
               "QNAME encoding")
    checkEqual(PacketCodec.readUInt16(query, 25), 1, "QTYPE A")
    checkEqual(PacketCodec.readUInt16(query, 27), 1, "QCLASS IN")

    guard let aaaa = DnsMessage.query(id: 7, name: "v6.example.com", type: 28) else {
        check(false, "aaaa query built")
        return
    }
    checkEqual(PacketCodec.readUInt16(aaaa, aaaa.count - 4), 28, "QTYPE AAAA")

    guard let rooted = DnsMessage.query(id: 1, name: "example.com.", type: 1),
          let plain = DnsMessage.query(id: 1, name: "example.com", type: 1) else {
        check(false, "trailing dot accepted")
        return
    }
    checkEqual(rooted, plain, "trailing dot normalised")

    check(DnsMessage.query(id: 1, name: "", type: 1) == nil, "empty name rejected")
    check(DnsMessage.query(id: 1, name: "a..b", type: 1) == nil, "empty label rejected")
    check(DnsMessage.query(id: 1, name: String(repeating: "a", count: 64), type: 1) == nil,
          "oversized label rejected")
    check(DnsMessage.query(id: 1, name: Array(repeating: "abcdefgh", count: 40).joined(separator: "."),
                           type: 1) == nil, "oversized name rejected")
}

func testDNSParse() {
    var packet = dnsHeader(id: 0x1234, flags: 0x8180, qd: 1, an: 2, ns: 1)
    packet += dnsQuestion("example.com")
    packet += dnsRecord(name: compressedExample, type: 1, ttl: 300,
                        rdata: [93, 184, 216, 34])
    packet += dnsRecord(name: compressedExample, type: 1, ttl: 60,
                        rdata: [1, 2, 3, 4])
    packet += dnsRecord(name: compressedExample, type: 2, ttl: 3600,
                        rdata: compressedExample)

    guard let response = DnsMessage.parse(packet) else {
        check(false, "response parsed")
        return
    }
    checkEqual(response.id, 0x1234, "response id")
    checkEqual(response.rcode, 0, "response rcode")
    check(!response.truncated, "response not truncated")
    checkEqual(response.name, "example.com", "question name")
    checkEqual(response.addresses, [0x5DB8_D822, 0x0102_0304], "A records collected")
    checkEqual(response.ttl, 60, "minimum TTL wins")

    // Truncated flag and error rcode.
    var truncatedPacket = dnsHeader(id: 9, flags: 0x8383, qd: 1, an: 0, ns: 0)
    truncatedPacket += dnsQuestion("example.com")
    guard let truncated = DnsMessage.parse(truncatedPacket) else {
        check(false, "truncated response parsed")
        return
    }
    check(truncated.truncated, "TC flag surfaced")
    checkEqual(truncated.rcode, 3, "rcode surfaced")
    check(truncated.addresses.isEmpty, "no addresses for NXDOMAIN")
    checkEqual(truncated.ttl, 0, "zero TTL without A records")

    // AAAA answers are skipped but the response still parses.
    var aaaaPacket = dnsHeader(id: 11, flags: 0x8180, qd: 1, an: 1, ns: 0)
    aaaaPacket += dnsQuestion("v6.example.com", type: 28)
    aaaaPacket += dnsRecord(name: compressedExample, type: 28, ttl: 120,
                            rdata: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    guard let aaaa = DnsMessage.parse(aaaaPacket) else {
        check(false, "aaaa response parsed")
        return
    }
    checkEqual(aaaa.name, "v6.example.com", "aaaa question name")
    check(aaaa.addresses.isEmpty, "AAAA answers do not produce IPv4 addresses")

    // A name whose pointer points into the middle of the question.
    var nested = dnsHeader(id: 12, flags: 0x8180, qd: 1, an: 1, ns: 0)
    nested += dnsQuestion("www.example.com")
    nested += dnsRecord(name: [0xC0, 0x10], type: 1, ttl: 10, rdata: [5, 6, 7, 8])
    guard let nestedResponse = DnsMessage.parse(nested) else {
        check(false, "nested pointer parsed")
        return
    }
    checkEqual(nestedResponse.name, "www.example.com", "nested question name")
    checkEqual(nestedResponse.addresses, [5 << 24 | 6 << 16 | 7 << 8 | 8], "nested A record")
}

func testDNSMalformed() {
    check(DnsMessage.parse([]) == nil, "empty packet rejected")
    check(DnsMessage.parse(Array(repeating: 0, count: 11)) == nil, "short header rejected")

    let headerOnly = dnsHeader(id: 1, flags: 0x8180, qd: 1, an: 0, ns: 0)
    check(DnsMessage.parse(headerOnly) == nil, "missing question rejected")

    var pointerLoop = dnsHeader(id: 2, flags: 0x8180, qd: 1, an: 0, ns: 0)
    pointerLoop += [0xC0, 0x0C, 0, 1, 0, 1]
    check(DnsMessage.parse(pointerLoop) == nil, "self-referencing pointer rejected")

    var forwardPointer = dnsHeader(id: 3, flags: 0x8180, qd: 1, an: 0, ns: 0)
    forwardPointer += [0xC0, 0x40, 0, 1, 0, 1]
    check(DnsMessage.parse(forwardPointer) == nil, "forward pointer rejected")

    var loopChain = dnsHeader(id: 4, flags: 0x8180, qd: 1, an: 0, ns: 0)
    loopChain += [3, 119, 119, 119, 0xC0, 0x0C, 0, 1, 0, 1]
    check(DnsMessage.parse(loopChain) == nil, "pointer chain loop rejected")

    var badLabel = dnsHeader(id: 5, flags: 0x8180, qd: 1, an: 0, ns: 0)
    badLabel += [0x46, 1, 2, 3, 4, 5, 0, 0, 1, 0, 1]
    check(DnsMessage.parse(badLabel) == nil, "reserved label type rejected")

    var lengthOverflow = dnsHeader(id: 6, flags: 0x8180, qd: 1, an: 1, ns: 0)
    lengthOverflow += dnsQuestion("example.com")
    lengthOverflow += compressedExample           // name
    lengthOverflow += [0, 1, 0, 1]                // type A, class IN
    lengthOverflow += [0, 0, 0, 10]               // TTL
    lengthOverflow += [0, 100]                    // rdlength claims 100 bytes
    lengthOverflow += [1, 2, 3, 4]                // but only four follow
    check(DnsMessage.parse(lengthOverflow) == nil, "rdata length overflow rejected")

    var truncatedAnswer = dnsHeader(id: 7, flags: 0x8180, qd: 1, an: 1, ns: 0)
    truncatedAnswer += dnsQuestion("example.com")
    truncatedAnswer += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 10]
    check(DnsMessage.parse(truncatedAnswer) == nil, "truncated answer rejected")

    // A valid response with a bogus section count is rejected, not crashed.
    var badCounts = dnsHeader(id: 8, flags: 0x8180, qd: 1, an: 5, ns: 0)
    badCounts += dnsQuestion("example.com")
    check(DnsMessage.parse(badCounts) == nil, "answer count beyond packet rejected")
}

// MARK: - Run

run("tcp handshake", testHandshake)
run("tcp outbound data slicing", testOutboundDataSlicing)
run("tcp window scaling", testWindowScaleOnData)
run("tcp inbound data", testInboundData)
run("tcp out-of-order reassembly", testOutOfOrderReassembly)
run("tcp receive window", testReceiveWindowLimit)
run("tcp retransmission on RTO", testRetransmissionOnRTO)
run("tcp fast retransmit", testFastRetransmit)
run("tcp zero window recovery", testZeroWindowRecovery)
run("tcp close from both sides", testCloseFromBothSides)
run("tcp peer initiated close", testPeerInitiatedClose)
run("tcp abort and reset", testAbortAndReset)
run("tcp connect timeout", testConnectTimeout)
run("tcp connection limit", testConnectionLimit)
run("tcp idle timeout", testIdleTimeout)
run("tcp closeAll", testCloseAllStopsTraffic)
run("tcp unknown port reset", testUnknownPortReset)
run("tcp multiple connections", testMultipleConnections)
run("tcp out-of-order FIN", testOutOfOrderFin)
run("tcp partial acknowledgement", testPartialAcknowledgement)
run("tcp 4-tuple validation", testTupleValidation)
run("tcp default configuration", testDefaultConfiguration)
run("tcp default timeouts", testDefaultTimeouts)
run("tcp robustness", testRobustness)
run("tcp connection churn", testConnectionChurn)
run("udp flow delivery", testUDPFlowDelivery)
run("udp idle eviction", testUDPIdleEviction)
run("udp flow limit and closeAll", testUDPFlowLimitAndCloseAll)
run("dns query", testDNSQuery)
run("dns parse", testDNSParse)
run("dns malformed", testDNSMalformed)

print("")
if failureCount == 0 {
    print("PASS: \(checkCount) checks, 0 failures")
} else {
    print("FAIL: \(checkCount) checks, \(failureCount) failures")
}
exit(failureCount == 0 ? 0 : 1)
