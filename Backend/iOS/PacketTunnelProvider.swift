// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune Packet Tunnel for iOS 17+.
// CSQTT / CSQTTR are linked into the Network Extension as native static libs.
// The core starts first; only after TUNCONF + 3 consecutive Active > 0
// do we create the iOS tunnel interface and bridge packets to the core's UDP TUN.

import Foundation
import NetworkExtension
import Network

private final class CoreReadinessState {
    static let shared = CoreReadinessState()

    private let condition = NSCondition()
    private var tunIP: String?
    private var dnsServers: [String] = []
    private var consecutiveActive = 0
    private var coreExitCode: Int32?

    private let tunconf = try! NSRegularExpression(
        pattern: #"TUNCONF:([\d.]+):([\d.,]+)"#
    )
    private let tunconfAlt = try! NSRegularExpression(
        pattern: #"Tunnel IP:\s*([\d.]+)(?:/\d+)?\s*\|\s*DNS:\s*([\d.,]+)"#,
        options: [.caseInsensitive]
    )
    private let active = try! NSRegularExpression(
        pattern: #"Активных:\s*(\d+)"#,
        options: [.caseInsensitive]
    )

    func reset() {
        condition.lock()
        tunIP = nil
        dnsServers = []
        consecutiveActive = 0
        coreExitCode = nil
        condition.broadcast()
        condition.unlock()
    }

    func ingest(_ line: String) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        let fullRange = NSRange(line.startIndex..., in: line)
        for regex in [tunconf, tunconfAlt] {
            if let match = regex.firstMatch(in: line, range: fullRange),
               match.numberOfRanges >= 3,
               let ipRange = Range(match.range(at: 1), in: line),
               let dnsRange = Range(match.range(at: 2), in: line) {
                tunIP = String(line[ipRange])
                dnsServers = String(line[dnsRange])
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                break
            }
        }

