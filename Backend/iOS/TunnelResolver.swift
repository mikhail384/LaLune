// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// DNS через туннель. SOCKS5-клиенты присылают доменные имена (ATYP=0x03), а
// TCP-стек умеет только IPv4-эндпоинты, поэтому имя надо разрешить, отправив
// обычный UDP-запрос через собственный UDP NAT — то есть так же, как это
// сделал бы браузер.
//
// Особенности, которые важны на практике:
//  * ответы приходят асинхронно и на общий NAT, поэтому запросы различаются
//    по DNS id, а чужие ответы игнорируются;
//  * один и тот же домен часто просят несколько соединений сразу — запросы
//    объединяются (in-flight coalescing), чтобы не плодить дубликаты;
//  * кеш ограничен по размеру и живёт по TTL из ответа (30...3600 с).
//
// Foundation only: DnsMessage приходит из соседнего файла, а тесты на Linux
// подставляют его мини-подделку.

import Foundation

final class TunnelResolver {

    // MARK: - Типы

    private struct Entry {
        var address: UInt32
        var expires: Date
    }

    /// Ожидающий запрос: одно имя — один сетевой обмен, сколько бы клиентов
    /// его ни ждали.
    private final class Pending {
        var completions: [(Result<UInt32, Error>) -> Void] = []
        var name: String = ""
        var flow: TunnelUdpFlow?
        var id: UInt16 = 0
        var serverIndex = 0
        var attemptsOnServer = 0
        /// Номер текущей попытки. Callback'и закрытого flow приходят позже,
        /// чем мы ушли на следующий сервер, и не должны ничего ломать.
        var generation = 0
        var timer: DispatchSourceTimer?
        var finished = false
    }

    // MARK: - Конфигурация

    private let nat: TunnelUdpNat
    private let servers: [String]
    private let timeout: TimeInterval
    private let maxEntries: Int
    private let queue = DispatchQueue(label: "lalune.tunnel.resolver")
    private let lock = NSLock()

    private var cache: [String: Entry] = [:]
    /// Порядок вставки для простой эвикции старейших.
    private var cacheOrder: [String] = []
    private var pending: [String: Pending] = [:]
    private var nextID: UInt16 = 1
    private var closed = false

    private static let minTTL: TimeInterval = 30
    private static let maxTTL: TimeInterval = 3600
    /// Сколько раз пробуем один и тот же сервер, прежде чем перейти к следующему.
    private static let attemptsPerServer = 2

    // MARK: - Инициализация

    init(nat: TunnelUdpNat, servers: [String],
         timeout: TimeInterval = 4, maxEntries: Int = 256) {
        self.nat = nat
        // Пустые/битые записи в списке серверов не должны ломать резолвер.
        let cleaned = servers.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        self.servers = cleaned
        self.timeout = max(0.5, timeout)
        self.maxEntries = max(1, maxEntries)
    }

    // MARK: - Публичный API

    /// Разрешает имя в IPv4-адрес (host byte order).
    ///
    /// Порядок: литерал → кеш → серверы по очереди. Completion вызывается
    /// ровно один раз, на внутренней очереди резолвера.
    func resolve(_ host: String, completion: @escaping (Result<UInt32, Error>) -> Void) {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if let literal = PacketCodec.ipv4Address(name) {
            completion(.success(literal))
            return
        }
        guard !name.isEmpty else {
            completion(.failure(TunnelError.resolverFailure("empty host name")))
            return
        }

        let key = name.lowercased()

        lock.lock()
        if closed {
            lock.unlock()
            completion(.failure(TunnelError.tunnelNotReady))
            return
        }
        if let entry = cache[key] {
            if entry.expires > Date() {
                lock.unlock()
                completion(.success(entry.address))
                return
            }
            removeCacheEntryLocked(key)
        }
        if let existing = pending[key] {
            existing.completions.append(completion)
            lock.unlock()
            return
        }
        let request = Pending()
        request.name = name
        request.completions.append(completion)
        pending[key] = request
        lock.unlock()

        startRequest(key: key, request: request)
    }

    /// Сбрасывает кеш. Ожидающие запросы не трогаем — они завершатся сами.
    func clearCache() {
        lock.lock()
        cache.removeAll()
        cacheOrder.removeAll()
        lock.unlock()
    }

    /// Текущее число записей кеша (для диагностики).
    var cacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Закрывает все активные flow и завершает ожидающие запросы ошибкой.
    func close() {
        lock.lock()
        closed = true
        let requests = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for request in requests {
            finish(request, result: .failure(TunnelError.tunnelNotReady))
        }
    }

    // MARK: - Обмен

    private func startRequest(key: String, request: Pending) {
        guard !servers.isEmpty else {
            fail(key: key, request: request, reason: "no DNS servers configured")
            return
        }
        request.serverIndex = 0
        request.attemptsOnServer = 0
        attempt(key: key, request: request)
    }

