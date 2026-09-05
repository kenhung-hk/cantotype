import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

@MainActor
final class ModelLabWindowController {
    private weak var state: AppState?
    private var window: NSWindow?
    private var lab: ModelLab?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        guard let state else { return }
        if window == nil {
            let lab = ModelLab(state: state)
            self.lab = lab
            let host = NSHostingController(rootView: ModelLabView(lab: lab).environmentObject(state.settings))
            let window = NSWindow(contentViewController: host)
            window.title = "模型試驗室"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 780))
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Model

@MainActor
final class ModelLab: ObservableObject {
    struct ASRCandidate: Identifiable, Hashable {
        enum Kind: Hashable {
            case apple(locale: String)
            case mlx(repo: String)
            /// HuggingFace transformers 格式，要先由伺服器轉成 MLX
            case hf(repo: String)
        }

        let kind: Kind
        let isCustom: Bool

        var id: String {
            switch kind {
            case .apple(let locale): return "apple:\(locale)"
            case .mlx(let repo): return "mlx:\(repo)"
            case .hf(let repo): return "hf:\(repo)"
            }
        }

        var label: String {
            switch kind {
            case .apple(let locale): return "Apple 內置 · \(locale)"
            case .mlx(let repo): return "MLX Whisper · \(repo)"
            case .hf(let repo): return "Whisper fine-tune · \(repo)"
            }
        }

        var repo: String? {
            switch kind {
            case .apple: return nil
            case .mlx(let repo), .hf(let repo): return repo
            }
        }
    }

    struct LLMCandidate: Identifiable, Hashable {
        enum Kind: Hashable {
            case mlx(repo: String)
            case ollama(model: String)
        }

        let kind: Kind
        let isCustom: Bool

        var id: String {
            switch kind {
            case .mlx(let repo): return "mlx:\(repo)"
            case .ollama(let model): return "ollama:\(model)"
            }
        }

        var label: String {
            switch kind {
            case .mlx(let repo): return "MLX · \(repo)"
            case .ollama(let model): return "Ollama · \(model)"
            }
        }
    }

    struct RunResult {
        var text = ""
        var ms = 0
        var cer: Double?
        var error: String?
        var running = false
        /// 進度說明（例如「轉換中：下載…」）
        var note = ""
    }

    @Published private(set) var clip: AudioClip?
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published private(set) var recordSeconds: Double = 0
    @Published var reference = ""

    @Published private(set) var asrCandidates: [ASRCandidate] = []
    @Published var asrSelected: Set<String> = []
    @Published private(set) var asrResults: [String: RunResult] = [:]
    @Published private(set) var asrRunning = false
    @Published var customWhisper = ""

    @Published var llmInput = ""
    @Published var llmMode: PolishMode = .colloquial
    @Published private(set) var llmCandidates: [LLMCandidate] = []
    @Published var llmSelected: Set<String> = []
    @Published private(set) var llmResults: [String: RunResult] = [:]
    @Published private(set) var llmRunning = false
    @Published var customLLM = ""

    @Published private(set) var status = ""

    private unowned let state: AppState
    private let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private var recordTimer: Timer?
    private var recordStart: Date?
    private var player: AVAudioPlayer?

    private static let customWhisperKey = "labCustomWhisper"
    private static let customHFWhisperKey = "labCustomHFWhisper"
    private static let customLLMKey = "labCustomLLM"
    private static let convertedPathsKey = "labConvertedPaths"
    /// HF repo → 已轉換嘅本地 MLX 路徑
    @Published private(set) var convertedPaths: [String: String] = [:]

    init(state: AppState) {
        self.state = state
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        buildCandidates()
        Task { await discoverOllama() }
    }

    // MARK: Candidates

