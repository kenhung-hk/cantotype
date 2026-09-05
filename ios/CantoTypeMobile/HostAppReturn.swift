import Foundation
import UIKit

/// 錄完之後開返用戶原本喺度嘅 app。
/// 1) 已知 URL scheme → UIApplication.open；2) LSApplicationWorkspace（私有，個人 app 用得就用）；3) 退場（會返主畫面）。
@MainActor
enum HostAppReturn {
    static let schemes: [String: String] = [
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.MobileSMS": "sms:",
        "com.apple.mobilemail": "message://",
        "com.apple.mobilesafari": "x-safari-https://",
        "com.apple.reminders": "x-apple-reminderkit://",
        "com.apple.mobilecal": "calshow://",
        "com.apple.shortcuts": "shortcuts://",
        "net.whatsapp.WhatsApp": "whatsapp://",
        "ph.telegra.Telegraph": "tg://",
        "com.tinyspeck.chatlyio": "slack://",
        "com.google.chrome.ios": "googlechrome://",
        "com.google.Gmail": "googlegmail://",
        "com.microsoft.Office.Outlook": "ms-outlook://",
        "com.microsoft.skype.teams": "msteams://",
        "jp.naver.line": "line://",
        "com.tencent.xin": "weixin://",
        "org.whispersystems.signal": "sgnl://",
        "com.hammerandchisel.discord": "discord://",
        "com.atebits.Tweetie2": "twitter://",
        "com.facebook.Facebook": "fb://",
        "com.burbn.instagram": "instagram://",
        "com.burbn.barcelona": "barcelona://",
        "com.reddit.Reddit": "reddit://",
        "com.google.Docs": "googledocs://",
        "notion.id": "notion://",
        "md.obsidian": "obsidian://",
        "net.shinyfrog.bear-iOS": "bear://",
        "com.lukilabs.lukiapp": "craftdocs://",
        "com.culturedcode.ThingsiPhone": "things:///",
        "com.todoist.ios": "todoist://",
        "com.readdle.smartemail": "readdle-spark://",
        "com.openai.chat": "chatgpt://",
        "com.anthropic.claude": "claude://",
    ]

    /// 回傳用咗邊種方法（畀 log）
    static func returnToHost(_ bundleID: String?) -> String {
        if let bundleID {
            if let scheme = schemes[bundleID], let url = URL(string: scheme) {
                UIApplication.shared.open(url)
                return "scheme \(scheme)"
            }
            if openViaWorkspace(bundleID) {
                return "workspace \(bundleID)"
            }
        }
        // 冇辦法知返去邊：退場（返主畫面），用戶自己撳返原本 app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        }
        return "suspend"
    }

    private static func openViaWorkspace(_ bundleID: String) -> Bool {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return false }
        let defaultSel = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: defaultSel), let workspace = cls.perform(defaultSel)?.takeUnretainedValue() as? NSObject else { return false }
        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSel) else { return false }
        let result = workspace.perform(openSel, with: bundleID)
        return result != nil && (result!.takeUnretainedValue() as? NSNumber)?.boolValue ?? true
    }
}
