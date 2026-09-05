import Foundation

/// 命令列模式：`CantoType --transcribe file.wav [--locale zh_HK] [--backend apple|http] [--mode raw|colloquial|written]`
/// 用來比較唔同模型／語言喺你自己錄音上嘅表現，唔需要撳快捷鍵。
enum CLIRunner {
    static let usage = """
    用法：
      CantoType --transcribe <音檔> [選項]
      CantoType --polish "<文字>" [--mode colloquial|written] [--model qwen3:14b]

    選項：
      --backend apple|http      辨識引擎（預設 apple）
      --locale zh_HK|yue_CN     Apple 語音語言（預設 zh_HK）
      --url <網址>               HTTP 引擎網址（預設 http://127.0.0.1:8787/v1/audio/transcriptions）
      --language yue            HTTP 引擎語言代碼（預設 yue）
      --http-model <名稱>        HTTP 引擎模型名稱（可省略）
      --mode raw|colloquial|written   LLM 整理模式（預設 raw，即唔整理）
      --llm mlx|ollama          LLM 提供者（預設 mlx，即 CantoType 嘅 MLX 伺服器）
      --llm-url <網址>           MLX 伺服器 base URL（預設 http://127.0.0.1:8787）
      --model <名稱>             LLM 模型（MLX 預設 mlx-community/Qwen3-14B-4bit；Ollama 預設 qwen3:14b）
      --ollama <網址>            Ollama 網址（預設 http://127.0.0.1:11434）
      --fallback-model <名稱>    Ollama 主模型回應斬斷時用嘅備用模型（預設 qwen2.5vl:7b）

    例：
      CantoType --transcribe ~/Desktop/test.wav --mode colloquial
      CantoType --transcribe ~/Desktop/test.wav --locale yue_CN
      CantoType --transcribe ~/Desktop/test.wav --backend http --language yue
    """

    static func shouldRun(_ args: [String]) -> Bool {
        args.contains("--transcribe") || args.contains("--polish") || args.contains("--help") || args.contains("-h")
    }

    static func run(_ args: [String]) {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(0)
        }
        Task {
            let code = await execute(args)
            exit(code)
        }
        RunLoop.main.run()
    }

    private static func value(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func execute(_ args: [String]) async -> Int32 {
        if let text = value("--polish", in: args) {
            return await polishOnly(text, args: args)
        }
        guard let path = value("--transcribe", in: args) else {
            print(usage)
            return 2
        }
        let localeId = value("--locale", in: args) ?? "zh_HK"
        let backendName = value("--backend", in: args) ?? "apple"
        let mode = PolishMode(rawValue: value("--mode", in: args) ?? "raw") ?? .raw
        let config = polishConfig(from: args)
        let httpURL = value("--url", in: args) ?? "http://127.0.0.1:8787/v1/audio/transcriptions"

        do {
            let clip = try AudioClip.load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            let backend: any TranscriptionBackend
            switch backendName {
            case "http":
                guard let url = URL(string: httpURL) else {
                    print("錯誤：HTTP 網址無效")
                    return 2
                }
                backend = HTTPTranscriptionBackend(
                    url: url,
                    model: value("--http-model", in: args) ?? "",
                    language: value("--language", in: args) ?? "yue"
                )
            default:
                let apple = AppleSpeechBackend(localeIdentifier: localeId)
                try await apple.prepare { print("  \($0)") }
                backend = apple
            }

            print("音檔：\(path)（\(String(format: "%.1f", clip.duration)) 秒）")
            print("辨識：\(backend.displayName)")

            let t0 = Date()
            let stats = clip.stats
            let prepared = clip.normalized()
            print("音量：峰值 \(Int(stats.peakDb)) dB，RMS \(Int(stats.rmsDb)) dB" + (prepared.stats.peakDb != stats.peakDb ? "，已增益到 \(Int(prepared.stats.peakDb)) dB" : ""))
            let raw = TranscriptCleaner.normalize(try await backend.transcribe(prepared))
            print("原文（\(elapsed(since: t0))）：\(raw)")

            if mode != .raw {
                let t1 = Date()
                let polished = try await TextPolisher().polish(raw, mode: mode, vocabulary: [], config: config)
                print("整理〔\(mode.label)〕（\(elapsed(since: t1))）：\(polished)")
            }
            return 0
        } catch {
            print("錯誤：\(error.localizedDescription)")
            return 1
        }
    }

    private static func polishOnly(_ text: String, args: [String]) async -> Int32 {
        let mode = PolishMode(rawValue: value("--mode", in: args) ?? "colloquial") ?? .colloquial
        let config = polishConfig(from: args)
        print("原文：\(text)")
        let started = Date()
        do {
            let polished = try await TextPolisher().polish(text, mode: mode, vocabulary: [], config: config)
            print("整理〔\(mode.label)〕（\(elapsed(since: started))）：\(polished)")
            return 0
        } catch {
            print("錯誤：\(error.localizedDescription)")
            return 1
        }
    }

    private static func polishConfig(from args: [String]) -> PolishConfig {
        var config = PolishConfig.cliDefault
        if let provider = value("--llm", in: args).flatMap(LLMProvider.init(rawValue:)) { config.provider = provider }
        if let url = value("--llm-url", in: args) { config.mlxBaseURL = url }
        if let model = value("--model", in: args) {
            if config.provider == .mlx { config.mlxModel = model } else { config.ollamaModel = model }
        }
        if let host = value("--ollama", in: args) { config.ollamaHost = host }
        if let fallback = value("--fallback-model", in: args) { config.ollamaFallbackModel = fallback }
        return config
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(date) * 1000)
    }
}
