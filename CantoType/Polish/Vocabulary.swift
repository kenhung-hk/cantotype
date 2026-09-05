import Foundation

/// 講者背景同詞彙，同時餵俾 Whisper（initial prompt）、Apple 語音（contextual strings）同 LLM（system prompt）。
///
/// 實測（2026-09）：Whisper prompt 一放詞彙清單就會令輸出變空白，連十幾個詞都會；
/// 寫成一句自然嘅描述句先有效。LLM 亦係：幾百個詞嘅清單會令佢亂改，一條清晰嘅修正規則加例子最有效。
enum SpeakerContext {
    static let defaultDescription = "香港嘅 full stack developer，日常講廣東話夾雜英文技術用語（GitHub、API、Kubernetes、SQL、deploy 等），會提到公司同 project 名。"

    /// Whisper prompt 入面順帶提及嘅幾個英文詞，幫佢定返正確拼法同大小寫。
    static let techAnchors = ["GitHub", "pull request", "API", "SQL", "PostgreSQL", "Kubernetes", "Docker", "deploy", "CI pipeline", "Python", "TypeScript", "iOS", "JSON", "Redis"]
}

enum VocabularyProvider {
    /// Whisper initial prompt：一句短嘅自然廣東話，唔要清單、唔要太長（實測長句會出亂碼）。
    static func whisperPrompt(user: [String], context: String, techCorrection: Bool) -> String {
        // 講者：取背景第一句（到第一個標點），最多 24 字
        var role = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = role.firstIndex(where: { "，,。；;（(".contains($0) }) {
            role = String(role[..<cut])
        }
        role = String(role.prefix(24)).trimmingCharacters(in: .whitespaces)

        var mentions = Array(user.prefix(6))
        if techCorrection {
            var seen = Set(mentions.map { $0.lowercased() })
            for term in SpeakerContext.techAnchors where mentions.count < 8 {
                if seen.insert(term.lowercased()).inserted { mentions.append(term) }
            }
        }

        var sentence = role.isEmpty ? "以下係一段廣東話口語" : "以下係一位\(role) 講嘅廣東話"
        if !mentions.isEmpty {
            sentence += "，會提到 \(mentions.joined(separator: "、")) 呢啲英文詞"
        }
        sentence += "，用繁體中文記錄。"
        return sentence
    }

    /// Apple 語音 contextual strings：用戶詞彙 + 技術詞。
    static func contextualStrings(user: [String], techCorrection: Bool) -> [String] {
        var seen = Set<String>()
        return (user + (techCorrection ? SpeakerContext.techAnchors : [])).filter { seen.insert($0.lowercased()).inserted }
    }
}
