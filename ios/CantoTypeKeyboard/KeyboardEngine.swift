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

    var proxyProvider: () -> UITextDocumentProxy? = { nil }
    var advanceKeyboard: () -> Void = {}
    var fullAccessProvider: () -> Bool = { false }
    var openHostApp: () -> Bool = { false }

    private let config = RemoteConfig.shared
    private let capture = AudioCapture()
    private var statusResetTask: Task<Void, Never>?

    init() {
        capture.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
    }

    func refresh() {
        hasFullAccess = fullAccessProvider()
        let proxy = proxyProvider()
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
            do {
                try capture.start()
                phase = .recording
                status = "錄音中…再按一下停止"
            } catch {
                // iOS 唔畀鍵盤錄音嘅情況
                phase = .idle
                if openHostApp() {
                    show("已開 CantoType app 錄音，錄完會複製到剪貼簿")
                } else {
                    show("iOS 唔畀鍵盤錄音：請開 CantoType app 錄音，結果會自動複製")
                }
            }
        default:
            break
        }
    }

    private func send(_ wav: Data) async {
        phase = .sending
        status = "傳去 Mac 辨識…"
        do {
            let result = try await CantoTypeClient(config: config).dictate(wav: wav, mode: config.mode)
            if result.text.isEmpty {
                show("聽唔到內容，試下大聲啲")
            } else {
                proxyProvider()?.insertText(result.text)
                hasText = true
                show("✓ \(result.asr_ms + result.llm_ms) ms" + ((result.note?.isEmpty ?? true) ? "" : " · \(result.note!)"))
            }
        } catch {
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
