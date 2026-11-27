// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Маршрутизация «напрямую vs в туннель» для userspace-транспорта iOS.
//
// Приложение поднимает SOCKS5-прокси поверх собственного TCP/UDP-стека,
// работающего через ядро CSQTT. Часть трафика обязана идти мимо туннеля:
// локальные сети (иначе мы потеряем доступ к самому устройству и к роутеру)
// и сервисы, которые нужны самому ядру (VK, CDN, обновления). Здесь живёт
// единственный источник правды об этих правилах.
//
// Foundation only: файл компилируется и тестируется на Linux.

import Foundation

struct Ipv4Routing {

    // MARK: - Встроенные списки

    /// Диапазоны, которые никогда не должны попадать в туннель.
    static let localCidrs: [String] = [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "255.255.255.255/32",
    ]

    /// Домены, которые обязаны идти напрямую: их использует ядро CSQTT
    /// (авторизация, звонки, TURN), CDN-раздача контента и загрузка
    /// обновлений приложения.
    static let serviceDomains: [String] = [
        "vk.com",
        "vk.ru",
        "vk.me",
        "vkvideo.ru",
        "userapi.com",
        "vk-cdn.net",
        "mycdn.me",
        "id.vk.com",
        "login.vk.com",
        "oauth.vk.ru",
        "reg.vk.com",
        "api.vk.com",
        "calls.vk.com",
        "turn.vk.com",
        "max.ru",
        "oneme.ru",
        "github.com",
        "githubusercontent.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "disk.yandex.ru",
        "yandex.net",
        "lalune",
    ]

    // MARK: - Правила

    /// Одно правило CIDR в уже нормализованном виде: адрес сети и маска.
    private struct Rule {
        let network: UInt32
        let mask: UInt32
    }

    /// CIDR-списки, которые реально участвуют в маршрутизации (без мусора
    /// и дублей, в порядке добавления).
    let bypassCidrs: [String]

    /// Доменные суффиксы (в нижнем регистре, без ведущей точки).
    let bypassDomains: [String]

    /// `bypassCidrs`, склеенные через запятую — готовый аргумент для incy.
    var bypassArgument: String { bypassCidrs.joined(separator: ",") }

    private let rules: [Rule]

    // MARK: - Инициализация

    /// - Parameters:
    ///   - localRanges: добавить `localCidrs` (локальные/служебные сети).
    ///   - extraCidrs: пользовательские CIDR. Невалидные записи отбрасываются.
    ///   - extraDomains: пользовательские домены-суффиксы.
    ///   - includeServices: добавить `serviceDomains` (домены ядра и его CDN).
    ///     Передавать их же в `extraDomains` не нужно — дубли отбрасываются,
    ///     но список читается один раз.
    init(localRanges: Bool, extraCidrs: [String] = [], extraDomains: [String] = [],
         includeServices: Bool = false) {
        var cidrs: [String] = []
        var rules: [Rule] = []
        var seen = Set<String>()

        func addCidr(_ raw: String) {
            guard let parsed = Ipv4Routing.parseCidr(raw) else { return }
            // Дедупликация по нормализованной сети: 10.1.2.3/8 и 10.0.0.0/8
            // описывают один и тот же диапазон.
            let text = "\(PacketCodec.ipv4String(parsed.network))/\(parsed.prefix)"
            guard seen.insert(text).inserted else { return }
            cidrs.append(text)
            rules.append(Rule(network: parsed.network, mask: parsed.mask))
        }

        if localRanges {
            Ipv4Routing.localCidrs.forEach(addCidr)
        }
        extraCidrs.forEach(addCidr)

        var domains: [String] = []
        var seenDomains = Set<String>()
        let domainSources = (includeServices ? Ipv4Routing.serviceDomains : []) + extraDomains
        for raw in domainSources {
            guard let domain = Ipv4Routing.normalizeDomain(raw) else { continue }
            if seenDomains.insert(domain).inserted {
                domains.append(domain)
            }
        }

        self.bypassCidrs = cidrs
        self.bypassDomains = domains
        self.rules = rules
    }

    // MARK: - IPv4

    /// Попадает ли адрес (host byte order) хотя бы в один CIDR.
    func matches(_ address: UInt32) -> Bool {
        for rule in rules where address & rule.mask == rule.network {
            return true
        }
        return false
    }

    // MARK: - Домены

    /// Суффиксное совпадение по границе метки: `vk.com` матчит `api.vk.com`,
    /// но не `notvk.com`. Сам домен тоже матчится.
    func matchesDomain(_ domain: String) -> Bool {
        guard let name = Ipv4Routing.normalizeDomain(domain) else { return false }
        for suffix in bypassDomains {
            if name == suffix { return true }
            if name.hasSuffix("." + suffix) { return true }
        }
        return false
    }

    // MARK: - Разбор

    /// Разбирает `a.b.c.d`, `a.b.c.d/n` или `a.b.c.d / n` (пробелы допустимы).
    /// Возвращает адрес сети (host bits обнулены), маску и длину префикса.
    static func parseCidr(_ raw: String) -> (network: UInt32, mask: UInt32, prefix: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pieces = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressPart = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)

        var prefix = 32
        if pieces.count == 2 {
            let prefixPart = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Пустой префикс после «/» — ошибка, а не «/32».
            guard let value = Int(prefixPart), (0...32).contains(value) else { return nil }
            prefix = value
        }

        guard let address = parseIPv4Literal(addressPart) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
        return (address & mask, mask, prefix)
    }

    /// Строгий разбор точечной записи: ровно 4 десятичных октета 0...255,
    /// без ведущих «+», знаков и прочих вольностей.
    static func parseIPv4Literal(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var address: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3 else { return nil }
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard let byte = UInt32(part), byte <= 255 else { return nil }
            address = address << 8 | byte
        }
        return address
    }

    /// Приводит домен к сравнимому виду: нижний регистр, без пробелов,
    /// без завершающей точки и без `:port`. Возвращает nil для мусора.
    static func normalizeDomain(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        // Отрезаем порт, если он есть: "example.com:443" -> "example.com".
        if let colon = value.lastIndex(of: ":") {
            let tail = value[value.index(after: colon)...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) {
                value = String(value[..<colon])
            }
        }

        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        // Внутри домена не должно быть пробелов и управляющих символов;
        // остальное (включая IDN в Unicode) сравниваем как есть.
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
        }
        return value
    }
}
