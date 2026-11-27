// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// UDP NAT for the userspace tunnel: every SOCKS5 UDP association gets a local
// ephemeral port, datagrams are rewritten between the application endpoint and
// the remote endpoint, and idle associations are evicted. Foundation only.

import Foundation

final class UdpNat: TunnelUdpNat {

    /// Tuning knobs; the defaults are the on-device values.
    struct Configuration {
        var idleTimeout: TimeInterval = 120
        var maximumFlows = 512
        var portRange: ClosedRange<UInt16> = 49152...65535
    }

    private let localAddress: UInt32
    private let sendPacket: ([UInt8]) -> Void
    private let configuration: Configuration
    private let clock: () -> TimeInterval

    private let lock = NSRecursiveLock()
    private var flows: [UInt16: UdpFlow] = [:]
    private var shutDown = false

    /// Production initializer used by `TunnelStackFactory`.
    convenience init(localAddress: UInt32, send: @escaping ([UInt8]) -> Void) {
        self.init(localAddress: localAddress, send: send,
                  configuration: Configuration(),
                  clock: { ProcessInfo.processInfo.systemUptime })
    }

    /// Injectable initializer for tests and custom clocks.
    init(localAddress: UInt32,
         send: @escaping ([UInt8]) -> Void,
         configuration: Configuration,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.localAddress = localAddress
        self.sendPacket = send
        self.configuration = configuration
        self.clock = clock
    }

    // MARK: TunnelUdpNat

    func open(remote: IPv4Endpoint, onData: @escaping ([UInt8]) -> Void,
              onClosed: @escaping () -> Void) -> TunnelUdpFlow {
        lock.lock()
        defer { lock.unlock() }

        let time = clock()
        guard !shutDown else {
            let flow = UdpFlow(nat: self, localPort: 0, remote: remote,
                               onData: onData, onClosed: onClosed, now: time)
            flow.markClosed(notify: true)
            return flow
        }
        evictIdleLocked(now: time)

        guard flows.count < configuration.maximumFlows else {
            let flow = UdpFlow(nat: self, localPort: 0, remote: remote,
                               onData: onData, onClosed: onClosed, now: time)
            flow.markClosed(notify: true)
            return flow
        }
        guard let port = allocatePortLocked() else {
            let flow = UdpFlow(nat: self, localPort: 0, remote: remote,
                               onData: onData, onClosed: onClosed, now: time)
            flow.markClosed(notify: true)
            return flow
        }

        let flow = UdpFlow(nat: self, localPort: port, remote: remote,
                           onData: onData, onClosed: onClosed, now: time)
        flows[port] = flow
        return flow
    }

    func handle(_ datagram: Ipv4Datagram) {
        guard case .udp(let udp) = datagram.transport else { return }
        guard datagram.destination == localAddress else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !shutDown else { return }

        let time = clock()
        evictIdleLocked(now: time)

        guard let flow = flows[udp.destinationPort] else { return }
        guard flow.remote.address == datagram.source,
              flow.remote.port == udp.sourcePort else { return }
        flow.lastActivity = time
        flow.deliver(udp.payload)
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        shutDown = true
        let active = flows.values
        flows.removeAll()
        for flow in active {
            flow.markClosed(notify: true)
        }
    }

    var flowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return flows.count
    }

    // MARK: Internals used by UdpFlow

    fileprivate func sendDatagram(from flow: UdpFlow, payload: [UInt8]) {
        guard !shutDown else { return }
        let packet = PacketCodec.buildUdp(source: localAddress,
                                          destination: flow.remote.address,
                                          sourcePort: flow.localPort,
                                          destinationPort: flow.remote.port,
                                          payload: payload)
        sendPacket(packet)
    }

    fileprivate func closeFlow(_ flow: UdpFlow) {
        lock.lock()
        defer { lock.unlock() }
        if flows[flow.localPort] === flow {
            flows.removeValue(forKey: flow.localPort)
        }
        flow.markClosed(notify: true)
    }

    fileprivate func flowSend(_ flow: UdpFlow, payload: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard !shutDown, !flow.isClosed else { return }
        flow.lastActivity = clock()
        sendDatagram(from: flow, payload: payload)
    }

    // MARK: Private helpers

    /// Drops flows that saw no traffic for `idleTimeout` and reports closure.
    private func evictIdleLocked(now time: TimeInterval) {
        guard !flows.isEmpty else { return }
        var expired: [UdpFlow] = []
        for flow in flows.values where time - flow.lastActivity >= configuration.idleTimeout {
            expired.append(flow)
        }
        for flow in expired {
            if flows[flow.localPort] === flow {
                flows.removeValue(forKey: flow.localPort)
            }
            flow.markClosed(notify: true)
        }
    }

    private func allocatePortLocked() -> UInt16? {
        let range = configuration.portRange
        let span = Int(range.upperBound) - Int(range.lowerBound) + 1
        guard span > 0 else { return nil }
        let start = Int.random(in: 0..<span)
        for step in 0..<span {
            let port = UInt16(Int(range.lowerBound) + (start + step) % span)
            if flows[port] == nil { return port }
        }
        return nil
    }
}

// MARK: - Flow

final class UdpFlow: TunnelUdpFlow {

    let localPort: UInt16
    let remote: IPv4Endpoint

    private let onData: ([UInt8]) -> Void
    private let onClosed: () -> Void
    private weak var nat: UdpNat?

    fileprivate var lastActivity: TimeInterval
    fileprivate var isClosed = false

    init(nat: UdpNat, localPort: UInt16, remote: IPv4Endpoint,
         onData: @escaping ([UInt8]) -> Void, onClosed: @escaping () -> Void,
         now: TimeInterval) {
        self.nat = nat
        self.localPort = localPort
        self.remote = remote
        self.onData = onData
        self.onClosed = onClosed
        self.lastActivity = now
    }

    func send(_ payload: [UInt8]) {
        nat?.flowSend(self, payload: payload)
    }

    func close() {
        nat?.closeFlow(self)
    }

    fileprivate func deliver(_ payload: [UInt8]) {
        guard !isClosed else { return }
        onData(payload)
    }

    fileprivate func markClosed(notify: Bool) {
        guard !isClosed else { return }
        isClosed = true
        if notify { onClosed() }
    }
}
