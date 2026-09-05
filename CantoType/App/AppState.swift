import AppKit
import Combine
import Foundation

/// 整個 app 嘅狀態機同流程協調：快捷鍵 → 錄音 → 辨識 → LLM 整理 → 貼上。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case polishing
        case pasting
        case done
        case error(String)

        var label: String {
            switch self {
            case .idle: return "閒置"
            case .recording: return "錄音中…"
            case .transcribing: return "辨識中…"
            case .polishing: return "整理中…"
            case .pasting: return "貼上中…"
            case .done: return "已貼上"
            case .error(let message): return "出錯：\(message)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing, .polishing, .pasting: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var lastText: String = ""
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var ollamaReachable: Bool?
    @Published private(set) var hotkeyArmed = false
    @Published private(set) var appleAssetStatus: String = ""

    let settings = AppSettings.shared
    let history = HistoryStore()
    let sidecar = WhisperSidecar()

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let polisher = TextPolisher()
    private lazy var hud = HUDController(state: self)
    private var appleBackends: [String: AppleSpeechBackend] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var resetTask: Task<Void, Never>?

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "mic.fill"
        case .transcribing, .polishing, .pasting: return "ellipsis.bubble"
        case .error: return "mic.slash"
        case .idle, .done: return "mic"
        }
    }

    // MARK: - Lifecycle

    func start() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.hotkeyPressed() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.hotkeyReleased() }
        }
        hotkey.onEscape = { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }

        settings.$hotkey
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.armHotkey() } }
            .store(in: &cancellables)
        settings.$appleLocale
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.warmUpApple() } }
            .store(in: &cancellables)
        Publishers.CombineLatest(settings.$ollamaHost, settings.$ollamaModel)
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.warmUpOllama() } }
            .store(in: &cancellables)

        Publishers.CombineLatest4(settings.$backend, settings.$whisperModel, settings.$manageSidecar, settings.$httpURL)
            .dropFirst()
            .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.syncSidecar() } }
            .store(in: &cancellables)

        refreshPermissions()
        armHotkey()
        startPermissionPolling()
        syncSidecar()

        Task { await warmUpApple() }
        Task { await warmUpOllama() }
        Task {
            let granted = await Permissions.requestMicrophone()
            microphoneGranted = granted
        }
    }

    func shutdown() {
        hotkey.stop()
        permissionTimer?.invalidate()
        sidecar.stop()
    }

    // MARK: - MLX Whisper sidecar

    /// 設定係「MLX Whisper + localhost」就由 app 管理伺服器，否則關掉。
    func syncSidecar() {
        if let port = settings.sidecarPort {
            sidecar.ensureRunning(model: settings.whisperModel, port: port, language: settings.httpLanguage)
        } else {
            sidecar.stop()
        }
    }

    func restartSidecar() {
        guard let port = settings.sidecarPort else { return }
        sidecar.restart(model: settings.whisperModel, port: port, language: settings.httpLanguage)
    }

    func armHotkey() {
        hotkey.configure(settings.hotkey)
        hotkeyArmed = hotkey.start()
    }

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityTrusted
        microphoneGranted = Permissions.microphoneGranted
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissions()
                if self.accessibilityGranted, !self.hotkeyArmed {
                    self.armHotkey()
                }
            }
        }
    }

    // MARK: - Hotkey

    private func hotkeyPressed() {
        switch settings.activation {
        case .hold:
            beginRecording()
        case .toggle:
            if phase == .recording {
                endRecording()
            } else {
                beginRecording()
            }
        }
    }

    private func hotkeyReleased() {
        guard settings.activation == .hold else { return }
        endRecording()
    }

    // MARK: - Recording

    func beginRecording() {
        guard !phase.isBusy else { return }
        resetTask?.cancel()
        do {
            try recorder.start()
        } catch {
            fail("開唔到麥克風：\(error.localizedDescription)")
            return
        }
        phase = .recording
        if settings.showHUD { hud.show() }
        if settings.playSounds { Sounds.play(.start) }
    }

    func endRecording() {
        guard phase == .recording else { return }
        let clip = recorder.stop()
        level = 0
        if settings.playSounds { Sounds.play(.stop) }
        // 太短當係誤觸
        guard clip.duration >= 0.4 else {
            phase = .idle
            hud.hide()
            return
        }
        Task { await process(clip) }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        _ = recorder.stop()
        level = 0
        phase = .idle
        hud.hide()
    }

    // MARK: - Pipeline

    private func process(_ clip: AudioClip) async {
        phase = .transcribing
        let started = Date()
        do {
            var backend = try currentBackend()
            var backendNote = ""
            // Whisper 伺服器仲喺載入（例如第一次下載模型）就先用 Apple 頂住
            if settings.backend == .http, settings.sidecarPort != nil, !sidecar.status.isReady {
                backend = appleBackend(for: settings.appleLocale)
                backendNote = "（Whisper 未就緒，改用 Apple）"
            }
            let raw = TranscriptCleaner.normalize(try await backend.transcribe(clip))
            guard !raw.isEmpty else { throw TranscriptionError.noResult }

            var output = raw
            if settings.polishMode != .raw {
                phase = .polishing
                output = await polisher.polishOrFallback(
                    raw,
                    mode: settings.polishMode,
                    vocabulary: settings.vocabularyList,
                    config: settings.polishConfig
                )
            }

            phase = .pasting
            await TextInserter.paste(output, restoreClipboard: settings.restoreClipboard)
            lastText = output
            history.add(HistoryItem(
                raw: raw,
                polished: output,
                duration: clip.duration,
                backend: backend.displayName + backendNote,
                mode: settings.polishMode,
                elapsed: Date().timeIntervalSince(started)
            ))
            phase = .done
            scheduleReset(after: 1.2)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        phase = .error(message)
        if settings.showHUD { hud.show() }
        scheduleReset(after: 3)
    }

    private func scheduleReset(after seconds: Double) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.phase = .idle
            self.hud.hide()
        }
    }

    // MARK: - Backends

    private func currentBackend() throws -> any TranscriptionBackend {
        switch settings.backend {
        case .apple:
            return appleBackend(for: settings.appleLocale)
        case .http:
            guard let url = URL(string: settings.httpURL) else {
                throw TranscriptionError.backendUnavailable("HTTP 網址無效")
            }
            return HTTPTranscriptionBackend(url: url, model: settings.httpModel, language: settings.httpLanguage)
        }
    }

    private func appleBackend(for identifier: String) -> AppleSpeechBackend {
        if let existing = appleBackends[identifier] { return existing }
        let backend = AppleSpeechBackend(localeIdentifier: identifier)
        appleBackends[identifier] = backend
        return backend
    }

    func warmUpApple() async {
        let identifier = settings.appleLocale
        let backend = appleBackend(for: identifier)
        appleAssetStatus = "檢查語言包…"
        do {
            try await backend.prepare { [weak self] status in
                Task { @MainActor in self?.appleAssetStatus = status }
            }
            appleAssetStatus = "已就緒（\(identifier)）"
        } catch {
            appleAssetStatus = "語言包失敗：\(error.localizedDescription)"
        }
    }

    func warmUpOllama() async {
        ollamaReachable = await polisher.warmUp(config: settings.polishConfig)
    }

    /// 設定頁「測試連線」用。
    func testOllama() async -> String {
        guard let url = URL(string: settings.ollamaHost) else { return "網址無效" }
        let client = OllamaClient(host: url)
        guard await client.isReachable() else { return "連接唔到 \(settings.ollamaHost)" }
        let models = (try? await client.listModels()) ?? []
        guard models.contains(where: { $0 == settings.ollamaModel || $0.hasPrefix(settings.ollamaModel + ":") }) else {
            return "已連接，但搵唔到模型「\(settings.ollamaModel)」。可用：\(models.joined(separator: "、"))"
        }
        let started = Date()
        do {
            let sample = "呃 我覺得 K M同 K Y嗰邊 security可以做好啲 即係 睇下佢係唔係識得聽廣東話"
            let result = try await polisher.polish(sample, mode: settings.polishMode, vocabulary: settings.vocabularyList, config: settings.polishConfig)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return "正常（\(ms) ms）：\(result)"
        } catch {
            return "出錯：\(error.localizedDescription)"
        }
    }
}
