// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SOCKS5-фронтенд userspace-туннеля. Заменяет старый Socks5Server: тот ходил
// в системный TUN, а этот — в собственный TCP-стек (TunnelTcpStack) и UDP NAT
// (TunnelUdpNat), которые общаются с ядром CSQTT сырыми IPv4-пакетами.
//
// Маршрутизация:
//   * адрес/домен из Ipv4Routing (локальные сети, сервисы ядра) — напрямую
//     через NWConnection в физическую сеть;
//   * всё остальное — в туннель, домен предварительно резолвится
//     TunnelResolver'ом (DNS тоже идёт через туннель).
//
// Стек не «тикает» сам: retransmission-таймеры двигает платформа
// (TunnelSession вызывает stack.tick()), чтобы не было двух источников тиков.
//
// Network.framework + Foundation.

import Foundation
import Network

final class TunnelSocks5Server {

    // MARK: - Константы SOCKS5

    fileprivate enum Socks {
        static let version: UInt8 = 0x05
        static let authNone: UInt8 = 0x00
        static let authUnacceptable: UInt8 = 0xFF

        static let cmdConnect: UInt8 = 0x01
        static let cmdBind: UInt8 = 0x02
        static let cmdUdpAssociate: UInt8 = 0x03

        static let atypIPv4: UInt8 = 0x01
        static let atypDomain: UInt8 = 0x03
        static let atypIPv6: UInt8 = 0x04

        // Коды ответов.
        static let succeeded: UInt8 = 0x00
        static let generalFailure: UInt8 = 0x01
        static let hostUnreachable: UInt8 = 0x04
        static let connectionRefused: UInt8 = 0x05
        static let ttlExpired: UInt8 = 0x06
        static let commandNotSupported: UInt8 = 0x07
        static let addressNotSupported: UInt8 = 0x08
    }

    // MARK: - Конфигурация

    private let host: String
    private let preferredPorts: [UInt16]
    fileprivate let routing: Ipv4Routing
    private let makeStack: () -> TunnelTcpStack
    fileprivate let resolver: TunnelResolver
    fileprivate let nat: TunnelUdpNat

    /// Вся работа с состоянием сервера идёт на этой последовательной очереди.
    fileprivate let queue = DispatchQueue(label: "lalune.socks5.tunnel")
    /// NWListener доставляет state-события на своей очереди. Она обязана быть
    /// отдельной: start()/beginUdpSession() синхронно ждут .ready, и если ждать
    /// на той же очереди, на которой приходит .ready, получится дедлок.
    fileprivate let listenerQueue = DispatchQueue(label: "lalune.socks5.listeners")
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var stack: TunnelTcpStack?
    private var tcpSessions: [ObjectIdentifier: TcpSession] = [:]
    private var udpSessions: [ObjectIdentifier: UdpSession] = [:]
    private var stopping = false

    private var _boundPort: UInt16 = 0

    /// Таймаут установки TCP-соединения (и прямого, и через туннель).
    fileprivate static let connectTimeout: TimeInterval = 12
    /// Сколько ждём закрытия со стороны туннеля после half-close клиента.
    fileprivate static let lingerTimeout: TimeInterval = 10
    /// Таймаут готовности NWListener/локального UDP-сокета.
    private static let readyTimeout: TimeInterval = 3

    // MARK: - Инициализация

    init(host: String = "127.0.0.1",
         preferredPorts: [UInt16] = [1080, 1180, 0],
         routing: Ipv4Routing,
         makeStack: @escaping () -> TunnelTcpStack,
         resolver: TunnelResolver,
         nat: TunnelUdpNat) {
        self.host = host
        self.preferredPorts = preferredPorts.isEmpty ? [0] : preferredPorts
        self.routing = routing
        self.makeStack = makeStack
        self.resolver = resolver
        self.nat = nat
    }

    // MARK: - Публичное состояние

