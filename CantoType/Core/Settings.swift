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
        case .http: return "MLX Whisper（本地伺服器，推薦）"
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
        static let whisperModel = "whisperModel"
        static let manageSidecar = "manageSidecar"
        static let llmProvider = "llmProvider"
        static let llmModel = "llmModel"
        static let inputDeviceUID = "inputDeviceUID"
        static let polishMode = "polishMode"
        static let ollamaHost = "ollamaHost"
        static let ollamaModel = "ollamaModel"
        static let ollamaFallbackModel = "ollamaFallbackModel"
        static let hotkey = "hotkey"
        static let activation = "activation"
        static let restoreClipboard = "restoreClipboard"
        static let playSounds = "playSounds"
        static let showHUD = "showHUD"
        static let vocabulary = "vocabulary"
        static let speakerContext = "speakerContext"
        static let techCorrection = "techCorrection"
        static let whisperPromptCustom = "whisperPromptCustom"
        static let remoteAccess = "remoteAccess"
        static let remoteToken = "remoteToken"
    }

    private let defaults = UserDefaults.standard

    @Published var backend: BackendKind { didSet { defaults.set(backend.rawValue, forKey: Keys.backend) } }
    @Published var appleLocale: String { didSet { defaults.set(appleLocale, forKey: Keys.appleLocale) } }
    @Published var httpURL: String { didSet { defaults.set(httpURL, forKey: Keys.httpURL) } }
    @Published var httpModel: String { didSet { defaults.set(httpModel, forKey: Keys.httpModel) } }
    @Published var httpLanguage: String { didSet { defaults.set(httpLanguage, forKey: Keys.httpLanguage) } }
    @Published var whisperModel: String { didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) } }
    @Published var manageSidecar: Bool { didSet { defaults.set(manageSidecar, forKey: Keys.manageSidecar) } }
    @Published var llmProvider: LLMProvider { didSet { defaults.set(llmProvider.rawValue, forKey: Keys.llmProvider) } }
    @Published var llmModel: String { didSet { defaults.set(llmModel, forKey: Keys.llmModel) } }
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) } }
    @Published var polishMode: PolishMode { didSet { defaults.set(polishMode.rawValue, forKey: Keys.polishMode) } }
    @Published var ollamaHost: String { didSet { defaults.set(ollamaHost, forKey: Keys.ollamaHost) } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) } }
    @Published var ollamaFallbackModel: String { didSet { defaults.set(ollamaFallbackModel, forKey: Keys.ollamaFallbackModel) } }
    @Published var hotkey: HotkeyPreset { didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) } }
    @Published var activation: ActivationMode { didSet { defaults.set(activation.rawValue, forKey: Keys.activation) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Keys.playSounds) } }
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: Keys.showHUD) } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Keys.vocabulary) } }
    @Published var speakerContext: String { didSet { defaults.set(speakerContext, forKey: Keys.speakerContext) } }
    @Published var techCorrection: Bool { didSet { defaults.set(techCorrection, forKey: Keys.techCorrection) } }
    /// 用戶自己寫嘅 Whisper prompt；空就用自動生成嗰句。
    @Published var whisperPromptCustom: String { didSet { defaults.set(whisperPromptCustom, forKey: Keys.whisperPromptCustom) } }
    /// 開放伺服器俾 Tailscale／局域網（iOS 鍵盤）連入；伺服器會 bind 0.0.0.0 並要求 token。
    @Published var remoteAccess: Bool { didSet { defaults.set(remoteAccess, forKey: Keys.remoteAccess) } }
    @Published var remoteToken: String { didSet { defaults.set(remoteToken, forKey: Keys.remoteToken) } }

    init() {
        let d = UserDefaults.standard
        backend = BackendKind(rawValue: d.string(forKey: Keys.backend) ?? "") ?? .http
        appleLocale = d.string(forKey: Keys.appleLocale) ?? "zh_HK"
        httpURL = d.string(forKey: Keys.httpURL) ?? "http://127.0.0.1:8787/v1/audio/transcriptions"
        httpModel = d.string(forKey: Keys.httpModel) ?? ""
        httpLanguage = d.string(forKey: Keys.httpLanguage) ?? "yue"
        whisperModel = d.string(forKey: Keys.whisperModel) ?? WhisperModelPreset.defaultModel
        manageSidecar = d.object(forKey: Keys.manageSidecar) as? Bool ?? true
        llmProvider = LLMProvider(rawValue: d.string(forKey: Keys.llmProvider) ?? "") ?? .mlx
        llmModel = d.string(forKey: Keys.llmModel) ?? LLMModelPreset.defaultModel
        inputDeviceUID = d.string(forKey: Keys.inputDeviceUID) ?? ""
        polishMode = PolishMode(rawValue: d.string(forKey: Keys.polishMode) ?? "") ?? .colloquial
        ollamaHost = d.string(forKey: Keys.ollamaHost) ?? "http://127.0.0.1:11434"
        ollamaModel = d.string(forKey: Keys.ollamaModel) ?? "qwen3:14b"
        ollamaFallbackModel = d.string(forKey: Keys.ollamaFallbackModel) ?? "qwen2.5vl:7b"
        hotkey = HotkeyPreset(rawValue: d.string(forKey: Keys.hotkey) ?? "") ?? .rightOption
        activation = ActivationMode(rawValue: d.string(forKey: Keys.activation) ?? "") ?? .hold
        restoreClipboard = d.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        playSounds = d.object(forKey: Keys.playSounds) as? Bool ?? true
        showHUD = d.object(forKey: Keys.showHUD) as? Bool ?? true
        vocabulary = d.string(forKey: Keys.vocabulary) ?? ""
        speakerContext = d.string(forKey: Keys.speakerContext) ?? SpeakerContext.defaultDescription
        techCorrection = d.object(forKey: Keys.techCorrection) as? Bool ?? true
        whisperPromptCustom = d.string(forKey: Keys.whisperPromptCustom) ?? ""
        remoteAccess = d.object(forKey: Keys.remoteAccess) as? Bool ?? false
        if let token = d.string(forKey: Keys.remoteToken), !token.isEmpty {
            remoteToken = token
        } else {
            let token = AppSettings.makeToken()
            remoteToken = token
            d.set(token, forKey: Keys.remoteToken)
        }
    }

    static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 伺服器要 bind 嘅位址同 token（冇開放就只聽 localhost、唔要 token）。
    var sidecarHost: String { remoteAccess ? "0.0.0.0" : "127.0.0.1" }
    var sidecarToken: String { remoteAccess ? remoteToken : "" }

    /// 餵俾 LLM 嘅詞彙：只係用戶自己嘅（技術詞靠規則，唔靠清單）。
    var llmVocabulary: [String] { vocabularyList }

    /// 餵俾 Apple 語音嘅 contextual strings。
    var contextualStrings: [String] {
        VocabularyProvider.contextualStrings(user: vocabularyList, techCorrection: techCorrection)
    }

    /// 自動生成嘅 Whisper prompt（由講者背景同詞彙砌出來）。
    var whisperPromptGenerated: String {
        VocabularyProvider.whisperPrompt(user: vocabularyList, context: speakerContext, techCorrection: techCorrection)
    }

    /// 實際餵俾 Whisper 嘅 initial prompt：用戶有自己寫就用佢，否則用自動生成嗰句。
    var whisperPrompt: String {
        let custom = whisperPromptCustom.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? whisperPromptGenerated : custom
    }

    /// 用戶自己嘅常用詞彙：每行一個，或者用逗號分隔。
    var vocabularyList: [String] {
        vocabulary
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Whisper 模型清單。Ken 用真人聲比較後只保留呢兩個（Apple zh_HK 係第三個選擇，喺引擎設定揀）。
/// 其他 HuggingFace 上嘅 Whisper／廣東話 fine-tune 可以喺試驗室貼 repo 加入，HF 格式會自動轉成 MLX。
enum WhisperModelPreset: String, CaseIterable, Identifiable {
    case cantoneseTurbo = "Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx"
    case cantoneseTurboInt8 = "Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx-int8"

    static let defaultModel = WhisperModelPreset.cantoneseTurboInt8.rawValue

    var id: String { rawValue }

    /// 需要由 HF 格式轉成 MLX 先用得。
    var needsConversion: Bool { false }

    /// 試驗室預設剔選。
    var selectedByDefault: Bool { true }

    var label: String {
        switch self {
        case .cantoneseTurbo: return "large-v3-turbo 廣東話＋英文 fine-tune（1.6 GB）"
        case .cantoneseTurboInt8: return "同上 int8 版（0.9 GB，較快，預設）"
        }
    }
}

extension AppSettings {
    /// HTTP 網址係 localhost 先會由 app 自己管理伺服器。
    var sidecarPort: Int? {
        guard manageSidecar, backend == .http, let url = URL(string: httpURL),
              let host = url.host(), ["127.0.0.1", "localhost", "::1"].contains(host)
        else { return nil }
        return url.port ?? 80
    }
}

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case mlx
    case ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mlx: return "MLX（本地伺服器，Qwen3）"
        case .ollama: return "Ollama"
        }
    }
}

