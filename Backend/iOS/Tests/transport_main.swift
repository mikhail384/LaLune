// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Автономные тесты чистых частей iOS-транспорта: Ipv4Routing и IncyConfig.
// Запускаются на Linux без Xcode и без Network.framework:
//
//   Backend/iOS/Tests/run-transport-tests.sh
//
// Собираются только Foundation-only файлы. Стиль — простой самодельный
// assert-раннер, чтобы не тянуть XCTest в Linux-сборку.

import Foundation

// MARK: - Мини-раннер

final class TestRunner {
    private var passed = 0
    private var failed = 0
    private var current = ""

    func suite(_ name: String) {
        current = name
        print("\n== \(name) ==")
    }

    func check(_ condition: Bool, _ message: String, file: StaticString = #file,
               line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("  FAIL [\(current)] \(message) (line \(line))")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                             line: UInt = #line) {
        check(actual == expected, "\(message): ожидалось \(expected), получено \(actual)",
              line: line)
    }

    func finish() -> Int32 {
        print("\n----------------------------------------")
        print("Пройдено: \(passed), провалено: \(failed)")
        if failed == 0 {
            print("РЕЗУЛЬТАТ: OK")
            return 0
        }
        print("РЕЗУЛЬТАТ: FAILED")
        return 1
    }
}

let runner = TestRunner()

func address(_ string: String) -> UInt32 {
    guard let value = PacketCodec.ipv4Address(string) else {
        fatalError("тест содержит некорректный адрес: \(string)")
    }
    return value
}

// MARK: - Ipv4Routing: CIDR

func testRoutingCidr() {
    runner.suite("Ipv4Routing: CIDR-совпадения и границы")

    let routing = Ipv4Routing(localRanges: true, extraCidrs: ["203.0.113.0/24"])

    runner.check(routing.matches(address("10.1.2.3")), "10.1.2.3 в 10.0.0.0/8")
    runner.check(routing.matches(address("10.255.255.255")), "верхняя граница 10.0.0.0/8")
    runner.check(!routing.matches(address("11.0.0.1")), "11.0.0.1 вне 10.0.0.0/8")
    runner.check(routing.matches(address("127.0.0.1")), "loopback")
    runner.check(routing.matches(address("192.168.1.1")), "192.168.0.0/16")
    runner.check(routing.matches(address("172.16.0.1")), "нижняя граница 172.16.0.0/12")
    runner.check(routing.matches(address("172.31.255.255")), "верхняя граница 172.16.0.0/12")
    runner.check(!routing.matches(address("172.32.0.1")), "172.32.0.1 вне 172.16.0.0/12")
    runner.check(routing.matches(address("169.254.10.10")), "link-local")
    runner.check(routing.matches(address("224.0.0.1")), "multicast 224.0.0.0/4")
    runner.check(routing.matches(address("239.255.255.255")), "верх multicast")
    runner.check(!routing.matches(address("240.0.0.0")) == false, "240.0.0.0/4 покрывает 240.0.0.0")
    runner.check(routing.matches(address("255.255.255.255")), "broadcast /32")
    runner.check(routing.matches(address("203.0.113.77")), "пользовательский /24")
    runner.check(!routing.matches(address("203.0.114.1")), "за пределами /24")
    runner.check(routing.matches(address("0.1.2.3")), "0.0.0.0/8")

    // Без локальных диапазонов остаётся только пользовательское правило.
    let narrow = Ipv4Routing(localRanges: false, extraCidrs: ["203.0.113.0/24"])
    runner.check(!narrow.matches(address("10.0.0.1")), "localRanges=false не добавляет 10/8")
    runner.check(narrow.matches(address("203.0.113.1")), "явный CIDR работает без localRanges")
}

