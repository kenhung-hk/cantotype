import Foundation

enum PolishError: LocalizedError {
    case badHost
    case empty
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badHost: return "Ollama 網址無效"
        case .empty: return "LLM 冇回應內容"
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

    func chat(model: String, messages: [Message], think: Bool? = false, timeout: TimeInterval = 60) async throws -> String {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": 0.1, "num_predict": 1024],
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
            return try await chat(model: model, messages: messages, think: nil, timeout: timeout)
        }
        guard (200..<300).contains(status) else {
            throw PolishError.server(status, bodyText)
        }
        struct Reply: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        return try JSONDecoder().decode(Reply.self, from: data).message.content
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

final class TextPolisher {
    func polishOrFallback(_ raw: String, mode: PolishMode, vocabulary: [String], host: String, model: String) async -> String {
        do {
            return try await polish(raw, mode: mode, vocabulary: vocabulary, host: host, model: model)
        } catch {
            NSLog("CantoType polish failed, using raw transcript: %@", error.localizedDescription)
            return raw
        }
    }

    func polish(_ raw: String, mode: PolishMode, vocabulary: [String], host: String, model: String) async throws -> String {
        guard mode != .raw else { return raw }
        guard let hostURL = URL(string: host) else { throw PolishError.badHost }
        let client = OllamaClient(host: hostURL)
        let system = Prompts.system(mode: mode, vocabulary: vocabulary)
        let reply = try await client.chat(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: raw)]
        )
        let cleaned = Self.sanitize(reply)
        guard !cleaned.isEmpty else { throw PolishError.empty }
        // 防止 LLM 亂加內容：長過原文太多就當失敗，用原文
        if cleaned.count > raw.count * 3 + 40 { return raw }
        return cleaned
    }

    func warmUp(host: String, model: String) async -> Bool {
        guard let hostURL = URL(string: host) else { return false }
        let client = OllamaClient(host: hostURL)
        guard await client.isReachable() else { return false }
        await client.preload(model: model)
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
