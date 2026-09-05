import SwiftUI

@main
struct CantoTypeMobileApp: App {
    @StateObject private var model = DictationModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    DebugLog.log("app", "onOpenURL \(url.absoluteString)")
                    // cantotype://record — 鍵盤叫 app 開錄音
                    if url.host == "record" || url.path.contains("record") {
                        model.startFromKeyboard()
                    }
                }
        }
    }
}
