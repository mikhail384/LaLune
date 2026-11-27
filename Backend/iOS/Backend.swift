// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend для iOS 17+.
// HTTP-сервер на 127.0.0.1:1062, ядро CSQTT в процессе приложения, VK через
// собственный WKWebView (VkWebViewController).
//
// Точка входа: Backend.shared.attach(window:).run()
//
// Без NetworkExtension: системный VPN поднимает приложение incy, которому мы
// отдаём локальный SOCKS5 (TunnelSession). Порт SOCKS5 — 1080 или следующий
// свободный.

import Foundation
#if canImport(FoundationNetworking)
// Linux toolchains keep URLSession/URLRequest in a separate module; on iOS this
// import is skipped and Foundation already provides them.
import FoundationNetworking
#endif
import Network
import UIKit
import UserNotifications

@available(iOS 17.0, *)
public final class Backend {

    public static let shared = Backend()

    private let PORT: UInt16 = 1062
    private let HOST = "127.0.0.1"
    private let VERSION = "0.9.18"
    private let APP_GROUP = "group.com.lalune"
    private let TUNNEL_BUNDLE_ID = "com.lalune.lalune.tunnel"

    private let DEFAULT_WORKERS = 9
    private let MIN_WORKERS = 1
    private let MAX_WORKERS = 127
    private let DEFAULT_AUTO_API_WORKERS = 9
    private let MIN_AUTO_API_WORKERS = 9
    private let MAX_AUTO_API_WORKERS = 27

    private let VK_API_BASE = "https://api.vk.ru/method/"
    private let VK_API_VERSION = "5.199"

    private var window: UIWindow?

