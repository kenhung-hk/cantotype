import Foundation

enum TranscriptionError: LocalizedError {
    case emptyAudio
    case tooQuiet(peakDb: Float)
    case noResult(peakDb: Float)
    case backendUnavailable(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio: return "冇錄到聲音"
        case .tooQuiet(let peak):
            return "冇錄到聲音（峰值 \(Int(peak)) dB）。檢查下麥克風揀對未、系統輸入音量夠唔夠。"
        case .noResult(let peak):
            if peak < -25 {
                return "聽唔到內容（錄音峰值 \(Int(peak)) dB，聲太細）。試下靠近麥克風或者大聲啲。"
            }
            return "聽唔到內容"
        case .backendUnavailable(let reason): return reason
        case .server(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "伺服器回應 \(code)" + (trimmed.isEmpty ? "" : "：\(trimmed.prefix(120))")
        }
    }
}

protocol TranscriptionBackend: AnyObject {
    var displayName: String { get }
    /// 下載模型／語言包等一次性準備。
    func prepare() async throws
    func transcribe(_ clip: AudioClip) async throws -> String
}

/// 對辨識結果做最基本嘅整理（唔經 LLM 都會做）。
enum TranscriptCleaner {
    static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 中文標點前後唔要空格
        result = result.replacingOccurrences(of: "\\s+(?=[，。？！、；：」』）])", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<=[，。？！、；：「『（])\\s+", with: "", options: .regularExpression)
        // 兩個漢字之間唔要空格
        result = result.replacingOccurrences(of: "(?<=\\p{Han})\\s+(?=\\p{Han})", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return result
    }
}
