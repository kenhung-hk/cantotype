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
            // 鍵盤 extension 一般唔准開 URL；試一下，唔得就叫用戶自己開 app
            guard let self, let url = URL(string: "cantotype://record") else { return false }
            var responder: UIResponder? = self
            while let current = responder {
                if let application = current as? UIApplication {
                    application.open(url)
                    return true
                }
                responder = current.next
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

        let height = view.heightAnchor.constraint(equalToConstant: 268)
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
