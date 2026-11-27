// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Тесты TunnelResolver на Linux: чистый Foundation-код, поэтому Network.framework
// не нужен. Вместо настоящего UDP NAT подставляем FakeNat, который отвечает
// заранее заготовленными DNS-пакетами.
//
// Проверяем то, что легко сломать: объединение одновременных запросов,
// игнорирование чужих id, переход к следующему серверу, TTL-кеш и эвикцию.

import Foundation

// MARK: - Поддельный UDP NAT

final class FakeNat: TunnelUdpNat {
    struct Opened {
        let remote: IPv4Endpoint
        let flow: FakeFlow
    }

    private let lock = NSLock()
    private(set) var opened: [Opened] = []
    /// Ответ на запрос: (remote, запрос, номер попытки) -> ответ или nil.
    var responder: ((IPv4Endpoint, [UInt8], Int) -> [UInt8]?)?

    var flowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return opened.count
    }

    func open(remote: IPv4Endpoint, onData: @escaping ([UInt8]) -> Void,
              onClosed: @escaping () -> Void) -> TunnelUdpFlow {
        let flow = FakeFlow(nat: self, remote: remote, onData: onData, onClosed: onClosed)
        lock.lock()
        opened.append(Opened(remote: remote, flow: flow))
        lock.unlock()
        return flow
    }

    func handle(_ datagram: Ipv4Datagram) {}
    func closeAll() {}

    func send(from flow: FakeFlow, payload: [UInt8]) {
        lock.lock()
        let attempt = opened.filter { $0.remote == flow.remote }.count
        let responder = self.responder
        lock.unlock()
        guard let response = responder?(flow.remote, payload, attempt) else { return }
        flow.onData(response)
    }
}

final class FakeFlow: TunnelUdpFlow {
    let remote: IPv4Endpoint
    private let nat: FakeNat
    let onData: ([UInt8]) -> Void
    let onClosed: () -> Void
    private(set) var closed = false
    private(set) var sent: [[UInt8]] = []

    var localPort: UInt16 { 0 }

    init(nat: FakeNat, remote: IPv4Endpoint, onData: @escaping ([UInt8]) -> Void,
         onClosed: @escaping () -> Void) {
        self.nat = nat
        self.remote = remote
        self.onData = onData
        self.onClosed = onClosed
    }

    func send(_ payload: [UInt8]) {
        sent.append(payload)
        nat.send(from: self, payload: payload)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onClosed()
    }
}

// MARK: - Сборка DNS-ответов

enum FakeDns {
    /// Ответ на запрос с тем же question, но своим id (по умолчанию — как в
    /// запросе). Адреса — список A-записей, ttl общий.
    static func response(to query: [UInt8], id: UInt16? = nil,
                         rcode: UInt8 = 0, addresses: [UInt32] = [],
                         ttl: UInt32 = 60) -> [UInt8] {
        guard query.count >= 12 else { return [] }
        let responseID = id ?? (UInt16(query[0]) << 8 | UInt16(query[1]))
        // Вопрос копируем из запроса целиком (QNAME + QTYPE + QCLASS).
        var questionEnd = 12
        while questionEnd < query.count, query[questionEnd] != 0 { 
            questionEnd += Int(query[questionEnd]) + 1
        }
        questionEnd += 1 + 4
        guard questionEnd <= query.count else { return [] }
        let question = Array(query[12..<questionEnd])

        var packet: [UInt8] = []
        packet.append(UInt8(responseID >> 8))
        packet.append(UInt8(responseID & 0xFF))
        packet.append(0x81)  // QR + RD
        packet.append(0x80 | (rcode & 0x0F))  // RA + rcode
        packet.append(contentsOf: [0x00, 0x01])  // QDCOUNT
        packet.append(contentsOf: [0x00, UInt8(addresses.count)])  // ANCOUNT
        packet.append(contentsOf: [0x00, 0x00])  // NSCOUNT
        packet.append(contentsOf: [0x00, 0x00])  // ARCOUNT
        let questionOffset = packet.count  // ровно 12
        packet.append(contentsOf: question)

        for address in addresses {
            // Указатель на QNAME в question-секции.
            packet.append(contentsOf: [0xC0, UInt8(questionOffset)])
            packet.append(contentsOf: [0x00, 0x01])  // TYPE A
            packet.append(contentsOf: [0x00, 0x01])  // CLASS IN
            PacketCodec.appendUInt32(ttl, to: &packet)
            packet.append(contentsOf: [0x00, 0x04])
            PacketCodec.appendUInt32(address, to: &packet)
        }
        return packet
    }

