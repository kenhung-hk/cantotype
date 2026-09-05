import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var sidecar: WhisperSidecar

    var body: some View {
        Text("狀態：\(state.phase.label)")
        if !state.lastText.isEmpty {
            Text("上次：\(truncated(state.lastText, 36))")
        }
        Divider()

        Picker("整理模式", selection: $settings.polishMode) {
            ForEach(PolishMode.allCases) { Text($0.label).tag($0) }
        }
        Picker("語音辨識", selection: $settings.backend) {
            ForEach(BackendKind.allCases) { Text($0.label).tag($0) }
        }
        Picker("快捷鍵", selection: $settings.hotkey) {
            ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0) }
        }
        Picker("觸發方式", selection: $settings.activation) {
            ForEach(ActivationMode.allCases) { Text($0.label).tag($0) }
        }
        Divider()

        if !history.items.isEmpty {
            Menu("最近輸入") {
                ForEach(history.items.prefix(8)) { item in
                    Button(truncated(item.polished, 40)) {
                        TextInserter.copy(item.polished)
                    }
                }
                Divider()
                Button("清除記錄") { history.clear() }
            }
            Divider()
        }

        if !state.accessibilityGranted {
            Button("⚠️ 未授權「輔助使用」— 按此設定…") {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
        } else if !state.hotkeyArmed {
            Button("⚠️ 快捷鍵未啟動 — 重試") { state.armHotkey() }
        }
        if !state.microphoneGranted {
            Button("⚠️ 未授權麥克風 — 按此設定…") { Permissions.openMicrophoneSettings() }
        }
        if settings.polishMode != .raw, state.ollamaReachable == false {
            Text("⚠️ 連接唔到 Ollama（\(settings.ollamaModel)），會直接貼上原文")
        }
        if settings.backend == .apple, !state.appleAssetStatus.isEmpty {
            Text("Apple 語音：\(state.appleAssetStatus)")
        }
        if settings.backend == .http, settings.sidecarPort != nil {
            Text("MLX Whisper：\(sidecar.status.label)")
            if case .starting = sidecar.status, !sidecar.lastLogLine.isEmpty {
                Text("　" + truncated(sidecar.lastLogLine, 48))
            }
            if case .failed = sidecar.status {
                Button("重啟 Whisper 伺服器") { state.restartSidecar() }
            }
        }
        Divider()

        SettingsLink { Text("設定…") }
            .keyboardShortcut(",")
        Button("結束 CantoType") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func truncated(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }
}
