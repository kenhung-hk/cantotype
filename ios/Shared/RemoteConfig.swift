import Foundation

/// App 同鍵盤 extension 共用嘅設定（App Group）。
final class RemoteConfig {
    static let appGroup = "group.com.kenhung.cantotype"
    static let shared = RemoteConfig()

    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: RemoteConfig.appGroup) ?? .standard
    }

    private enum Keys {
        static let serverURL = "serverURL"
        static let token = "token"
        static let mode = "mode"
        static let dictateModel = "dictateModel"
        static let rephraseModel = "rephraseModel"
        static let vocabulary = "vocabulary"
        static let holdToTalk = "holdToTalk"
    }

    /// 例：http://100.100.32.60:8787 或 http://kenhungs-mac-studio.tail1e4efd.ts.net:8787
    var serverURL: String {
        get { defaults.string(forKey: Keys.serverURL) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.serverURL) }
    }

    var token: String {
        get { defaults.string(forKey: Keys.token) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.token) }
    }

    /// colloquial | written | raw
    var mode: String {
        get { defaults.string(forKey: Keys.mode) ?? "colloquial" }
        set { defaults.set(newValue, forKey: Keys.mode) }
    }

    /// 空 = 用 Mac 伺服器預設 LLM
    var dictateModel: String {
        get { defaults.string(forKey: Keys.dictateModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.dictateModel) }
    }

    /// 「改寫」掣用嘅 LLM，預設 Gemma 3 12B
    var rephraseModel: String {
        get { defaults.string(forKey: Keys.rephraseModel) ?? "mlx-community/gemma-3-12b-it-4bit" }
        set { defaults.set(newValue, forKey: Keys.rephraseModel) }
    }

    var vocabulary: String {
        get { defaults.string(forKey: Keys.vocabulary) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vocabulary) }
    }

    var holdToTalk: Bool {
        get { defaults.object(forKey: Keys.holdToTalk) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.holdToTalk) }
    }

    var isConfigured: Bool { URL(string: serverURL)?.host != nil }

    /// 由 Mac 設定頁嘅 QR code（JSON {"url","token"}）套用設定。
    @discardableResult
    func apply(qrPayload: String) -> Bool {
        guard let data = qrPayload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, URL(string: url)?.host != nil
        else { return false }
        serverURL = url
        token = (object["token"] as? String) ?? ""
        return true
    }
}