        if let match = active.firstMatch(in: line, range: fullRange),
           match.numberOfRanges >= 2,
           let valueRange = Range(match.range(at: 1), in: line),
           let value = Int(line[valueRange]) {
            consecutiveActive = value > 0 ? consecutiveActive + 1 : 0
        }
    }

    func markCoreExited(_ code: Int32) {
        condition.lock()
        coreExitCode = code
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilReady(timeout: TimeInterval) -> (ip: String, dns: [String])? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while Date() < deadline {
            if let ip = tunIP, consecutiveActive >= 3 {
                return (ip, dnsServers.isEmpty ? ["1.1.1.1", "8.8.8.8"] : dnsServers)
            }
            if coreExitCode != nil { return nil }
            _ = condition.wait(until: deadline)
        }
        return nil
    }
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let appGroup = "group.com.lalune"
    private let coreListenPort: UInt16 = 52230

    private var udpConnection: NWConnection?
    private var isRunning = false
    private var isCoreStarted = false
    private var activeProtocol = "CSQTT"

    private let measurementLock = NSLock()
    private var measurementConfigId: Int64 = 0
    private var temporaryToken: String?
    private var measurementReady = false

    private let completionLock = NSLock()
    private var startCompletion: ((Error?) -> Void)?

    private let logCallback: csqtt_log_callback = { message in
        guard let message = message else { return }
        let line = String(cString: message)
        NSLog("[LALUNE-CORE] %@", line)
        CoreReadinessState.shared.ingest(line)

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lalune") else { return }
        let url = container.appendingPathComponent("la-lune/tunnel.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func makeError(_ message: String, code: Int) -> NSError {
        NSError(domain: "LaLuneTunnel", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func finishStart(_ error: Error?) {
        completionLock.lock()
        let completion = startCompletion
        startCompletion = nil
        completionLock.unlock()
        completion?(error)
    }

    private func log(_ message: String) {
        NSLog("[LALUNE-TUNNEL] %@", message)
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        let url = (container ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("la-lune/tunnel.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = "[\(Date())] \(message)\n".data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        startCompletion = completionHandler
        isRunning = true
        CoreReadinessState.shared.reset()

        let shared = UserDefaults(suiteName: appGroup)
        let token = options?["temporaryToken"] as? String
        // If this is a temporary start, use only its one-shot settings.
        func setting(_ key: String) -> Any? {
            if token != nil { return options?[key] }
            return shared?.object(forKey: key)
        }
        measurementLock.lock()
        temporaryToken = token
        measurementConfigId = (setting("configId") as? NSNumber)?.int64Value ?? 0
        measurementReady = false
        measurementLock.unlock()

        let protocolName = setting("protocol") as? String ?? "CSQTT"
        activeProtocol = protocolName
        let upperProtocol = protocolName.uppercased()

        guard upperProtocol.hasPrefix("CSQTT") || upperProtocol.hasPrefix("CSQTTR") else {
            finishStart(makeError("Unsupported iOS protocol: \(protocolName)", code: 10))
            return
        }

        let peer = (setting("peer") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = (setting("password") as? String) ?? ""
        let hashes = (setting("hashes") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawWorkers = (setting("workers") as? Int) ?? 0
        let workers = rawWorkers > 0 ? rawWorkers : 9
        let obfs = (setting("obfs") as? String) ?? "video"
        let fingerprint = (setting("fingerprint") as? String) ?? "firefox"
        let clientIds = (setting("clientIds") as? String) ?? "8202606,6287487"
        let vkAuthMode = (setting("vkAuthMode") as? String) ?? "vkcalls"
        let captchaMode = (setting("captchaMode") as? String) ?? "auto"
        let turnTransport = (setting("turnTransport") as? String) ?? "udp"
        let validateVkHashes = (setting("validateVkHashes") as? Bool) ?? false

        guard !peer.isEmpty else {
            finishStart(makeError("No CSQTT peer selected", code: 11)); return
        }
        guard !password.isEmpty else {
            finishStart(makeError("CSQTT password is empty", code: 12)); return
        }
        guard !hashes.isEmpty else {
            finishStart(makeError("VK hashes are empty", code: 13)); return
        }

        log("startTunnel protocol=\(protocolName) peer=\(peer) workers=\(workers)")

        if upperProtocol.hasPrefix("CSQTTR") {
            csqttr_set_log_callback(logCallback)
        } else {
            csqtt_set_log_callback(logCallback)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCore(
                peer: peer, password: password, hashes: hashes, workers: workers,
                obfs: obfs, fingerprint: fingerprint, clientIds: clientIds,
                vkAuthMode: vkAuthMode, captchaMode: captchaMode,
                turnTransport: turnTransport, validateVkHashes: validateVkHashes
            )
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let ready = CoreReadinessState.shared.waitUntilReady(timeout: 45) else {
                self.log("core did not become ready (TUNCONF + 3x active>0)")
                self.stopCore()
                self.finishStart(self.makeError(
                    "CSQTT core did not become ready before timeout", code: 14
                ))
                return
            }
            guard self.isRunning else {
                self.finishStart(self.makeError("Tunnel start was cancelled", code: 15))
                return
            }
            self.log("core ready; TUNCONF ip=\(ready.ip) dns=\(ready.dns.joined(separator: ","))")
            self.applyTunnelSettings(ip: ready.ip, dns: ready.dns)
        }
    }

    private func runCore(
        peer: String, password: String, hashes: String, workers: Int,
        obfs: String, fingerprint: String, clientIds: String,
        vkAuthMode: String, captchaMode: String, turnTransport: String,
        validateVkHashes: Bool
    ) {
        let listen = "127.0.0.1:\(coreListenPort)"
        isCoreStarted = true
        log("starting embedded \(activeProtocol) core")

        let result: Int32
        if activeProtocol.uppercased().hasPrefix("CSQTTR") {
            result = csqttr_run_extended(
                peer.cString(using: .utf8), hashes.cString(using: .utf8),
                password.cString(using: .utf8), listen.cString(using: .utf8),
                Int32(workers), "manual".cString(using: .utf8),
                vkAuthMode.cString(using: .utf8), captchaMode.cString(using: .utf8),
                fingerprint.cString(using: .utf8), clientIds.cString(using: .utf8),
                obfs.cString(using: .utf8), turnTransport.cString(using: .utf8),
                "auto".cString(using: .utf8), 0,
                "".cString(using: .utf8), "".cString(using: .utf8),
                "".cString(using: .utf8), "".cString(using: .utf8),
                validateVkHashes, "".cString(using: .utf8),
                false, false, false, false, "".cString(using: .utf8),
                false, false, "".cString(using: .utf8), false
            )
        } else {
            result = csqtt_run(
                peer.cString(using: .utf8), hashes.cString(using: .utf8),
                password.cString(using: .utf8), listen.cString(using: .utf8),
                Int32(workers), "manual".cString(using: .utf8),
                vkAuthMode.cString(using: .utf8), captchaMode.cString(using: .utf8),
                fingerprint.cString(using: .utf8), clientIds.cString(using: .utf8),
                obfs.cString(using: .utf8), turnTransport.cString(using: .utf8),
                "auto".cString(using: .utf8), 0,
                "".cString(using: .utf8), "".cString(using: .utf8),
                "".cString(using: .utf8), "".cString(using: .utf8),
                validateVkHashes, "".cString(using: .utf8),
                false, false, false, false, "".cString(using: .utf8),
                false, false, "".cString(using: .utf8), false
            )
        }

        isCoreStarted = false
        measurementLock.lock()
        measurementReady = false
        measurementLock.unlock()
        CoreReadinessState.shared.markCoreExited(result)
        log("embedded core exited with code \(result)")
        if isRunning {
            finishStart(makeError("Embedded core exited with code \(result)", code: 100 + Int(result)))
        }
    }

    private func applyTunnelSettings(ip: String, dns: [String]) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: ip)
        let ipv4 = NEIPv4Settings(addresses: [ip], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dns)
        settings.mtu = 1300

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("setTunnelNetworkSettings failed: \(error)")
                self.stopCore()
                self.finishStart(error)
                return
            }
            self.log("TUN settings applied")
            self.startUDPBridge()
        }
    }

    private func startUDPBridge() {
        guard isRunning else {
            finishStart(makeError("Tunnel stopped before UDP bridge start", code: 16))
            return
        }
        let host = NWEndpoint.Host("127.0.0.1")
        guard let port = NWEndpoint.Port(rawValue: coreListenPort) else {
            finishStart(makeError("Invalid core UDP port", code: 17))
            return
        }

        let connection = NWConnection(host: host, port: port, using: .udp)
        udpConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log("UDP packet bridge ready")
                self.measurementLock.lock()
                self.measurementReady = true
                self.measurementLock.unlock()
                self.finishStart(nil)
                self.startReadingFromTun()
                self.startReadingFromUDP()
            case .failed(let error):
                self.log("UDP packet bridge failed: \(error)")
                self.stopCore()
                self.finishStart(error)
            case .cancelled:
                self.log("UDP packet bridge cancelled")
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func startReadingFromTun() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self, self.isRunning else { return }
            for packet in packets {
                self.udpConnection?.send(
                    content: packet,
                    completion: .contentProcessed { [weak self] error in
                        if let error = error { self?.log("UDP uplink send failed: \(error)") }
                    }
                )
            }
            self.startReadingFromTun()
        }
    }

    private func startReadingFromUDP() {
        guard isRunning, let connection = udpConnection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, self.isRunning else { return }
            if let data = data, !data.isEmpty {
                let version = data.first.map { ($0 >> 4) & 0x0F } ?? 4
                let family = version == 6 ? AF_INET6 : AF_INET
                self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: family)])
            }
            if let error = error {
                self.log("UDP downlink receive failed: \(error)")
                self.cancelTunnelWithError(error)
                return
            }
            self.startReadingFromUDP()
        }
    }

    override func handleAppMessage(
        _ messageData: Data, completionHandler: ((Data?) -> Void)?
    ) {
        guard let reply = completionHandler,
              let command = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              command["operation"] as? String == "measure",
              let configId = (command["configId"] as? NSNumber)?.int64Value else {
            completionHandler?(nil)
            return
        }
        let token = command["temporaryToken"] as? String
        func replyJSON(_ value: [String: Any]) {
            reply(try? JSONSerialization.data(withJSONObject: value))
        }
        measurementLock.lock()
        let matches = measurementReady && configId == measurementConfigId && token == temporaryToken
        measurementLock.unlock()
        guard matches else {
            replyJSON(["conflict": true])
            return
        }

        // iOS 17-supported API: unlike NEProvider's ordinary socket API, this
        // explicitly injects the connection into this packet tunnel's utun.
        // The existing packetFlow <-> core UDP bridge carries the TCP handshake.
        // Numeric IPv4, no TLS or payload, no default-route fallback.
        let endpoint = NetworkExtension.NWHostEndpoint(hostname: "1.1.1.1", port: "443")
        let started = DispatchTime.now()
        let connection = createTCPConnectionThroughTunnel(
            to: endpoint, enableTLS: false, tlsParameters: nil, delegate: nil
        )
        DispatchQueue.global(qos: .userInitiated).async {
            defer { connection.cancel() }
            let terminal = DispatchSemaphore(value: 0)
            let observation = connection.observe(\.state, options: [.initial, .new]) { conn, _ in
                switch conn.state {
                case .connected, .disconnected, .cancelled: terminal.signal()
                default: break
                }
            }
            defer { observation.invalidate() }
            guard terminal.wait(timeout: started + 5) == .success,
                  connection.state == .connected else {
                replyJSON(["timeout": true])
                return
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            replyJSON(["latencyMs": max(1, elapsed)])
        }
    }

    private func stopCore() {
        if activeProtocol.uppercased().hasPrefix("CSQTTR") {
            _ = csqttr_stop()
        } else {
            _ = csqtt_stop()
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log("stopTunnel reason=\(reason.rawValue)")
        measurementLock.lock()
        measurementReady = false
        measurementLock.unlock()
        isRunning = false
        udpConnection?.stateUpdateHandler = nil
        udpConnection?.cancel()
        udpConnection = nil
        if isCoreStarted { stopCore() }
        finishStart(makeError("Tunnel stopped", code: 18))
        completionHandler()
    }
}