func testRoutingValidation() {
    runner.suite("Ipv4Routing: валидация и мусор")

    let routing = Ipv4Routing(localRanges: false, extraCidrs: [
        "192.0.2.0/24",
        "192.0.2.0/24",        // дубль
        "192.0.2.5/24",        // тот же диапазон, другой хост
        "10.0.0.0/33",         // префикс вне диапазона
        "10.0.0.0/-1",
        "10.0.0.0/",
        "10.0.0.0/abc",
        "300.1.1.1/8",         // октет > 255
        "10.0.0/8",            // три октета
        "1.2.3.4.5/8",
        "",                    // пустая строка
        "   ",
        "192.0.2.0/24 ",       // пробелы по краям — валидно
        "198.51.100.0 / 24",   // пробелы вокруг «/» — валидно
        "not-a-cidr",
        "::1/128",             // IPv6 не наш
    ])

    runner.equal(routing.bypassCidrs, ["192.0.2.0/24", "198.51.100.0/24"],
                 "в bypassCidrs остаются только валидные уникальные записи")
    runner.check(routing.matches(address("192.0.2.200")), "192.0.2.0/24")
    runner.check(routing.matches(address("198.51.100.7")), "CIDR с пробелами разобран")
    runner.check(!routing.matches(address("10.0.0.1")), "битые записи не попали в правила")
    runner.check(!routing.matches(address("198.51.101.1")), "чужая сеть не матчится")

    // /32 и /0 — граничные префиксы.
    let host32 = Ipv4Routing(localRanges: false, extraCidrs: ["1.2.3.4/32"])
    runner.check(host32.matches(address("1.2.3.4")), "/32 попадает ровно в свой адрес")
    runner.check(!host32.matches(address("1.2.3.5")), "/32 не покрывает соседний адрес")
    runner.check(!host32.matches(address("1.2.3.3")), "/32 не покрывает предыдущий адрес")

    let all = Ipv4Routing(localRanges: false, extraCidrs: ["5.6.7.8/0"])
    runner.check(all.matches(address("200.0.0.1")), "/0 покрывает всё")
    runner.check(all.matches(address("0.0.0.0")), "/0 покрывает нулевой адрес")

    // Дедупликация: 10.1.2.3/8 нормализуется к 10.0.0.0/8.
    let dedup = Ipv4Routing(localRanges: false, extraCidrs: ["10.1.2.3/8", "10.0.0.0/8"])
    runner.equal(dedup.bypassCidrs, ["10.0.0.0/8"], "CIDR нормализуется и дедуплицируется")
}

func testRoutingDefaults() {
    runner.suite("Ipv4Routing: встроенные списки")

    runner.equal(Ipv4Routing.localCidrs.count, 9, "localCidrs содержит 9 диапазонов")
    for cidr in ["0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16",
                 "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4",
                 "240.0.0.0/4", "255.255.255.255/32"] {
        runner.check(Ipv4Routing.localCidrs.contains(cidr), "localCidrs содержит \(cidr)")
    }
    for cidr in Ipv4Routing.localCidrs {
        runner.check(Ipv4Routing.parseCidr(cidr) != nil, "localCidrs: \(cidr) валиден")
    }

    let services = Ipv4Routing.serviceDomains
    for domain in ["vk.com", "vk.ru", "vk.me", "vkvideo.ru", "userapi.com",
                   "vk-cdn.net", "mycdn.me", "id.vk.com", "login.vk.com",
                   "oauth.vk.ru", "reg.vk.com", "api.vk.com", "calls.vk.com",
                   "turn.vk.com", "max.ru", "oneme.ru", "github.com",
                   "githubusercontent.com", "objects.githubusercontent.com",
                   "raw.githubusercontent.com", "disk.yandex.ru", "yandex.net",
                   "lalune"] {
        runner.check(services.contains(domain), "serviceDomains содержит \(domain)")
    }
    runner.check(!services.contains("example.com"), "serviceDomains без мусора")
    runner.equal(Set(services).count, services.count, "serviceDomains без дублей")

    // localRanges=true и bypassArgument.
    let routing = Ipv4Routing(localRanges: true,
                              extraCidrs: ["203.0.113.0/24"],
                              extraDomains: ["example.org", "Example.ORG."])
    runner.equal(routing.bypassCidrs.count, 10, "9 локальных + 1 пользовательский")
    runner.equal(routing.bypassArgument,
                 "0.0.0.0/8,10.0.0.0/8,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,"
                 + "192.168.0.0/16,224.0.0.0/4,240.0.0.0/4,255.255.255.255/32,203.0.113.0/24",
                 "bypassArgument — точечные CIDR в порядке добавления")
    runner.check(!routing.bypassArgument.contains("167772160"),
                 "bypassArgument не содержит сырых UInt32-значений")
    runner.check(routing.bypassArgument.contains("10.0.0.0/8"), "bypassArgument содержит 10.0.0.0/8")
    runner.equal(routing.bypassDomains, ["example.org"], "домены нормализованы и без дублей")

    // includeServices не дублирует то, что уже передали в extraDomains.
    let withServices = Ipv4Routing(localRanges: false,
                                   extraDomains: ["vk.com", "my.example"],
                                   includeServices: true)
    runner.equal(withServices.bypassDomains.first, "vk.com", "serviceDomains идут первыми")
    runner.equal(Set(withServices.bypassDomains).count, withServices.bypassDomains.count,
                 "includeServices не создаёт дублей")
    runner.check(withServices.bypassDomains.contains("my.example"),
                 "пользовательский домен сохранён")
}