    private var appDir: URL {
        if let c = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP) {
            let d = c.appendingPathComponent("la-lune", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("la-lune", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var settingsURL: URL { appDir.appendingPathComponent("settings.json") }
    private var deviceIdURL: URL { appDir.appendingPathComponent("device_id.json") }
    private var tokenURL: URL { appDir.appendingPathComponent("token.json") }
    private var logsURL: URL { appDir.appendingPathComponent("logs.log") }
    private var tunnelLogsURL: URL { appDir.appendingPathComponent("tunnel.log") }
    private var configsURL: URL { appDir.appendingPathComponent("configs.json") }
    private var selectedConfigURL: URL { appDir.appendingPathComponent("selected_config.json") }

    private let stateQueue = DispatchQueue(label: "lalune.backend.state", attributes: .concurrent)
    private var logs: [String] = []
    private var eventSubscribers: [UUID: (String) -> Void] = [:]
    private var httpServer: HttpServer?
    private var running = false
    private var activeConfigId: Int64 = 0
    /// Owns the core, the userspace stack and the incy registration.
    private var tunnel: TunnelSession?
    // Serialize explicit VPN mutations with a measurement's entire lifetime.
    // Recursive because a measurement nests connect/measure/disconnect.
    private let vpnOperation = NSRecursiveLock()
    private var smarttunnelRunning = false
    private var coreDownloading = false
    private var activeCallIds: [String] = []

    private var vkWebVC: VkWebViewController?
    private var vkLoginInProgress = false
    private var vkLoginMessage = ""

    // ============================================================
    //  Public API
    // ============================================================

    public func attach(window: UIWindow?) {
        self.window = window
    }

    public func run() {
        guard !running else { log("[BACKEND] already running"); return }
        running = true

        ensureDefaults()
        _ = makeTunnel()

        let server = HttpServer(host: HOST, port: PORT) { [weak self] method, path, body in
            guard let self = self else { return (500, "{}") }
            return self.route(method: method, rawPath: path, body: body)
        } onSseOpen: { [weak self] send in
            guard let self = self else { return UUID() }
            let id = UUID()
            self.stateQueue.async(flags: .barrier) {
                self.eventSubscribers[id] = send
            }
            return id
        } onSseClose: { [weak self] id in
            guard let self = self else { return }
            self.stateQueue.async(flags: .barrier) {
                self.eventSubscribers.removeValue(forKey: id)
            }
        }

        self.httpServer = server
        server.start()
        log("[BACKEND] LaLune iOS backend started on http://\(HOST):\(PORT)")
    }

    public func stop() {
        running = false
        tunnel?.stop()
        tunnel = nil
        httpServer?.stop()
        httpServer = nil
    }

    // ============================================================
    //  Router
    // ============================================================

    private func route(method: String, rawPath: String, body: String) -> (Int, String) {
        let qIdx = rawPath.firstIndex(of: "?")
        let path = qIdx.map { String(rawPath[..<$0]) } ?? rawPath
        let query = qIdx.map { String(rawPath[rawPath.index(after: $0)...]) } ?? ""

        if method == "OPTIONS" { return (200, "{}") }

        do {
            switch (method, path) {
            case ("GET", "/ping"):
                return (200, json(["ok": true, "version": VERSION,
                                   "os": "ios", "arch": "arm64", "uptime": 0,
                                   "socks5Port": Int(makeTunnel().snapshot().socksPort)]))
            case ("GET", "/version"):
                return (200, json(["api": 1, "backend": VERSION,
                                   "core": CoreManager.shared.readLatest(),
                                   "ui": VERSION]))
            case ("POST", "/shutdown"):
                stop(); return (200, json(["ok": true]))

            case ("GET", "/configs"):
                return (200, loadConfigsJson())
            case ("GET", "/configs/selected"):
                return (200, readSelectedConfigJson() ?? "{}")
            case ("PUT", "/configs/selected"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? Int64 {
                    if let c = findConfig(id: id) {
                        writeSelectedConfig(jsonString(from: c) ?? "{}")
                        return (200, json(["ok": true]))
                    }
                    return (404, err("config not found"))
                } else {
                    clearSelectedConfig()
                    return (200, json(["ok": true]))
                }
            case ("POST", "/configs/parse"):
                let obj = (try? JSONSerialization.jsonObject(
                    with: body.data(using: .utf8) ?? Data()) as? [String: Any])
                let link = obj?["link"] as? String ?? ""
                let protocolName = obj?["protocol"] as? String ?? "CSQTT"
                return (200, jsonString(from: parseLink(link, protocol: protocolName)) ?? "{}")
            case ("POST", "/configs"):
                return createConfig(body: body)

            case ("GET", "/settings"):
                return (200, loadSettingsJson())
            case ("PUT", "/settings"):
                return replaceSettings(body: body)
            case ("PATCH", "/settings"):
                return patchSettings(body: body)
            case ("POST", "/settings/reset"):
                saveSettings(defaultSettings())
                return (200, json(["ok": true]))

            case ("GET", "/device/id"):
                return (200, json(["deviceId": getDeviceId()]))
            case ("POST", "/device/id/regenerate"):
                let new = UUID().uuidString.lowercased()
                updateDeviceId(new)
                return (200, json(["deviceId": new]))
            case ("GET", "/device/info"):
                return (200, json(["os": "ios", "arch": "arm64",
                                   "deviceId": getDeviceId(),
                                   "hostname": UIDevice.current.name,
                                   "cores": ProcessInfo.processInfo.processorCount,
                                   "totalMemMb": Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)]))

            case ("POST", "/vpn/connect"):
                return withVpnOperation { vpnConnect(body: body) }
            case ("POST", "/vpn/disconnect"):
                return withVpnOperation { vpnDisconnect() }
            case ("POST", "/vpn/measure"):
                return withVpnOperation { vpnMeasure(body: body) }
            case ("GET", "/vpn/status"):
                return vpnStatus()
            case ("POST", "/vpn/reconnect"):
                return withVpnOperation {
                    _ = vpnDisconnect()
                    return vpnConnect(body: "{}")
                }
            case ("GET", "/vpn/stats"):
                return vpnStats()
            case ("GET", "/vpn/incy"):
                return vpnIncy(query: "")
            case ("POST", "/vpn/incy"):
                return vpnIncy(query: query)
            case ("GET", "/vpn/tunconf"):
                return (200, "{}")

            case ("GET", "/logs"):
                return (200, jsonArrayFromLogs())
            case ("GET", "/logs/tail"):
                let n = Int(queryValue(query, "lines") ?? "100") ?? 100
                return (200, jsonArrayFromLogs(tail: n))
            case ("DELETE", "/logs"):
                stateQueue.async(flags: .barrier) { self.logs.removeAll() }
                try? "".write(to: logsURL, atomically: true, encoding: .utf8)
                try? "".write(to: tunnelLogsURL, atomically: true, encoding: .utf8)
                return (200, json(["ok": true]))
            case ("GET", "/logs/export"):
                return (200, currentLogs().joined(separator: "\n"))

            case ("GET", "/core/version"):
                return (200, json(["version": CoreManager.shared.readLatest()]))
            case ("GET", "/core/latest"):
                return (200, json(["version": CoreManager.shared.fetchLatestVersion() ?? ""]))
            case ("GET", "/core/check"):
                let local = CoreManager.shared.readLatest()
                let remote = CoreManager.shared.fetchLatestVersion() ?? ""
                return (200, json([
                    "hasUpdate": !remote.isEmpty && remote != local,
                    "local": local, "remote": remote
                ]))
            case ("POST", "/core/download/sync"):
                let ok = CoreManager.shared.downloadCore()
                return ok ? (200, json(["ok": true])) : (500, err("download failed"))
            case ("GET", "/core/path"):
                return (200, json(["path": CoreManager.shared.corePath() ?? ""]))
            case ("GET", "/core/protocols"):
                return (200, """
                [{"id":"CSQTT","displayName":"CSQTT 2.5.1","repo":"Endlad2/csqtt-core","realtime":true,"description":"Встроенное iOS-ядро CSQTT","coreAsset":"embedded"},{"id":"CSQTTR","displayName":"CSQTTR 2.5.2","repo":"Endlad2/csqttr-core","realtime":true,"description":"Встроенное iOS-ядро CSQTTR","coreAsset":"embedded"}]
                """)
            case ("DELETE", "/core"):
                if let p = CoreManager.shared.corePath() {
                    try? FileManager.default.removeItem(atPath: p)
                }
                return (200, json(["ok": true]))

            case ("GET", "/update/check"):
                return (200, json(["hasUpdate": false, "remoteTag": "",
                                   "localVersion": VERSION]))
            case ("GET", "/update/url"):
                return (200, json(["url": "https://github.com/Endlad2/LaLune/releases/latest"]))

            case ("GET", "/vk/token/state"):
                return (200, readVkStateJson())
            case ("POST", "/vk/token/login"):
                return vkLogin()
            case ("POST", "/vk/token/submit"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = obj["token"] as? String, !token.isEmpty {
                    saveVkToken(token)
                    return (200, json(["ok": true]))
                }
                return (400, err("token empty"))
            case ("GET", "/vk/token/validate"):
                let has = readVkToken() != nil
                return (200, json(["valid": has, "message": has ? "" : "no token"]))
            case ("POST", "/vk/token/fetch/cancel"):
                DispatchQueue.main.async { self.vkWebVC?.dismiss(animated: true) }
                return (200, json(["ok": true]))
            case ("DELETE", "/vk/token"):
                try? FileManager.default.removeItem(at: tokenURL)
                return (200, json(["ok": true]))

            case ("POST", "/vk/calls/start"):
                return vkCallsStart(body: body)
            case ("POST", "/vk/calls/stop"):
                return (200, json(["finished": 0]))
            case ("POST", "/vk/calls/stop-all"):
                let n = activeCallIds.count
                activeCallIds.removeAll()
                return (200, json(["finished": n]))
            case ("GET", "/vk/calls/active"):
                return (200, json(["callIds": activeCallIds]))

            case ("GET", "/smarttunnel/status"):
                return (200, json(["running": smarttunnelRunning]))
            case ("POST", "/smarttunnel/start"):
                smarttunnelRunning = true
                return (200, json(["ok": true]))
            case ("POST", "/smarttunnel/stop"):
                smarttunnelRunning = false
                return (200, json(["ok": true]))
            case ("POST", "/smarttunnel/reload"):
                return (200, json(["ok": true]))
            case ("GET", "/smarttunnel/logs"):
                return (200, "[]")
            case ("GET", "/smarttunnel/args"):
                return (200, "[]")
            case ("PUT", "/smarttunnel/args"):
                return (200, json(["ok": true]))

            case ("POST", "/deploy/run"):
                return (200, json(["stub": true, "message": "DeployManager not yet implemented"]))
            case ("GET", "/deploy/status"):
                return (200, json(["busy": false, "stub": true]))
            case ("GET", "/deploy/log"):
                return (200, json(["log": "", "stub": true]))
            case ("POST", "/deploy/cancel"):
                return (200, json(["stub": true]))
            case ("GET", "/deploy/protocols"):
                return (200, json(["protocols": [], "stub": true]))

            case ("GET", "/platform/capabilities"):
                let snapshot = makeTunnel().snapshot()
                return (200, json([
                    "canShowWebView": true, "canRunTun": false, "canDeploy": false,
                    "canAutoUpdate": false, "canSendNotifications": true,
                    "canOpenExternalUrl": true, "os": "ios", "platform": "mobile",
                    "canSocks5": true, "requiresIncy": true,
                    "mode": "socks5-incy",
                    "socks5Port": Int(snapshot.socksPort),
                ]))
            case ("POST", "/platform/open-url"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let urlStr = obj["url"] as? String, let url = URL(string: urlStr) {
                    DispatchQueue.main.async { UIApplication.shared.open(url) }
                }
                return (200, json(["ok": true]))
            case ("POST", "/platform/notify"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let title = obj["title"] as? String ?? ""
                    let bodyStr = obj["body"] as? String ?? ""
                    let content = UNMutableNotificationContent()
                    content.title = title; content.body = bodyStr
                    let req = UNNotificationRequest(identifier: UUID().uuidString,
                                                     content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(req)
                }
                return (200, json(["ok": true]))
            case ("POST", "/platform/open-path"):
                return (200, json(["ok": true]))
            case ("POST", "/platform/share"):
                return (200, json(["ok": true]))

            case ("GET", "/debug/state"):
                let snapshot = makeTunnel().snapshot()
                return (200, json([
                    "logCount": currentLogs().count,
                    "appDir": appDir.path,
                    "vpnConnected": snapshot.connected,
                    "vpnState": snapshot.state,
                    "socks5Port": Int(snapshot.socksPort),
                    "tunnelIp": snapshot.tunnelIP,
                    "incyOpened": snapshot.incyOpened,
                    "callMode": snapshot.callMode,
                ]))
            case ("POST", "/debug/echo"):
                return (200, body)
            case ("GET", "/debug/config"):
                return (200, json([
                    "appDir": appDir.path, "configsPath": configsURL.path,
                    "settingsPath": settingsURL.path, "logsPath": logsURL.path,
                    "tokenPath": tokenURL.path,
                    "corePath": CoreManager.shared.corePath() ?? ""
                ]))
            case ("POST", "/debug/reload-config"):
                return (200, json(["ok": true]))

            default:
                return (404, err("route not found: \(method) \(path)"))
            }
        } catch {
            return (500, err(error.localizedDescription))
        }
    }

    // ============================================================
    //  Файлы
    // ============================================================

    private func ensureDefaults() {
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            saveSettings(defaultSettings())
        }
        if !FileManager.default.fileExists(atPath: logsURL.path) {
            try? "".write(to: logsURL, atomically: true, encoding: .utf8)
        }
    }

    private func defaultSettings() -> [String: Any] {
        return [
            "peer": "", "vkHashes": "", "vkJsToken": "",
            "workers": DEFAULT_WORKERS, "autoApiWorkers": DEFAULT_AUTO_API_WORKERS,
            "password": "", "obfs": "video", "fingerprint": "firefox",
            "clientIds": "8202606,6287487", "deviceId": getDeviceId(),
            "authMode": "manual", "turnTransport": "udp",
            "turnHost": "", "turnPort": "",
            "captchaMode": "auto", "vkAuthMode": "vkcalls",
            "allowHashRedistribution": false, "validateVkHashes": false,
            "enableSmartTunnel": false, "showCoreLogs": false,
            "shareVpn": false,
            // iOS-only: локальный «режим звонка» (аудиосессия .voiceChat с
            // тихим локально сгенерированным звуком) держит ядро и SOCKS5
            // живыми в фоне. Отключается в settings.json.
            "iosCallMode": true
        ]
    }

    private func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return defaultSettings() }
        // Existing installs predate the iOS-only call-mode switch; older
        // builds stored iosFakeCall/iosBackgroundAudio instead.
        var settings = obj
        if settings["iosCallMode"] == nil {
            settings["iosCallMode"] = (settings["iosBackgroundAudio"] as? Bool)
                ?? (settings["iosFakeCall"] as? Bool) ?? true
        }
        return settings
    }

    private func loadSettingsJson() -> String {
        jsonString(from: loadSettings()) ?? "{}"
    }

    private func saveSettings(_ s: [String: Any]) {
        var copy = s
        copy["deviceId"] = getDeviceId()
        if let w = copy["workers"] as? Int {
            copy["workers"] = min(max(w, MIN_WORKERS), MAX_WORKERS)
        }
        if let aw = copy["autoApiWorkers"] as? Int {
            copy["autoApiWorkers"] = min(max(aw, MIN_AUTO_API_WORKERS), MAX_AUTO_API_WORKERS)
        }
        if let data = try? JSONSerialization.data(withJSONObject: copy, options: .prettyPrinted) {
            try? data.write(to: settingsURL)
        }
    }

    private func replaceSettings(body: String) -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }
        saveSettings(obj)
        return (200, json(["ok": true]))
    }

    private func patchSettings(body: String) -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }
        var s = loadSettings()
        for (k, v) in patch { s[k] = v }
        saveSettings(s)
        return (200, json(["ok": true]))
    }

    /// Stable UUIDv4 persisted separately from editable settings. Read settings
    /// directly only for one-time migration to avoid defaultSettings recursion.
    private func getDeviceId() -> String {
        func canonicalUuid(_ raw: String?) -> String? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let expanded: String
            if raw.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil {
                let chars = Array(raw)
                expanded = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" +
                    String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
            } else {
                expanded = raw
            }
            guard let uuid = UUID(uuidString: expanded) else { return nil }
            let canonical = uuid.uuidString.lowercased()
            guard canonical.dropFirst(14).first == "4" else { return nil }
            return canonical
        }

        let fromFile: String? = {
            guard let data = try? Data(contentsOf: deviceIdURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return canonicalUuid(object["deviceId"] as? String)
        }()
        let legacyId: String? = {
            guard let data = try? Data(contentsOf: settingsURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return canonicalUuid(object["deviceId"] as? String)
        }()
        let id = fromFile ?? legacyId ?? UUID().uuidString.lowercased()
        let payload = ["deviceId": id]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            try? data.write(to: deviceIdURL, options: .atomic)
        }
        return id
    }

    private func updateDeviceId(_ new: String) {
        let canonical = UUID(uuidString: new)?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
        if let data = try? JSONSerialization.data(withJSONObject: ["deviceId": canonical], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: deviceIdURL, options: .atomic)
        }
        var s = loadSettings()
        s["deviceId"] = canonical
        saveSettings(s)
    }

    private func readVkToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let t = (obj["Token"] as? String) ?? (obj["token"] as? String) ?? ""
        return t.isEmpty ? nil : t
    }

    private func saveVkToken(_ token: String) {
        let iso = ISO8601DateFormatter().string(from: Date())
        let obj: [String: Any] = ["Token": token, "SavedAt": iso]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: tokenURL)
        }
        log("[VK] token saved to \(tokenURL.path)")
    }

    private func readVkStateJson() -> String {
        let has = readVkToken() != nil
        return json([
            "hasToken": has,
            "fetching": vkLoginInProgress,
            "progress": has ? 100 : (vkLoginInProgress ? 40 : 0),
            "message": has ? "VK token active"
                : (vkLoginInProgress ? vkLoginMessage : "")
        ])
    }

    // ============================================================
    //  Логи
    // ============================================================

    private func currentLogs() -> [String] {
        var out: [String] = []
        stateQueue.sync { out = self.logs }

        if let raw = try? String(contentsOf: tunnelLogsURL, encoding: .utf8) {
            let tunnelLines = raw
                .split(whereSeparator: \.isNewline)
                .map { "[TUNNEL] " + String($0) }
            out.append(contentsOf: tunnelLines)
        }

        if out.count > 1000 {
            out = Array(out.suffix(1000))
        }
        return out
    }

    private func log(_ line: String) {
        print("[LaLune] \(line)")
        stateQueue.async(flags: .barrier) {
            self.logs.append(line)
            if self.logs.count > 1000 { self.logs.removeFirst(self.logs.count - 1000) }
        }
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logsURL) {
                handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
            } else {
                try? data.write(to: logsURL)
            }
        }
        emitEvent(json(["type": "log", "line": line,
                        "ts": Int(Date().timeIntervalSince1970)]))
    }

    private func emitEvent(_ payload: String) {
        stateQueue.sync {
            for (_, send) in self.eventSubscribers { send(payload) }
        }
    }

    private func jsonArrayFromLogs(tail n: Int? = nil) -> String {
        var snap = currentLogs()
        if let n = n, snap.count > n { snap = Array(snap.suffix(n)) }
        if let data = try? JSONSerialization.data(withJSONObject: snap),
           let s = String(data: data, encoding: .utf8) { return s }
        return "[]"
    }

    // ============================================================
    //  Конфиги
    // ============================================================

    private func loadConfigs() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: configsURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr
    }

    private func loadConfigsJson() -> String {
        jsonString(from: loadConfigs()) ?? "[]"
    }

    private func saveConfigs(_ arr: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted) {
            try? data.write(to: configsURL)
        }
    }

    private func findConfig(id: Int64) -> [String: Any]? {
        loadConfigs().first {
            ($0["id"] as? Int64) == id || ($0["id"] as? Int) == Int(id)
        }
    }

    private func createConfig(body: String) -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }

        var parsed: [String: Any]
        if let link = b["link"] as? String, !link.isEmpty {
            parsed = parseLink(link, protocol: b["protocol"] as? String ?? "CSQTT")
        } else {
            parsed = [
                "protocol": b["protocol"] as? String ?? "CSQTT",
                "peer": b["peer"] as? String ?? "",
                "password": b["password"] as? String ?? "",
                "hashes": b["hashes"] as? String ?? "",
                "name": b["name"] as? String ?? "",
            ]
        }
        let id = Int64(Date().timeIntervalSince1970 * 1000)
        parsed["id"] = id
        parsed["rawLink"] = b["link"] as? String ?? ""
        var arr = loadConfigs()
        arr.append(parsed)
        saveConfigs(arr)
        return (200, json(["id": id]))
    }

    private func readSelectedConfigJson() -> String? {
        guard let data = try? Data(contentsOf: selectedConfigURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeSelectedConfig(_ jsonStr: String) {
        try? jsonStr.write(to: selectedConfigURL, atomically: true, encoding: .utf8)
    }

    private func clearSelectedConfig() {
        try? FileManager.default.removeItem(at: selectedConfigURL)
    }

    private func parseLink(_ link: String, protocol protocolName: String = "CSQTT") -> [String: Any] {
        var out: [String: Any] = [
            "protocol": protocolName, "peer": "", "password": "", "hashes": "", "name": ""
        ]
        guard link.lowercased().hasPrefix("csqtt://") else {
            out["peer"] = link
            return out
        }
        let rest = String(link.dropFirst("csqtt://".count))
        if rest.hasPrefix("connect?") {
            let query = String(rest.dropFirst("connect?".count))
            var host = "", port = "", password = "", hashes = ""
            for kv in query.split(separator: "&") {
                let parts = kv.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let k = String(parts[0]); let v = String(parts[1])
                switch k {
                case "host": host = v
                case "peer": port = v
                case "password": password = v
                case "hashes": hashes = v.replacingOccurrences(of: "+", with: ",")
                default: break
                }
            }
            let peer = "\(host):\(port)"
            out["peer"] = peer; out["password"] = password
            out["hashes"] = hashes; out["name"] = peer
        }
        return out
    }

    // ============================================================
    //  VPN — in-process core + userspace stack + incy
    // ============================================================

    private func withVpnOperation(_ operation: () -> (Int, String)) -> (Int, String) {
        guard vpnOperation.try() else { return (409, err("VPN operation in progress")) }
        defer { vpnOperation.unlock() }
        return operation()
    }

    private func makeTunnel() -> TunnelSession {
        if let tunnel = tunnel { return tunnel }
        let session = TunnelSession(
            log: { [weak self] line in self?.log(line) },
            emit: { [weak self] event in self?.emitEvent(self?.json(event) ?? "{}") },
            openURL: { [weak self] url in
                guard let self = self else { return false }
                return self.openExternalURL(url)
            }
        )
        tunnel = session
        return session
    }

    /// Opens a URL through the shared application. Must run on the main queue.
    private func openExternalURL(_ url: URL) -> Bool {
        // UIApplication requires the main thread; this helper is only called
        // from the session queue or an HTTP worker, never from main.
        guard !Thread.isMainThread else { return false }
        let sem = DispatchSemaphore(value: 0)
        var opened = false
        DispatchQueue.main.async {
            guard UIApplication.shared.canOpenURL(url) else {
                sem.signal()
                return
            }
            UIApplication.shared.open(url, options: [:]) { success in
                opened = success
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 8)
        return opened
    }

    private struct MeasureRequest: Decodable {
        let temporary: Bool
        let configId: Int64?
        let link: String?
        let `protocol`: String?
    }

    /// HTTP-style failure of a profile lookup: keeps the status code so the
    /// caller can answer with the same shape as the other platforms.
    private struct ProfileError: Error {
        let status: Int
        let message: String
    }

    /// Resolves the profile for a connect/measure request. Never mutates the
    /// stored selection for temporary sessions.
    private func resolveProfile(configId: Int64?, link: String?, `protocol`: String?)
        -> Result<([String: Any], Int64), ProfileError> {
        if let link = link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
            guard let parsed = parseLinkForTunnel(link, protocol: `protocol`) else {
                return .failure(ProfileError(status: 400, message: "invalid profile link"))
            }
            return .success((parsed, -1))
        }
        if let id = configId, id > 0 {
            guard let saved = findConfig(id: id) else {
                return .failure(ProfileError(status: 404, message: "profile not found"))
            }
            return .success((saved, id))
        }
        guard let selected = readSelectedConfigJson(),
              let config = try? JSONSerialization.jsonObject(with: Data(selected.utf8)) as? [String: Any]
        else {
            return .failure(ProfileError(status: 400, message: "no config selected"))
        }
        return .success((config, (config["id"] as? NSNumber)?.int64Value ?? 0))
    }

    /// The iOS core only understands plaintext `csqtt://`/`csqttr://` links.
    private func parseLinkForTunnel(_ link: String, protocol name: String?) -> [String: Any]? {
        let lower = link.lowercased()
        let isCsqttr = lower.hasPrefix("csqttr://connect?")
        guard isCsqttr || lower.hasPrefix("csqtt://connect?") else { return nil }
        let prefix = isCsqttr ? "csqttr://connect?" : "csqtt://connect?"
        let parsed = parseLink("csqtt://connect?" + link.dropFirst(prefix.count),
                               protocol: name ?? (isCsqttr ? "CSQTTR" : "CSQTT"))
        guard let peer = parsed["peer"] as? String,
              let separator = peer.lastIndex(of: ":"), separator != peer.startIndex,
              let port = UInt16(peer[peer.index(after: separator)...]), port > 0 else {
            return nil
        }
        var config = parsed
        config["id"] = NSNumber(value: -1)
        return config
    }

    private func vpnConnect(body: String) -> (Int, String) {
        let snapshot = makeTunnel().snapshot()
        guard snapshot.state == "disconnected" || snapshot.state == "error" else {
            return (409, err("VPN is already \(snapshot.state)"))
        }
        let request = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            ?? [:]
        let requestedId = (request["configId"] as? NSNumber)?.int64Value
        switch resolveProfile(configId: requestedId, link: nil, protocol: nil) {
        case .failure(let failure):
            return (failure.status, err(failure.message))
        case .success(let profile):
            return startTunnel(config: profile.0, configId: profile.1, temporary: false)
        }
    }

    private func startTunnel(config: [String: Any], configId: Int64,
                             temporary: Bool) -> (Int, String) {
        let session = makeTunnel()
        let settings = loadSettings()
        let sem = DispatchSemaphore(value: 0)
        var result: Result<TunnelSession.StartResult, Error>?
        session.start(config: config, settings: settings, configId: configId,
                      temporary: temporary) { outcome in
            result = outcome
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 90) == .success, let outcome = result else {
            session.stop()
            return (504, err("tunnel start timed out"))
        }
        switch outcome {
        case .success(let started):
            activeConfigId = configId
            if !temporary {
                saveSelectedConfigId(configId)
            }
            log("[VPN] connected, SOCKS5 port \(started.port), incy \(started.incyOpened ? "opened" : "not opened")")
            return (200, json([
                "ok": true, "status": "connected",
                "socks5Port": Int(started.port),
                "incyOpened": started.incyOpened,
                "incyUrl": started.incyURL,
            ]))
        case .failure(let error):
            let snapshot = session.snapshot()
            return (500, err(snapshot.message.isEmpty ? error.localizedDescription : snapshot.message))
        }
    }

    private func vpnDisconnect() -> (Int, String) {
        let session = makeTunnel()
        let snapshot = session.snapshot()
        guard snapshot.state != "disconnected" else {
            activeConfigId = 0
            return (200, json(["ok": true]))
        }
        let sem = DispatchSemaphore(value: 0)
        session.stop { sem.signal() }
        guard sem.wait(timeout: .now() + 20) == .success else {
            log("[VPN] disconnect timed out")
            return (504, err("VPN did not disconnect"))
        }
        activeConfigId = 0
        log("[VPN] disconnect")
        return (200, json(["ok": true]))
    }

    private func vpnStatus() -> (Int, String) {
        let snapshot = makeTunnel().snapshot()
        return (200, json([
            "state": snapshot.state,
            "connected": snapshot.connected,
            "uptimeSec": 0,
            "configId": snapshot.configId,
            "message": snapshot.message,
            "since": "",
            "socks5Port": Int(snapshot.socksPort),
            "tunnelIp": snapshot.tunnelIP,
            "incyOpened": snapshot.incyOpened,
            "callMode": snapshot.callMode,
            "platform": "ios",
            "mode": "socks5-incy",
        ]))
    }

    private func vpnStats() -> (Int, String) {
        let snapshot = makeTunnel().snapshot()
        return (200, json([
            "rxBytes": Int(snapshot.rxBytes), "txBytes": Int(snapshot.txBytes),
            "rxRate": 0, "txRate": 0,
            "activeSessions": snapshot.activeConnections,
            "socks5Port": Int(snapshot.socksPort),
        ]))
    }

    private func vpnIncy(query: String) -> (Int, String) {
        let template = queryValue(query, "template")
        let (opened, url) = makeTunnel().reapplyIncy(template: template)
        return (200, json([
            "opened": opened,
            "url": url,
            "hint": opened ? "" : "Установите incy и повторите, либо импортируйте SOCKS5 127.0.0.1:\(makeTunnel().snapshot().socksPort) вручную",
        ]))
    }

    private func vpnMeasure(body: String) -> (Int, String) {
        guard let request = try? JSONDecoder().decode(MeasureRequest.self, from: Data(body.utf8)) else {
            return (400, err("bad measurement request"))
        }
        let session = makeTunnel()
        if !request.temporary {
            let snapshot = session.snapshot()
            guard snapshot.connected, request.configId == snapshot.configId else {
                return (409, err("requested VPN profile is not connected"))
            }
            return measureLatency(session)
        }
        let current = session.snapshot()
        guard current.state == "disconnected" || current.state == "error" else {
            return (409, err("VPN is not disconnected"))
        }
        let profile: [String: Any]
        let id: Int64
        switch resolveProfile(configId: request.configId, link: request.link,
                              protocol: request.protocol) {
        case .failure(let failure):
            return (failure.status, err(failure.message))
        case .success(let value):
            profile = value.0
            id = value.1
        }
        let started = startTunnel(config: profile, configId: id, temporary: true)
        guard started.0 == 200 else {
            _ = vpnDisconnect()
            return started
        }
        let measured = measureLatency(session)
        _ = vpnDisconnect()
        activeConfigId = current.configId
        return measured
    }

    private func measureLatency(_ session: TunnelSession) -> (Int, String) {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Int, Error>?
        session.measure { outcome in
            result = outcome
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 12) == .success, let outcome = result else {
            return (504, err("tunnel latency probe timed out"))
        }
        switch outcome {
        case .success(let ms):
            return (200, json(["latencyMs": ms]))
        case .failure(let error):
            return (504, err(error.localizedDescription))
        }
    }

    private func saveSelectedConfigId(_ id: Int64) {
        guard id > 0 else { return }
        let shared = UserDefaults(suiteName: APP_GROUP)
        shared?.set(NSNumber(value: id), forKey: "configId")
        shared?.synchronize()
    }

    // ============================================================
    //  VK — свой WKWebView
    // ============================================================

    private func vkLogin() -> (Int, String) {
        if vkLoginInProgress {
            return (200, json(["ok": true, "needsUi": false, "message": "already in progress"]))
        }

        vkLoginInProgress = true
        vkLoginMessage = "Открываю окно авторизации..."
        log("[VK] opening WKWebView")

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                self.vkLoginInProgress = false
                self.emitEvent(self.json(["type": "error", "message": "no root view controller"]))
                return
            }

            let vc = VkWebViewController(
                onSuccess: { [weak self] token in
                    guard let self = self else { return }
                    self.vkLoginInProgress = false
                    self.vkLoginMessage = ""
                    self.vkWebVC = nil
                    self.saveVkToken(token)
                    self.log("[VK] token received successfully")
                    self.emitEvent(self.json(["type": "progress",
                                              "kind": "vk_token", "percent": 100]))
                },
                onError: { [weak self] message in
                    guard let self = self else { return }
                    self.vkLoginInProgress = false
                    self.vkLoginMessage = message
                    self.vkWebVC = nil
                    self.log("[VK] error: \(message)")
                    self.emitEvent(self.json(["type": "error", "message": "VK: \(message)"]))
                }
            )

            self.vkWebVC = vc
            rootVC.present(vc, animated: true)
        }

        return (200, json(["ok": true, "needsUi": false]))
    }

    private func topViewController() -> UIViewController? {
        var vc = window?.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    // ============================================================
    //  VK Calls
    // ============================================================

    private func vkCallsStart(body: String) -> (Int, String) {
        guard let token = readVkToken() else { return (400, err("no VK token")) }
        guard let data = body.data(using: .utf8),
              let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }

        let s = loadSettings()
        let workers = b["workers"] as? Int ?? s["workers"] as? Int ?? DEFAULT_WORKERS
        let aw = b["autoApiWorkers"] as? Int
            ?? s["autoApiWorkers"] as? Int ?? DEFAULT_AUTO_API_WORKERS
        let count = callCountForWorkers(workers: workers, aw: aw)

        var hashes: [String] = []
        var callIds: [String] = []

        for slot in 0..<count {
            if slot > 0 { Thread.sleep(forTimeInterval: count <= 4 ? 0.08 : 0.202) }
            let (cid, hash, errCode) = startVkCall(token: token)
            if !hash.isEmpty {
                hashes.append(hash); callIds.append(cid); activeCallIds.append(cid)
            } else if [4, 5, 27, 28].contains(errCode) {
                return (401, err("VK token invalid"))
            }
        }
        if hashes.isEmpty { return (500, err("no calls created")) }
        return (200, json(["hashes": hashes, "callIds": callIds]))
    }

    private func callCountForWorkers(workers: Int, aw: Int) -> Int {
        let aw2 = aw <= 0 ? DEFAULT_AUTO_API_WORKERS : aw
        let w2 = workers <= 0 ? DEFAULT_WORKERS : workers
        let count = Int(ceil(Double(w2) / Double(aw2)))
        return min(max(count, 1), 6)
    }

    private func startVkCall(token: String) -> (String, String, Int) {
        guard let url = URL(string: VK_API_BASE + "calls.start") else { return ("", "", -1) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.httpBody = "v=\(VK_API_VERSION)".data(using: .utf8)

        let sem = DispatchSemaphore(value: 0)
        var result: (String, String, Int) = ("", "", -1)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let e = j["error"] as? [String: Any] {
                result = ("", "", e["error_code"] as? Int ?? 0)
                return
            }
            guard let r = j["response"] as? [String: Any] else { return }
            let callId = r["call_id"] as? String ?? ""
            let okLink = r["ok_join_link"] as? String ?? ""
            let joinLink = r["join_link"] as? String ?? ""
            let hash = !okLink.isEmpty ? okLink
                : (joinLink.components(separatedBy: "/").last ?? "")
            result = (callId, hash, 0)
        }.resume()
        sem.wait()
        return result
    }

    // ============================================================
    //  Helpers
    // ============================================================

    private func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func jsonString(from obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func err(_ message: String) -> String {
        json(["error": message])
    }

    private func queryValue(_ query: String, _ key: String) -> String? {
        for kv in query.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == key { return String(parts[1]) }
        }
        return nil
    }
}
