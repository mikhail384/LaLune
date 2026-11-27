// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Client-side TCP implementation for the userspace tunnel.
//
// The stack owns a set of active-open connections, hands every outgoing
// datagram to `send` exactly once and never touches the host network stack.
// `tick()` is driven by the platform layer (~50 ms) and only runs timers:
// handshake retries, RTO retransmission, zero-window probes, idle and
// TIME_WAIT expiry.
//
// Time is read through an injectable clock so the off-device tests can run
// deterministic scenarios without sleeping. Foundation only.

import Foundation

/// Wrapping comparison for TCP sequence numbers (RFC 1982, 32-bit space).
@inline(__always)
fileprivate func tcpSeqLess(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
    Int32(bitPattern: lhs &- rhs) < 0
}

// MARK: - Stack

final class TcpStack: TunnelTcpStack {

    /// Tuning knobs. The defaults are the values used on device; the test
    /// harness overrides the timeouts to keep scenarios short.
    struct Configuration {
        var maxSegmentSize: UInt16 = 1300
        var receiveWindow: Int = 256 * 1024
        var receiveWindowScale: UInt8 = 4
        var initialRTO: TimeInterval = 1.0
        var maximumRTO: TimeInterval = 8.0
        var connectTimeout: TimeInterval = 20.0
        var halfOpenTimeout: TimeInterval = 20.0
        var idleTimeout: TimeInterval = 600.0
        var timeWaitTimeout: TimeInterval = 30.0
        var maximumConnections: Int = 512
        var maximumSendBuffer: Int = 1024 * 1024
        var portRange: ClosedRange<UInt16> = 49152...65535
        var zeroWindowProbeInterval: TimeInterval = 0.5
        var maximumZeroWindowProbeInterval: TimeInterval = 2.0
    }

    fileprivate let localAddress: UInt32
    fileprivate let sendPacket: ([UInt8]) -> Void
    fileprivate let configuration: Configuration
    fileprivate let clock: () -> TimeInterval

    fileprivate let lock = NSRecursiveLock()
    private var connections: [UInt16: TcpConnection] = [:]
    private var shutDown = false

    /// Production initializer used by `TunnelStackFactory`.
    convenience init(localAddress: UInt32, send: @escaping ([UInt8]) -> Void) {
        self.init(localAddress: localAddress, send: send,
                  configuration: Configuration(),
                  clock: { ProcessInfo.processInfo.systemUptime })
    }

    /// Injectable initializer for tests and for callers that want a custom
    /// clock or tighter timeouts.
    init(localAddress: UInt32,
         send: @escaping ([UInt8]) -> Void,
         configuration: Configuration,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.localAddress = localAddress
        self.sendPacket = send
        self.configuration = configuration
        self.clock = clock
    }

    // MARK: TunnelTcpStack

    func open(remote: IPv4Endpoint, timeout: TimeInterval,
              onEvent: @escaping (TunnelTcpEvent) -> Void) -> TunnelTcpConnection {
        lock.lock()
        defer { lock.unlock() }

        guard !shutDown else {
            return failedConnection(remote: remote, reason: "tcp stack is shut down", onEvent: onEvent)
        }
        reapLocked()
        guard connections.count < configuration.maximumConnections else {
            return failedConnection(remote: remote, reason: "connection limit reached", onEvent: onEvent)
        }
        guard let port = allocatePortLocked() else {
            return failedConnection(remote: remote, reason: "no free local port", onEvent: onEvent)
        }

        let connection = TcpConnection(stack: self, localPort: port, remote: remote, onEvent: onEvent)
        connections[port] = connection
        connection.beginHandshake(timeout: timeout)
        return connection
    }

    func handle(_ datagram: Ipv4Datagram) {
        guard case .tcp(let segment) = datagram.transport else { return }
        guard datagram.destination == localAddress else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !shutDown else { return }

        if let connection = connections[segment.destinationPort] {
            guard connection.remote.address == datagram.source,
                  connection.remote.port == segment.sourcePort else {
                sendResetLocked(to: datagram.source, segment: segment)
                return
            }
            connection.receive(segment)
        } else if !segment.describesRst {
            sendResetLocked(to: datagram.source, segment: segment)
        }
    }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard !shutDown, !connections.isEmpty else { return }

