import CoreGraphics
import Foundation

/// 全局快捷鍵監聽。用 CGEvent tap（需要「輔助使用」權限）。
/// - 修飾鍵（右 Option 等）：由 flagsChanged 判斷按下／放開
/// - 普通鍵（F5 等）：keyDown／keyUp，並且會吞掉該鍵，唔會傳去前面嘅 app
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var preset: HotkeyPreset = .rightOption
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    func configure(_ preset: HotkeyPreset) {
        self.preset = preset
        isDown = false
    }

    /// 回傳 false 代表建立唔到 event tap（通常係未授權「輔助使用」）。
    @discardableResult
    func start() -> Bool {
        stop()
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    /// 回傳 true 代表要吞掉呢個事件。
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            guard preset.isModifier, keyCode == preset.keyCode else { return false }
            let pressed = event.flags.contains(preset.modifierFlag)
            if pressed, !isDown {
                isDown = true
                onPress?()
            } else if !pressed, isDown {
                isDown = false
                onRelease?()
            }
            return false

        case .keyDown:
            if keyCode == 53 { // Escape
                onEscape?()
                return false
            }
            guard !preset.isModifier, keyCode == preset.keyCode else { return false }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return true
            }
            if !isDown {
                isDown = true
                onPress?()
            }
            return true

        case .keyUp:
            guard !preset.isModifier, keyCode == preset.keyCode else { return false }
            if isDown {
                isDown = false
                onRelease?()
            }
            return true

        default:
            return false
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
