import AudioToolbox
import AVFoundation
import Foundation
import UIKit

/// Action Button／Shortcut 觸發、喺背景行嘅錄音：唔開 app 畫面，Notes 同鍵盤一直喺前面。
/// 講完靜 1.3 秒自動停 → 傳去 Mac → 放入 App Group → 鍵盤（每秒 poll）自動插入。
@MainActor
final class BackgroundDictation {
    static let shared = BackgroundDictation()

    enum State: Equatable { case idle, recording, sending }
    private(set) var state: State = .idle

    private let config = RemoteConfig.shared
    private let capture = AudioCapture(category: .playAndRecord)
    private var speechStarted = false
    private var lastLoudAt = Date()
    private var startedAt = Date()
    private var timer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        capture.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self, value > 0.36 else { return }
                self.speechStarted = true
                self.lastLoudAt = Date()
            }
        }
    }

    /// 回傳畀 Intent 顯示嘅一句話。
    func toggle() -> String {
        switch state {
        case .recording:
            stopAndSend()
            return "已停止，送去 Mac 整理中…"
        case .sending:
            return "上一段仲處理中…"
        case .idle:
            guard config.isConfigured else { return "未設定 Mac：開 CantoType app 掃 QR" }
            guard AVAudioApplication.shared.recordPermission == .granted else {
                return "請先開 CantoType app 一次，授權麥克風"
            }
            do {
                beginBackgroundTask()
                try capture.start()
            } catch {
                DebugLog.log("bg", "start failed: \(error.localizedDescription)")
                endBackgroundTask()
                return "開唔到麥克風：\(error.localizedDescription)"
            }
            state = .recording
            speechStarted = false
            startedAt = Date()
            lastLoudAt = Date()
            AudioServicesPlaySystemSound(1113) // begin_record
            DebugLog.log("bg", "recording started in background")
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return config.autoStop ? "錄音中，講完停 1.3 秒會自動送去 Mac" : "錄音中，再按一次停止"
        }
    }

    private func tick() {
        guard state == .recording else { return }
        let now = Date()
        let quiet = now.timeIntervalSince(lastLoudAt)
        let total = now.timeIntervalSince(startedAt)
        if (config.autoStop && speechStarted && quiet > 1.3 && total > 0.8) || (!speechStarted && total > 8) || total > 60 {
            stopAndSend()
        }
    }

    private func stopAndSend() {
        timer?.invalidate()
        timer = nil
        let clip = capture.stop()
        AudioServicesPlaySystemSound(1114) // end_record
        guard clip.seconds >= 0.4, speechStarted else {
            DebugLog.log("bg", "nothing recorded (\(clip.seconds)s, speech=\(speechStarted))")
            state = .idle
            endBackgroundTask()
            return
        }
        state = .sending
        Task {
            do {
                let result = try await CantoTypeClient(config: config).dictate(wav: clip.wav, mode: config.mode)
                DebugLog.log("bg", "dictate ok raw=\(result.raw.prefix(40)) text=\(result.text.prefix(40))")
                if !result.text.isEmpty {
                    config.storePendingInsert(result.text)
                    UIPasteboard.general.string = result.text
                    AudioServicesPlaySystemSound(1057) // tink：已交返鍵盤
                } else {
                    AudioServicesPlaySystemSound(1053) // 錯誤
                }
            } catch {
                DebugLog.log("bg", "dictate failed: \(error.localizedDescription)")
                AudioServicesPlaySystemSound(1053)
            }
            state = .idle
            endBackgroundTask()
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CantoType dictation") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