    static func id(of query: [UInt8]) -> UInt16 {
        guard query.count >= 2 else { return 0 }
        return UInt16(query[0]) << 8 | UInt16(query[1])
    }

    static func qname(of query: [UInt8]) -> String {
        DnsMessage.parse(query)?.name ?? ""
    }
}

// MARK: - Ожидание асинхронного результата

final class ResultBox {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _result: Result<UInt32, Error>?

    var result: Result<UInt32, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return _result
    }

    func complete(_ result: Result<UInt32, Error>) {
        lock.lock()
        if _result == nil {
            _result = result
            lock.unlock()
            semaphore.signal()
        } else {
            lock.unlock()
        }
    }

    @discardableResult
    func wait(_ seconds: TimeInterval = 5) -> Result<UInt32, Error>? {
        _ = semaphore.wait(timeout: .now() + seconds)
        return result
    }

    var address: UInt32? {
        if case .success(let value) = result { return value }
        return nil
    }

    var error: Error? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

// MARK: - Тесты

func testResolverLiteralAndCache() {
    runner.suite("TunnelResolver: литерал и кеш")

    let nat = FakeNat()
    let resolver = TunnelResolver(nat: nat, servers: ["10.0.0.1"], timeout: 1)
    defer { resolver.close() }

    // Литерал разрешается без единого UDP-запроса.
    let literal = ResultBox()
    resolver.resolve("192.0.2.10") { literal.complete($0) }
    runner.equal(literal.address, address("192.0.2.10"), "IPv4-литерал разобран")
    runner.equal(nat.flowCount, 0, "для литерала NAT не использовался")

    // Домен — один запрос, ответ кладётся в кеш.
    nat.responder = { _, query, _ in
        FakeDns.response(to: query, addresses: [address("203.0.113.5")], ttl: 120)
    }
    let first = ResultBox()
    resolver.resolve("api.example.com") { first.complete($0) }
    runner.equal(first.address, address("203.0.113.5"), "A-запись из ответа")
    runner.equal(nat.flowCount, 1, "ровно один UDP-flow на запрос")
    runner.equal(resolver.cacheCount, 1, "ответ закеширован")

    let second = ResultBox()
    resolver.resolve("api.example.com") { second.complete($0) }
    runner.equal(second.address, address("203.0.113.5"), "второй запрос из кеша")
    runner.equal(nat.flowCount, 1, "повторный запрос не ходил в сеть")

    // Регистр имени не должен создавать вторую запись.
    let upper = ResultBox()
    resolver.resolve("API.EXAMPLE.COM") { upper.complete($0) }
    runner.equal(upper.address, address("203.0.113.5"), "имя в верхнем регистре из кеша")
    runner.equal(nat.flowCount, 1, "регистр не влияет на кеш")

    resolver.clearCache()
    runner.equal(resolver.cacheCount, 0, "clearCache очищает кеш")

    let afterClear = ResultBox()
    resolver.resolve("api.example.com") { afterClear.complete($0) }
    runner.equal(nat.flowCount, 2, "после clearCache запрос уходит заново")
}