// MARK: - Ipv4Routing: домены

func testRoutingDomains() {
    runner.suite("Ipv4Routing: суффиксы доменов")

    let routing = Ipv4Routing(localRanges: false, extraDomains: [
        "vk.com", "userapi.com", "lalune", ".Example.ORG.", "  spaced.com  ",
        "port.example:443", "", "bad domain.com",
    ])

    runner.check(routing.matchesDomain("vk.com"), "точное совпадение")
    runner.check(routing.matchesDomain("api.vk.com"), "поддомен первого уровня")
    runner.check(routing.matchesDomain("a.b.c.vk.com"), "глубокий поддомен")
    runner.check(routing.matchesDomain("VK.COM"), "регистр не важен")
    runner.check(routing.matchesDomain("api.vk.com:443"), "порт в запросе отбрасывается")
    runner.check(!routing.matchesDomain("notvk.com"), "notvk.com не матчится")
    runner.check(!routing.matchesDomain("vk.com.evil.net"), "vk.com в середине не матчится")
    runner.check(!routing.matchesDomain("evil-vk.com"), "постфикс без точки-границы не матчится")
    runner.check(routing.matchesDomain("cdn.userapi.com"), "второй суффикс")
    runner.check(routing.matchesDomain("lalune"), "домен без точки")
    runner.check(routing.matchesDomain("api.lalune"), "поддомен домена без точки")
    runner.check(!routing.matchesDomain("notlalune"), "notlalune не матчится")
    runner.check(routing.matchesDomain("example.org"), "ведущая/хвостовая точка нормализованы")
    runner.check(routing.matchesDomain("deep.example.org"), "и его поддомены")
    runner.check(routing.matchesDomain("spaced.com"), "пробелы по краям обрезаны")
    runner.check(routing.matchesDomain("port.example"), "порт отброшен при нормализации")
    runner.check(routing.matchesDomain("port.example:8080"), "порт в запросе отброшен")
    runner.check(!routing.matchesDomain(""), "пустая строка не матчится")
    runner.check(!routing.matchesDomain("bad domain.com"), "домен с пробелом внутри не матчится")

    runner.equal(routing.bypassDomains,
                 ["vk.com", "userapi.com", "lalune", "example.org", "spaced.com",
                  "port.example"],
                 "невалидные домены отброшены, валидные нормализованы")
}

// MARK: - IncyConfig

