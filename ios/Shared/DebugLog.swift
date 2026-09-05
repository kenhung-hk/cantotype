import Foundation

/// 寫入 App Group container 嘅簡單 log（app 同鍵盤共用），方便由 Mac 用 devicectl 拉返嚟查問題。
/// 路徑：<group container>/Library/Caches/cantotype.log
enum DebugLog {
    private static let queue = DispatchQueue(label: "cantotype.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RemoteConfig.appGroup) else { return nil }
        let dir = container.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cantotype.log")
    }

    static func log(_ source: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(source)] \(message)\n"
        NSLog("CantoType %@", line.trimmingCharacters(in: .newlines))
        queue.async {
            guard let url = fileURL else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
            // 太大就砍
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 400_000 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
