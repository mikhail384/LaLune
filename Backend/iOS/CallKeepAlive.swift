// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// «Режим звонка» для iOS.
//
// iOS не усыпляет приложения, которые ведут звонок: у них активна
// аудиосессия .playAndRecord + .voiceChat и постоянно идёт звук в обе
// стороны. Нам не нужен настоящий звонок и не нужен VK API — достаточно
// поднять такую же сессию и бесконечно проигрывать локально
// сгенерированный почти беззвучный сигнал «от собеседника». Вход (микрофон)
// тоже держим открытым и сразу выбрасываем — именно это система считает
// живым звонком и не даёт процессу умереть через 30 секунд после ухода в фон.
//
// Громкость выхода = 0, поэтому пользователь ничего не слышит. Если
// микрофон запрещён, честно откатываемся в режим .playback: он тоже даёт
// фоновое аудио, но без «звонковой» сессии.
//
// Только iOS: на других платформах и в Linux-тестах тело класса не
// компилируется.

#if canImport(AVFoundation)
import AVFoundation
import Foundation

final class CallKeepAlive {

    /// Какую именно сессию удалось поднять. Отдаётся в /vpn/status для
    /// диагностики: пользователю видно, «звонок» это или просто фоновое аудио.
    enum Mode: String {
        /// .playAndRecord + .voiceChat + открытый вход: сессия звонка.
        case call
        /// .playback: фоновое аудио без входа.
        case playback

        var title: String {
            switch self {
            case .call: return "звонок"
            case .playback: return "фоновое аудио"
            }
        }
    }

    private let log: (String) -> Void
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    private var running = false
    private var tapInstalled = false
    private var mode: Mode?
    private var observers: [NSObjectProtocol] = []

    /// 44.1 кГц, моно: формат принимает любой выходной узел.
    private static let sampleRate: Double = 44100
    /// Амплитуда «фейкового собеседника». Не ноль, чтобы поток был реальным
    /// аудио, но на выходе всё равно 0 громкости — пользователь не слышит.
    private static let amplitude: Float = 0.0001
    private static let toneHz: Double = 220

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    // MARK: - Состояние

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// nil, пока режим не поднят.
    var activeMode: Mode? {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    var statusDescription: String {
        guard let mode = activeMode, isRunning else { return "off" }
        return mode.rawValue
    }

    // MARK: - Запуск

    /// Поднимает «звонок», при невозможности — фоновое аудио.
    /// - Returns: true, если звук реально идёт.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        if running {
            lock.unlock()
            return true
        }
        lock.unlock()

        // Микрофон нужен только для «звонковой» сессии. Спрашиваем
        // разрешение один раз и не блокируем подключение VPN.
        switch recordPermission() {
        case .granted:
            if startEngine(mode: .call) { return true }
        case .undetermined:
            requestRecordPermission { [weak self] granted in
                guard let self = self, granted else { return }
                // Пользователь разрешил микрофон, пока мы уже работали в
                // режиме playback — перезапускаемся в полноценный звонок.
                guard self.activeMode == .playback else { return }
                self.stop()
                self.start()
            }
        case .denied:
            log("[CALL] микрофон запрещён — остаёмся в режиме фонового аудио")
        }

        if startEngine(mode: .playback) { return true }

        log("[CALL] не удалось запустить ни звонок, ни фоновое аудио")
        return false
    }

    /// Останавливает звук и деактивирует сессию. Повторный вызов безопасен.
    func stop() {
        lock.lock()
        let hadSession = running || engine != nil
        running = false
        mode = nil
        let engine = self.engine
        let player = self.player
        let tapInstalled = self.tapInstalled
        self.engine = nil
        self.player = nil
        self.buffer = nil
        self.tapInstalled = false
        let observers = self.observers
        self.observers = []
        lock.unlock()

        guard hadSession else { return }

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        player?.stop()
        if let engine = engine {
            // removeTap must not run for a bus that never got a tap.
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            if let player = player { engine.detach(player) }
        }
        deactivateSession()
        log("[CALL] режим звонка остановлен")
    }

    // MARK: - Движок

    private func startEngine(mode: Mode) -> Bool {
        guard configureSession(mode: mode) else { return false }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: CallKeepAlive.sampleRate,
                                         channels: 1),
              let silence = makeFakePeerAudio(format: format) else {
            log("[CALL] не удалось создать аудиоформат")
            deactivateSession()
            return false
        }

        var inputTapInstalled = false
        if mode == .call {
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            if inputFormat.channelCount > 0, inputFormat.sampleRate > 0 {
                // Вход открыт, но всё, что «говорит» пользователь, сразу
                // выбрасывается: нам нужен факт звонка, а не запись.
                input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { _, _ in }
                inputTapInstalled = true
            } else {
                log("[CALL] нет входного маршрута — звонок без микрофона")
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Пользователь не должен ничего слышать.
        engine.mainMixerNode.outputVolume = 0

        do {
            engine.prepare()
            try engine.start()
        } catch {
            log("[CALL] движок не запустился (\(mode.rawValue)): \(error.localizedDescription)")
            if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.detach(player)
            deactivateSession()
            return false
        }

        // Локально сгенерированный «голос собеседника» играет по кругу.
        player.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
        player.play()

        lock.lock()
        self.engine = engine
        self.player = player
        self.buffer = silence
        self.tapInstalled = inputTapInstalled
        self.mode = mode
        running = true
        lock.unlock()

        installObservers()
        log("[CALL] режим \(mode.title) активен — iOS не будет усыплять процесс")
        return true
    }

    private func configureSession(mode: Mode) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            switch mode {
            case .call:
                // Как у приложений-звонков: запись + воспроизведение и
                // голосовой режим. mixWithOthers не глушит музыку.
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.mixWithOthers, .allowBluetooth])
            case .playback:
                try session.setCategory(.playback, mode: .default,
                                        options: [.mixWithOthers])
            }
            try session.setActive(true, options: [])
            return true
        } catch {
            log("[CALL] не удалось активировать аудиосессию (\(mode.rawValue)): "
                + error.localizedDescription)
            return false
        }
    }

    private func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log("[CALL] деактивация сессии: \(error.localizedDescription)")
        }
    }

    /// Почти беззвучный тон: не цифровая тишина (её часть систем считает
    /// отсутствием аудио), но и не слышимый сигнал.
    private func makeFakePeerAudio(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CallKeepAlive.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        let step = 2 * Double.pi * CallKeepAlive.toneHz / CallKeepAlive.sampleRate
        for index in 0..<Int(frames) {
            samples[0][index] = CallKeepAlive.amplitude * Float(sin(step * Double(index)))
        }
        return buffer
    }

    // MARK: - Прерывания и маршруты

    private func installObservers() {
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self = self else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            switch AVAudioSession.InterruptionType(rawValue: raw) {
            case .began:
                self.log("[CALL] звонок прерван системой")
            case .ended:
                // Если система разрешает — поднимаем звонок заново.
                let optionsRaw =
                    (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) {
                    self.log("[CALL] прерывание закончилось — восстанавливаю звонок")
                    self.stop()
                    self.start()
                }
            default:
                break
            }
        }
        let route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self = self else { return }
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            self.log("[CALL] сменился аудиомаршрут (reason=\(raw))")
        }

        lock.lock()
        observers.append(interruption)
        observers.append(route)
        lock.unlock()
    }

    // MARK: - Разрешение на микрофон

    private enum Permission {
        case granted
        case denied
        case undetermined
    }

    private func recordPermission() -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    private func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

#endif