    private func buildCandidates() {
        var asr: [ASRCandidate] = [
            ASRCandidate(kind: .apple(locale: "zh_HK"), isCustom: false),
        ]
        asr += WhisperModelPreset.allCases.map {
            ASRCandidate(kind: $0.needsConversion ? .hf(repo: $0.rawValue) : .mlx(repo: $0.rawValue), isCustom: false)
        }
        asr += savedCustom(Self.customWhisperKey).map { ASRCandidate(kind: .mlx(repo: $0), isCustom: true) }
        asr += savedCustom(Self.customHFWhisperKey).map { ASRCandidate(kind: .hf(repo: $0), isCustom: true) }
        asrCandidates = asr
        asrSelected = Set(asr.filter {
            switch $0.kind {
            case .apple(let locale): return locale == "zh_HK"
            case .mlx(let repo), .hf(let repo): return WhisperModelPreset(rawValue: repo)?.selectedByDefault ?? false
            }
        }.map(\.id))
        convertedPaths = (UserDefaults.standard.dictionary(forKey: Self.convertedPathsKey) as? [String: String]) ?? [:]

        var llm = LLMModelPreset.allCases.map { LLMCandidate(kind: .mlx(repo: $0.rawValue), isCustom: false) }
        llm += savedCustom(Self.customLLMKey).map { LLMCandidate(kind: .mlx(repo: $0), isCustom: true) }
        llmCandidates = llm
        llmSelected = Set(llm.filter {
            if case .mlx(let repo) = $0.kind {
                return LLMModelPreset(rawValue: repo)?.selectedByDefault ?? false
            }
            return false
        }.map(\.id))
    }

