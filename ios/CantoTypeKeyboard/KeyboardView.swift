import SwiftUI

/// 簡單英文 QWERTY 鍵盤 + 🎤 錄音（廣東話＋英文）+ ✨ Gemma 改寫。
struct KeyboardView: View {
    @ObservedObject var engine: KeyboardEngine
    @Environment(\.colorScheme) private var scheme

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let symbolRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]

    var body: some View {
        VStack(spacing: 6) {
            statusBar
            let rows = engine.symbols ? symbolRows : letterRows
            keyRow(rows[0])
            keyRow(rows[1])
            HStack(spacing: 6) {
                specialKey(engine.shifted ? "shift.fill" : "shift", width: 44) { engine.toggleShift() }
                keyRow(rows[2])
                specialKey("delete.left", width: 44) { engine.deleteBackward() }
            }
            HStack(spacing: 6) {
                textKey(engine.symbols ? "ABC" : "123", width: 48) { engine.toggleSymbols() }
                specialKey("globe", width: 40) { engine.globe() }
                micKey
                Button { engine.space() } label: { keyLabel(Text("space").font(.callout)) }
                    .buttonStyle(.plain)
                rephraseKey
                textKey("return", width: 64) { engine.newline() }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(scheme == .dark ? Color(white: 0.11) : Color(red: 0.82, green: 0.84, blue: 0.86))
    }

    // MARK: 狀態列

    private var statusBar: some View {
        HStack(spacing: 8) {
            if engine.phase == .recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBarsSmall(level: engine.level)
            } else if engine.phase == .sending || engine.phase == .rephrasing {
                ProgressView().controlSize(.small)
            }
            Text(engine.status.isEmpty ? "CantoType · 廣東話＋英文口述" : engine.status)
                .font(.caption)
                .foregroundStyle(engine.status.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(height: 20)
        .padding(.horizontal, 6)
    }

    // MARK: 掣

    private func keyRow(_ letters: String) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(letters), id: \.self) { letter in
                Button { engine.insert(String(letter)) } label: {
                    keyLabel(Text(engine.shifted && !engine.symbols ? String(letter).uppercased() : String(letter)).font(.title3))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func keyLabel<Content: View>(_ content: Content, dark: Bool = false) -> some View {
        content
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(keyColor(dark: dark), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
    }

    private func keyColor(dark: Bool) -> Color {
        if scheme == .dark { return dark ? Color(white: 0.28) : Color(white: 0.42) }
        return dark ? Color(red: 0.68, green: 0.71, blue: 0.75) : .white
    }

    private func specialKey(_ symbol: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            keyLabel(Image(systemName: symbol).font(.body), dark: true).frame(width: width)
        }
        .buttonStyle(.plain)
    }

    private func textKey(_ title: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            keyLabel(Text(title).font(.callout), dark: true).frame(width: width)
        }
        .buttonStyle(.plain)
    }

    private var micKey: some View {
        Button { engine.toggleRecording() } label: {
            Image(systemName: engine.phase == .recording ? "stop.fill" : "mic.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 42)
                .background(engine.phase == .recording ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(engine.phase == .sending || engine.phase == .rephrasing)
    }

    private var rephraseKey: some View {
        Button { engine.rephrase() } label: {
            Image(systemName: "wand.and.stars")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 42)
                .background(Color.purple, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(engine.phase != .idle)
        .help("用 Gemma 改寫游標前後嘅文字")
    }
}

struct LevelBarsSmall: View {
    var level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(level > Float(index) / 8 ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 4 + CGFloat(index) * 1.5)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
