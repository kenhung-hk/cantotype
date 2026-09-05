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
    @Published var recordInApp: Bool { didSet { config.recordInApp = recordInApp } }
    @Published var autoStop: Bool { didSet { config.autoStop = autoStop } }

    private var speechStarted = false
    private var lastLoudAt = Date()
    private var recordStartedAt = Date()
    private var silenceTimer: Timer?

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
        recordInApp = config.recordInApp
        autoStop = config.autoStop
        DictationModel.shared = self
        capture.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.level = value
                if value > 0.36 {
                    self.speechStarted = true
                    self.lastLoudAt = Date()
                }
            }
        }
    }

    /// 由鍵盤跳過嚟：即刻開始錄；靜音自動停；完成後將文字交返鍵盤並彈返上一個 app。
    static weak var shared: DictationModel?

    func startFromKeyboard() {
        config.markAppOpened()
        DebugLog.log("app", "startFromKeyboard (phase=\(phase.label))")
        cameFromKeyboard = true
        if phase != .recording { toggleRecording() }
    }

    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        speechStarted = false
        recordStartedAt = Date()
        lastLoudAt = Date()
        guard cameFromKeyboard, autoStop else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.capture.isRecording else { return }
                let now = Date()
                let quietFor = now.timeIntervalSince(self.lastLoudAt)
                let total = now.timeIntervalSince(self.recordStartedAt)
                // 講過嘢之後靜 1.3 秒就停；一直冇聲 8 秒都停
                if (self.speechStarted && quietFor > 1.3 && total > 0.8) || (!self.speechStarted && total > 8) {
                    self.toggleRecording()
                }
            }
        }
    }

    /// 返去叫我哋出嚟嘅 app（例如 Notes）。用 UIApplication 嘅 suspend，個人 app 用冇問題。
    private func returnToPreviousApp() {
        cameFromKeyboard = false
        DebugLog.log("app", "suspending to return to previous app")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        }
    }

    func toggleRecording() {
        if capture.isRecording {
            silenceTimer?.invalidate()
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
                    DebugLog.log("app", "recording started (fromKeyboard=\(cameFromKeyboard) autoStop=\(autoStop))")
                    startSilenceWatch()
                } catch {
                    DebugLog.log("app", "recording failed: \(error.localizedDescription)")
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    private func send(_ wav: Data) async {
        phase = .sending
        do {
            let result = try await CantoTypeClient(config: config).dictate(wav: wav, mode: mode)
            DebugLog.log("app", "dictate ok raw=\(result.raw.prefix(40)) text=\(result.text.prefix(40)) fromKeyboard=\(cameFromKeyboard)")
            rawText = result.raw
            text = result.text
            timing = "辨識 \(result.asr_ms) ms · 整理 \(result.llm_ms) ms" + ((result.note?.isEmpty ?? true) ? "" : " · \(result.note!)")
            if text.isEmpty {
                phase = .error("聽唔到內容，試下大聲啲")
            } else {
                UIPasteboard.general.string = text
                phase = .done
                if cameFromKeyboard {
                    // 交返鍵盤自動插入，然後彈返上一個 app
                    config.storePendingInsert(text)
                    timing += " · 已交返鍵盤：返去原本 app 撳入文字框就會自動插入（或者按鍵盤頂「貼上次」）"
                    returnToPreviousApp()
                }
            }
        } catch {
            DebugLog.log("app", "dictate failed: \(error.localizedDescription)")
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
