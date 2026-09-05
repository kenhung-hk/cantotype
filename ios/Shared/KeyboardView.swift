import SwiftUI

/// 同 iOS 原生鍵盤一樣嘅 QWERTY 排位、大小同顏色；額外功能（🎤 錄音、✨ 改寫、口語／書面）放喺頂部一行。
struct KeyboardView: View {
    @ObservedObject var engine: KeyboardEngine
    @Environment(\.colorScheme) private var scheme

    static let toolbarHeight: CGFloat = 44
    static let keyHeight: CGFloat = 42
    static let rowGap: CGFloat = 11
    static let totalHeight: CGFloat = toolbarHeight + keyHeight * 4 + rowGap * 3 + 6 + 8

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let symbolRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]

    private var dark: Bool { engine.darkAppearance ?? (scheme == .dark) }

    // iOS 鍵盤配色
    private var background: Color { dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color(red: 0.82, green: 0.835, blue: 0.85) }
    private var keyColor: Color { dark ? Color(red: 0.42, green: 0.42, blue: 0.43) : .white }
    private var specialColor: Color { dark ? Color(red: 0.27, green: 0.27, blue: 0.28) : Color(red: 0.68, green: 0.71, blue: 0.74) }
    private var textColor: Color { dark ? .white : .black }

    var body: some View {
        GeometryReader { geo in
            let sideInset: CGFloat = 3
            let gap: CGFloat = 6
            let keyWidth = (geo.size.width - sideInset * 2 - gap * 9) / 10
            let rows = engine.symbols ? symbolRows : letterRows

            VStack(spacing: 0) {
                toolbar
                    .frame(height: Self.toolbarHeight)
                    .padding(.horizontal, 6)
                VStack(spacing: Self.rowGap) {
                    letterRow(rows[0], keyWidth: keyWidth, gap: gap)
                    letterRow(rows[1], keyWidth: keyWidth, gap: gap)
                    HStack(spacing: gap) {
                        specialKey(width: keyWidth * 1.25 + gap, symbol: engine.shifted ? "shift.fill" : "shift") { engine.toggleShift() }
                        Spacer(minLength: 0)
                        letterRow(rows[2], keyWidth: keyWidth, gap: gap)
                        Spacer(minLength: 0)
                        deleteKey(width: keyWidth * 1.25 + gap)
                    }
                    HStack(spacing: gap) {
                        specialKey(width: keyWidth * 1.25 + gap, title: engine.symbols ? "ABC" : "123") { engine.toggleSymbols() }
                        specialKey(width: keyWidth * 1.25 + gap, symbol: "globe") { engine.globe() }
                        Button { engine.space() } label: {
                            keyShape(color: keyColor) {
                                Text(engine.symbols ? "space" : "space").font(.system(size: 16)).foregroundStyle(textColor)
                            }
                        }
                        .buttonStyle(KeyPressStyle())
                        specialKey(width: keyWidth * 2.4 + gap * 2, title: "return") { engine.newline() }
                    }
                }
                .padding(.horizontal, sideInset)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(height: Self.totalHeight)
        .background(background)
    }

    // MARK: 頂部工具列

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarChip(
                icon: engine.phase == .recording ? "stop.fill" : "mic.fill",
                title: engine.phase == .recording ? "停止" : "錄音",
                tint: engine.phase == .recording ? .red : .blue,
                disabled: engine.phase == .sending || engine.phase == .rephrasing
            ) { engine.toggleRecording() }
            toolbarChip(icon: "wand.and.stars", title: "改寫", tint: .purple, disabled: engine.phase != .idle) { engine.rephrase() }
            toolbarChip(icon: "character.book.closed", title: engine.modeLabel, tint: .gray, disabled: false) { engine.cycleMode() }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if engine.phase == .recording {
                    LevelBarsSmall(level: engine.level)
                } else if engine.phase == .sending || engine.phase == .rephrasing {
                    ProgressView().controlSize(.small)
                }
                if !engine.status.isEmpty {
                    Text(engine.status)
                        .font(.caption2)
                        .foregroundStyle(dark ? .white.opacity(0.85) : .black.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 170, alignment: .trailing)
                }
            }
        }
    }

    private func toolbarChip(icon: String, title: String, tint: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint == .gray ? textColor : .white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(tint == .gray ? specialColor : tint, in: Capsule())
        }
        .buttonStyle(KeyPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    // MARK: 字母鍵

    private func letterRow(_ letters: String, keyWidth: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(letters), id: \.self) { letter in
                let shown = engine.shifted && !engine.symbols ? String(letter).uppercased() : String(letter)
                Button { engine.insert(String(letter)) } label: {
                    keyShape(color: keyColor) {
                        Text(shown).font(.system(size: engine.symbols ? 22 : 24, weight: .regular)).foregroundStyle(textColor)
                    }
                }
                .buttonStyle(KeyPressStyle())
                .frame(width: keyWidth)
            }
        }
    }

    private func specialKey(width: CGFloat, symbol: String? = nil, title: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            keyShape(color: specialColor) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(textColor)
                } else if let title {
                    Text(title).font(.system(size: 16)).foregroundStyle(textColor)
                }
            }
        }
        .buttonStyle(KeyPressStyle())
        .frame(width: width)
    }

    /// 長按會連續刪除
    private func deleteKey(width: CGFloat) -> some View {
        RepeatButton(action: { engine.deleteBackward() }) {
            keyShape(color: specialColor) {
                Image(systemName: "delete.left").font(.system(size: 18)).foregroundStyle(textColor)
            }
        }
        .frame(width: width)
    }

    private func keyShape<Content: View>(color: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: Self.keyHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(color)
                    .shadow(color: .black.opacity(dark ? 0.6 : 0.35), radius: 0, x: 0, y: 1)
            )
            .contentShape(Rectangle())
    }
}

/// 按落去會變暗，似 iOS 鍵盤
struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.05), value: configuration.isPressed)
    }
}

/// 按一下刪一個字，長按每 0.08 秒連續刪
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false
    @State private var timer: Timer?

    var body: some View {
        label()
            .opacity(pressed ? 0.55 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in action() }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
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