    /// Одна попытка: открыть flow, послать запрос, завести таймаут.
    private func attempt(key: String, request: Pending) {
        if isFinished(request) { return }

        while request.attemptsOnServer >= Self.attemptsPerServer {
            request.attemptsOnServer = 0
            request.serverIndex += 1
        }
        guard request.serverIndex < servers.count else {
            fail(key: key, request: request,
                 reason: "all DNS servers failed for \(request.name)")
            return
        }

        let server = servers[request.serverIndex]
        guard let serverAddress = PacketCodec.ipv4Address(server) else {
            // Имена DNS-серверов не поддерживаем: разрешать их нечем.
            request.serverIndex += 1
            request.attemptsOnServer = 0
            attempt(key: key, request: request)
            return
        }

        let id = allocateID()
        guard let query = DnsMessage.query(id: id, name: request.name, type: 1) else {
            fail(key: key, request: request, reason: "invalid DNS name \(request.name)")
            return
        }

        lock.lock()
        guard pending[key] === request, !request.finished else {
            lock.unlock()
            return
        }
        request.id = id
        request.generation += 1
        let generation = request.generation
        lock.unlock()

        let endpoint = IPv4Endpoint(address: serverAddress, port: 53)
        let flow = nat.open(remote: endpoint, onData: { [weak self] payload in
            self?.handle(payload: payload, key: key, request: request, generation: generation)
        }, onClosed: { [weak self] in
            self?.handleFlowClosed(key: key, request: request, generation: generation)
        })

        lock.lock()
        let stale = request.finished || pending[key] !== request
        if !stale {
            request.flow = flow
        }
        lock.unlock()
        if stale {
            flow.close()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.handleTimeout(key: key, request: request, generation: generation)
        }
        timer.resume()

        lock.lock()
        if request.finished {
            lock.unlock()
            timer.cancel()
            flow.close()
            return
        }
        request.timer?.cancel()
        request.timer = timer
        lock.unlock()

        flow.send(query)
    }

    private func handle(payload: [UInt8], key: String, request: Pending,
                        generation: Int) {
        lock.lock()
        let expectedID = request.id
        let active = pending[key] === request && !request.finished
            && request.generation == generation
        lock.unlock()
        guard active else { return }

        guard let response = DnsMessage.parse(payload), response.id == expectedID else {
            // Чужой или битый ответ (общий NAT) — просто ждём дальше.
            return
        }
        guard response.rcode == 0 else {
            // NXDOMAIN/SERVFAIL: этот сервер не помог, пробуем следующий.
            retryNextServer(key: key, request: request)
            return
        }
        guard let address = response.addresses.first else {
            retryNextServer(key: key, request: request)
            return
        }

        store(key: key, address: address, ttl: response.ttl)
        finish(key: key, request: request, result: .success(address))
    }

    private func handleFlowClosed(key: String, request: Pending, generation: Int) {
        lock.lock()
        // Закрытие flow, с которого мы уже ушли, — не повод повторять попытку.
        let active = pending[key] === request && !request.finished
            && request.generation == generation
        lock.unlock()
        guard active else { return }
        retryNextServer(key: key, request: request)
    }

    private func handleTimeout(key: String, request: Pending, generation: Int) {
        lock.lock()
        let active = pending[key] === request && !request.finished
            && request.generation == generation
        let flow = request.flow
        request.flow = nil
        request.timer = nil
        // Таймер относился к попытке, которую мы уже могли сменить.
        if active { request.generation += 1 }
        lock.unlock()
        guard active else { return }
        flow?.close()

        // UDP не гарантирует доставку: даём каждому серверу по несколько
        // попыток и только потом переходим к следующему.
        request.attemptsOnServer += 1
        attempt(key: key, request: request)
    }

    /// Переход к следующему серверу после «осмысленного» отказа (rcode,
    /// пустой ответ, закрытый flow).
    private func retryNextServer(key: String, request: Pending) {
        lock.lock()
        // Сначала объявляем текущую попытку недействительной, и только потом
        // закрываем flow: иначе его onClosed запустит ещё один retry.
        request.generation += 1
        let flow = request.flow
        request.flow = nil
        request.timer?.cancel()
        request.timer = nil
        request.serverIndex += 1
        request.attemptsOnServer = 0
        let active = pending[key] === request && !request.finished
        lock.unlock()
        guard active else {
            flow?.close()
            return
        }
        flow?.close()
        attempt(key: key, request: request)
    }

    // MARK: - Завершение

    private func fail(key: String, request: Pending, reason: String) {
        finish(key: key, request: request,
               result: .failure(TunnelError.resolverFailure(reason)))
    }

    private func finish(key: String, request: Pending,
                        result: Result<UInt32, Error>) {
        lock.lock()
        guard !request.finished else {
            lock.unlock()
            return
        }
        request.finished = true
        if pending[key] === request {
            pending.removeValue(forKey: key)
        }
        let flow = request.flow
        request.flow = nil
        let timer = request.timer
        request.timer = nil
        let completions = request.completions
        request.completions.removeAll()
        lock.unlock()

        timer?.cancel()
        flow?.close()
        for completion in completions {
            completion(result)
        }
    }

    private func finish(_ request: Pending, result: Result<UInt32, Error>) {
        lock.lock()
        guard !request.finished else {
            lock.unlock()
            return
        }
        request.finished = true
        let flow = request.flow
        request.flow = nil
        let timer = request.timer
        request.timer = nil
        let completions = request.completions
        request.completions.removeAll()
        lock.unlock()

        timer?.cancel()
        flow?.close()
        for completion in completions {
            completion(result)
        }
    }

    private func isFinished(_ request: Pending) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.finished
    }

    // MARK: - Кеш

    private func store(key: String, address: UInt32, ttl: UInt32) {
        let seconds = min(max(TimeInterval(ttl), Self.minTTL), Self.maxTTL)
        lock.lock()
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = Entry(address: address, expires: Date().addingTimeInterval(seconds))
        evictLocked()
        lock.unlock()
    }

    private func evictLocked() {
        while cacheOrder.count > maxEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func removeCacheEntryLocked(_ key: String) {
        cache.removeValue(forKey: key)
        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
        }
    }

    // MARK: - Идентификаторы

    private func allocateID() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        nextID = nextID &+ 1
        if nextID == 0 { nextID = 1 }
        return nextID
    }
}
