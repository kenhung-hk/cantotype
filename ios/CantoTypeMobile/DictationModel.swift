import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class DictationModel: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, sending, rephrasing, done, error(String)

        var label: String {
            switch self {
            case .idle: return "按一下開始錄音"
            case .recording: return "錄音中…再按一下停止"
            case .sending: return "傳去 Mac 辨識＋整理…"
            case .rephrasing: return "Gemma 改寫中…"
            case .done: return "完成，已可複製"
            case .error(let message): return message
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var rawText = ""
    @Published var text = ""
    @Published var timing = ""
    @Published var connection = ""
    @Published var cameFromKeyboard = false

    // 設定（App Group）
    @Published var serverURL: String { didSet { config.serverURL = serverURL } }
    @Published var token: String { didSet { config.token = token } }
    @Published var mode: String { didSet { config.mode = mode } }
    @Published var dictateModel: String { didSet { config.dictateModel = dictateModel } }
    @Published var rephraseModel: String { didSet { config.rephraseModel = rephraseModel } }
    @Published var vocabulary: String { didSet { config.vocabulary = vocabulary } }

    let config = RemoteConfig.shared
    private let capture = AudioCapture()

    init() {
        serverURL = config.serverURL
        token = config.token
        mode = config.mode
        dictateModel = config.dictateModel
        rephraseModel = config.rephraseModel
        vocabulary = config.vocabulary
        capture.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
    }

    func startFromKeyboard() {
        cameFromKeyboard = true
        if phase != .recording { toggleRecording() }
    }

    func toggleRecording() {
        if capture.isRecording {
            let clip = capture.stop()
            level = 0
            guard clip.seconds >= 0.4 else {
                phase = .idle
                return
            }
            Task { await send(clip.wav) }
        } else {
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else {
                    phase = .error("未授權麥克風：去 iOS 設定 → CantoType 開返")
                    return
                }
                do {
                    try capture.start()
                    phase = .recording
                } catch {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    private func send(_ wav: Data) async {
        phase = .sending
        do {
            let result = try await CantoTypeClient(config: config).dictate(wav: wav, mode: mode)
            rawText = result.raw
            text = result.text
            timing = "辨識 \(result.asr_ms) ms · 整理 \(result.llm_ms) ms" + ((result.note?.isEmpty ?? true) ? "" : " · \(result.note!)")
            if text.isEmpty {
                phase = .error("聽唔到內容，試下大聲啲")
            } else {
                UIPasteboard.general.string = text
                phase = .done
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func rephrase() {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        phase = .rephrasing
        Task {
            do {
                let started = Date()
                let result = try await CantoTypeClient(config: config).polish(text: source, mode: "rephrase", model: rephraseModel)
                text = result
                UIPasteboard.general.string = result
                timing = "改寫 \(Int(Date().timeIntervalSince(started) * 1000)) ms（\(rephraseModel.split(separator: "/").last ?? "")）"
                phase = .done
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func copy() {
        UIPasteboard.general.string = text
    }

    func clear() {
        text = ""
        rawText = ""
        timing = ""
        phase = .idle
    }

    func testConnection() {
        connection = "連接中…"
        Task {
            do {
                let health = try await CantoTypeClient(config: config).health()
                let llm = health.llm.ready ? "LLM 就緒" : "LLM 載入中"
                let tokenNote = (health.token_required ?? false) && token.isEmpty ? "（伺服器要 token，你未填）" : ""
                connection = "已連接 · \(health.model.split(separator: "/").last ?? "") · \(llm)\(tokenNote)"
            } catch {
                connection = "連接失敗：\(error.localizedDescription)"
            }
        }
    }

    func applyQR(_ payload: String) -> Bool {
        guard config.apply(qrPayload: payload) else { return false }
        serverURL = config.serverURL
        token = config.token
        testConnection()
        return true
    }
}
