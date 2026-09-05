import Foundation

/// 任何 OpenAI 相容嘅 `/v1/audio/transcriptions` 伺服器：
/// server/whisper_server.py（mlx-whisper）、whisper.cpp server、Speaches 等。
final class HTTPTranscriptionBackend: TranscriptionBackend {
    let url: URL
    let model: String
    let language: String
    let timeout: TimeInterval
    /// Whisper initial prompt（詞彙表）；nil 就用伺服器預設。
    let prompt: String?

    init(url: URL, model: String, language: String, timeout: TimeInterval = 120, prompt: String? = nil) {
        self.url = url
        self.model = model
        self.language = language
        self.timeout = timeout
        self.prompt = prompt
    }

    var displayName: String { "HTTP（\(url.host() ?? url.absoluteString)）" }

    func prepare() async throws {}

    func transcribe(_ clip: AudioClip) async throws -> String {
        guard !clip.isEmpty else { throw TranscriptionError.emptyAudio }

        let boundary = "CantoType-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        if !model.isEmpty { field("model", model) }
        if !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        field("response_format", "json")
        body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(clip.wavData())
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.backendUnavailable("伺服器無效回應")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
    }
}

extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: Array(string.utf8))
    }
}