func testIncyDefaultURL() {
    runner.suite("IncyConfig: URL по умолчанию")

    let config = IncyConfig(host: "127.0.0.1", port: 1080, name: "LaLune",
                            bypassCidrs: ["10.0.0.0/8"], bypassDomains: ["vk.com"])
    guard let url = config.url(template: nil) else {
        runner.check(false, "url(template: nil) вернул nil")
        return
    }
    let text = url.absoluteString
    runner.check(text.hasPrefix("incy://add?"), "схема incy://add: \(text)")
    runner.check(text.contains("socks5=127.0.0.1:1080"), "socks5={host}:{port}")
    runner.check(text.contains("name=LaLune"), "name подставлен")
    runner.check(text.contains("bypass="), "bypass присутствует")
    runner.check(text.contains("10.0.0.0%2F8"), "CIDR закодирован как %2F: \(text)")
    runner.check(!text.contains("{"), "не осталось плейсхолдеров")
    runner.check(text.contains("bypassDomains=vk.com"), "домены подставлены")

    // bypassArgument: пользовательские CIDR + локальные, без дублей.
    // 10.0.0.0/8 передан явно и входит в localCidrs, поэтому остаётся один раз,
    // но на своём (первом) месте — порядок сохраняется.
    let expected = "10.0.0.0/8,0.0.0.0/8,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,"
        + "192.168.0.0/16,224.0.0.0/4,240.0.0.0/4,255.255.255.255/32"
    runner.equal(config.bypassArgument, expected, "bypassArgument объединяет списки без дублей")
    runner.equal(config.bypassArgument.components(separatedBy: "10.0.0.0/8").count, 2,
                 "10.0.0.0/8 встречается ровно один раз")
    runner.check(!config.bypassArgument.contains("167772160"),
                 "bypassArgument без сырых UInt32")

    // Локальный диапазон не дублируется, если его передали явно.
    let withLocal = IncyConfig(port: 1080, bypassCidrs: ["10.0.0.0/8", "127.0.0.0/8"])
    runner.equal(withLocal.bypassArgument.components(separatedBy: "127.0.0.0/8").count, 2,
                 "127.0.0.0/8 встречается ровно один раз")

    // Пустой bypass: локальные диапазоны всё равно уходят в incy.
    let empty = IncyConfig(port: 1080, bypassCidrs: [], bypassDomains: [])
    runner.equal(empty.bypassArgument, Ipv4Routing.localCidrs.joined(separator: ","),
                 "пустой bypass заменяется локальными диапазонами")
    runner.equal(empty.domainArgument, "", "пустой domainArgument")
    let emptyURL = empty.url(template: nil)?.absoluteString ?? ""
    runner.check(emptyURL.contains("bypassDomains=&") || emptyURL.hasSuffix("bypassDomains="),
                 "пустой bypassDomains остаётся пустым параметром: \(emptyURL)")
}

func testIncyEncoding() {
    runner.suite("IncyConfig: percent-encoding")

    let config = IncyConfig(host: "127.0.0.1", port: 1180,
                            name: "my proxy, a+b",
                            bypassCidrs: ["192.168.0.0/16"],
                            bypassDomains: ["vk.com", "userapi.com"])
    let text = config.url(template: nil)?.absoluteString ?? ""
    runner.check(text.contains("name=my%20proxy%2C%20a%2Bb"),
                 "пробел → %20, запятая → %2C, плюс → %2B: \(text)")
    runner.check(text.contains("bypass=192.168.0.0%2F16,"),
                 "CIDR: слэш экранирован, разделитель-запятая литеральная: \(text)")
    runner.check(text.contains("bypassDomains=vk.com,userapi.com"),
                 "домены разделены литеральной запятой: \(text)")

    // Хост со спецсимволами тоже экранируется.
    let weird = IncyConfig(host: "127.0.0.1&x=1", port: 1)
    let weirdText = weird.url(template: nil)?.absoluteString ?? ""
    runner.check(weirdText.contains("127.0.0.1%26x%3D1"),
                 "& и = в хосте экранированы: \(weirdText)")

    // Кириллица в имени — в UTF-8 percent-encoding.
    let cyrillic = IncyConfig(port: 1080, name: "Луна")
    let cyrillicText = cyrillic.url(template: nil)?.absoluteString ?? ""
    runner.check(cyrillicText.contains("name=%D0%9B%D1%83%D0%BD%D0%B0"),
                 "кириллица кодируется в UTF-8: \(cyrillicText)")
}

