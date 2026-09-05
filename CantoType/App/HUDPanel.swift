import AppKit
import SwiftUI

/// 屏幕底部中央嘅浮動狀態膠囊（唔會搶 focus）。
@MainActor
final class HUDController {
    private weak var state: AppState?
    private var panel: NSPanel?
    private let size = NSSize(width: 360, height: 64)

    init(state: AppState) {
        self.state = state
    }

    func show() {
        guard let state else { return }
        if panel == nil {
            panel = makePanel(state: state)
        }
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(state: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView().environmentObject(state))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48)
        panel.setFrameOrigin(origin)
    }
}

struct HUDView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 18, height: 18)
            Text(state.phase.label)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if state.phase == .recording {
                LevelMeter(level: state.level)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .recording:
            Circle().fill(.red).frame(width: 10, height: 10)
        case .transcribing, .polishing, .pasting:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .idle:
            Image(systemName: "mic")
        }
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                let threshold = Float(index) / 7
                Capsule()
                    .fill(level > threshold ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: 6 + CGFloat(index) * 2.5)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
