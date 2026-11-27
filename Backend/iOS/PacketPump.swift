// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// UDP-мост до ядра CSQTT. Ядро живёт в том же процессе и обменивается с
// userspace-транспортом сырыми IPv4-пакетами через loopback UDP-сокет.
// PacketPump — единственная точка этого обмена: он отправляет пакеты,
// которые построил TCP-стек / UDP NAT, и раздаёт входящие датаграммы.
//
// Network.framework + Foundation. На Linux не компилируется — там тестируются
// только чистые части (PacketCodec, Ipv4Routing, IncyConfig, TunnelResolver).

import Foundation
import Network

final class PacketPump {

    // MARK: - Конфигурация

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "lalune.packet.pump")
    private let lock = NSLock()

    /// Предельный размер IPv4-датаграммы, которую примет receive.
    private static let maxDatagram = 65535
    /// Сколько ждём .ready в start(). Ядро поднимается за миллисекунды, но на
    /// холодном старте может потребоваться чуть больше времени.
    private static let readyTimeout: DispatchTimeInterval = .seconds(5)

    // MARK: - Состояние

    private var connection: NWConnection?
    private var running = false
    private var receiving = false

    /// Входящая IPv4-датаграмма. Вызывается на внутренней очереди насоса;
    /// обработчик должен быть быстрым и не блокировать её.
    var onDatagram: (([UInt8]) -> Void)?

    /// Изменение состояния: `(работает, сообщение об ошибке или nil)`.
    var onStateChange: ((Bool, String?) -> Void)?

    // MARK: - Инициализация

    init(host: String = "127.0.0.1", port: UInt16 = 52230) {
        self.host = host
        self.port = port
    }

    // MARK: - Жизненный цикл

    /// Открывает UDP-сокет и синхронно ждёт готовности (до 5 секунд).
    /// - Returns: true, если сокет готов к обмену.
    @discardableResult
    func start() -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange?(false, "invalid port \(port)")
            return false
        }

        lock.lock()
        if running {
            lock.unlock()
            return true
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        self.connection = connection
        lock.unlock()

        let gate = ReadyGate()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if gate.open() {
                    self.onStateChange?(true, nil)
                }
            case .waiting(let error):
                // Для loopback это «ядро ещё не слушает». Состояние временное,
                // NWConnection сам повторит, поэтому НЕ рапортуем наружу как
                // ошибку: подписчик вправе счесть любой (false, error)
                // фатальным и погасить туннель. Достаточно локального лога.
                NSLog("[PUMP] waiting: %@", error.localizedDescription)
            case .failed(let error):
                gate.fail(error.localizedDescription)
                self.onStateChange?(false, error.localizedDescription)
                self.teardown(connection, notify: false)
            case .cancelled:
                gate.fail("cancelled")
                self.teardown(connection, notify: false)
            default:
                break
            }
        }

        connection.start(queue: queue)

        let ready = gate.wait(timeout: Self.readyTimeout)
        if !ready {
            lock.lock()
            if self.connection === connection {
                self.connection = nil
            }
            lock.unlock()
            connection.cancel()
            onStateChange?(false, "timeout waiting for UDP socket")
            return false
        }

        lock.lock()
        running = true
        lock.unlock()
        beginReceiving(connection)
        return true
    }

    /// Отправляет одну IPv4-датаграмму. Потокобезопасно; после stop() — no-op.
    func send(_ packet: [UInt8]) {
        guard !packet.isEmpty else { return }
        lock.lock()
        let connection = running ? self.connection : nil
        lock.unlock()
        guard let connection = connection else { return }
        connection.send(content: Data(packet), completion: .contentProcessed { _ in })
    }

    /// Закрывает сокет. Повторный вызов безопасен.
    func stop() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        let wasRunning = running
        running = false
        receiving = false
        lock.unlock()

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        if wasRunning {
            onStateChange?(false, nil)
        }
    }

    /// true, если сокет открыт и готов.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Приём

    private func beginReceiving(_ connection: NWConnection) {
        lock.lock()
        if receiving || !running {
            lock.unlock()
            return
        }
        receiving = true
        lock.unlock()
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        // `receiveMessage` has only the `completion:` form; the
        // minimumIncompleteLength/maximumLength variant is `receive`.
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: Self.maxDatagram) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.onDatagram?([UInt8](data))
            }

            if let error = error {
                self.onStateChange?(false, error.localizedDescription)
                self.teardown(connection, notify: false)
                return
            }

            self.lock.lock()
            let stillCurrent = self.running && self.connection === connection
            self.lock.unlock()
            guard stillCurrent else { return }
            self.receiveLoop(connection)
        }
    }

    // MARK: - Служебное

    /// Снимает сокет после ошибки/отмены и сообщает наружу, если он был живым.
    private func teardown(_ connection: NWConnection, notify: Bool) {
        lock.lock()
        guard self.connection === connection else {
            lock.unlock()
            return
        }
        self.connection = nil
        let wasRunning = running
        running = false
        receiving = false
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        if notify && wasRunning {
            onStateChange?(false, nil)
        }
    }
}

// MARK: - Ожидание готовности

/// Однократный «затвор» для синхронного start(): .ready и .failed могут
/// прийти несколько раз, сработать должен только первый.
private final class ReadyGate {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var settled = false
    private var ready = false

    func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        ready = true
        semaphore.signal()
        return true
    }

    func fail(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        ready = false
        semaphore.signal()
    }

    /// Ждёт вердикта; по таймауту возвращает false.
    func wait(timeout: DispatchTimeInterval) -> Bool {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
}
