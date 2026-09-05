import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sidecar: MLXSidecar

    @State private var polishTestResult = ""
    @State private var testingPolish = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var defaultInputName = ""

    var body: some View {
        TabView {
            generalTab.tabItem { Label("一般", systemImage: "gear") }
            recognitionTab.tabItem { Label("辨識", systemImage: "waveform") }
            polishTab.tabItem { Label("整理", systemImage: "wand.and.stars") }
            permissionsTab.tabItem { Label("權限", systemImage: "lock.shield") }
        }
        .frame(width: 600, height: 520)
    }

    // MARK: - 一般

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
            Section("麥克風") {
                Picker("輸入裝置", selection: $settings.inputDeviceUID) {
                    Text(defaultInputName.isEmpty ? "系統預設" : "系統預設（\(defaultInputName)）").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                HStack(spacing: 12) {
                    Toggle("測試麥克風", isOn: micTestBinding)
                        .toggleStyle(.switch)
                    LevelMeter(level: state.micTesting ? state.level : 0)
                    Spacer()
                    Button("系統聲音設定…") { Permissions.openSoundSettings() }
                }
                Text("正常講嘢應該有 4 至 5 格。太細就揀另一個麥克風，或者去系統聲音設定較高輸入音量。細聲錄音 app 會自動增益（最多 +30 dB），但太細會連噪音一齊放大。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("回饋") {
                Toggle("顯示浮動狀態", isOn: $settings.showHUD)
                Toggle("播放提示音", isOn: $settings.playSounds)
                Toggle("貼上後還原剪貼簿原本內容", isOn: $settings.restoreClipboard)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshDevices)
        .onDisappear { state.setMicTest(false) }
    }

    private var micTestBinding: Binding<Bool> {
        Binding(
            get: { state.micTesting },
            set: { state.setMicTest($0) }
        )
    }

    private func refreshDevices() {
        inputDevices = AudioDevices.inputDevices()
        defaultInputName = AudioDevices.defaultInputDevice()?.name ?? ""
    }

    // MARK: - 辨識

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
                    Text("完全 on-device，零下載（語言包約 30 秒）。英文名同術語聽得比 Whisper 差。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("MLX 伺服器（Whisper）") {
                    Toggle("由 CantoType 自動啟動本地伺服器（需要 uv）", isOn: $settings.manageSidecar)
                    Picker("Whisper 模型", selection: $settings.whisperModel) {
                        ForEach(WhisperModelPreset.allCases) { Text($0.label).tag($0.rawValue) }
                        if WhisperModelPreset(rawValue: settings.whisperModel) == nil {
                            Text("自訂：\(settings.whisperModel)").tag(settings.whisperModel)
                        }
                    }
                    TextField("HuggingFace repo 或本地路徑", text: $settings.whisperModel)
                        .font(.caption.monospaced())
                    sidecarStatus
                }
                Section("進階") {
                    TextField("網址", text: $settings.httpURL)
                    TextField("語言代碼", text: $settings.httpLanguage)
                    TextField("model 欄位（大部分伺服器可留空）", text: $settings.httpModel)
                    Text("任何 OpenAI 相容嘅 /v1/audio/transcriptions 都用得。網址唔係 localhost 就唔會自動啟動伺服器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var sidecarStatus: some View {
        LabeledContent("狀態", value: sidecar.summary)
        if !sidecar.recentLog.isEmpty {
            Text(sidecar.recentLog.suffix(3).joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        HStack {
            Button("重啟伺服器") { state.restartSidecar() }
            Text("第一次用新模型要下載（Whisper 約 1.6 GB，LLM 約 8 GB），期間會顯示進度。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 整理

    private var polishTab: some View {
        Form {
            Section("整理模式") {
                Picker("模式", selection: $settings.polishMode) {
                    ForEach(PolishMode.allCases) { Text($0.label).tag($0) }
                }
                Text("口語：刪填充詞、加標點，保留「唔、係、嘅」。書面語：同時轉成書面中文。原文：唔經 LLM，最快。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("LLM") {
                Picker("提供者", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { Text($0.label).tag($0) }
                }
                if settings.llmProvider == .mlx {
                    Picker("模型", selection: $settings.llmModel) {
                        ForEach(LLMModelPreset.allCases) { Text($0.label).tag($0.rawValue) }
                        if LLMModelPreset(rawValue: settings.llmModel) == nil {
                            Text("自訂：\(settings.llmModel)").tag(settings.llmModel)
                        }
                    }
                    TextField("HuggingFace repo 或本地路徑", text: $settings.llmModel)
                        .font(.caption.monospaced())
                    if settings.sidecarPort != nil {
                        sidecarStatus
                    } else {
                        Text("MLX LLM 同 Whisper 用同一個本地伺服器；請喺「辨識」揀 MLX Whisper 並開啟自動啟動。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    TextField("Ollama 網址", text: $settings.ollamaHost)
                    TextField("模型", text: $settings.ollamaModel)
                    TextField("備用模型（主模型回應斬斷時用，可留空）", text: $settings.ollamaFallbackModel)
                    if let reachable = state.ollamaReachable {
                        Label(reachable ? "已連接" : "未連接", systemImage: reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(reachable ? .green : .red)
                    }
                }
                HStack {
                    Button(testingPolish ? "測試中…" : "測試 LLM") {
                        testingPolish = true
                        Task {
                            polishTestResult = await state.testPolish()
                            testingPolish = false
                        }
                    }
                    .disabled(testingPolish)
                }
                if !polishTestResult.isEmpty {
                    Text(polishTestResult).font(.caption).textSelection(.enabled)
                }
            }
            Section("常用詞彙") {
                TextEditor(text: $settings.vocabulary)
                    .font(.body)
                    .frame(minHeight: 70)
                Text("每行一個：人名、公司名、產品名。辨識到讀音相近嘅字會改用你嘅寫法。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 權限

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
