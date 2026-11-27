// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Сборка deeplink-а для стороннего приложения incy: именно оно поднимает
// системный VPN, а мы отдаём ему адрес своего SOCKS5-прокси и список
// исключений, которые должны идти мимо туннеля.
//
// Foundation only: файл компилируется и тестируется на Linux.

import Foundation

struct IncyConfig {

    // MARK: - Шаблон

    /// Шаблон по умолчанию: `{host}`, `{port}`, `{name}`, `{bypass}`,
    /// `{bypassDomains}` подставляются с percent-encoding.
    static let defaultTemplate =
        "incy://add?socks5={host}:{port}&name={name}&bypass={bypass}&bypassDomains={bypassDomains}"

    // MARK: - Поля

    /// Адрес, на котором слушает наш SOCKS5-прокси (loopback).
    var host: String
    /// Фактический порт прокси (не 0 — иначе incy подключится в никуда).
    var port: UInt16
    /// Человекочитаемое имя профиля в incy.
    var name: String
    /// CIDR-исключения, которые нужно отдать incy дополнительно к локальным.
    var bypassCidrs: [String]
    /// Доменные исключения (суффиксы), которые идут напрямую.
    var bypassDomains: [String]

    init(host: String = "127.0.0.1",
         port: UInt16,
         name: String = "LaLune",
         bypassCidrs: [String] = [],
         bypassDomains: [String] = []) {
        self.host = host
        self.port = port
        self.name = name
        self.bypassCidrs = bypassCidrs
        self.bypassDomains = bypassDomains
    }

    // MARK: - Аргументы

    /// CIDR-список для incy: пользовательские записи плюс локальные диапазоны,
    /// без дублей и с сохранением порядка. Невалидные CIDR отбрасываются —
    /// иначе incy получит мусор и может отвергнуть профиль целиком.
    var bypassArgument: String {
        var result: [String] = []
        var seen = Set<String>()
        for raw in bypassCidrs + Ipv4Routing.localCidrs {
            guard let parsed = Ipv4Routing.parseCidr(raw) else { continue }
            let key = "\(PacketCodec.ipv4String(parsed.network))/\(parsed.prefix)"
            guard seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result.joined(separator: ",")
    }

    /// Доменный список для incy (через запятую, без дублей).
    var domainArgument: String {
        var result: [String] = []
        var seen = Set<String>()
        for raw in bypassDomains {
            guard let domain = Ipv4Routing.normalizeDomain(raw) else { continue }
            guard seen.insert(domain).inserted else { continue }
            result.append(domain)
        }
        return result.joined(separator: ",")
    }

    // MARK: - URL

    /// Собирает deeplink. `template == nil` — использовать стандартный шаблон.
    /// Известные плейсхолдеры заменяются, неизвестные остаются в тексте.
    func url(template: String? = nil) -> URL? {
        let pattern: String
        if let template = template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pattern = template
        } else {
            pattern = IncyConfig.defaultTemplate
        }

        let values: [(String, String)] = [
            ("{host}", encode(host)),
            ("{port}", String(port)),
            ("{name}", encode(name)),
            ("{bypass}", encodeList(bypassArgument)),
            ("{bypassDomains}", encodeList(domainArgument)),
        ]

        var result = pattern
        for (placeholder, value) in values {
            result = result.replacingOccurrences(of: placeholder, with: value)
        }
        // Неизвестные плейсхолдеры не подставляем, но и не оставляем «сырыми»
        // фигурными скобками: с ними URL(string:) вернул бы nil и incy не
        // открылся бы вовсе.
        result = result.replacingOccurrences(of: "{", with: "%7B")
            .replacingOccurrences(of: "}", with: "%7D")
        return URL(string: result)
    }

    // MARK: - Диагностика

    /// Плоский словарь для `/vpn/incy`: без секретов, только то, что реально
    /// уходит в incy.
    func diagnostics() -> [String: Any] {
        [
            "host": host,
            "port": Int(port),
            "url": url(template: nil)?.absoluteString ?? "",
            "bypassCount": bypassArgument.isEmpty ? 0 : bypassArgument.split(separator: ",").count,
            "domainCount": domainArgument.isEmpty ? 0 : domainArgument.split(separator: ",").count,
        ]
    }

    // MARK: - Percent-encoding

    /// Кодирует значение целиком (включая запятые и слэши) по RFC 3986:
    /// незакодированными остаются только unreserved-символы.
    private func encode(_ value: String) -> String {
        IncyConfig.percentEncode(value, allowComma: false)
    }

    /// Кодирует список поэлементно и склеивает запятой: разделитель списка
    /// должен остаться литеральным, а мусор внутри элемента — экранироваться.
    private func encodeList(_ list: String) -> String {
        guard !list.isEmpty else { return "" }
        return list.split(separator: ",", omittingEmptySubsequences: false)
            .map { IncyConfig.percentEncode(String($0), allowComma: false) }
            .joined(separator: ",")
    }

    private static func percentEncode(_ value: String, allowComma: Bool) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                output.append(Character(UnicodeScalar(byte)))
            case 0x2C where allowComma:
                output.append(",")
            default:
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }
}