        let time = clock()
        // Snapshot: timer handlers may remove their own connection (failures,
        // TIME_WAIT expiry), and mutating the table while iterating it would
        // be undefined behaviour.
        let snapshot = Array(connections.values)
        var finished: [TcpConnection] = []
        for connection in snapshot {
            if connection.driveTimers(now: time) {
                finished.append(connection)
            }
        }
        for connection in finished {
            removeConnection(connection)
        }
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        shutDown = true
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active {
            connection.stackDidShutDown()
        }
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    // MARK: Internals used by TcpConnection

    fileprivate func now() -> TimeInterval { clock() }

    fileprivate func removeConnection(_ connection: TcpConnection) {
        if connections[connection.localPort] === connection {
            connections.removeValue(forKey: connection.localPort)
        }
    }

    /// Emits one IPv4/TCP datagram. `options` is only non-empty for SYN.
    fileprivate func sendSegment(_ segment: TcpSegment, destination: UInt32, options: [UInt8]) {
        guard !shutDown else { return }
        sendPacket(encodeSegment(segment, destination: destination, options: options))
    }

    fileprivate func encodeSegment(_ segment: TcpSegment, destination: UInt32,
                                   options: [UInt8]) -> [UInt8] {
        guard !options.isEmpty else {
            return PacketCodec.buildTcp(source: localAddress, destination: destination, segment: segment)
        }

        // PacketCodec.buildTcp writes a fixed 20-byte header, so a SYN that
        // carries MSS/window-scale options is encoded here with the same wire
        // layout and the same checksum routine.
        var body: [UInt8] = []
        body.reserveCapacity(20 + options.count + segment.payload.count)
        PacketCodec.appendUInt16(segment.sourcePort, to: &body)
        PacketCodec.appendUInt16(segment.destinationPort, to: &body)
        PacketCodec.appendUInt32(segment.sequence, to: &body)
        PacketCodec.appendUInt32(segment.acknowledgment, to: &body)
        body.append(UInt8((20 + options.count) / 4) << 4)
        body.append(segment.flags)
        PacketCodec.appendUInt16(segment.window, to: &body)
        PacketCodec.appendUInt16(0, to: &body) // checksum, filled below
        PacketCodec.appendUInt16(0, to: &body) // urgent pointer
        body.append(contentsOf: options)
        body.append(contentsOf: segment.payload)

        var pseudo: [UInt8] = []
        pseudo.reserveCapacity(12)
        PacketCodec.appendUInt32(localAddress, to: &pseudo)
        PacketCodec.appendUInt32(destination, to: &pseudo)
        pseudo.append(0)
        pseudo.append(6)
        PacketCodec.appendUInt16(UInt16(body.count), to: &pseudo)
        let sum = PacketCodec.checksum(pseudo, body)
        body[16] = UInt8(sum >> 8)
        body[17] = UInt8(sum & 0xFF)
        return PacketCodec.buildIPv4(source: localAddress, destination: destination, proto: 6, body: body)
    }

    // MARK: Private helpers

    private func failedConnection(remote: IPv4Endpoint, reason: String,
                                  onEvent: @escaping (TunnelTcpEvent) -> Void) -> TunnelTcpConnection {
        let connection = TcpConnection(stack: self, localPort: 0, remote: remote, onEvent: onEvent)
        connection.markFailed(reason)
        return connection
    }

    private func allocatePortLocked() -> UInt16? {
        let range = configuration.portRange
        let span = Int(range.upperBound) - Int(range.lowerBound) + 1
        guard span > 0 else { return nil }
        let start = Int.random(in: 0..<span)
        for step in 0..<span {
            let port = UInt16(Int(range.lowerBound) + (start + step) % span)
            if connections[port] == nil { return port }
        }
        return nil
    }

    /// Drops connections whose TIME_WAIT expired, so a saturated table can
    /// still accept new work between ticks.
    private func reapLocked() {
        guard !connections.isEmpty else { return }
        let time = clock()
        var expired: [UInt16] = []
        for (port, connection) in connections where connection.isFinished(at: time) {
            expired.append(port)
        }
        for port in expired {
            connections.removeValue(forKey: port)
        }
    }

