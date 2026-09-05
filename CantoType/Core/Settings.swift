import Combine
import CoreGraphics
import Foundation

enum PolishMode: String, CaseIterable, Identifiable, Codable {
    case colloquial
    case written
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colloquial: return "口語（保留廣東話）"
        case .written: return "書面語（轉成書面中文）"
        case .raw: return "原文（唔經 LLM）"
        }
    }
}

enum BackendKind: String, CaseIterable, Identifiable, Codable {
    case apple
    case http

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "Apple 內置語音（on-device）"
        case .http: return "HTTP 伺服器（Whisper / SenseVoice）"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    case hold
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hold: return "按住講話，放手就輸入"
        case .toggle: return "按一下開始，再按一下結束"
        }
    }
}

enum HotkeyPreset: String, CaseIterable, Identifiable, Codable {
    case rightOption
    case rightCommand
    case rightControl
    case fn
    case f5
    case f6

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: return "右邊 Option ⌥"
        case .rightCommand: return "右邊 Command ⌘"
        case .rightControl: return "右邊 Control ⌃"
        case .fn: return "Fn / 🌐"
        case .f5: return "F5"
        case .f6: return "F6"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        case .f5: return 96
        case .f6: return 97
        }
    }

    /// 修飾鍵（Option／Command／Control／Fn）靠 flagsChanged 事件判斷按下／放開；
    /// 普通鍵（F5／F6）靠 keyDown／keyUp。
    var isModifier: Bool {
        switch self {
        case .f5, .f6: return false
        default: return true
        }
    }

    var modifierFlag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        case .f5, .f6: return []
        }
    }

    var hint: String {
        switch self {
        case .fn:
            return "要去「系統設定 › 鍵盤 › 按下 🌐 鍵時」揀「不執行任何操作」，Fn 先唔會同時彈出表情符號或者 Apple 聽寫。"
        case .rightOption:
            return "右邊 Option 平時好少用；如果你打特殊符號會用到右 Option，可以轉用右 Command。"
        default:
            return ""
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let backend = "backend"
        static let appleLocale = "appleLocale"
        static let httpURL = "httpURL"
        static let httpModel = "httpModel"
        static let httpLanguage = "httpLanguage"
        static let polishMode = "polishMode"
        static let ollamaHost = "ollamaHost"
        static let ollamaModel = "ollamaModel"
        static let hotkey = "hotkey"
        static let activation = "activation"
        static let restoreClipboard = "restoreClipboard"
        static let playSounds = "playSounds"
        static let showHUD = "showHUD"
        static let vocabulary = "vocabulary"
    }

    private let defaults = UserDefaults.standard

    @Published var backend: BackendKind { didSet { defaults.set(backend.rawValue, forKey: Keys.backend) } }
    @Published var appleLocale: String { didSet { defaults.set(appleLocale, forKey: Keys.appleLocale) } }
    @Published var httpURL: String { didSet { defaults.set(httpURL, forKey: Keys.httpURL) } }
    @Published var httpModel: String { didSet { defaults.set(httpModel, forKey: Keys.httpModel) } }
    @Published var httpLanguage: String { didSet { defaults.set(httpLanguage, forKey: Keys.httpLanguage) } }
    @Published var polishMode: PolishMode { didSet { defaults.set(polishMode.rawValue, forKey: Keys.polishMode) } }
    @Published var ollamaHost: String { didSet { defaults.set(ollamaHost, forKey: Keys.ollamaHost) } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) } }
    @Published var hotkey: HotkeyPreset { didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) } }
    @Published var activation: ActivationMode { didSet { defaults.set(activation.rawValue, forKey: Keys.activation) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Keys.playSounds) } }
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: Keys.showHUD) } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Keys.vocabulary) } }

    init() {
        let d = UserDefaults.standard
        backend = BackendKind(rawValue: d.string(forKey: Keys.backend) ?? "") ?? .apple
        appleLocale = d.string(forKey: Keys.appleLocale) ?? "zh_HK"
        httpURL = d.string(forKey: Keys.httpURL) ?? "http://127.0.0.1:8787/v1/audio/transcriptions"
        httpModel = d.string(forKey: Keys.httpModel) ?? ""
        httpLanguage = d.string(forKey: Keys.httpLanguage) ?? "yue"
        polishMode = PolishMode(rawValue: d.string(forKey: Keys.polishMode) ?? "") ?? .colloquial
        ollamaHost = d.string(forKey: Keys.ollamaHost) ?? "http://127.0.0.1:11434"
        ollamaModel = d.string(forKey: Keys.ollamaModel) ?? "qwen3:14b"
        hotkey = HotkeyPreset(rawValue: d.string(forKey: Keys.hotkey) ?? "") ?? .rightOption
        activation = ActivationMode(rawValue: d.string(forKey: Keys.activation) ?? "") ?? .hold
        restoreClipboard = d.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        playSounds = d.object(forKey: Keys.playSounds) as? Bool ?? true
        showHUD = d.object(forKey: Keys.showHUD) as? Bool ?? true
        vocabulary = d.string(forKey: Keys.vocabulary) ?? ""
    }

    /// 常用詞彙：每行一個，或者用逗號分隔。
    var vocabularyList: [String] {
        vocabulary
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