/// 常用 MLX LLM。任何 HuggingFace 上 mlx-community 格式嘅 instruct 模型都可以手動輸入。
enum LLMModelPreset: String, CaseIterable, Identifiable {
    case qwen3_14b = "mlx-community/Qwen3-14B-4bit"
    case qwen3_8b = "mlx-community/Qwen3-8B-4bit"
    case qwen3_4b = "mlx-community/Qwen3-4B-4bit"
    case qwen3_32b = "mlx-community/Qwen3-32B-4bit"
    case qwen3_30bA3bInstruct = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
    case qwen3_30bA3b = "mlx-community/Qwen3-30B-A3B-4bit"
    case gemma3_12b = "mlx-community/gemma-3-12b-it-4bit"
    case gemma3_27b = "mlx-community/gemma-3-27b-it-4bit"
    case qwen25_14b = "mlx-community/Qwen2.5-14B-Instruct-4bit"
    case mistralSmall = "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit"
    case gptOss20b = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    case llama33_70b = "mlx-community/Llama-3.3-70B-Instruct-4bit"
    case cantoneseQwen2_7b = "hyperkit/Qwen2-Cantonese-7B-Instruct-mlx"
    case cantoneseLLMChat7b = "hyperkit/CantoneseLLMChat-v1.0-7B-mlx"