    /// Answers a segment for a port we do not own with RST, as a host stack
    /// would (RFC 793: sequence from ACK when present, otherwise ACK the peer).
    private func sendResetLocked(to source: UInt32, segment: TcpSegment) {
        let sequence: UInt32
        let acknowledgment: UInt32
        let flags: UInt8
        if segment.describesAck {
            sequence = segment.acknowledgment
            acknowledgment = 0
            flags = TcpSegment.rst
        } else {
            sequence = 0
            var next = segment.sequence &+ UInt32(segment.payload.count)
            if segment.describesSyn { next = next &+ 1 }
            if segment.describesFin { next = next &+ 1 }
            acknowledgment = next
            flags = TcpSegment.rst | TcpSegment.ack
        }
        let reset = TcpSegment(sourcePort: segment.destinationPort,
                               destinationPort: segment.sourcePort,
                               sequence: sequence,
                               acknowledgment: acknowledgment,
                               flags: flags,
                               window: 0,
                               maxSegmentSize: nil,
                               windowScale: nil,
                               payload: [])
        sendSegment(reset, destination: source, options: [])
    }
}

// MARK: - Connection

final class TcpConnection: TunnelTcpConnection {

    enum State {
        case synSent
        case established
        case finWait1
        case finWait2
        case closing
        case closeWait
        case lastAck
        case timeWait
        case closed
    }

    private struct Outstanding {
        var sequence: UInt32
        var length: Int        // payload bytes; a FIN occupies one sequence number
        var isFin: Bool
        var retransmitted: Bool
    }

    let localPort: UInt16
    let remote: IPv4Endpoint
    private(set) var bytesIn: UInt64 = 0
    private(set) var bytesOut: UInt64 = 0

    fileprivate(set) var state: State = .synSent

    private weak var stack: TcpStack?
    private let configuration: TcpStack.Configuration
    private let onEvent: (TunnelTcpEvent) -> Void

    // Send side.
    private var iss: UInt32 = 0
    private var sndUna: UInt32 = 0
    private var sndNxt: UInt32 = 0
    private var sndWnd: UInt32 = 0
    private var sndWndRight: UInt32 = 0
    private var peerScale: UInt8 = 0
    private var peerMSS: UInt16 = 536
    private var outBuf: [UInt8] = []
    private var unacked: [Outstanding] = []
    private var rto: TimeInterval
    private var rtoDeadline: TimeInterval?
    private var nextSynRetransmit: TimeInterval?
    private var connectDeadline: TimeInterval?
    private var dupAckCount = 0
    private var zeroWindowDeadline: TimeInterval?
    private var zeroWindowInterval: TimeInterval

    // Receive side.
    private var rcvNxt: UInt32 = 0
    private var rcvWindow: Int
    private var outOfOrder: [UInt32: [UInt8]] = [:]
    private var outOfOrderBytes = 0
    private var pendingFinSeq: UInt32?

    // Close bookkeeping.
    private var closeRequested = false
    private var finSent = false
    private var finAcked = false
    private var timeWaitDeadline: TimeInterval?
    private var lastActivity: TimeInterval
    private var terminalEmitted = false
    private var stackClosed = false

    init(stack: TcpStack, localPort: UInt16, remote: IPv4Endpoint,
         onEvent: @escaping (TunnelTcpEvent) -> Void) {
        self.stack = stack
        self.localPort = localPort
        self.remote = remote
        self.configuration = stack.configuration
        self.onEvent = onEvent
        self.rcvWindow = stack.configuration.receiveWindow
        self.rto = stack.configuration.initialRTO
        self.zeroWindowInterval = stack.configuration.zeroWindowProbeInterval
        self.lastActivity = stack.now()
    }

