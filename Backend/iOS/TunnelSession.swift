// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// iOS tunnel session without NetworkExtension.
//
// The CSQTT/CSQTTR core is linked into the app and started in-process. It
// speaks raw IPv4 over UDP on 127.0.0.1:52230. LaLune bridges those packets
// into a userspace stack (TCP + UDP) and exposes the result as a local SOCKS5
// proxy. The incy app is then asked, through its URL scheme, to route system
// traffic through that proxy. A fake VK call keeps the core's call hash alive
// and gives the process steady network activity.

import Foundation

@available(iOS 17.0, *)
final class TunnelSession {

    // MARK: - Types

    struct StartResult {
        var port: UInt16
        var incyOpened: Bool
        var incyURL: String
    }

    struct Snapshot {
        var state: String
        var connected: Bool
        var message: String
        var configId: Int64
        var socksPort: UInt16
        var tunnelIP: String
        var rxBytes: UInt64
        var txBytes: UInt64
        var activeConnections: Int
        var incyOpened: Bool
        /// "call" | "playback" | "off" — что именно держит приложение живым.
        var callMode: String
    }

    private let coreListenPort: UInt16 = 52230
    private let log: (String) -> Void
    private let emit: ([String: Any]) -> Void
    private let openURL: (URL) -> Bool

    private let queue = DispatchQueue(label: "lalune.tunnel.session")

    // Guarded by `queue` unless stated otherwise.
    private var state = "disconnected"
    private var message = ""
    private var configId: Int64 = 0
    private var protocolName = "CSQTT"
    private var tunnelIP = ""
    private var dnsServers: [String] = []
    private var running = false
    private var coreStarted = false
    private var socksPort: UInt16 = 0
    private var incyOpened = false
    private var temporary = false
    private var callModeEnabled = true
    private var rxBytes: UInt64 = 0
    private var txBytes: UInt64 = 0

    private var pump: PacketPump?
    private var tcpStack: TunnelTcpStack?
    private var udpNat: TunnelUdpNat?
    private var resolver: TunnelResolver?
    private var socksServer: TunnelSocks5Server?
    private var routing: Ipv4Routing?
    private var callKeepAlive: CallKeepAlive?
    private var tickTimer: DispatchSourceTimer?
    private var readyTimer: DispatchSourceTimer?

    /// Readiness bookkeeping shared with the core log callback.
    private let readinessLock = NSLock()
    private var readyIP: String?
    private var readyDNS: [String] = []
    private var activeTicks = 0
    private var coreExitCode: Int32?

    init(log: @escaping (String) -> Void,
         emit: @escaping ([String: Any]) -> Void,
         openURL: @escaping (URL) -> Bool) {
        self.log = log
        self.emit = emit
        self.openURL = openURL
    }

