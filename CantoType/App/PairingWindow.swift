import AppKit
import SwiftUI

/// Menubar「iPhone 配對 QR…」彈出嘅視窗：大 QR + 網址 + token。
@MainActor
final class PairingWindowController {
    private weak var state: AppState?
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        guard let state else { return }
        if window == nil {
            let host = NSHostingController(rootView: PairingView().environmentObject(state.settings).environmentObject(state.sidecar))
            let window = NSWindow(contentViewController: host)
            window.title = "iPhone 配對"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 460, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PairingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sidecar: MLXSidecar
    @State private var tailscale = TailscaleInfo.Result()
    @State private var copied = ""

    private var port: Int { URL(string: settings.httpURL)?.port ?? 8787 }
    private var url: String { "http://\(tailscale.dnsName ?? tailscale.ip ?? "<Tailscale IP>"):\(port)" }
    private var ipURL: String? { tailscale.ip.map { "http://\($0):\(port)" } }

    var body: some View {
        VStack(spacing: 16) {
            if !settings.remoteAccess {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("遠端存取未開").font(.title3).bold()
                    Text("要俾 iPhone 經 Tailscale 連入呢部 Mac，先要開放伺服器（會 bind 所有網絡介面並要求 token）。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("開啟遠端存取") { settings.remoteAccess = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 40)
            } else {
                Text("用 iPhone 上嘅 CantoType app → 設定 → 「掃描 Mac 嘅 QR code」")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if tailscale.ip == nil {
                    Label("偵測唔到 Tailscale IP，Tailscale 有冇開？", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let cg = TailscaleInfo.qrImage(url: url, token: settings.remoteToken) {
                    Image(decorative: cg, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 300, height: 300)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    row("網址", url)
                    if let ipURL, ipURL != url { row("IP 網址", ipURL) }
                    row("Token", settings.remoteToken)
                    HStack {
                        Text("伺服器").frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                        Text(sidecar.summary).font(.callout)
                    }
                }
                .font(.callout.monospaced())
                if !copied.isEmpty { Text(copied).font(.caption).foregroundStyle(.green) }
                Text("iPhone 同 Mac 都要登入同一個 Tailscale 帳戶並開住。掃唔到就喺 iPhone app 手動輸入網址同 token。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 620)
        .onAppear { tailscale = TailscaleInfo.detect() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("複製") {
                TextInserter.copy(value)
                copied = "已複製\(label)"
            }
            .controlSize(.small)
        }
    }
}
