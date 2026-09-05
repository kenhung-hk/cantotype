import Foundation
import UIKit

/// 鍵盤嘅狀態同動作（SwiftUI view 透過佢操作 textDocumentProxy）。
@MainActor
final class KeyboardEngine: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, sending, rephrasing
    }

    @Published var shifted = true
    @Published var symbols = false
    @Published var phase: Phase = .idle
    @Published var status = ""
    @Published var level: Float = 0
    @Published var hasFullAccess = false
    @Published var hasText = false
    /// 跟 host app 嘅 keyboardAppearance；nil 就跟系統
    @Published var darkAppearance: Bool?
    @Published var mode: String = RemoteConfig.shared.mode
    /// app 上一次錄音嘅結果，可以手動貼
    @Published var lastResult: String?

    var proxyProvider: () -> UITextDocumentProxy? = { nil }
    var advanceKeyboard: () -> Void = {}
    var fullAccessProvider: () -> Bool = { false }
    var openHostApp: () -> String = { "none" }

    private let config = RemoteConfig.shared
    private let capture = AudioCapture()
    private var statusResetTask: Task<Void, Never>?

    init() {
        capture.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
    }

    var modeLabel: String {
        switch mode {
        case "written": return "書面"
        case "raw": return "原文"
        default: return "口語"
        }
    }

    /// 口語 → 書面 → 原文 → 口語
    func cycleMode() {
        mode = mode == "colloquial" ? "written" : (mode == "written" ? "raw" : "colloquial")
        config.mode = mode
        show("整理模式：\(modeLabel)")
    }

    func refresh() {
        hasFullAccess = fullAccessProvider()
        let proxy = proxyProvider()
        // app 錄完返嚟：自動插入
        if let pending = config.consumePendingInsert(), let proxy {
            proxy.insertText(pending)
            hasText = true
            DebugLog.log("kb", "inserted pending text (\(pending.count) chars)")
            show("✓ 已插入")
        }
        lastResult = config.lastResult
        DebugLog.log("kb", "refresh fullAccess=\(hasFullAccess) configured=\(config.isConfigured) proxy=\(proxy != nil) pending=\(config.lastResult != nil)")
        if let appearance = proxy?.keyboardAppearance {
            darkAppearance = appearance == .dark ? true : (appearance == .light ? false : nil)
        }
        mode = config.mode
        hasText = !((proxy?.documentContextBeforeInput ?? "").isEmpty && (proxy?.documentContextAfterInput ?? "").isEmpty)
        // 句首自動大寫
        if let before = proxy?.documentContextBeforeInput, !before.isEmpty {
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            shifted = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        } else {
            shifted = true
        }
        if !hasFullAccess, status.isEmpty {
            status = "要開「允許完整存取」先可以連 Mac：iOS 設定 → 一般 → 鍵盤 → CantoType 鍵盤"
        }
    }

    // MARK: 打字

    func insert(_ text: String) {
        proxyProvider()?.insertText(shifted && !symbols ? text.uppercased() : text)
        if shifted, !symbols { shifted = false }
        hasText = true
    }

    func space() {
        proxyProvider()?.insertText(" ")
    }

    func newline() {
        proxyProvider()?.insertText("\n")
    }

    func deleteBackward() {
        proxyProvider()?.deleteBackward()
    }

    func toggleShift() { shifted.toggle() }
    func toggleSymbols() { symbols.toggle() }
    func globe() { advanceKeyboard() }

    /// 鍵盤每秒都 poll 一次，app 錄完返嚟就算鍵盤一直開住都會插入
    func pollPending() {
        guard let proxy = proxyProvider(), let pending = config.consumePendingInsert() else { return }
        proxy.insertText(pending)
        hasText = true
        lastResult = config.lastResult
        DebugLog.log("kb", "inserted pending text via poll (\(pending.count) chars)")
        show("✓ 已插入")
    }

    /// 手動貼上 app 上一次嘅結果
    func insertLastResult() {
        guard let text = config.lastResult, !text.isEmpty else {
            show("未有上一次結果")
            return
        }
        proxyProvider()?.insertText(text)
        _ = config.consumePendingInsert()
        hasText = true
        show("✓ 已貼上上次結果")
    }

    // MARK: 錄音 → Mac

    func toggleRecording() {
        switch phase {
        case .recording:
            let clip = capture.stop()
            level = 0
            guard clip.seconds >= 0.4 else {
                phase = .idle
                show("太短，再試")
                return
            }
            Task { await send(clip.wav) }
        case .idle:
            guard config.isConfigured else {
                show("未設定 Mac：開 CantoType app → 設定 → 掃 QR")
                return
            }
            guard hasFullAccess else {
                show("要開「允許完整存取」先可以連 Mac")
                return
            }
            if config.recordInApp {
                hopToApp()
                return
            }
            do {
                try capture.start()
                phase = .recording
                status = "錄音中…再按一下停止"
                DebugLog.log("kb", "in-keyboard recording started")
            } catch {
                // iOS 唔畀鍵盤錄音：跳去 app 錄，錄完會自動返嚟插入
                DebugLog.log("kb", "in-keyboard recording failed: \(error.localizedDescription)")
                phase = .idle
                hopToApp()
            }
        default:
            break
        }
    }

    private func hopToApp() {
        let requested = Date()
        let strategy = openHostApp()
        DebugLog.log("kb", "hop to app via \(strategy)")
        status = "嘗試跳去 CantoType…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            DebugLog.log("kb", "hop verified=\(self.config.appOpened(since: requested))")
            if self.config.appOpened(since: requested) {
                self.show("已跳去 CantoType 錄音，講完會自動返嚟插入")
            } else {
                // 跳唔到：iOS 唔畀鍵盤開 app。最穩陣係 Action Button／Shortcut 開「CantoType 錄音」
                self.show("iOS 唔畀鍵盤開 app（\(strategy)）。用 Action Button 或 Shortcut「CantoType 錄音」，返嚟會自動插入")
            }
        }
    }

    private func send(_ wav: Data) async {
        phase = .sending
        status = "傳去 Mac 辨識…"
        do {
            let result = try await CantoTypeClient(config: config).dictate(wav: wav, mode: mode)
            DebugLog.log("kb", "dictate ok raw=\(result.raw.prefix(40)) text=\(result.text.prefix(40))")
            if result.text.isEmpty {
                show("聽唔到內容，試下大聲啲")
            } else {
                proxyProvider()?.insertText(result.text)
                hasText = true
                show("✓ \(result.asr_ms + result.llm_ms) ms" + ((result.note?.isEmpty ?? true) ? "" : " · \(result.note!)"))
            }
        } catch {
            DebugLog.log("kb", "dictate failed: \(error.localizedDescription)")
            show(error.localizedDescription)
        }
        phase = .idle
    }

    // MARK: 改寫（Gemma）

    func rephrase() {
        guard phase == .idle, let proxy = proxyProvider() else { return }
        guard hasFullAccess else {
            show("要開「允許完整存取」先可以連 Mac")
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        let source = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            show("冇文字可以改寫")
            return
        }
        phase = .rephrasing
        status = "Gemma 改寫中…"
        Task {
            do {
                let rewritten = try await CantoTypeClient(config: config).polish(text: source, mode: "rephrase", model: config.rephraseModel)
                // 游標移到最尾，刪走原文，插入改寫
                if !after.isEmpty { proxy.adjustTextPosition(byCharacterOffset: after.count) }
                for _ in 0..<(before.count + after.count) { proxy.deleteBackward() }
                proxy.insertText(rewritten)
                show("✓ 已改寫")
            } catch {
                show(error.localizedDescription)
            }
            phase = .idle
        }
    }

    private func show(_ message: String) {
        status = message
        statusResetTask?.cancel()
        statusResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self?.phase == .idle { self?.status = "" }
        }
    }
}
