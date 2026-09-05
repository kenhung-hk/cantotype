import AppKit
import CoreGraphics
import Foundation

/// 將文字放入剪貼簿，再模擬 ⌘V 貼到目前 focus 嘅 app。
@MainActor
enum TextInserter {
    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    static func paste(_ text: String, restoreClipboard: Bool) async {
        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? snapshot(of: pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postCommandV()

        if let snapshot {
            // 等目標 app 讀完剪貼簿先還原
            try? await Task.sleep(for: .milliseconds(400))
            restore(snapshot, to: pasteboard)
        }
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