    // MARK: - Status

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(state: state, connected: state == "connected",
                     message: message, configId: configId, socksPort: socksPort,
                     tunnelIP: tunnelIP, rxBytes: rxBytes, txBytes: txBytes,
                     activeConnections: socksServer?.activeConnections ?? 0,
                     incyOpened: incyOpened,
                     callMode: callKeepAlive?.statusDescription ?? "off")
        }
    }

    /// Re-opens the incy registration URL for an already running session.
    func reapplyIncy(template: String?) -> (Bool, String) {
        queue.sync {
            guard state == "connected", socksPort != 0 else {
                return (false, "VPN is not connected")
            }
            let config = makeIncyConfig(port: socksPort)
            guard let url = config.url(template: template) else {
                return (false, "cannot build incy url")
            }
            let opened = openURL(url)
            incyOpened = opened
            log("[INCY] \(opened ? "opened" : "could not open") \(url.absoluteString)")
            return (opened, url.absoluteString)
        }
    }

    // MARK: - Start

    func start(config: [String: Any], settings: [String: Any], configId id: Int64,
               temporary isTemporary: Bool,
               completion: @escaping (Result<StartResult, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.running else {
                completion(.failure(TunnelError.proxyFailure("VPN is already running")))
                return
            }
            self.configId = id
            self.temporary = isTemporary
            self.setState("connecting", "Подключение")
            self.startLocked(config: config, settings: settings, completion: completion)
        }
    }

    private func startLocked(config: [String: Any], settings: [String: Any],
                             completion: @escaping (Result<StartResult, Error>) -> Void) {
        let protocolName = (config["protocol"] as? String)
            ?? (settings["protocol"] as? String) ?? "CSQTT"
        let upper = protocolName.uppercased()
        guard upper.hasPrefix("CSQTT") || upper.hasPrefix("CSQTTR") else {
            fail("iOS поддерживает только CSQTT/CSQTTR", completion: completion)
            return
        }
        self.protocolName = upper.hasPrefix("CSQTTR") ? "CSQTTR" : protocolName

        let peer = (config["peer"] as? String ?? settings["peer"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = config["password"] as? String ?? settings["password"] as? String ?? ""
        let hashes = (config["hashes"] as? String
            ?? settings["vkHashes"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { fail("Не выбран CSQTT peer", completion: completion); return }
        guard !password.isEmpty else { fail("Пустой пароль CSQTT", completion: completion); return }
        guard !hashes.isEmpty else { fail("Пустые VK-хеши", completion: completion); return }

        let workers = settings["workers"] as? Int ?? 9
        let obfs = settings["obfs"] as? String ?? "video"
        let fingerprint = settings["fingerprint"] as? String ?? "firefox"
        let clientIds = settings["clientIds"] as? String ?? "8202606,6287487"
        let vkAuthMode = settings["vkAuthMode"] as? String ?? "vkcalls"
        let captchaMode = settings["captchaMode"] as? String ?? "auto"
        let turnTransport = settings["turnTransport"] as? String ?? "udp"
        let validate = settings["validateVkHashes"] as? Bool ?? false
        self.callModeEnabled = settings["iosCallMode"] as? Bool ?? true
        var extraIPs = Self.splitList(settings["ipRoutingIps"] as? String)
        let extraDomains = Self.splitList(settings["directDomains"] as? String)
        // The core's own peer must stay outside the proxy: incy routes the
        // whole device, including our sockets, so a tunnelled peer would loop
        // the core's transport back into itself.
        if let peerIP = Self.ipv4FromHostPort(peer) {
            extraIPs.append("\(PacketCodec.ipv4String(peerIP))/32")
        }

        // Local networks plus the services our own core depends on (VK calls,
        // CDN, updates) must never be sent through the proxy.
        let routes = Ipv4Routing(localRanges: true, extraCidrs: extraIPs,
                                 extraDomains: extraDomains, includeServices: true)
        self.routing = routes
        self.running = true
        self.resetReadiness()
        // The C log callback has no context pointer, so the sink looks the
        // active session up here before the core starts printing.
        TunnelSession.active = self

        // «Режим звонка» поднимается после старта ядра: до этого процесс и
        // так активен, а сессию звонка лучше держать как можно ближе к
        // моменту, когда приложение уйдёт в фон.

        log("[TUNNEL] start protocol=\(self.protocolName) peer=\(peer) workers=\(workers)")

        installCoreLogHandler()

        let directIPs = routes.bypassArgument
        let directDomains = routes.bypassDomains.joined(separator: ",")
        let listen = "127.0.0.1:\(coreListenPort)"
        let csqttr = self.protocolName.uppercased().hasPrefix("CSQTTR")
        self.coreStarted = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let code: Int32
            if csqttr {
                code = csqttr_run_extended(
                    peer.cString(using: .utf8), hashes.cString(using: .utf8),
                    password.cString(using: .utf8), listen.cString(using: .utf8),
                    Int32(workers), "manual".cString(using: .utf8),
                    vkAuthMode.cString(using: .utf8), captchaMode.cString(using: .utf8),
                    fingerprint.cString(using: .utf8), clientIds.cString(using: .utf8),
                    obfs.cString(using: .utf8), turnTransport.cString(using: .utf8),
                    "auto".cString(using: .utf8), 0,
                    "".cString(using: .utf8), "".cString(using: .utf8),
                    "".cString(using: .utf8), "".cString(using: .utf8),
                    validate, "".cString(using: .utf8),
                    true, false, false, false, directDomains.cString(using: .utf8),
                    true, false, directIPs.cString(using: .utf8), false
                )
            } else {
                code = csqtt_run(
                    peer.cString(using: .utf8), hashes.cString(using: .utf8),
                    password.cString(using: .utf8), listen.cString(using: .utf8),
                    Int32(workers), "manual".cString(using: .utf8),
                    vkAuthMode.cString(using: .utf8), captchaMode.cString(using: .utf8),
                    fingerprint.cString(using: .utf8), clientIds.cString(using: .utf8),
                    obfs.cString(using: .utf8), turnTransport.cString(using: .utf8),
                    "auto".cString(using: .utf8), 0,
                    "".cString(using: .utf8), "".cString(using: .utf8),
                    "".cString(using: .utf8), "".cString(using: .utf8),
                    validate, "".cString(using: .utf8),
                    true, false, false, false, directDomains.cString(using: .utf8),
                    true, false, directIPs.cString(using: .utf8), false
                )
            }
            self?.coreExited(code)
        }

        waitForCoreReady(deadline: Date().addingTimeInterval(60)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.teardownLocked()
                self.fail(error.localizedDescription, completion: completion)
            case .success(let ready):
                self.tunnelIP = ready.0
                self.dnsServers = ready.1
                self.bringUpProxy(completion: completion)
            }
        }
    }

    // MARK: - Core readiness

    private func resetReadiness() {
        readinessLock.lock()
        readyIP = nil
        readyDNS = []
        activeTicks = 0
        coreExitCode = nil
        readinessLock.unlock()
    }

    private func installCoreLogHandler() {
        let callback: csqtt_log_callback = { pointer in
            guard let pointer = pointer else { return }
            TunnelSession.active?.ingestCoreLine(String(cString: pointer))
        }
        csqtt_set_log_callback(callback)
        csqttr_set_log_callback(callback)
    }

    /// Only one session exists at a time; the C callback cannot capture `self`,
    /// so it looks the instance up here.
    private static weak var active: TunnelSession?

    private func ingestCoreLine(_ line: String) {
        log("[CORE] \(line)")
        let parsed = CoreLogParser.parse(line)
        readinessLock.lock()
        if let ip = parsed.tunIP {
            readyIP = ip
            readyDNS = parsed.dns
        }
        if let active = parsed.active {
            activeTicks = active > 0 ? activeTicks + 1 : 0
        }
        readinessLock.unlock()
    }

    private func coreExited(_ code: Int32) {
        readinessLock.lock()
        coreExitCode = code
        readinessLock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.coreStarted = false
            guard self.running else { return }
            self.log("[TUNNEL] ядро завершилось с кодом \(code)")
            self.teardownLocked()
            self.setState("error", "Ядро завершилось (код \(code))")
        }
    }

    private func waitForCoreReady(deadline: Date,
                                  completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.running else {
                timer.cancel()
                completion(.failure(TunnelError.tunnelNotReady))
                return
            }
            self.readinessLock.lock()
            let ip = self.readyIP
            let dns = self.readyDNS
            let ticks = self.activeTicks
            let exit = self.coreExitCode
            self.readinessLock.unlock()

            if let ip = ip, ticks >= 3 {
                timer.cancel()
                self.readyTimer = nil
                completion(.success((ip, dns.isEmpty ? ["1.1.1.1", "8.8.8.8"] : dns)))
                return
            }
            if exit != nil {
                timer.cancel()
                self.readyTimer = nil
                completion(.failure(TunnelError.tunnelNotReady))
                return
            }
            if Date() >= deadline {
                timer.cancel()
                self.readyTimer = nil
                completion(.failure(TunnelError.tunnelNotReady))
            }
        }
        readyTimer = timer
        timer.resume()
    }

    // MARK: - Proxy bring-up

    private func bringUpProxy(completion: @escaping (Result<StartResult, Error>) -> Void) {
        guard running else {
            completion(.failure(TunnelError.tunnelNotReady))
            return
        }
        guard let localAddress = PacketCodec.ipv4Address(tunnelIP) else {
            teardownLocked()
            fail("Некорректный адрес туннеля: \(tunnelIP)", completion: completion)
            return
        }

        let pump = PacketPump(host: "127.0.0.1", port: coreListenPort)
        let tcp = TunnelStackFactory.makeTcpStack(localAddress: localAddress) { packet in
            pump.send(packet)
        }
        let nat = TunnelStackFactory.makeUdpNat(localAddress: localAddress) { packet in
            pump.send(packet)
        }
        pump.onDatagram = { [weak self] packet in
            guard let self = self,
                  let datagram = PacketCodec.parseIPv4(packet) else { return }
            self.counters(for: datagram)
            switch datagram.transport {
            case .tcp:
                tcp.handle(datagram)
            case .udp:
                nat.handle(datagram)
            case .other:
                break
            }
        }
        pump.onStateChange = { [weak self] ready, error in
            guard let self = self else { return }
            if !ready, let error = error {
                self.log("[TUNNEL] UDP bridge failed: \(error)")
                self.queue.async {
                    guard self.running else { return }
                    self.teardownLocked()
                    self.setState("error", "Мост до ядра упал: \(error)")
                }
            }
        }
        guard pump.start() else {
            teardownLocked()
            fail("Не удалось открыть UDP-мост к ядру", completion: completion)
            return
        }

        let resolver = TunnelResolver(nat: nat, servers: dnsServers)
        guard let routes = routing else {
            teardownLocked()
            fail("Не заданы маршруты", completion: completion)
            return
        }
        let socks = TunnelSocks5Server(
            routing: routes,
            makeStack: { tcp },
            resolver: resolver,
            nat: nat
        )
        let port: UInt16
        do {
            port = try socks.start()
        } catch {
            pump.stop()
            teardownLocked()
            fail("SOCKS5 не запустился: \(error.localizedDescription)", completion: completion)
            return
        }

        self.pump = pump
        self.tcpStack = tcp
        self.udpNat = nat
        self.resolver = resolver
        self.socksServer = socks
        self.socksPort = port
        log("[PROXY] SOCKS5 на 127.0.0.1:\(port)")

        startTickTimer()
        if callModeEnabled {
            let call = CallKeepAlive(log: { [weak self] line in self?.log(line) })
            if call.start() {
                self.callKeepAlive = call
            } else {
                self.log("[CALL] режим звонка недоступен; продолжаем без него")
            }
        }

        // Traffic bookkeeping for the UI.
        emit(["type": "status", "state": "connected", "connected": true,
              "configId": configId, "socks5Port": Int(port),
              "message": "", "ts": Int(Date().timeIntervalSince1970)])

        let incy = makeIncyConfig(port: port)
        var opened = false
        if let url = incy.url(template: nil) {
            opened = openURL(url)
            log("[INCY] \(opened ? "открыт" : "не открылся") \(url.absoluteString)")
        }
        if !opened {
            log("[INCY] не удалось открыть incy; импортируйте SOCKS5 127.0.0.1:\(port) вручную")
        }
        incyOpened = opened
        setState("connected", "")

        completion(.success(StartResult(port: port, incyOpened: opened,
                                        incyURL: incy.url(template: nil)?.absoluteString ?? "")))
    }

    private func makeIncyConfig(port: UInt16) -> IncyConfig {
        let routes = routing ?? Ipv4Routing(localRanges: true, includeServices: true)
        // `bypassCidrs` already contains loopback; IncyConfig dedupes anyway.
        return IncyConfig(host: "127.0.0.1", port: port, name: "LaLune",
                          bypassCidrs: routes.bypassCidrs,
                          bypassDomains: routes.bypassDomains)
    }

    private func counters(for datagram: Ipv4Datagram) {
        switch datagram.transport {
        case .tcp(let segment):
            rxBytes &+= UInt64(segment.payload.count)
        case .udp(let udp):
            rxBytes &+= UInt64(udp.payload.count)
        case .other:
            break
        }
    }

    private func startTickTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.running else { return }
            self.tcpStack?.tick()
        }
        tickTimer = timer
        timer.resume()
    }

    // MARK: - Stop

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { completion?(); return }
            guard self.running || self.coreStarted else {
                self.setState("disconnected", "")
                completion?()
                return
            }
            self.setState("disconnecting", "Отключение...")
            self.teardownLocked()
            DispatchQueue.global(qos: .userInitiated).async {
                if self.protocolName.uppercased().hasPrefix("CSQTTR") {
                    _ = csqttr_stop()
                } else {
                    _ = csqtt_stop()
                }
                self.readinessLock.lock()
                self.coreExitCode = -1
                self.readinessLock.unlock()
                self.queue.async {
                    self.setState("disconnected", "")
                    self.emit(["type": "status", "state": "disconnected",
                               "connected": false, "configId": 0,
                               "ts": Int(Date().timeIntervalSince1970)])
                    completion?()
                }
            }
        }
    }

    /// Releases every resource of the current session. Called on `queue`.
    private func teardownLocked() {
        tickTimer?.cancel(); tickTimer = nil
        readyTimer?.cancel(); readyTimer = nil
        socksServer?.stop(); socksServer = nil
        tcpStack?.closeAll(); tcpStack = nil
        udpNat?.closeAll(); udpNat = nil
        resolver?.clearCache(); resolver = nil
        pump?.stop(); pump = nil
        callKeepAlive?.stop(); callKeepAlive = nil
        running = false
        socksPort = 0
        incyOpened = false
        tunnelIP = ""
        resetReadiness()
    }

    // MARK: - Measurement

    func measure(completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.running, let stack = self.tcpStack else {
                completion(.failure(TunnelError.tunnelNotReady))
                return
            }
            guard let target = PacketCodec.ipv4Address("1.1.1.1") else {
                completion(.failure(TunnelError.invalidPacket("target")))
                return
            }
            let started = Date()
            var finished = false
            // Assigned below; the event closure needs it before the initializer
            // returns, so it is captured through an optional box.
            var connection: TunnelTcpConnection?
            connection = stack.open(remote: IPv4Endpoint(address: target, port: 443),
                                    timeout: 8) { event in
                guard !finished else { return }
                switch event {
                case .connected:
                    finished = true
                    let ms = max(1, Int(Date().timeIntervalSince(started) * 1000))
                    connection?.abort()
                    completion(.success(ms))
                case .failed(let detail):
                    finished = true
                    completion(.failure(TunnelError.tcpConnectionFailed(detail)))
                case .closed:
                    finished = true
                    completion(.failure(TunnelError.tcpConnectionFailed("closed before handshake")))
                case .data:
                    break
                }
            }
            // The stack may time out without emitting an event.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                guard !finished else { return }
                finished = true
                connection?.abort()
                completion(.failure(TunnelError.tcpTimeout))
            }
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: String, _ newMessage: String) {
        state = newState
        message = newMessage
        emit(["type": "status", "state": newState,
              "connected": newState == "connected", "configId": configId,
              "message": newMessage, "socks5Port": Int(socksPort),
              "ts": Int(Date().timeIntervalSince1970)])
    }

    private func fail(_ text: String,
                      completion: @escaping (Result<StartResult, Error>) -> Void) {
        setState("error", text)
        completion(.failure(TunnelError.proxyFailure(text)))
    }

    /// `"1.2.3.4:443"` -> 0x01020304; nil for hostnames (they stay in
    /// `serviceDomains` instead).
    private static func ipv4FromHostPort(_ peer: String) -> UInt32? {
        guard let separator = peer.lastIndex(of: ":") else { return nil }
        return PacketCodec.ipv4Address(String(peer[peer.startIndex..<separator]))
    }

    private static func splitList(_ value: String?) -> [String] {
        guard let value = value else { return [] }
        return value
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

}

