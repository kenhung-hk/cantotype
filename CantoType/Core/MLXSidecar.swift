import Foundation

/// 管理本地 MLX 伺服器（server/mlx_server.py：Whisper 辨識 + Qwen3 整理），用 uv 執行。
/// App 啟動時自動開，結束時自動關；伺服器亦會自己監察 app 仲喺唔喺度。
@MainActor
final class MLXSidecar: ObservableObject {
    enum ProcessState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    struct Health {
        let whisperModel: String
        let llmModel: String?
        let llmReady: Bool
        let llmError: String?
    }

    @Published private(set) var state: ProcessState = .stopped
    @Published private(set) var whisperReady = false
    @Published private(set) var llmReady = false
    @Published private(set) var llmError: String?
    @Published private(set) var recentLog: [String] = []

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var wantedPort = 0
    private var wantedWhisper = ""
    private var wantedLLM = "none"
    private var wantedLanguage = "yue"
    private var launchedAt: Date?
    private var quickFailures = 0

    var lastLogLine: String { recentLog.last ?? "" }
    var isRunning: Bool { state == .starting || state == .running }

    /// 一句話總結，畀 menubar 同設定用。
    var summary: String {
        switch state {
        case .stopped: return "未啟動"
        case .failed(let reason): return "失敗：\(reason)"
        case .starting, .running:
            var parts = [whisperReady ? "Whisper 就緒" : "Whisper 載入中…"]
            if wantedLLM.lowercased() != "none" {
                if llmReady {
                    parts.append("LLM 就緒")
                } else if let llmError {
                    parts.append("LLM 失敗：\(llmError)")
                } else {
                    parts.append("LLM 載入中…")
                }
            }
            return parts.joined(separator: "，")
        }
    }

    /// 確保有一個用呢啲模型嘅伺服器喺 `port` 運行；已經係就唔重開。
    func ensureRunning(whisperModel: String, llmModel: String, port: Int, language: String) {
        let sameConfig = wantedPort == port && wantedWhisper == whisperModel && wantedLLM == llmModel
        if sameConfig, isRunning { return }
        Task { await startOrAdopt(whisperModel: whisperModel, llmModel: llmModel, port: port, language: language) }
    }

    func restart(whisperModel: String, llmModel: String, port: Int, language: String) {
        stop()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await startOrAdopt(whisperModel: whisperModel, llmModel: llmModel, port: port, language: language)
        }
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        state = .stopped
        whisperReady = false
        llmReady = false
        llmError = nil
    }

    private func startOrAdopt(whisperModel: String, llmModel: String, port: Int, language: String) async {
        stop()
        wantedPort = port
        wantedWhisper = whisperModel
        wantedLLM = llmModel
        wantedLanguage = language

        // 已經有個伺服器（例如上次冇關到）而且模型一樣就直接用
        if let running = await Self.health(port: port) {
            let llmMatches = llmModel.lowercased() == "none" ? running.llmModel == nil : running.llmModel == llmModel
            if running.whisperModel == whisperModel, llmMatches {
                state = .running
                apply(running)
                startHealthPolling(port: port)
                return
            }
            appendLog("port \(port) 有另一個設定嘅伺服器，關閉再重開…")
            Self.killStray(port: port)
            try? await Task.sleep(for: .seconds(1))
        }

        guard let script = Bundle.main.url(forResource: "mlx_server", withExtension: "py") else {
            state = .failed("app bundle 入面搵唔到 mlx_server.py")
            return
        }
        guard let uv = Self.findExecutable("uv") else {
            state = .failed("搵唔到 uv，請先 brew install uv")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uv)
        proc.arguments = [
            "run", script.path,
            "--port", String(port),
            "--model", whisperModel,
            "--llm", llmModel,
            "--language", language,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        proc.environment = environment
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text) }
        }
        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in self?.handleTermination(code: code) }
        }

        do {
            try proc.run()
            process = proc
            launchedAt = Date()
            state = .starting
            appendLog("啟動 uv run mlx_server.py --model \(whisperModel) --llm \(llmModel) --port \(port)")
            startHealthPolling(port: port)
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("CantoType MLX sidecar failed to launch: %@", error.localizedDescription)
        }
    }

    private func startHealthPolling(port: Int) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                if let health = await Self.health(port: port) {
                    guard let self else { return }
                    misses = 0
                    if self.state == .starting { self.state = .running }
                    self.apply(health)
                    // 兩樣都就緒（或者 LLM 出錯／唔需要）就唔使再 poll 咁密
                    let llmSettled = health.llmModel == nil || health.llmReady || health.llmError != nil
                    try? await Task.sleep(for: .seconds(llmSettled ? 10 : 1.5))
                } else {
                    guard let self else { return }
                    misses += 1
                    if self.state == .running, misses >= 3 {
                        // 伺服器唔見咗：自己起嘅由 terminationHandler 處理；接管返嚟嘅就重開
                        self.whisperReady = false
                        self.llmReady = false
                        if self.process == nil {
                            self.appendLog("伺服器冇回應，重新啟動…")
                            let (whisper, llm, language) = (self.wantedWhisper, self.wantedLLM, self.wantedLanguage)
                            await self.startOrAdopt(whisperModel: whisper, llmModel: llm, port: port, language: language)
                            return
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func apply(_ health: Health) {
        whisperReady = true
        llmReady = health.llmReady
        llmError = health.llmError
    }

    private func handleTermination(code: Int32) {
        healthTask?.cancel()
        process = nil
        whisperReady = false
        llmReady = false
        if case .stopped = state { return }
        state = .failed("伺服器退出（code \(code)）：\(lastLogLine)")
        NSLog("CantoType MLX sidecar exited (code %d). Last log: %@", code, recentLog.suffix(8).joined(separator: " | "))

        // 啟動後好快就死（例如 port 仲被上一個伺服器霸住）就自動重試兩次
        if let launchedAt, Date().timeIntervalSince(launchedAt) < 20, quickFailures < 2 {
            quickFailures += 1
            appendLog("啟動失敗，\(quickFailures) 次重試…")
            let (whisper, llm, port, language) = (wantedWhisper, wantedLLM, wantedPort, wantedLanguage)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.startOrAdopt(whisperModel: whisper, llmModel: llm, port: port, language: language)
            }
        } else if state != .stopped {
            quickFailures = 0
        }
    }

    private func appendLog(_ text: String) {
        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Warning: You are sending unauthenticated") }
        guard !lines.isEmpty else { return }
        recentLog.append(contentsOf: lines)
        if recentLog.count > 40 {
            recentLog.removeFirst(recentLog.count - 40)
        }
    }

    static func health(port: Int) async -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let llm = json["llm"] as? [String: Any]
        return Health(
            whisperModel: (json["model"] as? String) ?? "",
            llmModel: llm?["model"] as? String,
            llmReady: (llm?["ready"] as? Bool) ?? false,
            llmError: llm?["error"] as? String
        )
    }

    static func findExecutable(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin",
        ]
        for directory in candidates {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func killStray(port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "mlx_server.py.*--port \(port)"]
        try? task.run()
        task.waitUntilExit()
    }
}
