import AVFoundation
import Foundation
import Speech

/// macOS 26 嘅 SpeechAnalyzer／SpeechTranscriber，完全 on-device。
/// 支援 zh_HK（中文（香港），出繁體）同 yue_CN（粵語，出簡體）。
final class AppleSpeechBackend: TranscriptionBackend {
    let locale: Locale
    /// 詞彙表（人名、技術用語）：Apple 語音會偏向呢啲寫法。
    var contextualStrings: [String] = []
    private var assetsReady = false

    init(localeIdentifier: String) {
        locale = Locale(identifier: localeIdentifier)
    }

    var displayName: String { "Apple 語音（\(locale.identifier)）" }

    func prepare() async throws {
        try await prepare(progress: nil)
    }

    func prepare(progress: ((String) -> Void)?) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.backendUnavailable("此 Mac 唔支援 SpeechTranscriber")
        }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw TranscriptionError.backendUnavailable("Apple 語音唔支援 \(locale.identifier)")
        }
        let transcriber = makeTranscriber()
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress?("下載語言包 \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        assetsReady = true
    }

    func transcribe(_ clip: AudioClip) async throws -> String {
        if !assetsReady {
            try await prepare()
        }
        guard clip.duration > 0.1, let source = clip.pcmBuffer() else {
            throw TranscriptionError.emptyAudio
        }

        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(200))
            try? await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? AudioClip.format
        let input = try AudioConvert.convert(source, to: format)

        let collector = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts.joined()
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()

        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }
}
