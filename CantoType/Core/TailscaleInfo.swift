import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 搵出呢部 Mac 喺 Tailscale 上嘅 IP 同 MagicDNS 名，畀 iOS app 連入。
enum TailscaleInfo {
    struct Result {
        var ip: String?
        var dnsName: String?
        var hostName: String?
    }

    static func detect() -> Result {
        var result = Result()
        let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.isExecutableFile(atPath: cli), let json = run(cli, ["status", "--json"]),
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let me = object["Self"] as? [String: Any] {
            result.ip = (me["TailscaleIPs"] as? [String])?.first { $0.contains(".") }
            if let dns = me["DNSName"] as? String { result.dnsName = dns.hasSuffix(".") ? String(dns.dropLast()) : dns }
            result.hostName = me["HostName"] as? String
        }
        if result.ip == nil, let ifconfig = run("/sbin/ifconfig", []) {
            // Tailscale 用 CGNAT 100.64.0.0/10
            let pattern = #"inet (100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+)"#
            if let match = ifconfig.range(of: pattern, options: .regularExpression) {
                result.ip = String(ifconfig[match]).replacingOccurrences(of: "inet ", with: "")
            }
        }
        return result
    }

    /// iOS app 掃嘅 QR：{"url": "...", "token": "..."}
    static func qrImage(url: String, token: String) -> CGImage? {
        let payload: [String: String] = ["url": url, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
