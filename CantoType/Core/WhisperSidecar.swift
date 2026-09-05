import Foundation

/// 管理本地 MLX Whisper 伺服器（server/whisper_server.py，用 uv 執行）。
/// App 啟動時自動開，結束時自動關；伺服器亦會自己監察 app 仲喺唔喺度。
@MainActor
final class WhisperSidecar: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case ready(model: String)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "未啟動"
            case .starting: return "載入中…"
            case .ready(let model): return "就緒（\(model)）"
            case .failed(let reason): return "失敗：\(reason)"
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var recentLog: [String] = []

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var currentPort = 0
    private var currentModel = ""

    var lastLogLine: String { recentLog.last ?? "" }

    /// 確保有一個用 `model` 嘅伺服器喺 `port` 運行；已經有就唔重開。
    func ensureRunning(model: String, port: Int, language: String) {
        if process != nil, currentPort == port, currentModel == model, status != .stopped {
            if case .failed = status {} else { return }
        }
        Task { await startOrAdopt(model: model, port: port, language: language) }
    }

    func restart(model: String, port: Int, language: String) {
        stop()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await startOrAdopt(model: model, port: port, language: language)
        }
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        status = .stopped
    }

    private func startOrAdopt(model: String, port: Int, language: String) async {
        stop()
        currentPort = port
        currentModel = model

        // 已經有個伺服器（例如上次冇關到）就直接用
        if let running = await Self.health(port: port) {
            if running == model {
                status = .ready(model: model)
                return
            }
            appendLog("port \(port) 有另一個模型（\(running)）嘅伺服器，關閉再重開…")
            Self.killStray(port: port)
            try? await Task.sleep(for: .seconds(1))
        }

        guard let script = Bundle.main.url(forResource: "whisper_server", withExtension: "py") else {
            status = .failed("app bundle 入面搵唔到 whisper_server.py")
            return
        }
        guard let uv = Self.findExecutable("uv") else {
            status = .failed("搵唔到 uv，請先 brew install uv")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uv)
        proc.arguments = [
            "run", script.path,
            "--port", String(port),
            "--model", model,
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
            status = .starting
            appendLog("啟動 uv run whisper_server.py --model \(model) --port \(port)")
            startHealthPolling(port: port, model: model)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func startHealthPolling(port: Int, model: String) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                if await Self.health(port: port) != nil {
                    self?.status = .ready(model: model)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handleTermination(code: Int32) {
        healthTask?.cancel()
        process = nil
        if case .stopped = status { return }
        status = .failed("伺服器退出（code \(code)）：\(lastLogLine)")
    }

    private func appendLog(_ text: String) {
        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Warning: You are sending unauthenticated") }
        guard !lines.isEmpty else { return }
        recentLog.append(contentsOf: lines)
        if recentLog.count > 30 {
            recentLog.removeFirst(recentLog.count - 30)
        }
    }

    /// 回傳伺服器正在用嘅模型名；連唔到就 nil。
    static func health(port: Int) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["model"] as? String) ?? ""
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
        task.arguments = ["-f", "whisper_server.py.*--port \(port)"]
        try? task.run()
        task.waitUntilExit()
    }
}
