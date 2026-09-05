import AppIntents
import Foundation

/// 「CantoType 錄音」：可以設去 Action Button、Shortcut、Siri。開 app 即刻錄，講完自動送去 Mac，
/// 再自動返去原本 app，鍵盤會自動插入文字。
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "CantoType 錄音"
    static var description = IntentDescription("喺背景開始錄廣東話（唔會跳 app），講完自動送去 Mac 整理，CantoType 鍵盤會即刻插入文字。再按一次即刻停。")
    /// 唔開 app：Notes 同鍵盤留喺前面，錄完直接插入
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DebugLog.log("intent", "StartDictationIntent.perform (background)")
        let message = BackgroundDictation.shared.toggle()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// 舊流程：開 app 錄（想睇住畫面用）
struct OpenAndDictateIntent: AppIntent {
    static var title: LocalizedStringResource = "CantoType 開 app 錄音"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
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

struct CantoTypeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["用 \(.applicationName) 錄音", "Start \(.applicationName) dictation"],
            shortTitle: "錄音",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: OpenAndDictateIntent(),
            phrases: ["開 \(.applicationName) 錄音"],
            shortTitle: "開 app 錄音",
            systemImageName: "mic.badge.plus"
        )
    }
}
