import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var ollamaTestResult = ""
    @State private var testingOllama = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("一般", systemImage: "gear") }
            recognitionTab.tabItem { Label("辨識", systemImage: "waveform") }
            polishTab.tabItem { Label("整理", systemImage: "wand.and.stars") }
            permissionsTab.tabItem { Label("權限", systemImage: "lock.shield") }
        }
        .frame(width: 580, height: 460)
    }

    private var generalTab: some View {
        Form {
            Section("快捷鍵") {
                Picker("快捷鍵", selection: $settings.hotkey) {
                    ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("觸發方式", selection: $settings.activation) {
                    ForEach(ActivationMode.allCases) { Text($0.label).tag($0) }
                }
                if !settings.hotkey.hint.isEmpty {
                    Text(settings.hotkey.hint).font(.caption).foregroundStyle(.secondary)
                }
                Text("錄音期間按 Esc 可以取消。").font(.caption).foregroundStyle(.secondary)
            }
            Section("回饋") {
                Toggle("顯示浮動狀態", isOn: $settings.showHUD)
                Toggle("播放提示音", isOn: $settings.playSounds)
                Toggle("貼上後還原剪貼簿原本內容", isOn: $settings.restoreClipboard)
            }
        }
        .formStyle(.grouped)
    }

    private var recognitionTab: some View {
        Form {
            Section("語音辨識引擎") {
                Picker("引擎", selection: $settings.backend) {
                    ForEach(BackendKind.allCases) { Text($0.label).tag($0) }
                }
            }
            if settings.backend == .apple {
                Section("Apple 內置語音") {
                    Picker("語言", selection: $settings.appleLocale) {
                        Text("中文（香港）— 廣東話，繁體　zh_HK").tag("zh_HK")
                        Text("粵語（中國大陸）— 廣東話，簡體　yue_CN").tag("yue_CN")
                        Text("中文（台灣）— 國語　zh_TW").tag("zh_TW")
                    }
                    LabeledContent("狀態", value: state.appleAssetStatus.isEmpty ? "—" : state.appleAssetStatus)
                    Text("完全 on-device，第一次會下載語言包（約 30 秒）。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("HTTP 伺服器") {
                    TextField("網址", text: $settings.httpURL)
                    TextField("模型名稱（可留空）", text: $settings.httpModel)
                    TextField("語言代碼", text: $settings.httpLanguage)
                    Text("任何 OpenAI 相容嘅 /v1/audio/transcriptions 都用得。跟 project 嘅 server/whisper_server.py 用 mlx-whisper，可以載入廣東話 fine-tune 模型：\n  uv run server/whisper_server.py --model mlx-community/whisper-large-v3-turbo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var polishTab: some View {
        Form {
            Section("整理模式") {
                Picker("模式", selection: $settings.polishMode) {
                    ForEach(PolishMode.allCases) { Text($0.label).tag($0) }
                }
                Text("口語：刪填充詞、加標點，保留「唔、係、嘅」。書面語：同時轉成書面中文。原文：唔經 LLM，最快。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ollama") {
                TextField("網址", text: $settings.ollamaHost)
                TextField("模型", text: $settings.ollamaModel)
                HStack {
                    Button(testingOllama ? "測試中…" : "測試連線") {
                        testingOllama = true
                        Task {
                            ollamaTestResult = await state.testOllama()
                            testingOllama = false
                        }
                    }
                    .disabled(testingOllama)
                    if let reachable = state.ollamaReachable {
                        Label(reachable ? "已連接" : "未連接", systemImage: reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(reachable ? .green : .red)
                    }
                }
                if !ollamaTestResult.isEmpty {
                    Text(ollamaTestResult).font(.caption).textSelection(.enabled)
                }
            }
            Section("常用詞彙") {
                TextEditor(text: $settings.vocabulary)
                    .font(.body)
                    .frame(minHeight: 80)
                Text("每行一個：人名、公司名、產品名。辨識到讀音相近嘅字會改用你嘅寫法。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var permissionsTab: some View {
        Form {
            Section {
                permissionRow(
                    title: "輔助使用（Accessibility）",
                    detail: "監聽全局快捷鍵同模擬 ⌘V 貼上都需要。",
                    granted: state.accessibilityGranted
                ) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                permissionRow(
                    title: "麥克風",
                    detail: "錄低你講嘅話。",
                    granted: state.microphoneGranted
                ) {
                    Permissions.openMicrophoneSettings()
                }
                LabeledContent("快捷鍵監聽", value: state.hotkeyArmed ? "運作中" : "未啟動")
            }
            Section {
                Text("授權後如果快捷鍵仍然冇反應，先結束再重開 CantoType。每次 rebuild 都用同一個 Apple Development 證書簽名，權限先會保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshPermissions() }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("前往設定…", action: action)
            }
        }
        .padding(.vertical, 2)
    }
}