func testIncyTemplates() {
    runner.suite("IncyConfig: пользовательский шаблон")

    let config = IncyConfig(host: "127.0.0.1", port: 1080, name: "LaLune",
                            bypassCidrs: ["10.0.0.0/8"], bypassDomains: ["vk.com"])

    let custom = config.url(template: "incy://import?socks={host}:{port}&tag={name}")?
        .absoluteString ?? ""
    runner.equal(custom, "incy://import?socks=127.0.0.1:1080&tag=LaLune",
                 "пользовательский шаблон: подставлены только известные плейсхолдеры")

    // Неизвестные плейсхолдеры остаются как есть.
    let unknown = config.url(template: "incy://add?socks5={host}:{port}&extra={unknown}")?
        .absoluteString ?? ""
    runner.check(unknown.contains("extra=%7Bunknown%7D"),
                 "неизвестный плейсхолдер экранирован и не ломает URL: \(unknown)")

    // Пустой шаблон = шаблон по умолчанию.
    let blank = config.url(template: "")?.absoluteString ?? ""
    let fallback = config.url(template: nil)?.absoluteString ?? ""
    runner.equal(blank, fallback, "пустой шаблон трактуется как nil")

    // Шаблон без параметров.
    let plain = config.url(template: "incy://status")?.absoluteString ?? ""
    runner.equal(plain, "incy://status", "шаблон без плейсхолдеров не меняется")

    // Заведомо невалидный URL — nil, без падения.
    runner.check(config.url(template: ":// no scheme") == nil,
                 "невалидный шаблон даёт nil")
}

func testIncyDiagnostics() {
    runner.suite("IncyConfig: diagnostics")

    let config = IncyConfig(host: "127.0.0.1", port: 1080, name: "LaLune",
                            bypassCidrs: ["10.0.0.0/8", "192.168.0.0/16"],
                            bypassDomains: ["vk.com", "userapi.com"])
    let diagnostics = config.diagnostics()

    runner.equal(diagnostics["host"] as? String, "127.0.0.1", "host")
    runner.equal(diagnostics["port"] as? Int, 1080, "port — Int, а не UInt16")
    runner.equal(diagnostics["bypassCount"] as? Int, Ipv4Routing.localCidrs.count,
                 "bypassCount учитывает локальные диапазоны и дедупликацию")
    runner.equal(diagnostics["domainCount"] as? Int, 2, "domainCount")
    let url = diagnostics["url"] as? String ?? ""
    runner.check(url.hasPrefix("incy://add?"), "url присутствует в диагностике")

    let empty = IncyConfig(port: 1080).diagnostics()
    runner.equal(empty["bypassCount"] as? Int, Ipv4Routing.localCidrs.count,
                 "пустой bypass: count = число локальных диапазонов")
    runner.equal(empty["domainCount"] as? Int, 0, "пустые домены: count = 0")

    // JSON-сериализуемость: /vpn/incy отдаёт именно JSON.
    runner.check(JSONSerialization.isValidJSONObject(diagnostics),
                 "diagnostics сериализуется в JSON")
}

// MARK: - Запуск

// @main, а не top-level код: файл называется transport_main.swift (префикс
// обязателен, каталог Tests делят два агента), поэтому точкой входа служит
// атрибут, а не имя main.swift.
@main
struct TransportTests {
    static func main() {
        testRoutingCidr()
        testRoutingValidation()
        testRoutingDefaults()
        testRoutingDomains()
        testIncyDefaultURL()
        testIncyEncoding()
        testIncyTemplates()
        testIncyDiagnostics()
        testResolverLiteralAndCache()
        testResolverCoalescing()
        testResolverIgnoresForeignIDs()
        testResolverFailover()
        testResolverErrorsAndEviction()

        exit(runner.finish())
    }
}