    static let defaultModel = LLMModelPreset.gemma3_12b.rawValue

    var id: String { rawValue }

    var selectedByDefault: Bool {
        switch self {
        case .gemma3_12b, .qwen3_8b: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .qwen3_14b: return "Qwen3 14B 4-bit（約 8 GB，偶然會改句意）"
        case .qwen3_8b: return "Qwen3 8B 4-bit（快，約 5 GB）"
        case .qwen3_4b: return "Qwen3 4B 4-bit（最快，約 2.5 GB）"
        case .qwen3_32b: return "Qwen3 32B 4-bit（約 18 GB）"
        case .qwen3_30bA3bInstruct: return "Qwen3 30B-A3B Instruct 2507 4-bit（MoE，快，約 17 GB）"
        case .qwen3_30bA3b: return "Qwen3 30B-A3B 4-bit（MoE，約 17 GB）"
        case .gemma3_12b: return "Gemma 3 12B it 4-bit（預設，約 8 GB，開發用語最準）"
        case .gemma3_27b: return "Gemma 3 27B it 4-bit（約 16 GB）"
        case .qwen25_14b: return "Qwen2.5 14B Instruct 4-bit（約 8 GB）"
        case .mistralSmall: return "Mistral Small 3.2 24B 4-bit（約 14 GB）"
        case .gptOss20b: return "gpt-oss 20B MXFP4（約 12 GB）"
        case .llama33_70b: return "Llama 3.3 70B 4-bit（約 40 GB，慢）"
        case .cantoneseQwen2_7b: return "Qwen2 Cantonese 7B Instruct（廣東話 fine-tune，約 4 GB）"
        case .cantoneseLLMChat7b: return "CantoneseLLMChat v1.0 7B（廣東話 fine-tune，約 4 GB）"
        }
    }
}

extension AppSettings {
    /// 伺服器 base URL（由辨識網址推算）：http://127.0.0.1:8787
    var sidecarBaseURL: String {
        guard let url = URL(string: httpURL), let host = url.host() else { return "http://127.0.0.1:8787" }
        let scheme = url.scheme ?? "http"
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// 傳畀 sidecar 嘅 LLM 模型；用 Ollama 就唔載入。
    var sidecarLLMModel: String {
        llmProvider == .mlx ? llmModel : "none"
    }

    var polishConfig: PolishConfig {
        PolishConfig(
            provider: llmProvider,
            mlxBaseURL: sidecarBaseURL,
            mlxModel: llmModel,
            ollamaHost: ollamaHost,
            ollamaModel: ollamaModel,
            ollamaFallbackModel: ollamaFallbackModel,
            speakerContext: speakerContext,
            techCorrection: techCorrection
        )
    }
}
