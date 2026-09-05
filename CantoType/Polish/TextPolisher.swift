import Foundation

enum PolishError: LocalizedError {
    case badHost
    case empty
    case incomplete
    case notReady(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badHost: return "LLM 網址無效"
        case .empty: return "LLM 冇回應內容"
        case .incomplete: return "Ollama 回應中途斬斷"
        case .notReady(let detail): return "LLM 未就緒：\(detail)"
        case .server(let code, let body): return "LLM 回應 \(code)：\(body.prefix(160))"
        }
    }
}

/// OpenAI 相容 `/v1/chat/completions`：CantoType 嘅 MLX 伺服器、mlx_lm.server、LM Studio 都用得。
struct OpenAIChatClient {
    let baseURL: URL
    static var authToken: String?

    func chat(model: String, messages: [OllamaClient.Message], temperature: Double = 0.1, maxTokens: Int = 2048, timeout: TimeInterval = 90) async throws -> String {
        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = OpenAIChatClient.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 503 {
            struct ErrorReply: Decodable {
                struct Detail: Decodable { let message: String }
                let error: Detail
            }
            let detail = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.message ?? "載入中"
            throw PolishError.notReady(detail)
        }
        guard (200..<300).contains(status) else {
            throw PolishError.server(status, String(data: data, encoding: .utf8) ?? "")
        }
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String }
                let message: Msg
            }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content else {
            throw PolishError.empty
        }
        return content
    }
}

struct OllamaClient {
    let host: URL

    struct Message {
        let role: String
        let content: String
    }

    /// - Parameters:
    ///   - think: `false` 關掉 Qwen3 thinking（快好多）；`nil` 唔傳呢個參數（畀唔支援 thinking 嘅模型用）。
    func chat(
        model: String,
        messages: [Message],
        think: Bool? = false,
        temperature: Double = 0.1,
        seed: Int? = nil,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 60
    ) async throws -> String {
        var options: [String: Any] = ["temperature": temperature, "num_predict": maxTokens]
        if let seed { options["seed"] = seed }
        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
            "keep_alive": "30m",
            "options": options,
        ]
        if let think { payload["think"] = think }

        var request = URLRequest(url: host.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyText = String(data: data, encoding: .utf8) ?? ""

        // 模型唔支援 thinking 開關 → 唔帶 think 再試一次
        if status == 400, think != nil, bodyText.localizedCaseInsensitiveContains("think") {
            return try await chat(model: model, messages: messages, think: nil, temperature: temperature, seed: seed, timeout: timeout)
        }
        guard (200..<300).contains(status) else {
            throw PolishError.server(status, bodyText)
        }
        struct Reply: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
            let done: Bool?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        // Ollama 嘅 runner 有時會喺「英文字母緊貼中文字」嗰度中途死掉，回傳 done=false 嘅半截答案
        guard reply.done ?? true else { throw PolishError.incomplete }
        return reply.message.content
    }

