import AppIntents
import Foundation

/// Action Button／Shortcut 主流程：開 CantoType 畫面即刻錄音，講完停 1.3 秒自動送去 Mac，
/// 然後自動開返你原本嘅 app（鍵盤記低嘅 host app），鍵盤即刻插入。
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "CantoType 錄音"
    static var description = IntentDescription("開 CantoType 錄廣東話，講完自動送去 Mac 整理並返回原本 app，CantoType 鍵盤會即刻插入文字。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DebugLog.log("intent", "StartDictationIntent.perform (open app)")
        for _ in 0..<20 {
            if let model = DictationModel.shared {
                model.startFromKeyboard()
                return .result()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return .result()
    }
}

/// 實驗：唔開 app 喺背景錄（要 app 開過一次、背景常駐）。開唔到麥克風會喺 log 寫明。
struct BackgroundDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "CantoType 背景錄音（測試）"
    static var description = IntentDescription("唔跳 app，直接喺背景錄；iOS 唔一定容許。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        DebugLog.log("intent", "BackgroundDictationIntent.perform")
        let message = BackgroundDictation.shared.toggle()
        DebugLog.log("intent", message)
        return .result()
    }
}

struct CantoTypeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["用 \(.applicationName) 錄音", "Start \(.applicationName) dictation"],
            shortTitle: "錄音",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: BackgroundDictationIntent(),
            phrases: ["\(.applicationName) 背景錄音"],
            shortTitle: "背景錄音（測試）",
            systemImageName: "mic.badge.plus"
        )
    }
}