// MARK: - Core log parsing

/// Parses the two structured lines the core prints: tunnel parameters and
/// per-second statistics.
enum CoreLogParser {
    struct Result {
        var tunIP: String?
        var dns: [String] = []
        var active: Int?
    }

    private static let tunconf = try! NSRegularExpression(
        pattern: #"TUNCONF:([\d.]+):([\d.,]+)"#)
    private static let tunconfAlt = try! NSRegularExpression(
        pattern: #"Tunnel IP:\s*([\d.]+)(?:/\d+)?\s*\|\s*DNS:\s*([\d.,]+)"#,
        options: [.caseInsensitive])
    private static let active = try! NSRegularExpression(
        pattern: #"Активных:\s*(\d+)"#, options: [.caseInsensitive])

    static func parse(_ line: String) -> Result {
        var result = Result()
        let range = NSRange(line.startIndex..., in: line)
        for regex in [tunconf, tunconfAlt] {
            if let match = regex.firstMatch(in: line, range: range),
               match.numberOfRanges >= 3,
               let ipRange = Range(match.range(at: 1), in: line),
               let dnsRange = Range(match.range(at: 2), in: line) {
                result.tunIP = String(line[ipRange])
                result.dns = String(line[dnsRange])
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                break
            }
        }
        if let match = active.firstMatch(in: line, range: range),
           match.numberOfRanges >= 2,
           let valueRange = Range(match.range(at: 1), in: line) {
            result.active = Int(line[valueRange])
        }
        return result
    }
}

/// Small path/token helpers shared with `Backend`.
enum SettingsPaths {
    static let appGroup = "group.com.lalune"

    static var appDir: URL {
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let dir = container.appendingPathComponent("la-lune", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("la-lune", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