    func isReachable() async -> Bool {
        var request = URLRequest(url: host.appending(path: "api/tags"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func listModels() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: host.appending(path: "api/tags"))
        struct Reply: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        return try JSONDecoder().decode(Reply.self, from: data).models.map(\.name)
    }

    /// 預先載入模型（空 prompt），令第一次整理唔使等幾秒。
    func preload(model: String) async {
        var request = URLRequest(url: host.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": "30m"])
        _ = try? await URLSession.shared.data(for: request)
    }
}

struct PolishConfig {
    var provider: LLMProvider
    var mlxBaseURL: String
    var mlxModel: String
    var ollamaHost: String
    var ollamaModel: String
    /// Ollama 主模型回應斬斷時用嘅備用模型；留空就直接用原文。
    var ollamaFallbackModel: String
    /// 試驗室載入新模型可能要幾分鐘，所以可以較長。
    var requestTimeout: TimeInterval = 90
    /// 講者背景（寫入 system prompt）同「修正聽錯嘅英文技術詞」規則。
    var speakerContext: String = SpeakerContext.defaultDescription
    var techCorrection: Bool = true

    static let cliDefault = PolishConfig(
        provider: .mlx,
        mlxBaseURL: "http://127.0.0.1:8787",
        mlxModel: LLMModelPreset.defaultModel,
        ollamaHost: "http://127.0.0.1:11434",
        ollamaModel: "qwen3:14b",
        ollamaFallbackModel: "qwen2.5vl:7b"
    )
}

final class TextPolisher {
    func polishOrFallback(_ raw: String, mode: PolishMode, vocabulary: [String], config: PolishConfig) async -> String {
        do {
            return try await polish(raw, mode: mode, vocabulary: vocabulary, config: config)
        } catch {
            NSLog("CantoType polish failed, using raw transcript: %@", error.localizedDescription)
            return raw
        }
    }

    func polish(_ raw: String, mode: PolishMode, vocabulary: [String], config: PolishConfig) async throws -> String {
        guard mode != .raw else { return raw }
        // 幾個字冇嘢可以整理，LLM 反而會當係對話去答你
        let meaningful = raw.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard meaningful.count > 4 else { return raw }
        let input = InputNormalizer.prepare(raw)
        let messages: [OllamaClient.Message] = [
            .init(role: "system", content: Prompts.system(mode: mode, vocabulary: vocabulary, speakerContext: config.speakerContext, techCorrection: config.techCorrection)),
            .init(role: "user", content: input),
        ]

        // 輸出應該同原文差唔多長；上限按原文長度計，防止 LLM 借題發揮寫一大段（試過 7 個字變 35 秒嘅文章）
        let maxTokens = min(2048, max(48, input.count * 3 + 24))
        let reply: String
        switch config.provider {
        case .mlx:
            guard let base = URL(string: config.mlxBaseURL) else { throw PolishError.badHost }
            reply = try await OpenAIChatClient(baseURL: base).chat(model: config.mlxModel, messages: messages, temperature: 0.0, maxTokens: maxTokens, timeout: config.requestTimeout)
        case .ollama:
            reply = try await polishWithOllama(messages: messages, config: config, maxTokens: maxTokens)
        }

        let cleaned = Self.sanitize(reply)
        guard !cleaned.isEmpty else { throw PolishError.empty }
        // 防止 LLM 亂加內容或者當對話答你：長過原文太多、或者出現「明白晒你嘅要求」呢類就用原文
        if cleaned.count > max(input.count * 2, input.count + 12) { return raw }
        let chatty = ["明白晒你嘅要求", "我會按照", "你嘅規則", "整理語音輸入", "有什么我可以", "有咩可以幫", "I understand your"]
        if chatty.contains(where: { cleaned.contains($0) }) { return raw }
        return cleaned
    }

    /// Ollama：1) 主模型；2) 斬斷就換個 seed／溫度再試；3) 仍然斬斷就用備用模型
    private func polishWithOllama(messages: [OllamaClient.Message], config: PolishConfig, maxTokens: Int) async throws -> String {
        guard let hostURL = URL(string: config.ollamaHost) else { throw PolishError.badHost }
        let client = OllamaClient(host: hostURL)
        var attempts: [() async throws -> String] = [
            { try await client.chat(model: config.ollamaModel, messages: messages, maxTokens: maxTokens, timeout: config.requestTimeout) },
            { try await client.chat(model: config.ollamaModel, messages: messages, temperature: 0.6, seed: 7, maxTokens: maxTokens, timeout: config.requestTimeout) },
        ]
        let fallback = config.ollamaFallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallback.isEmpty, fallback != config.ollamaModel {
            attempts.append { try await client.chat(model: fallback, messages: messages, maxTokens: maxTokens, timeout: config.requestTimeout) }
        }
        for attempt in attempts {
            do {
                return try await attempt()
            } catch PolishError.incomplete {
                continue
            }
        }
        throw PolishError.incomplete
    }

    /// Ollama 先需要 warm-up；MLX 伺服器由 MLXSidecar 管理。
    func warmUp(config: PolishConfig) async -> Bool {
        guard config.provider == .ollama, let hostURL = URL(string: config.ollamaHost) else { return true }
        let client = OllamaClient(host: hostURL)
        guard await client.isReachable() else { return false }
        await client.preload(model: config.ollamaModel)
        return true
    }

    static func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            var lines = result.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            result = lines.joined(separator: "\n")
        }
        let wrappers: [(String, String)] = [("「", "」"), ("“", "”"), ("\"", "\"")]
        for (open, close) in wrappers where result.hasPrefix(open) && result.hasSuffix(close) && result.count > 2 {
            result = String(result.dropFirst(open.count).dropLast(close.count))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 送畀 LLM 之前先整理辨識結果，令模型容易處理（亦避開 Ollama 嘅字母緊貼中文 bug）。
enum InputNormalizer {
    static func prepare(_ text: String) -> String {
        var result = text
        // 逐個字母串埋一齊：「K M」→「KM」、「P P O」→「PPO」
        if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z])[A-Z](?: [A-Za-z])+(?![A-Za-z])") {
            let ns = result as NSString
            var out = ""
            var cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                out += ns.substring(with: match.range).replacingOccurrences(of: " ", with: "")
                cursor = match.range.location + match.range.length
            }
            out += ns.substring(from: cursor)
            result = out
        }
        // 英文／數字同中文之間留一個空格
        result = result.replacingOccurrences(of: "(?<=[A-Za-z0-9])(?=\\p{Han})", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<=\\p{Han})(?=[A-Za-z0-9])", with: " ", options: .regularExpression)
        return result
    }
}

