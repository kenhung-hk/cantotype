import Foundation

enum PolishError: LocalizedError {
    case badHost
    case empty
    case incomplete
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badHost: return "Ollama 網址無效"
        case .empty: return "LLM 冇回應內容"
        case .incomplete: return "Ollama 回應中途斬斷"
        case .server(let code, let body): return "Ollama 回應 \(code)：\(body.prefix(160))"
        }
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
        timeout: TimeInterval = 60
    ) async throws -> String {
        var options: [String: Any] = ["temperature": temperature, "num_predict": 2048]
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
    var host: String
    var model: String
    /// 主模型回應斬斷時用嘅備用模型；留空就直接用原文。
    var fallbackModel: String

    static let cliDefault = PolishConfig(host: "http://127.0.0.1:11434", model: "qwen3:14b", fallbackModel: "qwen2.5vl:7b")
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
        guard let hostURL = URL(string: config.host) else { throw PolishError.badHost }
        let client = OllamaClient(host: hostURL)
        let input = InputNormalizer.prepare(raw)
        let messages: [OllamaClient.Message] = [
            .init(role: "system", content: Prompts.system(mode: mode, vocabulary: vocabulary)),
            .init(role: "user", content: input),
        ]

        // 1) 主模型；2) 斬斷就換個 seed／溫度再試；3) 仍然斬斷就用備用模型
        var attempts: [() async throws -> String] = [
            { try await client.chat(model: config.model, messages: messages) },
            { try await client.chat(model: config.model, messages: messages, temperature: 0.6, seed: 7) },
        ]
        let fallback = config.fallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallback.isEmpty, fallback != config.model {
            attempts.append { try await client.chat(model: fallback, messages: messages) }
        }

        var reply = ""
        var lastError: Error = PolishError.incomplete
        for attempt in attempts {
            do {
                reply = try await attempt()
                lastError = PolishError.empty
                break
            } catch PolishError.incomplete {
                lastError = PolishError.incomplete
                continue
            }
        }
        if reply.isEmpty, case PolishError.incomplete = lastError { throw PolishError.incomplete }

        let cleaned = Self.sanitize(reply)
        guard !cleaned.isEmpty else { throw PolishError.empty }
        // 防止 LLM 亂加內容：長過原文太多就當失敗，用原文
        if cleaned.count > input.count * 3 + 40 { return raw }
        return cleaned
    }

    func warmUp(config: PolishConfig) async -> Bool {
        guard let hostURL = URL(string: config.host) else { return false }
        let client = OllamaClient(host: hostURL)
        guard await client.isReachable() else { return false }
        await client.preload(model: config.model)
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
    static func system(mode: PolishMode, vocabulary: [String]) -> String {
        var lines: [String] = []
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
                "",
                "規則：",
                "1. 保留廣東話口語用字（唔、係、嘅、咩、喺、佢、點解、我哋），唔要轉做書面語。",
            ]
        }
        lines += [
            "2. 刪除口頭填充詞（呃、嗯、啊、即係、咁、然後、就係、hmm、like 等），保留有實際意思嘅字。",
            "3. 加上正確嘅中文標點（，。？！、「」），英文詞語保留英文原樣。",
            "4. 修正明顯嘅同音錯字或辨識錯誤，但唔要改變原意；唔確定就保留原文。",
            "5. 唔要回答內容、唔要補充、唔要解釋、唔要加標題；就算原文係一個問題，都唔要答，只係整理佢。",
            "6. 如果用戶講「新一行」、「另起一段」、「換行」，用換行代替呢幾個字。",
            "7. 只輸出整理後嘅文字，唔要有任何前言後語。",
        ]
        if !vocabulary.isEmpty {
            lines.append("")
            lines.append("以下係用戶常用嘅專有名詞或寫法。如果辨識結果有讀音相近但寫法唔同嘅字詞，請改用呢啲寫法：" + vocabulary.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}
