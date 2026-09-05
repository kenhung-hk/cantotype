import AppKit
import ApplicationServices
import AVFoundation
import Foundation

enum Permissions {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 彈出系統嘅「輔助使用」授權提示。
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Sounds {
    enum Kind { case start, stop, error }

    static func play(_ kind: Kind) {
        let name: String
        switch kind {
        case .start: name = "Pop"
        case .stop: name = "Tink"
        case .error: name = "Basso"
        }
        NSSound(named: name)?.play()
    }
}
