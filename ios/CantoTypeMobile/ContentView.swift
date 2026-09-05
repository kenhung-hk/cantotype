import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: DictationModel
    @State private var tab = CommandLine.arguments.contains("--settings") ? 1 : 0

    var body: some View {
        if CommandLine.arguments.contains("--keyboard-preview") {
            KeyboardPreviewScreen()
        } else {
            mainTabs
        }
    }

    private var mainTabs: some View {
        TabView(selection: $tab) {
            DictateView().tabItem { Label("口述", systemImage: "mic") }.tag(0)
            SettingsScreen().tabItem { Label("設定", systemImage: "gear") }.tag(1)
        }
    }
}

struct DictateView: View {
    @EnvironmentObject var model: DictationModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("模式", selection: $model.mode) {
                    Text("口語").tag("colloquial")
                    Text("書面語").tag("written")
                    Text("原文").tag("raw")
                }
                .pickerStyle(.segmented)

                Spacer(minLength: 8)

                Button(action: model.toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(model.phase == .recording ? Color.red : Color.accentColor)
                            .frame(width: 120, height: 120)
                            .shadow(radius: 8)
                        Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.phase == .sending || model.phase == .rephrasing)

                if model.phase == .recording {
                    LevelBars(level: model.level)
                }
                if model.cameFromKeyboard, model.phase == .recording {
                    Text("由鍵盤跳過嚟：講完停 1.3 秒會自動送去 Mac，然後自動返去原本 app").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Text(model.phase.label)
                    .font(.callout)
                    .foregroundStyle(isError ? .red : .secondary)
                    .multilineTextAlignment(.center)
                if model.phase == .sending || model.phase == .rephrasing {
                    ProgressView()
                }

                GroupBox {
                    ScrollView {
                        Text(model.text.isEmpty ? "結果會喺呢度出現，並自動複製到剪貼簿。" : model.text)
                            .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    if !model.timing.isEmpty {
                        Text(model.timing).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button { model.copy() } label: { Label("複製", systemImage: "doc.on.doc") }
                        .disabled(model.text.isEmpty)
                    Button { model.rephrase() } label: { Label("Gemma 改寫", systemImage: "wand.and.stars") }
                        .disabled(model.text.isEmpty || model.phase == .rephrasing)
                    Button(role: .destructive) { model.clear() } label: { Label("清除", systemImage: "xmark") }
                        .disabled(model.text.isEmpty)
                }
                .buttonStyle(.bordered)

                if !model.config.isConfigured {
                    Text("未設定 Mac 伺服器：去「設定」掃 Mac 上嘅 QR code。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("CantoType")
        }
    }

    private var isError: Bool {
        if case .error = model.phase { return true }
        return false
    }
}

struct LevelBars: View {
    var level: Float

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(level > Float(index) / 12 ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 10 + CGFloat(index) * 2)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject var model: DictationModel
    @State private var showScanner = false
    @State private var scanMessage = ""
    @StateObject private var previewEngine = KeyboardEngine()

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac 伺服器（經 Tailscale）") {
                    TextField("http://100.x.y.z:8787", text: $model.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Token", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button {
                        showScanner = true
                    } label: {
                        Label("掃描 Mac 嘅 QR code", systemImage: "qrcode.viewfinder")
                    }
                    if !scanMessage.isEmpty { Text(scanMessage).font(.caption).foregroundStyle(.secondary) }
                    Button("測試連線") { model.testConnection() }
                    if !model.connection.isEmpty {
                        Text(model.connection).font(.caption).foregroundStyle(model.connection.hasPrefix("已連接") ? .green : .red)
                    }
                    Text("Mac 上：CantoType 設定 → 遠端 → 開「允許其他裝置經 Tailscale 連入」。iPhone 同 Mac 都要開住 Tailscale。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("模型") {
                    TextField("整理模型（留空＝Mac 預設）", text: $model.dictateModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    TextField("改寫模型", text: $model.rephraseModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    Text("改寫預設用 Gemma 3 12B（mlx-community/gemma-3-12b-it-4bit），第一次 Mac 要下載約 8 GB。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("常用詞彙（每行一個）") {
                    TextEditor(text: $model.vocabulary).frame(minHeight: 80)
                }
                Section("鍵盤錄音方式") {
                    Toggle("按 🎤 一定跳去 CantoType app 錄", isOn: $model.recordInApp)
                    Toggle("跳去 app 錄時，靜音 1.3 秒自動停", isOn: $model.autoStop)
                    Text("iOS 對鍵盤 extension 錄音好嚴。跳去 app 錄完，會自動彈返原本個 app 並插入文字。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("鍵盤") {
                    KeyboardView(engine: previewEngine)
                        .frame(height: KeyboardView.totalHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .listRowInsets(EdgeInsets())
                    Text("1. iOS 設定 → 一般 → 鍵盤 → 鍵盤 → 新增鍵盤 → CantoType 鍵盤\n2. 再入 CantoType 鍵盤 → 開「允許完整存取」（連 Mac 要用網絡）\n3. 打字時按 🌐 切換到 CantoType 鍵盤：頂行 🎤 錄音、✨ 改寫、口語／書面切換")
                        .font(.footnote)
                    Button("開啟 iOS 設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { payload in
                    showScanner = false
                    scanMessage = model.applyQR(payload) ? "已套用 Mac 嘅設定" : "呢個 QR 唔係 CantoType 設定"
                }
            }
        }
    }
}


/// `--keyboard-preview` 啟動參數：模擬鍵盤喺屏幕底部嘅樣（開發／截圖用）
struct KeyboardPreviewScreen: View {
    @StateObject private var engine = KeyboardEngine()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("咁而家呢個 repo 係咪真係 work？")
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .padding()
            KeyboardView(engine: engine)
        }
        .ignoresSafeArea(edges: .bottom)
        .background(Color(.systemBackground))
    }
}
