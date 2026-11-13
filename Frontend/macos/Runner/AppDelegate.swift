import Cocoa
import FlutterMacOS

// LaLune для macOS: при старте поднимает встроенный бэкенд (Contents/Resources/lalune-backend)
// с правами администратора (нужны для utun и маршрутов) и останавливает его при выходе.
// Без Mac не проверялось — см. Backend/README.md.
@main
class AppDelegate: FlutterAppDelegate {
  private let apiURL = URL(string: "http://127.0.0.1:1062")!

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.ensureBackend()
    }
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    stopBackend()
    return .terminateNow
  }

  private func backendAlive() -> Bool {
    var request = URLRequest(url: apiURL.appendingPathComponent("ping"))
    request.timeoutInterval = 1.5
    let sem = DispatchSemaphore(value: 0)
    var alive = false
    URLSession.shared.dataTask(with: request) { _, response, _ in
      alive = (response as? HTTPURLResponse)?.statusCode == 200
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 2.5)
    return alive
  }

  private func ensureBackend() {
    if backendAlive() { return }
    guard let binary = Bundle.main.path(forResource: "lalune-backend", ofType: nil) else {
      NSLog("[LaLune] lalune-backend не найден в Resources")
      return
    }
    // Бэкенд должен работать под root (utun, route, networksetup): запрашиваем пароль
    // администратора штатным диалогом macOS.
    let quoted = binary.replacingOccurrences(of: "'", with: "'\\''")
    let shell = "'\(quoted)' >/tmp/lalune-backend.log 2>&1 &"
    let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    do { try task.run() } catch { NSLog("[LaLune] osascript: \(error)") }
  }

  private func stopBackend() {
    var request = URLRequest(url: apiURL.appendingPathComponent("shutdown"))
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 3.5)
  }
}