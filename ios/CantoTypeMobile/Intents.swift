import AppIntents
import Foundation

/// 「CantoType 錄音」：可以設去 Action Button、Shortcut、Siri。開 app 即刻錄，講完自動送去 Mac，
/// 再自動返去原本 app，鍵盤會自動插入文字。
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "CantoType 錄音"
    static var description = IntentDescription("開始錄廣東話，講完自動送去 Mac 整理，返去原本 app 時鍵盤會自動插入。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DebugLog.log("intent", "StartDictationIntent.perform")
        // app 可能剛剛先啟動，model 未必即刻有；等一陣再試
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
    }
}