    /// Порт, который реально слушается (0, пока не готов).
    var boundPort: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _boundPort
    }

    /// Сколько TCP-клиентов обслуживается прямо сейчас.
    var activeConnections: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tcpSessions.count
    }

    // MARK: - Жизненный цикл

    /// Поднимает listener на loopback. Пробует `preferredPorts` по порядку;
    /// 0 означает «любой свободный». Синхронно ждёт .ready.
    @discardableResult
    func start() throws -> UInt16 {
        stateLock.lock()
        if _boundPort != 0, listener != nil {
            let port = _boundPort
            stateLock.unlock()
            return port
        }
        stopping = false
        stateLock.unlock()

        var lastError: Error?
        for candidate in preferredPorts {
            let port: NWEndpoint.Port
            if candidate == 0 {
                port = .any
            } else if let value = NWEndpoint.Port(rawValue: candidate) {
                port = value
            } else {
                continue
            }

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Привязываемся только к loopback: наружу SOCKS5 без пароля
            // выставлять нельзя.
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)

            do {
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self else {
                        connection.cancel()
                        return
                    }
                    self.queue.async { self.accept(connection) }
                }
                guard let readyPort = waitForReady(listener) else {
                    listener.newConnectionHandler = nil
                    listener.cancel()
                    lastError = TunnelError.proxyFailure(
                        "SOCKS5 listener did not become ready on port \(candidate)")
                    continue
                }

                stateLock.lock()
                self.listener = listener
                _boundPort = readyPort
                stateLock.unlock()

                NSLog("[PROXY] SOCKS5 (tunnel) listening on %@:%d", host, Int(readyPort))
                return readyPort
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? TunnelError.proxyFailure("no usable SOCKS5 port")
    }

    /// Останавливает listener и закрывает всех клиентов.
    func stop() {
        stateLock.lock()
        stopping = true
        let listener = self.listener
        self.listener = nil
        _boundPort = 0
        let tcp = Array(tcpSessions.values)
        let udp = Array(udpSessions.values)
        tcpSessions.removeAll()
        udpSessions.removeAll()
        stateLock.unlock()

        listener?.newConnectionHandler = nil
        listener?.cancel()
        // Сессии закрываем на их очереди: иначе состояние, которым владеет
        // queue, менялось бы из чужого потока.
        for session in tcp {
            queue.async { session.close() }
        }
        for session in udp {
            queue.async { session.close() }
        }
        NSLog("[PROXY] SOCKS5 (tunnel) stopped")
    }

    /// Запускает listener и ждёт .ready, возвращая фактический порт.
    /// Listener стартует здесь же — повторный start(queue:) не нужен.
    private func waitForReady(_ listener: NWListener) -> UInt16? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: UInt16?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock()
                result = listener.port?.rawValue
                lock.unlock()
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: listenerQueue)
        _ = semaphore.wait(timeout: .now() + Self.readyTimeout)

        lock.lock()
        defer { lock.unlock() }
        return result
    }

    // MARK: - Приём TCP-клиентов

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        let blocked = stopping
        stateLock.unlock()
        guard !blocked else {
            connection.cancel()
            return
        }

        let session = TcpSession(server: self, connection: connection)
        stateLock.lock()
        tcpSessions[ObjectIdentifier(session)] = session
        stateLock.unlock()

        connection.start(queue: queue)
        session.begin()
    }

    fileprivate func finish(_ session: TcpSession) {
        stateLock.lock()
        tcpSessions.removeValue(forKey: ObjectIdentifier(session))
        stateLock.unlock()
    }

    fileprivate func finish(_ session: UdpSession) {
        stateLock.lock()
        udpSessions.removeValue(forKey: ObjectIdentifier(session))
        stateLock.unlock()
    }

    /// Стек создаётся лениво: makeStack может поднимать тяжёлые структуры.
    fileprivate func tcpStack() -> TunnelTcpStack {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let stack = stack { return stack }
        let created = makeStack()
        stack = created
        return created
    }

    // MARK: - SOCKS5: ответы

    /// Собирает ответ SOCKS5. BND.ADDR всегда IPv4 (ATYP=1): IPv6 не
    /// поддерживаем и в ответах не отдаём.
    fileprivate static func reply(_ code: UInt8, address: UInt32, port: UInt16) -> Data {
        var bytes: [UInt8] = [Socks.version, code, 0x00, Socks.atypIPv4]
        bytes.append(UInt8(address >> 24 & 0xFF))
        bytes.append(UInt8(address >> 16 & 0xFF))
        bytes.append(UInt8(address >> 8 & 0xFF))
        bytes.append(UInt8(address & 0xFF))
        bytes.append(UInt8(port >> 8 & 0xFF))
        bytes.append(UInt8(port & 0xFF))
        return Data(bytes)
    }

    // ============================================================
    //  TCP-сессия (greeting → request → мост)
    // ============================================================

    /// Одно клиентское TCP-соединение SOCKS5.
    fileprivate final class TcpSession {
        private weak var server: TunnelSocks5Server?
        private let client: NWConnection
        private var closed = false

        // Туннельная сторона (одно из двух).
        private var tunnel: TunnelTcpConnection?
        private var direct: NWConnection?
        private var udp: TunnelSocks5Server.UdpSession?
        private var connectTimer: DispatchSourceTimer?
        private var lingerTimer: DispatchSourceTimer?
        private var established = false
        /// Клиент прислал FIN, ответ ещё может прийти из туннеля.
        private var halfClosed = false

        init(server: TunnelSocks5Server, connection: NWConnection) {
            self.server = server
            self.client = connection
        }

        func begin() {
            readGreeting()
        }

        // MARK: Чтение запроса

        private func readGreeting() {
            client.receive(minimumIncompleteLength: 2, maximumLength: 2) {
                [weak self] data, _, _, error in
                guard let self = self, !self.closed else { return }
                guard error == nil, let data = data, data.count == 2,
                      data[0] == TunnelSocks5Server.Socks.version else {
                    self.close()
                    return
                }
                let count = Int(data[1])
                guard count > 0 else {
                    self.close()
                    return
                }
                self.client.receive(minimumIncompleteLength: count, maximumLength: count) {
                    [weak self] methods, _, _, error in
                    guard let self = self, !self.closed else { return }
                    guard error == nil, let methods = methods, methods.count == count else {
                        self.close()
                        return
                    }
                    // Поддерживаем только «без аутентификации».
                    guard methods.contains(TunnelSocks5Server.Socks.authNone) else {
                        self.sendRaw(Data([TunnelSocks5Server.Socks.version,
                                           TunnelSocks5Server.Socks.authUnacceptable])) {
                            self.close()
                        }
                        return
                    }
                    self.sendRaw(Data([TunnelSocks5Server.Socks.version,
                                       TunnelSocks5Server.Socks.authNone])) {
                        self.readRequest()
                    }
                }
            }
        }

        private func readRequest() {
            client.receive(minimumIncompleteLength: 4, maximumLength: 4) {
                [weak self] data, _, _, error in
                guard let self = self, !self.closed else { return }
                guard error == nil, let data = data, data.count == 4,
                      data[0] == TunnelSocks5Server.Socks.version else {
                    self.close()
                    return
                }
                let command = data[1]
                switch data[3] {
                case TunnelSocks5Server.Socks.atypIPv4:
                    self.readIPv4Tail(command: command)
                case TunnelSocks5Server.Socks.atypDomain:
                    self.readDomainTail(command: command)
                case TunnelSocks5Server.Socks.atypIPv6:
                    // IPv6 в этом стеке не поддерживается вовсе.
                    self.replyAndClose(TunnelSocks5Server.Socks.addressNotSupported)
                default:
                    self.replyAndClose(TunnelSocks5Server.Socks.addressNotSupported)
                }
            }
        }

        private func readIPv4Tail(command: UInt8) {
            client.receive(minimumIncompleteLength: 6, maximumLength: 6) {
                [weak self] data, _, _, error in
                guard let self = self, !self.closed else { return }
                guard error == nil, let data = data, data.count == 6 else {
                    self.close()
                    return
                }
                let address = UInt32(data[0]) << 24 | UInt32(data[1]) << 16
                    | UInt32(data[2]) << 8 | UInt32(data[3])
                let port = UInt16(data[4]) << 8 | UInt16(data[5])
                self.dispatch(command: command,
                              host: PacketCodec.ipv4String(address),
                              literal: address,
                              port: port)
            }
        }

        private func readDomainTail(command: UInt8) {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1) {
                [weak self] data, _, _, error in
                guard let self = self, !self.closed else { return }
                guard error == nil, let data = data, data.count == 1 else {
                    self.close()
                    return
                }
                let length = Int(data[0])
                guard length > 0 else {
                    self.replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                    return
                }
                self.client.receive(minimumIncompleteLength: length + 2,
                                    maximumLength: length + 2) {
                    [weak self] payload, _, _, error in
                    guard let self = self, !self.closed else { return }
                    guard error == nil, let payload = payload,
                          payload.count == length + 2 else {
                        self.close()
                        return
                    }
                    let nameBytes = payload[0..<length]
                    guard let name = String(bytes: nameBytes, encoding: .utf8),
                          !name.isEmpty else {
                        self.replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                        return
                    }
                    let port = UInt16(payload[length]) << 8 | UInt16(payload[length + 1])
                    self.dispatch(command: command, host: name, literal: nil, port: port)
                }
            }
        }

        private func dispatch(command: UInt8, host: String, literal: UInt32?, port: UInt16) {
            switch command {
            case TunnelSocks5Server.Socks.cmdConnect:
                connect(host: host, literal: literal, port: port)
            case TunnelSocks5Server.Socks.cmdUdpAssociate:
                associateUdp(host: host, literal: literal, port: port)
            case TunnelSocks5Server.Socks.cmdBind:
                replyAndClose(TunnelSocks5Server.Socks.commandNotSupported)
            default:
                replyAndClose(TunnelSocks5Server.Socks.commandNotSupported)
            }
        }

        // MARK: CONNECT

        private func connect(host: String, literal: UInt32?, port: UInt16) {
            guard port != 0 else {
                replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                return
            }
            guard let server = server else {
                replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                return
            }

            // 1. Прямой маршрут: локальные сети и сервисы ядра.
            let bypassByAddress = literal.map { server.routing.matches($0) } ?? false
            let bypassByDomain = server.routing.matchesDomain(host)
            if bypassByAddress || bypassByDomain {
                connectDirect(host: host, port: port)
                return
            }

            // 2. Туннель. Домен резолвим через DNS поверх туннеля.
            if let literal = literal {
                connectTunnel(remote: IPv4Endpoint(address: literal, port: port))
                return
            }
            server.resolver.resolve(host) { [weak self] result in
                guard let self = self else { return }
                self.onQueue {
                    guard !self.closed else { return }
                    switch result {
                    case .success(let address):
                        self.connectTunnel(remote: IPv4Endpoint(address: address, port: port))
                    case .failure(let error):
                        NSLog("[PROXY] resolve %@ failed: %@", host, error.localizedDescription)
                        self.replyAndClose(TunnelSocks5Server.Socks.hostUnreachable)
                    }
                }
            }
        }

        private func connectDirect(host: String, port: UInt16) {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            self.direct = connection
            startConnectTimer(code: TunnelSocks5Server.Socks.hostUnreachable)

            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, !self.closed else { return }
                switch state {
                case .ready:
                    self.established = true
                    self.cancelConnectTimer()
                    self.sendReply(TunnelSocks5Server.Socks.succeeded, address: 0, port: 0) {
                        self.startDirectBridge()
                    }
                case .failed(let error):
                    NSLog("[PROXY] direct connect %@:%d failed: %@", host, Int(port),
                          error.localizedDescription)
                    self.replyAndClose(TunnelSocks5Server.Socks.connectionRefused)
                case .cancelled:
                    self.close()
                default:
                    break
                }
            }
            connection.start(queue: self.queue())
        }

        private func connectTunnel(remote: IPv4Endpoint) {
            guard let server = server else {
                replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                return
            }
            startConnectTimer(code: TunnelSocks5Server.Socks.ttlExpired)
            let connection = server.tcpStack().open(
                remote: remote,
                timeout: TunnelSocks5Server.connectTimeout
            ) { [weak self] event in
                guard let self = self else { return }
                self.onQueue {
                    guard !self.closed else { return }
                    switch event {
                    case .connected:
                        self.established = true
                        self.cancelConnectTimer()
                        self.sendReply(TunnelSocks5Server.Socks.succeeded, address: 0, port: 0) {
                            self.pumpClientIntoTunnel()
                        }
                    case .data(let bytes):
                        self.client.send(content: Data(bytes),
                                         completion: .contentProcessed { _ in })
                    case .closed:
                        self.close()
                    case .failed(let reason):
                        NSLog("[PROXY] tunnel connect %@ failed: %@",
                              remote.description, reason)
                        self.replyAndClose(TunnelSocks5Server.Socks.connectionRefused)
                    }
                }
            }
            self.tunnel = connection
        }

        // MARK: Мост

        /// Клиент → цель (прямое соединение). Запускается ровно один раз;
        /// каждое следующее чтение перевзводится из своего completion.
        private func startDirectBridge() {
            pumpClientIntoDirect()
            pumpDirectIntoClient()
        }

        private func pumpClientIntoDirect() {
            guard !closed else { return }
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                guard let self = self, !self.closed, let direct = self.direct else { return }
                if let data = data, !data.isEmpty {
                    direct.send(content: data, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            self.close()
                            return
                        }
                        self.onQueue { self.pumpClientIntoDirect() }
                    })
                    return
                }
                if error != nil || isComplete {
                    // Клиент закрыл поток — закрываем и вторую сторону.
                    self.close()
                    return
                }
                self.onQueue { self.pumpClientIntoDirect() }
            }
        }

        private func pumpDirectIntoClient() {
            guard !closed, let direct = self.direct else { return }
            direct.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                guard let self = self, !self.closed else { return }
                if let data = data, !data.isEmpty {
                    self.client.send(content: data, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            self.close()
                            return
                        }
                        self.onQueue { self.pumpDirectIntoClient() }
                    })
                    return
                }
                if error != nil || isComplete {
                    self.close()
                    return
                }
                self.onQueue { self.pumpDirectIntoClient() }
            }
        }

        /// Клиент → туннель. Данные из туннеля приходят в onEvent, поэтому
        /// здесь читаем только клиента.
        private func pumpClientIntoTunnel() {
            guard !closed, !halfClosed else { return }
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                guard let self = self, !self.closed, !self.halfClosed else { return }
                if let data = data, !data.isEmpty {
                    self.tunnel?.send([UInt8](data))
                    self.onQueue { self.pumpClientIntoTunnel() }
                    return
                }
                if error != nil || isComplete {
                    // Half-close: досылаем FIN и ждём закрытия со стороны
                    // туннеля, чтобы не потерять ответ, который ещё в пути.
                    self.finishTunnelWrite()
                    return
                }
                self.onQueue { self.pumpClientIntoTunnel() }
            }
        }

        /// Клиент закончил писать. Закрываем свою половину и ждём ответ,
        /// но не бесконечно: если стек не пришлёт .closed, сессию снимет
        /// linger-таймер, иначе клиент остался бы висеть навсегда.
        private func finishTunnelWrite() {
            guard !closed, !halfClosed else { return }
            halfClosed = true
            tunnel?.close()

            let timer = DispatchSource.makeTimerSource(queue: queue())
            timer.schedule(deadline: .now() + TunnelSocks5Server.lingerTimeout)
            timer.setEventHandler { [weak self] in
                guard let self = self, !self.closed else { return }
                NSLog("[PROXY] linger timeout, закрываем сессию")
                self.close()
            }
            timer.resume()
            lingerTimer?.cancel()
            lingerTimer = timer
        }

        // MARK: UDP ASSOCIATE

        private func associateUdp(host: String, literal: UInt32?, port: UInt16) {
            guard let server = server else {
                replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                return
            }
            // Клиент вправе указать 0.0.0.0:0 — «адрес узнаешь из TCP».
            // Иначе ограничиваем ассоциацию объявленным endpoint'ом.
            var declared: String?
            if let literal = literal, literal != 0, port != 0 {
                declared = "\(PacketCodec.ipv4String(literal)):\(port)"
            }

            server.beginUdpSession(declaredClient: declared) { [weak self] result in
                guard let self = self else { return }
                self.onQueue {
                    guard !self.closed else {
                        if case .success(let session) = result { session.close() }
                        return
                    }
                    switch result {
                    case .success(let session):
                        self.udp = session
                        self.sendReply(TunnelSocks5Server.Socks.succeeded,
                                       address: session.boundAddress,
                                       port: session.boundPort) {
                            // Контрольное TCP-соединение живёт, пока клиенту
                            // нужен ассоциированный UDP.
                            self.watchUdpControl()
                        }
                    case .failure(let error):
                        NSLog("[PROXY] UDP ASSOCIATE failed: %@", error.localizedDescription)
                        self.replyAndClose(TunnelSocks5Server.Socks.generalFailure)
                    }
                }
            }
        }

        private func watchUdpControl() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 512) {
                [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if error != nil || isComplete || (data?.isEmpty ?? true) {
                    self.close()
                    return
                }
                self.onQueue { self.watchUdpControl() }
            }
        }

        // MARK: Таймер установки соединения

        private func startConnectTimer(code: UInt8) {
            cancelConnectTimer()
            let timer = DispatchSource.makeTimerSource(queue: queue())
            timer.schedule(deadline: .now() + TunnelSocks5Server.connectTimeout)
            timer.setEventHandler { [weak self] in
                guard let self = self, !self.closed, !self.established else { return }
                self.replyAndClose(code)
            }
            timer.resume()
            connectTimer = timer
        }

        private func cancelConnectTimer() {
            connectTimer?.cancel()
            connectTimer = nil
        }

        // MARK: Служебное

        private func queue() -> DispatchQueue {
            server?.queue ?? DispatchQueue.global()
        }

        private func onQueue(_ work: @escaping () -> Void) {
            guard let server = server else { return }
            server.queue.async(execute: work)
        }

        private func sendRaw(_ data: Data, completion: @escaping () -> Void) {
            client.send(content: data, completion: .contentProcessed { _ in completion() })
        }

        private func sendReply(_ code: UInt8, address: UInt32, port: UInt16,
                               completion: @escaping () -> Void) {
            client.send(content: TunnelSocks5Server.reply(code, address: address, port: port),
                        completion: .contentProcessed { _ in completion() })
        }

        private func replyAndClose(_ code: UInt8) {
            guard !closed else { return }
            client.send(content: TunnelSocks5Server.reply(code, address: 0, port: 0),
                        completion: .contentProcessed { _ in self.close() })
        }

        /// Закрывает обе стороны. Идемпотентно.
        func close() {
            guard !closed else { return }
            closed = true
            cancelConnectTimer()
            lingerTimer?.cancel()
            lingerTimer = nil

            client.stateUpdateHandler = nil
            client.cancel()

            direct?.stateUpdateHandler = nil
            direct?.cancel()
            direct = nil

            // Для туннеля закрываем мягко: стек сам дошлёт FIN и уберёт
            // соединение из таблицы.
            tunnel?.close()
            tunnel = nil

            udp?.close()
            udp = nil

            server?.finish(self)
        }
    }

    // ============================================================
    //  UDP ASSOCIATE
    // ============================================================

    /// Локальный UDP-сокет одной ассоциации. Клиент шлёт датаграммы в формате
    /// SOCKS5 UDP request, мы проксируем их через TunnelUdpNat.
    ///
    /// Для UDP-листенера NWConnection привязан к адресу клиента, поэтому
    /// ответы уходят ровно тому, кто прислал запрос.
    fileprivate final class UdpSession {
        private weak var server: TunnelSocks5Server?
        private let listener: NWListener
        private var clients: [ObjectIdentifier: NWConnection] = [:]
        private var flows: [String: TunnelUdpFlow] = [:]
        private var flowClients: [String: NWConnection] = [:]
        private var remotes: [String: IPv4Endpoint] = [:]
        private var resolving: Set<String> = []
        private var closed = false

        let boundAddress: UInt32
        let boundPort: UInt16
        private let declaredClient: String?

        init(server: TunnelSocks5Server, listener: NWListener, port: UInt16,
             address: UInt32, declaredClient: String?) {
            self.server = server
            self.listener = listener
            self.boundPort = port
            self.boundAddress = address
            self.declaredClient = declaredClient
        }

        // MARK: Старт

        func start(on listenerQueue: DispatchQueue) {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self, let server = self.server else {
                    connection.cancel()
                    return
                }
                server.queue.async {
                    guard !self.closed else {
                        connection.cancel()
                        return
                    }
                    // Объявленный клиентом endpoint (если был) — только для
                    // диагностики: за NAT источник может не совпадать, и
                    // жёсткая проверка ломала бы легитимный трафик.
                    self.clients[ObjectIdentifier(connection)] = connection
                    connection.start(queue: server.queue)
                    self.receive(on: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                NSLog("[PROXY] UDP listener failed: %@", error.localizedDescription)
                guard let self = self, let server = self.server else { return }
                server.queue.async { self.closeOnQueue() }
            }
            listener.start(queue: listenerQueue)
        }

        private func receive(on connection: NWConnection) {
            connection.receiveMessage(minimumIncompleteLength: 1, maximumLength: 65535) {
                [weak self] data, _, _, error in
                guard let self = self, !self.closed else { return }
                if let data = data, !data.isEmpty {
                    self.handle(datagram: [UInt8](data), from: connection)
                }
                if error != nil {
                    connection.cancel()
                    self.clients.removeValue(forKey: ObjectIdentifier(connection))
                    return
                }
                self.receive(on: connection)
            }
        }

        // MARK: Разбор SOCKS5 UDP request

        private func handle(datagram: [UInt8], from client: NWConnection) {
            // RSV(2) + FRAG(1)
            guard datagram.count >= 4, datagram[0] == 0, datagram[1] == 0 else { return }
            // Фрагментация не поддерживается: FRAG != 0 отбрасываем.
            guard datagram[2] == 0 else { return }

            var offset = 4
            var host: String?
            var literal: UInt32?

            switch datagram[3] {
            case TunnelSocks5Server.Socks.atypIPv4:
                guard datagram.count >= offset + 4 else { return }
                let address = UInt32(datagram[offset]) << 24 | UInt32(datagram[offset + 1]) << 16
                    | UInt32(datagram[offset + 2]) << 8 | UInt32(datagram[offset + 3])
                literal = address
                host = PacketCodec.ipv4String(address)
                offset += 4
            case TunnelSocks5Server.Socks.atypDomain:
                guard datagram.count >= offset + 1 else { return }
                let length = Int(datagram[offset])
                offset += 1
                guard length > 0, datagram.count >= offset + length + 2 else { return }
                guard let name = String(bytes: datagram[offset..<offset + length],
                                        encoding: .utf8), !name.isEmpty else { return }
                host = name
                offset += length
            default:
                // IPv6 и неизвестные типы — молча отбрасываем.
                return
            }

            guard datagram.count >= offset + 2 else { return }
            let port = UInt16(datagram[offset]) << 8 | UInt16(datagram[offset + 1])
            offset += 2
            guard port != 0 else { return }
            let payload = Array(datagram[offset...])
            guard let host = host else { return }

            if let literal = literal {
                forward(literal: literal, port: port, payload: payload, client: client)
            } else {
                forwardByName(host: host, port: port, payload: payload, client: client)
            }
        }

        /// Домен: сначала резолвим через туннель, потом шлём. Один резолв на
        /// пару «имя:порт», чтобы поток датаграмм не порождал лавину запросов.
        private func forwardByName(host: String, port: UInt16, payload: [UInt8],
                                   client: NWConnection) {
            let key = "\(host.lowercased()):\(port)"
            if let flow = flows[key] {
                flowClients[key] = client
                flow.send(payload)
                return
            }
            guard !resolving.contains(key) else { return }
            resolving.insert(key)
            server?.resolver.resolve(host) { [weak self] result in
                guard let self = self, !self.closed else { return }
                self.onQueue {
                    guard !self.closed else { return }
                    self.resolving.remove(key)
                    switch result {
                    case .success(let address):
                        self.forward(literal: address, port: port, payload: payload,
                                     client: client)
                    case .failure(let error):
                        NSLog("[PROXY] UDP resolve %@ failed: %@", host,
                              error.localizedDescription)
                    }
                }
            }
        }

        private func forward(literal: UInt32, port: UInt16, payload: [UInt8],
                             client: NWConnection) {
            let key = "\(PacketCodec.ipv4String(literal)):\(port)"
            if let flow = flows[key] {
                flowClients[key] = client
                flow.send(payload)
                return
            }
            guard let server = server else { return }
            let remote = IPv4Endpoint(address: literal, port: port)
            let flow = server.nat.open(remote: remote, onData: { [weak self] data in
                guard let self = self, !self.closed else { return }
                self.onQueue { self.deliver(data, key: key) }
            }, onClosed: { [weak self] in
                guard let self = self, !self.closed else { return }
                self.onQueue { self.dropFlow(key: key) }
            })
            flows[key] = flow
            flowClients[key] = client
            remotes[key] = remote
            flow.send(payload)
        }

        /// Ответ клиенту: SOCKS5 UDP response (RSV, FRAG, ATYP+ADDR+PORT, DATA).
        private func deliver(_ payload: [UInt8], key: String) {
            guard !closed, let remote = remotes[key],
                  let client = flowClients[key] else { return }
            var datagram: [UInt8] = [0x00, 0x00, 0x00, TunnelSocks5Server.Socks.atypIPv4]
            datagram.append(UInt8(remote.address >> 24 & 0xFF))
            datagram.append(UInt8(remote.address >> 16 & 0xFF))
            datagram.append(UInt8(remote.address >> 8 & 0xFF))
            datagram.append(UInt8(remote.address & 0xFF))
            datagram.append(UInt8(remote.port >> 8 & 0xFF))
            datagram.append(UInt8(remote.port & 0xFF))
            datagram.append(contentsOf: payload)
            client.send(content: Data(datagram), completion: .contentProcessed { _ in })
        }

        private func dropFlow(key: String) {
            flows.removeValue(forKey: key)?.close()
            flowClients.removeValue(forKey: key)
            remotes.removeValue(forKey: key)
        }

        private func onQueue(_ work: @escaping () -> Void) {
            guard let server = server else { return }
            server.queue.async(execute: work)
        }

        // MARK: Закрытие

        /// Идемпотентно; состояние меняется только на очереди сервера.
        func close() {
            guard let server = server else {
                closeOnQueue()
                return
            }
            server.queue.async { self.closeOnQueue() }
        }

        private func closeOnQueue() {
            guard !closed else { return }
            closed = true
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            for connection in clients.values {
                connection.cancel()
            }
            clients.removeAll()
            for flow in flows.values {
                flow.close()
            }
            flows.removeAll()
            flowClients.removeAll()
            remotes.removeAll()
            resolving.removeAll()
            server?.finish(self)
        }
    }

    /// Поднимает UDP-листенер на loopback и отдаёт готовую сессию.
    /// Completion вызывается на внутренней очереди сервера.
    fileprivate func beginUdpSession(declaredClient: String?,
                                     completion: @escaping (Result<UdpSession, Error>) -> Void) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            completion(.failure(error))
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var port: UInt16 = 0

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock()
                port = listener.port?.rawValue ?? 0
                lock.unlock()
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: listenerQueue)
        _ = semaphore.wait(timeout: .now() + Self.readyTimeout)

        lock.lock()
        let bound = port
        lock.unlock()
        guard bound != 0 else {
            listener.newConnectionHandler = nil
            listener.cancel()
            completion(.failure(TunnelError.proxyFailure("UDP associate listener failed")))
            return
        }

        let session = UdpSession(server: self, listener: listener, port: bound,
                                 address: PacketCodec.ipv4Address("127.0.0.1") ?? 0x7F00_0001,
                                 declaredClient: declaredClient)
        stateLock.lock()
        let blocked = stopping
        if !blocked {
            udpSessions[ObjectIdentifier(session)] = session
        }
        stateLock.unlock()
        guard !blocked else {
            listener.newConnectionHandler = nil
            listener.cancel()
            completion(.failure(TunnelError.tunnelNotReady))
            return
        }

        session.start(on: listenerQueue)
        completion(.success(session))
    }
}