func testResolverCoalescing() {
    runner.suite("TunnelResolver: объединение одновременных запросов")

    let nat = FakeNat()
    let resolver = TunnelResolver(nat: nat, servers: ["10.0.0.1"], timeout: 1)
    defer { resolver.close() }

    // Отвечаем вручную, чтобы оба клиента гарантированно успели подписаться.
    var pendingFlow: FakeFlow?
    var pendingQuery: [UInt8] = []
    nat.responder = { _, query, _ in
        pendingQuery = query
        return nil  // ответ отправим позже
    }

    let first = ResultBox()
    let second = ResultBox()
    let third = ResultBox()
    resolver.resolve("same.example.com") { first.complete($0) }
    resolver.resolve("same.example.com") { second.complete($0) }
    resolver.resolve("same.example.com") { third.complete($0) }

    runner.equal(nat.flowCount, 1, "три запроса — один UDP-flow")

    // Досылаем ответ в тот же flow.
    if case .some(let opened) = nat.opened.last as FakeNat.Opened? {
        pendingFlow = opened.flow
    }
    guard let flow = pendingFlow, !pendingQuery.isEmpty else {
        runner.check(false, "flow не открылся")
        return
    }
    flow.onData(FakeDns.response(to: pendingQuery, addresses: [address("198.51.100.9")]))

    runner.equal(first.address, address("198.51.100.9"), "первый клиент получил ответ")
    runner.equal(second.address, address("198.51.100.9"), "второй клиент получил ответ")
    runner.equal(third.address, address("198.51.100.9"), "третий клиент получил ответ")
    runner.equal(nat.flowCount, 1, "дубликатов запросов не было")
}

func testResolverIgnoresForeignIDs() {
    runner.suite("TunnelResolver: чужие id и rcode")

    let nat = FakeNat()
    let resolver = TunnelResolver(nat: nat, servers: ["10.0.0.1", "10.0.0.2"], timeout: 0.2)
    defer { resolver.close() }

    nat.responder = { _, query, _ in
        let id = FakeDns.id(of: query)
        // Сначала чужой ответ с тем же вопросом, но другим id — его надо
        // проигнорировать, иначе клиент получит адрес из чужого запроса.
        if id != 0xFFFF {
            return FakeDns.response(to: query, id: id &+ 1,
                                    addresses: [address("1.1.1.1")])
        }
        return nil
    }

    let box = ResultBox()
    resolver.resolve("foreign.example.com") { box.complete($0) }
    // Ответа с правильным id не будет — резолвер должен уйти на второй сервер
    // и в итоге отдать ошибку, но НЕ адрес 1.1.1.1.
    _ = box.wait(3)
    runner.check(box.address != address("1.1.1.1"), "чужой id не принят как свой ответ")
    runner.check(box.error != nil, "по исчерпании серверов вернулась ошибка")
    if let error = box.error as? TunnelError {
        if case .resolverFailure = error {
            runner.check(true, "ошибка типа resolverFailure")
        } else {
            runner.check(false, "ожидался resolverFailure, получено \(error)")
        }
    } else {
        runner.check(false, "ошибка не TunnelError")
    }
}

func testResolverFailover() {
    runner.suite("TunnelResolver: переход между серверами")

    // Первый сервер молчит, второй отвечает.
    let nat = FakeNat()
    let resolver = TunnelResolver(nat: nat, servers: ["10.0.0.1", "10.0.0.2"], timeout: 0.2)
    defer { resolver.close() }

    nat.responder = { remote, query, _ in
        guard remote.address == address("10.0.0.2") else { return nil }
        return FakeDns.response(to: query, addresses: [address("93.184.216.34")], ttl: 300)
    }

    let box = ResultBox()
    resolver.resolve("failover.example.com") { box.complete($0) }
    _ = box.wait(5)
    runner.equal(box.address, address("93.184.216.34"), "ответ получен со второго сервера")
    runner.check(nat.opened.contains { $0.remote.address == address("10.0.0.2") },
                 "второй сервер действительно опрашивался")

    // rcode != 0 (NXDOMAIN) на первом сервере — тоже повод перейти к следующему.
    let nat2 = FakeNat()
    let resolver2 = TunnelResolver(nat: nat2, servers: ["10.0.0.1", "10.0.0.2"], timeout: 1)
    defer { resolver2.close() }
    nat2.responder = { remote, query, _ in
        if remote.address == address("10.0.0.1") {
            return FakeDns.response(to: query, rcode: 3)
        }
        return FakeDns.response(to: query, addresses: [address("203.0.113.9")])
    }
    let box2 = ResultBox()
    resolver2.resolve("nxdomain.example.com") { box2.complete($0) }
    _ = box2.wait(3)
    runner.equal(box2.address, address("203.0.113.9"), "NXDOMAIN → следующий сервер")

    // Пустой ответ без A-записей — тоже повод идти дальше.
    let nat3 = FakeNat()
    let resolver3 = TunnelResolver(nat: nat3, servers: ["10.0.0.1", "10.0.0.2"], timeout: 1)
    defer { resolver3.close() }
    nat3.responder = { remote, query, _ in
        if remote.address == address("10.0.0.1") {
            return FakeDns.response(to: query, addresses: [])
        }
        return FakeDns.response(to: query, addresses: [address("203.0.113.11")])
    }
    let box3 = ResultBox()
    resolver3.resolve("noa.example.com") { box3.complete($0) }
    _ = box3.wait(3)
    runner.equal(box3.address, address("203.0.113.11"), "ответ без A → следующий сервер")
}