    private func savedCustom(_ key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addCustomWhisper() {
        let repo = customWhisper.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty, !asrCandidates.contains(where: { $0.repo == repo }) else { return }
        status = "檢查 \(repo) 嘅格式…"
        Task {
            do {
                try await ensureServer()
                let format = try await inspectFormat(repo: repo)
                let candidate: ASRCandidate
                switch format {
                case "mlx", "local", "converted":
                    candidate = ASRCandidate(kind: .mlx(repo: repo), isCustom: true)
                    UserDefaults.standard.set(savedCustom(Self.customWhisperKey) + [repo], forKey: Self.customWhisperKey)
                case "hf":
                    candidate = ASRCandidate(kind: .hf(repo: repo), isCustom: true)
                    UserDefaults.standard.set(savedCustom(Self.customHFWhisperKey) + [repo], forKey: Self.customHFWhisperKey)
                default:
                    status = "\(repo) 唔係 Whisper 模型（搵唔到 weights）"
                    return
                }
                asrCandidates.append(candidate)
                asrSelected.insert(candidate.id)
                customWhisper = ""
                status = format == "hf" ? "已加入，第一次跑會自動轉成 MLX" : ""
            } catch {
                status = "加入失敗：\(error.localizedDescription)"
            }
        }
    }

    func addCustomLLM() {
        let repo = customLLM.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty, !llmCandidates.contains(where: { $0.id == "mlx:\(repo)" }) else { return }
        llmCandidates.append(LLMCandidate(kind: .mlx(repo: repo), isCustom: true))
        llmSelected.insert("mlx:\(repo)")
        UserDefaults.standard.set(savedCustom(Self.customLLMKey) + [repo], forKey: Self.customLLMKey)
        customLLM = ""
    }

    func remove(_ candidate: ASRCandidate) {
        asrCandidates.removeAll { $0.id == candidate.id }
        asrSelected.remove(candidate.id)
        switch candidate.kind {
        case .mlx(let repo):
            UserDefaults.standard.set(savedCustom(Self.customWhisperKey).filter { $0 != repo }, forKey: Self.customWhisperKey)
        case .hf(let repo):
            UserDefaults.standard.set(savedCustom(Self.customHFWhisperKey).filter { $0 != repo }, forKey: Self.customHFWhisperKey)
        case .apple:
            break
        }
    }

    func remove(_ candidate: LLMCandidate) {
        llmCandidates.removeAll { $0.id == candidate.id }
        llmSelected.remove(candidate.id)
        if case .mlx(let repo) = candidate.kind {
            UserDefaults.standard.set(savedCustom(Self.customLLMKey).filter { $0 != repo }, forKey: Self.customLLMKey)
        }
    }

    private func discoverOllama() async {
        guard let host = URL(string: settings.ollamaHost) else { return }
        let client = OllamaClient(host: host)
        guard await client.isReachable(), let models = try? await client.listModels() else { return }
        for model in models where !model.contains("embed") {
            let candidate = LLMCandidate(kind: .ollama(model: model), isCustom: false)
            if !llmCandidates.contains(where: { $0.id == candidate.id }) {
                llmCandidates.append(candidate)
            }
        }
    }

    func selectionBinding(asr id: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.asrSelected.contains(id) ?? false },
            set: { [weak self] on in if on { self?.asrSelected.insert(id) } else { self?.asrSelected.remove(id) } }
        )
    }

    func selectionBinding(llm id: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.llmSelected.contains(id) ?? false },
            set: { [weak self] on in if on { self?.llmSelected.insert(id) } else { self?.llmSelected.remove(id) } }
        )
    }

    // MARK: Audio

    func toggleRecording() {
        if isRecording {
            recordTimer?.invalidate()
            recordTimer = nil
            let captured = recorder.stop()
            isRecording = false
            level = 0
            clip = captured.isEmpty ? nil : captured
            asrResults = [:]
            status = captured.isEmpty ? "冇錄到聲音" : ""
        } else {
            recorder.inputDeviceUID = settings.inputDeviceUID
            do {
                try recorder.start()
            } catch {
                status = "開唔到麥克風：\(error.localizedDescription)"
                return
            }
            isRecording = true
            recordStart = Date()
            recordSeconds = 0
            recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordStart else { return }
                    self.recordSeconds = Date().timeIntervalSince(start)
                }
            }
        }
    }

    /// 載入 app 上一次真正輸入時嘅錄音。
    func loadLastRecording() {
        let url = AppState.lastRecordingURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "仲未有錄音記錄（用快捷鍵講一句先）"
            return
        }
        do {
            clip = try AudioClip.load(url)
            asrResults = [:]
            status = ""
        } catch {
            status = "載入失敗：\(error.localizedDescription)"
        }
    }

    func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "揀一個音檔（wav / m4a / mp3 / aiff）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            clip = try AudioClip.load(url)
            asrResults = [:]
            status = ""
        } catch {
            status = "載入失敗：\(error.localizedDescription)"
        }
    }

    func play() {
        guard let clip else { return }
        player = try? AVAudioPlayer(data: clip.wavData())
        player?.play()
    }

    var clipDescription: String {
        guard let clip else { return "未有音檔" }
        let stats = clip.stats
        return String(format: "%.1f 秒 · 峰值 %d dB · RMS %d dB", clip.duration, Int(stats.peakDb), Int(stats.rmsDb))
    }

    // MARK: Runs

    private var serverPort: Int {
        URL(string: settings.httpURL)?.port ?? 8787
    }

    private func ensureServer() async throws {
        if await MLXSidecar.health(port: serverPort) != nil { return }
        status = "啟動 MLX 伺服器…"
        state.ensureSidecarForLab()
        for _ in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            if await MLXSidecar.health(port: serverPort) != nil {
                status = ""
                return
            }
        }
        throw TranscriptionError.backendUnavailable("MLX 伺服器未能啟動：\(state.sidecar.summary)")
    }

    private var serverBase: String { settings.sidecarBaseURL }

    private func inspectFormat(repo: String) async throws -> String {
        var components = URLComponents(string: serverBase + "/models/inspect")!
        components.queryItems = [URLQueryItem(name: "repo", value: repo)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? String
        else { throw TranscriptionError.backendUnavailable("HuggingFace 搵唔到 \(repo)") }
        return format
    }

    /// 已轉換就即刻回傳路徑；否則叫伺服器轉換，一路更新 row 嘅進度。
    private func ensureConverted(repo: String, candidateID: String) async throws -> String {
        if let path = convertedPaths[repo], FileManager.default.fileExists(atPath: path + "/weights.safetensors") {
            return path
        }
        var request = URLRequest(url: URL(string: serverBase + "/models/convert")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["repo": repo])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let job = try JSONSerialization.jsonObject(with: data) as? [String: Any], let jobID = job["job"] as? String else {
            throw TranscriptionError.backendUnavailable("伺服器唔接受轉換要求")
        }
        var current = job
        while (current["status"] as? String) == "running" {
            let lastLog = (current["log"] as? [String])?.last ?? ""
            asrResults[candidateID] = RunResult(running: true, note: "轉換成 MLX：\(lastLog)")
            try await Task.sleep(for: .seconds(3))
            let (poll, _) = try await URLSession.shared.data(from: URL(string: serverBase + "/models/convert/\(jobID)")!)
            current = (try JSONSerialization.jsonObject(with: poll) as? [String: Any]) ?? current
        }
        guard (current["status"] as? String) == "done", let path = current["path"] as? String else {
            throw TranscriptionError.backendUnavailable("轉換失敗：\((current["error"] as? String) ?? "未知原因")")
        }
        convertedPaths[repo] = path
        UserDefaults.standard.set(convertedPaths, forKey: Self.convertedPathsKey)
        return path
    }

    func runASR() async {
        guard let clip, !asrRunning else { return }
        asrRunning = true
        let prepared = clip.normalized()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in asrCandidates where asrSelected.contains(candidate.id) {
            asrResults[candidate.id] = RunResult(running: true)
            status = "跑 \(candidate.label)…"
            let started = Date()
            do {
                let text: String
                switch candidate.kind {
                case .apple(let locale):
                    let backend = AppleSpeechBackend(localeIdentifier: locale)
                    backend.contextualStrings = settings.contextualStrings
                    try await backend.prepare()
                    text = try await backend.transcribe(prepared)
                case .mlx(let repo):
                    try await ensureServer()
                    guard let url = URL(string: settings.httpURL) else {
                        throw TranscriptionError.backendUnavailable("HTTP 網址無效")
                    }
                    let backend = HTTPTranscriptionBackend(url: url, model: repo, language: settings.httpLanguage, timeout: 900, prompt: settings.whisperPrompt)
                    text = try await backend.transcribe(prepared)
                case .hf(let repo):
                    try await ensureServer()
                    let path = try await ensureConverted(repo: repo, candidateID: candidate.id)
                    asrResults[candidate.id] = RunResult(running: true, note: "辨識中…")
                    guard let url = URL(string: settings.httpURL) else {
                        throw TranscriptionError.backendUnavailable("HTTP 網址無效")
                    }
                    let backend = HTTPTranscriptionBackend(url: url, model: path, language: settings.httpLanguage, timeout: 900, prompt: settings.whisperPrompt)
                    text = try await backend.transcribe(prepared)
                }
                let cleaned = TranscriptCleaner.normalize(text)
                asrResults[candidate.id] = RunResult(
                    text: cleaned,
                    ms: Int(Date().timeIntervalSince(started) * 1000),
                    cer: reference.isEmpty ? nil : CER.compute(reference: reference, hypothesis: cleaned)
                )
            } catch {
                asrResults[candidate.id] = RunResult(error: error.localizedDescription)
            }
        }
        status = ""
        asrRunning = false
        if llmInput.trimmingCharacters(in: .whitespaces).isEmpty {
            useBestASRForLLM()
        }
    }

    /// 有 CER 就揀最低嘅，否則揀第一個成功嘅。
    func useBestASRForLLM() {
        let successes = asrCandidates.compactMap { candidate -> (ASRCandidate, RunResult)? in
            guard let result = asrResults[candidate.id], result.error == nil, !result.text.isEmpty else { return nil }
            return (candidate, result)
        }
        let best = successes.min { ($0.1.cer ?? 1) < ($1.1.cer ?? 1) } ?? successes.first
        if let best {
            llmInput = best.1.text
        }
    }

    func runLLM() async {
        let input = llmInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !llmRunning else { return }
        llmRunning = true
        for candidate in llmCandidates where llmSelected.contains(candidate.id) {
            llmResults[candidate.id] = RunResult(running: true)
            status = "跑 \(candidate.label)…"
            let started = Date()
            var config = settings.polishConfig
            config.requestTimeout = 900
            do {
                switch candidate.kind {
                case .mlx(let repo):
                    try await ensureServer()
                    config.provider = .mlx
                    config.mlxModel = repo
                case .ollama(let model):
                    config.provider = .ollama
                    config.ollamaModel = model
                    config.ollamaFallbackModel = ""
                }
                let output = try await TextPolisher().polish(input, mode: llmMode, vocabulary: settings.llmVocabulary, config: config)
                llmResults[candidate.id] = RunResult(text: output, ms: Int(Date().timeIntervalSince(started) * 1000))
            } catch {
                llmResults[candidate.id] = RunResult(error: error.localizedDescription)
            }
        }
        status = ""
        llmRunning = false
    }

    // MARK: Apply

    func isDefault(_ candidate: ASRCandidate) -> Bool {
        switch candidate.kind {
        case .apple(let locale): return settings.backend == .apple && settings.appleLocale == locale
        case .mlx(let repo): return settings.backend == .http && settings.whisperModel == repo
        case .hf(let repo): return settings.backend == .http && convertedPaths[repo] != nil && settings.whisperModel == convertedPaths[repo]
        }
    }

    /// 未轉換嘅 fine-tune 唔可以直接設為預設，要先跑一次。
    func canUse(_ candidate: ASRCandidate) -> Bool {
        if case .hf(let repo) = candidate.kind { return convertedPaths[repo] != nil }
        return true
    }

    func isDefault(_ candidate: LLMCandidate) -> Bool {
        switch candidate.kind {
        case .mlx(let repo): return settings.llmProvider == .mlx && settings.llmModel == repo
        case .ollama(let model): return settings.llmProvider == .ollama && settings.ollamaModel == model
        }
    }

    func use(_ candidate: ASRCandidate) {
        switch candidate.kind {
        case .apple(let locale):
            settings.appleLocale = locale
            settings.backend = .apple
        case .mlx(let repo):
            settings.whisperModel = repo
            settings.backend = .http
        case .hf(let repo):
            guard let path = convertedPaths[repo] else { return }
            settings.whisperModel = path
            settings.backend = .http
        }
        objectWillChange.send()
    }

    func use(_ candidate: LLMCandidate) {
        switch candidate.kind {
        case .mlx(let repo):
            settings.llmModel = repo
            settings.llmProvider = .mlx
        case .ollama(let model):
            settings.ollamaModel = model
            settings.llmProvider = .ollama
        }
        objectWillChange.send()
    }
}