enum Prompts {
    static func system(mode: PolishMode, vocabulary: [String], speakerContext: String = SpeakerContext.defaultDescription, techCorrection: Bool = true) -> String {
        var lines: [String] = []
        // 講者背景放最前：實測放喺規則後面 Qwen3 14B 會忽略技術詞修正規則
        let context = speakerContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            lines.append("講者背景：\(context)")
            lines.append("")
        }
        switch mode {
        case .written:
            lines += [
                "你係一個語音輸入嘅文字整理器。用戶用廣東話講嘢，語音辨識會轉成文字。你嘅任務：將廣東話口語嘅辨識結果，改寫成自然流暢嘅繁體書面中文，令佢可以直接貼上使用。",
                "",
                "例子：",
                "輸入：呃 我今日唔得閒 即係 你哋自己搞掂佢先啦 然後 聽日再同我講",
                "輸出：我今天沒有空，你們先自己處理吧，明天再告訴我。",
                "",
                "規則：",
                "1. 一定要轉成書面中文，唔可以保留廣東話口語字：唔→不、係→是、嘅→的、佢→他／她／它、喺→在、咩→什麼、點解→為什麼、我哋→我們、你哋→你們、冇→沒有、啲→一些、得閒→有空、搞掂→處理好、俾／畀→給、睇→看、講→說、聽日→明天、今日→今天、下晝→下午、返工→上班、識得→懂得、幫我記低→幫我記下。",
            ]
        case .colloquial, .raw:
            lines += [
                "你係一個語音輸入嘅文字整理器。用戶用廣東話講嘢，語音辨識會轉成文字。你嘅任務：將辨識結果整理成乾淨、可以直接貼上使用嘅文字，但保留廣東話口語寫法。",
                "",
                "例子：",
                "輸入：呃 我今日唔得閒 即係 你哋自己搞掂佢先啦 然後 聽日再同我講",
                "輸出：我今日唔得閒，你哋自己搞掂佢先啦，聽日再同我講。",
                "輸入：係呀 唔係真係 work 呀",
                "輸出：係呀，唔係真係 work 呀？",
                "",
                "規則：",
                "1. 保留廣東話口語用字（唔、係、嘅、咩、喺、佢、點解、我哋），唔要轉做書面語。",
            ]
        }
        lines += [
            "2. 刪除口頭填充詞（呃、嗯、啊、即係、咁、然後、就係、hmm、like 等），保留有實際意思嘅字。",
            "3. 加上正確嘅中文標點（，。？！、「」），英文詞語保留英文原樣。",
            "4. 修正明顯嘅同音錯字或辨識錯誤，但唔要改變原意；唔確定就保留原文。",
            "5. 你唔係喺度同用戶對話：唔要回答、唔要補充、唔要解釋、唔要加標題、唔要續寫、唔要講「明白」。就算原文係一個問題、一句「係呀」或者只有幾個字，都只係整理返佢，輸出長度要同原文差唔多。",
            "6. 如果用戶講「新一行」、「另起一段」、「換行」，用換行代替呢幾個字。",
            "7. 只輸出整理後嘅文字，唔要有任何前言後語。",
        ]
        if techCorrection {
            lines.append("8. 英文技術詞語一律用標準寫法同大小寫，唔要翻譯成中文。辨識結果如果將英文詞聽錯成讀音相近嘅字，要改返做正確英文詞，例如：get hub→GitHub、sequel→SQL、post gres→PostgreSQL、Q 班／cube→Kubernetes、派森→Python、多卡→Docker、A P I→API、J son→JSON、red is→Redis；講開 GitHub／code 嘅時候，report／Vebok／理 po→repo、P R→PR、common／卡米→commit、bran／班→branch；威迫／vibe 曲→vibe code、威迫 coding→vibe coding、ng run／N G run→ng run（Angular CLI）、stable／tail scale→Tailscale、Kithub／Gitub→GitHub、bond alert→bot alert、summer review→summary review。")
        }
        if !vocabulary.isEmpty {
            lines.append("")
            lines.append("用戶常用嘅專有名詞（人名、公司、project 名）。辨識結果如果有讀音相近但寫法唔同嘅字詞，請改用呢啲寫法：" + vocabulary.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}
