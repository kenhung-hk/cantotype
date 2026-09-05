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
            // 鍵盤 extension 冇 UIApplication；沿 responder chain 搵到 host 嘅 UIApplication 再叫 openURL:
            guard let self, let url = URL(string: "cantotype://record") else { return false }
            let selector = NSSelectorFromString("openURL:")
            var responder: UIResponder? = self
            while let current = responder {
                if current.responds(to: selector), !(current is UIInputViewController) {
                    _ = current.perform(selector, with: url)
                    return true
                }
                responder = current.next
            }
            if let context = self.extensionContext {
                context.open(url, completionHandler: nil)
                return true
            }
            return false
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