func testResolverErrorsAndEviction() {
    runner.suite("TunnelResolver: ошибки, TTL и эвикция")

    // Нет серверов — сразу ошибка, без зависания.
    let emptyNat = FakeNat()
    let emptyResolver = TunnelResolver(nat: emptyNat, servers: [], timeout: 1)
    let emptyBox = ResultBox()
    emptyResolver.resolve("nowhere.example.com") { emptyBox.complete($0) }
    runner.check(emptyBox.error != nil, "без серверов возвращается ошибка")
    emptyResolver.close()

    // Пустое имя — ошибка без сети.
    let nameNat = FakeNat()
    let nameResolver = TunnelResolver(nat: nameNat, servers: ["10.0.0.1"], timeout: 1)
    let nameBox = ResultBox()
    nameResolver.resolve("   ") { nameBox.complete($0) }
    runner.check(nameBox.error != nil, "пустое имя — ошибка")
    nameResolver.close()

    // TTL = 0 всё равно кешируется (минимум 30 секунд), иначе мы бы били по
    // DNS на каждый запрос.
    let nat = FakeNat()
    let resolver = TunnelResolver(nat: nat, servers: ["10.0.0.1"], timeout: 1)
    defer { resolver.close() }
    nat.responder = { _, query, _ in
        FakeDns.response(to: query, addresses: [address("203.0.113.20")], ttl: 0)
    }
    let ttlBox = ResultBox()
    resolver.resolve("ttl.example.com") { ttlBox.complete($0) }
    let ttlAgain = ResultBox()
    resolver.resolve("ttl.example.com") { ttlAgain.complete($0) }
    runner.equal(ttlAgain.address, address("203.0.113.20"), "TTL=0 всё равно кешируется")
    runner.equal(nat.flowCount, 1, "второй запрос не ушёл в сеть")

    // Эвикция: maxEntries=2, три разных имени.
    let evictNat = FakeNat()
    let evictResolver = TunnelResolver(nat: evictNat, servers: ["10.0.0.1"],
                                       timeout: 1, maxEntries: 2)
    defer { evictResolver.close() }
    evictNat.responder = { _, query, _ in
        FakeDns.response(to: query, addresses: [address("203.0.113.30")], ttl: 300)
    }
    for name in ["one.example.com", "two.example.com", "three.example.com"] {
        let box = ResultBox()
        evictResolver.resolve(name) { box.complete($0) }
        runner.check(box.address != nil, "\(name) разрешён")
    }
    runner.equal(evictResolver.cacheCount, 2, "кеш ограничен maxEntries")
    runner.equal(evictNat.flowCount, 3, "каждое новое имя сходило в сеть")

    // После закрытия резолвер не висит и отвечает ошибкой.
    let closedNat = FakeNat()
    let closedResolver = TunnelResolver(nat: closedNat, servers: ["10.0.0.1"], timeout: 1)
    closedResolver.close()
    let closedBox = ResultBox()
    closedResolver.resolve("after.close") { closedBox.complete($0) }
    runner.check(closedBox.error != nil, "закрытый резолвер отвечает ошибкой")
}