    // MARK: TunnelTcpConnection

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let stack = stack else { return }
        stack.lock.lock()
        defer { stack.lock.unlock() }
        guard !stackClosed, !closeRequested else { return }
        guard state == .synSent || state == .established || state == .closeWait else { return }
        guard outBuf.count + bytes.count <= configuration.maximumSendBuffer else {
            fail("send buffer overflow")
            return
        }
        outBuf.append(contentsOf: bytes)
        transmit()
    }

    func close() {
        guard let stack = stack else { return }
        stack.lock.lock()
        defer { stack.lock.unlock() }
        guard !stackClosed else { return }

        switch state {
        case .synSent:
            // Abort an unfinished handshake instead of leaving a half-open socket.
            sendReset()
            state = .closed
            emit(.closed)
            stack.removeConnection(self)
        case .established, .closeWait:
            closeRequested = true
            transmit()
        case .finWait1, .finWait2, .closing, .lastAck, .timeWait, .closed:
            break
        }
    }

    func abort() {
        guard let stack = stack else { return }
        stack.lock.lock()
        defer { stack.lock.unlock() }
        guard !stackClosed, state != .closed else { return }
        sendReset()
        state = .closed
        emit(.closed)
        stack.removeConnection(self)
    }

    // MARK: Handshake

    fileprivate func beginHandshake(timeout: TimeInterval) {
        guard let stack = stack else { return }
        let time = stack.now()
        iss = UInt32.random(in: 0...UInt32.max)
        sndUna = iss
        sndNxt = iss
        state = .synSent
        // The open() timeout is capped by the half-open guard.
        let effective = timeout > 0 ? timeout : configuration.connectTimeout
        connectDeadline = time + min(effective, configuration.halfOpenTimeout)
        rto = configuration.initialRTO
        nextSynRetransmit = time + rto
        lastActivity = time
        sendSyn()
    }

    fileprivate func markFailed(_ reason: String) {
        state = .closed
        terminalEmitted = true
        onEvent(.failed(reason))
    }

    fileprivate func stackDidShutDown() {
        stackClosed = true
        state = .closed
        outBuf.removeAll()
        unacked.removeAll()
        outOfOrder.removeAll()
        outOfOrderBytes = 0
        rtoDeadline = nil
        zeroWindowDeadline = nil
        nextSynRetransmit = nil
        timeWaitDeadline = nil
        pendingFinSeq = nil
        emit(.closed)
    }

    private func sendSyn() {
        let segment = TcpSegment(sourcePort: localPort,
                                 destinationPort: remote.port,
                                 sequence: iss,
                                 acknowledgment: 0,
                                 flags: TcpSegment.syn,
                                 window: advertisedWindow(),
                                 maxSegmentSize: nil,
                                 windowScale: nil,
                                 payload: [])
        stack?.sendSegment(segment, destination: remote.address, options: synOptions())
    }

    private func synOptions() -> [UInt8] {
        let mss = configuration.maxSegmentSize
        return [2, 4, UInt8(mss >> 8), UInt8(mss & 0xFF),
                3, 3, configuration.receiveWindowScale,
                1] // NOP padding to a 4-byte boundary
    }

    // MARK: Inbound processing

    fileprivate func receive(_ segment: TcpSegment) {
        guard !stackClosed, state != .closed else { return }
        guard let stack = stack else { return }
        let time = stack.now()
        lastActivity = time

        if segment.describesRst {
            handleReset()
            return
        }
        if state == .synSent {
            handleSynAck(segment, now: time)
            return
        }
        if segment.describesSyn {
            // A SYN on a synchronized connection is bogus: acknowledge and drop.
            sendAck()
            return
        }
        if segment.describesAck {
            processAck(segment, now: time)
        }
        guard !stackClosed, state != .closed else { return }
        if state == .timeWait {
            sendAck()
            return
        }

        var acknowledged = false
        if !segment.payload.isEmpty {
            receiveData(sequence: segment.sequence, payload: segment.payload, now: time)
            acknowledged = true
        }
        if segment.describesFin {
            receiveFin(sequence: segment.sequence &+ UInt32(segment.payload.count), now: time)
            acknowledged = true
        }
        // Every segment that consumes sequence space is acknowledged, including
        // duplicates and data dropped for being outside the window. Pure ACKs
        // are not answered with an ACK: that would double the reverse traffic
        // and can ping-pong with a peer that acknowledges everything.
        if acknowledged {
            sendAck()
        }
    }

    private func handleSynAck(_ segment: TcpSegment, now time: TimeInterval) {
        guard segment.describesSyn, segment.describesAck else { return }
        guard segment.acknowledgment == iss &+ 1 else { return }

        rcvNxt = segment.sequence &+ 1
        sndUna = iss &+ 1
        sndNxt = iss &+ 1
        peerMSS = max(1, min(segment.maxSegmentSize ?? 536, configuration.maxSegmentSize))
        peerScale = min(segment.windowScale ?? 0, 14)
        sndWnd = UInt32(segment.window) << Int(peerScale)
        sndWndRight = sndUna &+ sndWnd
        state = .established
        connectDeadline = nil
        nextSynRetransmit = nil
        rto = configuration.initialRTO
        rtoDeadline = nil
        lastActivity = time

        sendAck()
        emit(.connected)
        transmit()
    }

    private func handleReset() {
        if state == .timeWait {
            state = .closed
            stack?.removeConnection(self)
            return
        }
        fail(state == .synSent ? "connection refused" : "connection reset by peer")
    }

    private func processAck(_ segment: TcpSegment, now time: TimeInterval) {
        guard state != .synSent, state != .closed else { return }
        let ack = segment.acknowledgment
        let newWindow = UInt32(segment.window) << Int(peerScale)
        let previousRight = sndWndRight
        sndWnd = newWindow
        sndWndRight = ack &+ newWindow

        if ack == sndUna {
            if tcpSeqLess(previousRight, sndWndRight) {
                // Window update: resume sending immediately.
                dupAckCount = 0
                zeroWindowDeadline = nil
                zeroWindowInterval = configuration.zeroWindowProbeInterval
                transmit()
            } else if state == .established || state == .closeWait {
                dupAckCount += 1
                if dupAckCount == 3 {
                    retransmitOldest(now: time, fast: true)
                }
            }
            return
        }
        if tcpSeqLess(ack, sndUna) {
            return // stale ACK
        }
        if tcpSeqLess(sndNxt, ack) {
            // ACK for bytes we never sent: ignore, but keep the peer informed.
            sendAck()
            return
        }

        let acked = Int(ack &- sndUna)
        sndUna = ack
        if acked >= outBuf.count {
            outBuf.removeAll(keepingCapacity: true)
        } else if acked > 0 {
            outBuf.removeFirst(acked)
        }

        var kept: [Outstanding] = []
        kept.reserveCapacity(unacked.count)
        for var entry in unacked {
            let end = entry.sequence &+ UInt32(entry.length)
            if !tcpSeqLess(ack, end) { // fully acknowledged
                if entry.isFin { finAcked = true }
                continue
            }
            if tcpSeqLess(entry.sequence, ack) {
                let consumed = Int(ack &- entry.sequence)
                entry.sequence = ack
                entry.length -= consumed
            }
            kept.append(entry)
        }
        unacked = kept

        dupAckCount = 0
        zeroWindowDeadline = nil
        zeroWindowInterval = configuration.zeroWindowProbeInterval
        // Karn's rule: only re-arm the base RTO when no retransmission is pending.
        if unacked.isEmpty || !unacked.contains(where: { $0.retransmitted }) {
            rto = configuration.initialRTO
        }
        rtoDeadline = unacked.isEmpty ? nil : time + rto

        advanceClosingState(now: time)
        guard !stackClosed, state != .closed else { return }
        transmit()
    }

    private func advanceClosingState(now time: TimeInterval) {
        switch state {
        case .finWait1:
            if finAcked { state = .finWait2 }
        case .closing:
            if finAcked { enterTimeWait(now: time) }
        case .lastAck:
            if finAcked {
                state = .closed
                emit(.closed)
                stack?.removeConnection(self)
            }
        default:
            break
        }
    }

    private func receiveData(sequence: UInt32, payload: [UInt8], now time: TimeInterval) {
        guard state == .established || state == .closeWait
            || state == .finWait1 || state == .finWait2 else { return }

        var data = payload
        var seq = sequence

        // Trim the part we already delivered.
        if tcpSeqLess(seq, rcvNxt) {
            let skip = Int(rcvNxt &- seq)
            guard skip < data.count else { return }
            data.removeFirst(skip)
            seq = rcvNxt
        }

        // Enforce the advertised receive window: drop anything past its edge.
        let windowEnd = rcvNxt &+ UInt32(rcvWindow)
        guard !tcpSeqLess(windowEnd, seq) else { return }
        if tcpSeqLess(windowEnd, seq &+ UInt32(data.count)) {
            let allowed = Int(windowEnd &- seq)
            guard allowed > 0 else { return }
            data.removeLast(data.count - allowed)
        }
        guard !data.isEmpty else { return }

        if seq == rcvNxt {
            deliver(data)
            rcvNxt = rcvNxt &+ UInt32(data.count)
            drainOutOfOrder()
            processPendingFinIfReady(now: time)
        } else {
            if let existing = outOfOrder[seq], existing.count >= data.count { return }
            if let existing = outOfOrder[seq] { outOfOrderBytes -= existing.count }
            outOfOrder[seq] = data
            outOfOrderBytes += data.count
            trimOutOfOrderBelowRcvNxt()
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytesIn += UInt64(bytes.count)
        onEvent(.data(bytes))
    }

    private func drainOutOfOrder() {
        while let chunk = outOfOrder[rcvNxt] {
            outOfOrder.removeValue(forKey: rcvNxt)
            outOfOrderBytes -= chunk.count
            deliver(chunk)
            rcvNxt = rcvNxt &+ UInt32(chunk.count)
            trimOutOfOrderBelowRcvNxt()
        }
    }

    /// Keeps the reassembly table consistent after `rcvNxt` moved forward.
    private func trimOutOfOrderBelowRcvNxt() {
        guard !outOfOrder.isEmpty else { return }
        for key in Array(outOfOrder.keys) where tcpSeqLess(key, rcvNxt) {
            guard var chunk = outOfOrder.removeValue(forKey: key) else { continue }
            outOfOrderBytes -= chunk.count
            let skip = Int(rcvNxt &- key)
            if skip < chunk.count {
                chunk.removeFirst(skip)
                outOfOrderBytes += chunk.count
                if let existing = outOfOrder[rcvNxt] {
                    if chunk.count > existing.count {
                        outOfOrderBytes -= existing.count
                        outOfOrder[rcvNxt] = chunk
                        outOfOrderBytes += chunk.count
                    }
                } else {
                    outOfOrder[rcvNxt] = chunk
                }
            }
        }
    }

    private func receiveFin(sequence: UInt32, now time: TimeInterval) {
        let windowEnd = rcvNxt &+ UInt32(rcvWindow)
        if sequence == rcvNxt {
            rcvNxt = rcvNxt &+ 1
            handleFinReceived(now: time)
        } else if tcpSeqLess(rcvNxt, sequence), !tcpSeqLess(windowEnd, sequence) {
            pendingFinSeq = sequence
        }
        // sequence < rcvNxt: duplicate FIN, the ACK below covers it.
        // sequence >= windowEnd: outside the window, drop it.
    }

    private func processPendingFinIfReady(now time: TimeInterval) {
        guard let fin = pendingFinSeq else { return }
        if fin == rcvNxt {
            pendingFinSeq = nil
            rcvNxt = rcvNxt &+ 1
            handleFinReceived(now: time)
        } else if tcpSeqLess(fin, rcvNxt) {
            // Overlapping data already moved past the FIN: the peer is done.
            pendingFinSeq = nil
            handleFinReceived(now: time)
        }
    }

    private func handleFinReceived(now time: TimeInterval) {
        switch state {
        case .established:
            // Half-close: signal EOF but keep the send side usable until the
            // application calls close()/abort() or the idle timeout fires.
            state = .closeWait
            emit(.closed)
        case .finWait1:
            if finAcked {
                enterTimeWait(now: time)
            } else {
                state = .closing
            }
        case .finWait2:
            enterTimeWait(now: time)
        case .closing, .closeWait, .lastAck, .timeWait, .synSent, .closed:
            break
        }
    }

    private func enterTimeWait(now time: TimeInterval) {
        state = .timeWait
        timeWaitDeadline = time + configuration.timeWaitTimeout
        unacked.removeAll()
        outBuf.removeAll()
        rtoDeadline = nil
        zeroWindowDeadline = nil
        emit(.closed)
    }

    // MARK: Outbound processing

    private func transmit() {
        guard let stack = stack, !stackClosed else { return }
        let time = stack.now()

        while state == .established || state == .closeWait {
            let inFlight = Int(sndNxt &- sndUna)
            guard inFlight < outBuf.count else { break }
            let available = windowAvailable()
            guard available > 0 else {
                armZeroWindowProbe(now: time)
                return
            }
            let mss = Int(min(peerMSS, configuration.maxSegmentSize))
            let chunk = min(mss, min(outBuf.count - inFlight, available))
            guard chunk > 0 else { break }

            let seq = sndUna &+ UInt32(inFlight)
            let payload = Array(outBuf[inFlight..<(inFlight + chunk)])
            let segment = TcpSegment(sourcePort: localPort,
                                     destinationPort: remote.port,
                                     sequence: seq,
                                     acknowledgment: rcvNxt,
                                     flags: TcpSegment.ack | TcpSegment.psh,
                                     window: advertisedWindow(),
                                     maxSegmentSize: nil,
                                     windowScale: nil,
                                     payload: payload)
            stack.sendSegment(segment, destination: remote.address, options: [])
            sndNxt = seq &+ UInt32(chunk)
            unacked.append(Outstanding(sequence: seq, length: chunk,
                                       isFin: false, retransmitted: false))
            bytesOut += UInt64(chunk)
            if rtoDeadline == nil { rtoDeadline = time + rto }
            lastActivity = time
        }

        if closeRequested && !finSent && (state == .established || state == .closeWait) {
            sendFin(now: time)
        }
    }

    private func sendFin(now time: TimeInterval) {
        guard !finSent, state == .established || state == .closeWait else { return }
        finSent = true
        let segment = TcpSegment(sourcePort: localPort,
                                 destinationPort: remote.port,
                                 sequence: sndNxt,
                                 acknowledgment: rcvNxt,
                                 flags: TcpSegment.fin | TcpSegment.ack,
                                 window: advertisedWindow(),
                                 maxSegmentSize: nil,
                                 windowScale: nil,
                                 payload: [])
        stack?.sendSegment(segment, destination: remote.address, options: [])
        unacked.append(Outstanding(sequence: sndNxt, length: 1,
                                   isFin: true, retransmitted: false))
        sndNxt = sndNxt &+ 1
        if rtoDeadline == nil { rtoDeadline = time + rto }
        state = state == .established ? .finWait1 : .lastAck
        lastActivity = time
    }

    private func windowAvailable() -> Int {
        guard tcpSeqLess(sndNxt, sndWndRight) else { return 0 }
        return Int(sndWndRight &- sndNxt)
    }

    private func armZeroWindowProbe(now time: TimeInterval) {
        if zeroWindowDeadline == nil {
            zeroWindowDeadline = time + zeroWindowInterval
        }
    }

    private func retransmitOldest(now time: TimeInterval, fast: Bool) {
        guard let stack = stack, !unacked.isEmpty else { return }
        let first = unacked[0]

        if first.isFin {
            let segment = TcpSegment(sourcePort: localPort,
                                     destinationPort: remote.port,
                                     sequence: first.sequence,
                                     acknowledgment: rcvNxt,
                                     flags: TcpSegment.fin | TcpSegment.ack,
                                     window: advertisedWindow(),
                                     maxSegmentSize: nil,
                                     windowScale: nil,
                                     payload: [])
            stack.sendSegment(segment, destination: remote.address, options: [])
        } else {
            let offset = Int(first.sequence &- sndUna)
            guard offset >= 0, offset < outBuf.count else { return }
            let end = min(offset + first.length, outBuf.count)
            guard end > offset else { return }
            let payload = Array(outBuf[offset..<end])
            let segment = TcpSegment(sourcePort: localPort,
                                     destinationPort: remote.port,
                                     sequence: first.sequence,
                                     acknowledgment: rcvNxt,
                                     flags: TcpSegment.ack | TcpSegment.psh,
                                     window: advertisedWindow(),
                                     maxSegmentSize: nil,
                                     windowScale: nil,
                                     payload: payload)
            stack.sendSegment(segment, destination: remote.address, options: [])
        }

        unacked[0].retransmitted = true
        if !fast {
            rto = min(rto * 2, configuration.maximumRTO)
        }
        rtoDeadline = time + rto
    }

    private func sendZeroWindowProbe(now time: TimeInterval) {
        let inFlight = Int(sndNxt &- sndUna)
        if inFlight < outBuf.count {
            // Classic probe: one byte at sndNxt, outside the closed window.
            // It is not counted as sent, so it is repeated normally later.
            let seq = sndNxt
            let payload = [outBuf[inFlight]]
            let segment = TcpSegment(sourcePort: localPort,
                                     destinationPort: remote.port,
                                     sequence: seq,
                                     acknowledgment: rcvNxt,
                                     flags: TcpSegment.ack | TcpSegment.psh,
                                     window: advertisedWindow(),
                                     maxSegmentSize: nil,
                                     windowScale: nil,
                                     payload: payload)
            stack?.sendSegment(segment, destination: remote.address, options: [])
        } else {
            sendAck()
        }
        lastActivity = time
    }

    private func sendAck() {
        guard let stack = stack, !stackClosed else { return }
        let segment = TcpSegment(sourcePort: localPort,
                                 destinationPort: remote.port,
                                 sequence: sndNxt,
                                 acknowledgment: rcvNxt,
                                 flags: TcpSegment.ack,
                                 window: advertisedWindow(),
                                 maxSegmentSize: nil,
                                 windowScale: nil,
                                 payload: [])
        stack.sendSegment(segment, destination: remote.address, options: [])
    }

    private func sendReset() {
        guard let stack = stack, !stackClosed else { return }
        let segment = TcpSegment(sourcePort: localPort,
                                 destinationPort: remote.port,
                                 sequence: sndNxt,
                                 acknowledgment: rcvNxt,
                                 flags: rcvNxt == 0 ? TcpSegment.rst : TcpSegment.rst | TcpSegment.ack,
                                 window: 0,
                                 maxSegmentSize: nil,
                                 windowScale: nil,
                                 payload: [])
        stack.sendSegment(segment, destination: remote.address, options: [])
    }

    private func advertisedWindow() -> UInt16 {
        let available = max(0, configuration.receiveWindow - outOfOrderBytes)
        let scaled = available >> Int(configuration.receiveWindowScale)
        return UInt16(min(scaled, 65535))
    }

    // MARK: Timers

    /// Returns true when the connection must be removed from the stack.
    fileprivate func driveTimers(now time: TimeInterval) -> Bool {
        guard !stackClosed else { return true }

        switch state {
        case .timeWait:
            if let deadline = timeWaitDeadline, time >= deadline {
                state = .closed
                return true
            }
            return false
        case .synSent:
            if let deadline = connectDeadline, time >= deadline {
                fail("connection timed out")
                return true
            }
            if let retransmitAt = nextSynRetransmit, time >= retransmitAt {
                sendSyn()
                rto = min(rto * 2, configuration.maximumRTO)
                nextSynRetransmit = time + rto
            }
            return false
        case .closed:
            return true
        default:
            break
        }

        if let deadline = rtoDeadline, time >= deadline, !unacked.isEmpty {
            retransmitOldest(now: time, fast: false)
        }

        if let probeAt = zeroWindowDeadline, time >= probeAt {
            if windowAvailable() > 0 {
                zeroWindowDeadline = nil
                zeroWindowInterval = configuration.zeroWindowProbeInterval
                transmit()
            } else {
                sendZeroWindowProbe(now: time)
                zeroWindowInterval = min(zeroWindowInterval * 2,
                                         configuration.maximumZeroWindowProbeInterval)
                zeroWindowDeadline = time + zeroWindowInterval
            }
        }

        if time - lastActivity >= configuration.idleTimeout {
            if closeRequested || state == .finWait2 || state == .closing || state == .lastAck {
                // The application already closed; report completion, not an error.
                state = .closed
                emit(.closed)
            } else {
                fail("connection idle timeout")
            }
            return true
        }
        return false
    }

    fileprivate func isFinished(at time: TimeInterval) -> Bool {
        if state == .closed { return true }
        if state == .timeWait, let deadline = timeWaitDeadline, time >= deadline { return true }
        return false
    }

    // MARK: Events

    private func fail(_ reason: String) {
        guard !stackClosed, state != .closed else { return }
        state = .closed
        emit(.failed(reason))
        stack?.removeConnection(self)
    }

    /// Terminal events (`closed` / `failed`) are delivered at most once.
    private func emit(_ event: TunnelTcpEvent) {
        switch event {
        case .closed, .failed:
            guard !terminalEmitted else { return }
            terminalEmitted = true
        case .connected, .data:
            break
        }
        onEvent(event)
    }
}
