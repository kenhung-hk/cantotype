import Foundation

struct DictateResult: Decodable {
    let raw: String
    let text: String
    let asr_ms: Int
    let llm_ms: Int
    let note: String?
}

struct ServerHealth: Decodable {
    struct LLM: Decodable {
        let model: String?
        let ready: Bool
    }
    let ok: Bool
    let model: String
    let llm: LLM
    let token_required: Bool?
}

enum ClientError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未設定 Mac 伺服器網址（開 CantoType app → 設定）"
        case .http(let code, let body):
            if code == 401 { return "Token 唔對，請重新掃 Mac 上嘅 QR" }
            if code == 503 { return "Mac 嘅 LLM 仲載入中" }
            return "伺服器回應 \(code)：\(body.prefix(120))"
        case .invalidResponse: return "伺服器回應無效"
        }
    }
}

/// 同部 Mac 上嘅 CantoType MLX 伺服器講嘢（經 Tailscale）。
struct CantoTypeClient {
    let config: RemoteConfig

    init(config: RemoteConfig = .shared) {
        self.config = config
    }

    private func request(path: String, timeout: TimeInterval) throws -> URLRequest {
        guard let base = URL(string: config.serverURL), base.host != nil else { throw ClientError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = timeout
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func health() async throws -> ServerHealth {
        let request = try request(path: "health", timeout: 8)
        return try JSONDecoder().decode(ServerHealth.self, from: try await send(request))
    }

    /// 錄音（16 kHz mono WAV）→ 辨識 + 整理，一個 request。
    func dictate(wav: Data, mode: String) async throws -> DictateResult {
        var request = try request(path: "v1/dictate", timeout: 300)
        request.httpMethod = "POST"
        let boundary = "CantoType-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("mode", mode)
        if !config.dictateModel.isEmpty { field("llm_model", config.dictateModel) }
        if !config.vocabulary.isEmpty { field("vocabulary", config.vocabulary) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return try JSONDecoder().decode(DictateResult.self, from: try await send(request))
    }

    /// 文字整理／改寫。mode: colloquial | written | rephrase
    func polish(text: String, mode: String, model: String? = nil) async throws -> String {
        var request = try request(path: "v1/polish", timeout: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["text": text, "mode": mode]
        if let model, !model.isEmpty { payload["model"] = model }
        if !config.vocabulary.isEmpty {
            payload["vocabulary"] = config.vocabulary.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" }).map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: try await send(request)).text
    }
}
