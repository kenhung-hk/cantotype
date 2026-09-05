import SwiftUI
import UIKit

/// 鍵盤 extension 入口：SwiftUI 鍵盤 + 錄音 + 改寫，文字經 textDocumentProxy 插入。
final class KeyboardViewController: UIInputViewController {
    private let engine = KeyboardEngine()
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        engine.proxyProvider = { [weak self] in self?.textDocumentProxy }
        engine.advanceKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        engine.fullAccessProvider = { [weak self] in self?.hasFullAccess ?? false }
        engine.openHostApp = { [weak self] in
            // 鍵盤 extension 冇公開 API 開 app；逐個試，回傳用咗邊招（真正有冇開到由 KeyboardEngine 驗證）
            guard let self, let url = URL(string: "cantotype://record") else { return "no-url" }
            var attempted: [String] = []

            // 1) extensionContext.open（文件話只支援 Today widget，但有版本畀鍵盤開自己嘅 container app）
            if let context = self.extensionContext {
                context.open(url) { success in
                    if !success { NSLog("CantoType keyboard: extensionContext.open failed") }
                }
                attempted.append("ctx")
            }
            // 2) UIApplication.sharedApplication（extension process 內部其實有一個）
            if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
               let shared = appClass.value(forKey: "sharedApplication") as? NSObject {
                let open = NSSelectorFromString("openURL:options:completionHandler:")
                if shared.responds(to: open) {
                    _ = shared.perform(open, with: url, with: [:] as NSDictionary)
                    attempted.append("shared")
                } else if shared.responds(to: NSSelectorFromString("openURL:")) {
                    _ = shared.perform(NSSelectorFromString("openURL:"), with: url)
                    attempted.append("shared-legacy")
                }
            }
            // 3) responder chain
            let selector = NSSelectorFromString("openURL:")
            var responder: UIResponder? = self.next
            while let current = responder {
                if current.responds(to: selector) {
                    _ = current.perform(selector, with: url)
                    attempted.append("chain:\(type(of: current))")
                    break
                }
                responder = current.next
            }
            return attempted.isEmpty ? "none" : attempted.joined(separator: "+")
        }

        let host = UIHostingController(rootView: KeyboardView(engine: engine))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.totalHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        engine.refresh()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        engine.refresh()
    }
}