// MARK: - CER

enum CER {
    /// 字錯率：唔計標點同空格，英文唔分大小寫。
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = strip(reference)
        let hyp = strip(hypothesis)
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1 }
        return Double(levenshtein(ref, hyp)) / Double(ref.count)
    }

    private static func strip(_ text: String) -> [Character] {
        Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// MARK: - View

struct ModelLabView: View {
    @ObservedObject var lab: ModelLab
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                audioSection
                asrSection
                llmSection
            }
            .padding(22)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            
            Text("錄一段廣東話，一次過跑幾個辨識模型同 LLM 並排比較，滿意就按「用呢個」設為預設。")
                .foregroundStyle(.secondary)
            if !lab.status.isEmpty {
                Label(lab.status, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 1. 音檔

    private var audioSection: some View {
        GroupBox("1. 音檔") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        lab.toggleRecording()
                    } label: {
                        Label(lab.isRecording ? String(format: "停止（%.1f 秒）", lab.recordSeconds) : "錄一段", systemImage: lab.isRecording ? "stop.circle.fill" : "record.circle")
                            .frame(minWidth: 120)
                    }
                    .tint(lab.isRecording ? .red : nil)
                    .buttonStyle(.borderedProminent)
                    if lab.isRecording {
                        LevelMeter(level: lab.level)
                    }
                    Button("載入音檔…") { lab.loadFile() }
                        .disabled(lab.isRecording)
                    Button("上一次輸入嘅錄音") { lab.loadLastRecording() }
                        .disabled(lab.isRecording)
                        .help("app 每次快捷鍵輸入都會保留最後一段錄音，方便喺呢度重播同比較")
                    Button {
                        lab.play()
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .disabled(lab.clip == nil || lab.isRecording)
                    Spacer()
                    Text(lab.clipDescription).font(.caption).foregroundStyle(.secondary)
                }
                TextField("你實際講咗啲乜（可選；填咗就會計每個模型嘅字錯率 CER）", text: $lab.reference)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(6)
        }
    }

    // MARK: 2. 辨識

    private var asrSection: some View {
        GroupBox("2. 語音辨識") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        Task { await lab.runASR() }
                    } label: {
                        Label(lab.asrRunning ? "跑緊…" : "跑全部已選", systemImage: "play.rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lab.clip == nil || lab.asrRunning || lab.asrSelected.isEmpty)
                    if lab.asrRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    TextField("加入 HuggingFace 上其他 MLX Whisper repo…", text: $lab.customWhisper)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)
                        .onSubmit { lab.addCustomWhisper() }
                    Button("加入") { lab.addCustomWhisper() }
                        .disabled(lab.customWhisper.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Divider()
                ForEach(lab.asrCandidates) { candidate in
                    candidateRow(
                        label: candidate.label,
                        isCustom: candidate.isCustom,
                        isDefault: lab.isDefault(candidate),
                        selected: lab.selectionBinding(asr: candidate.id),
                        result: lab.asrResults[candidate.id],
                        showCER: true,
                        canUse: lab.canUse(candidate),
                        use: { lab.use(candidate) },
                        remove: { lab.remove(candidate) }
                    )
                    Divider()
                }
                Text("MLX 格式嘅模型第一次會下載（0.5 至 3 GB）；HuggingFace 格式嘅廣東話 fine-tune 會自動下載並轉成 MLX（1 至 6 GB，幾分鐘），呢一行會顯示進度。舊版 Whisper（large-v3 之前）冇 yue token，伺服器會自動改用 zh 解碼。CER 越低越準。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: 3. LLM

    private var llmSection: some View {
        GroupBox("3. LLM 整理") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("模式", selection: $lab.llmMode) {
                        Text(PolishMode.colloquial.label).tag(PolishMode.colloquial)
                        Text(PolishMode.written.label).tag(PolishMode.written)
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                    Button("用最佳辨識結果") { lab.useBestASRForLLM() }
                        .disabled(lab.asrResults.isEmpty)
                }
                TextEditor(text: $lab.llmInput)
                    .font(.body)
                    .frame(minHeight: 64, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                HStack {
                    Button {
                        Task { await lab.runLLM() }
                    } label: {
                        Label(lab.llmRunning ? "跑緊…" : "跑全部已選", systemImage: "play.rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lab.llmInput.trimmingCharacters(in: .whitespaces).isEmpty || lab.llmRunning || lab.llmSelected.isEmpty)
                    if lab.llmRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    TextField("加入 mlx-community 上其他 LLM repo…", text: $lab.customLLM)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)
                        .onSubmit { lab.addCustomLLM() }
                    Button("加入") { lab.addCustomLLM() }
                        .disabled(lab.customLLM.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Divider()
                ForEach(lab.llmCandidates) { candidate in
                    candidateRow(
                        label: candidate.label,
                        isCustom: candidate.isCustom,
                        isDefault: lab.isDefault(candidate),
                        selected: lab.selectionBinding(llm: candidate.id),
                        result: lab.llmResults[candidate.id],
                        showCER: false,
                        canUse: true,
                        use: { lab.use(candidate) },
                        remove: { lab.remove(candidate) }
                    )
                    Divider()
                }
                Text("第一次用新 LLM 會下載（Qwen3 8B 約 5 GB、14B 約 8 GB、30B-A3B 約 17 GB）。伺服器最多同時 keep 三個 LLM 喺記憶體。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    /// 參考文字改咗都會即時重新計 CER，唔使重跑。
    private func liveCER(_ result: ModelLab.RunResult) -> Double? {
        let reference = lab.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, result.error == nil, !result.text.isEmpty else { return nil }
        return CER.compute(reference: reference, hypothesis: result.text)
    }

    // MARK: Row

    private func candidateRow(
        label: String,
        isCustom: Bool,
        isDefault: Bool,
        selected: Binding<Bool>,
        result: ModelLab.RunResult?,
        showCER: Bool,
        canUse: Bool,
        use: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: selected).labelsHidden().padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(label).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    if isDefault {
                        Text("現時預設")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    if let result {
                        if result.running {
                            if !result.note.isEmpty {
                                Text(result.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            ProgressView().controlSize(.small)
                        } else {
                            if result.ms > 0 {
                                Text("\(result.ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if showCER, let cer = liveCER(result) {
                                Text(String(format: "CER %.0f%%", cer * 100))
                                    .font(.caption.monospacedDigit()).bold()
                                    .foregroundStyle(cer < 0.1 ? .green : (cer < 0.25 ? .orange : .red))
                            }
                        }
                    }
                    Button("用呢個", action: use).disabled(isDefault || !canUse)
                    if isCustom {
                        Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if let error = result?.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if let text = result?.text, !text.isEmpty {
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
