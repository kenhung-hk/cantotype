import AVFoundation
import Foundation

/// 背景常駐：app 開過一次之後，播一條無聲音軌保持 audio session 活躍，
/// 咁 Action Button 嘅 Intent 喺背景先可以即刻開麥克風（iOS 唔畀冷啟動嘅背景 app 開始錄音）。
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private(set) var isRunning = false
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            DebugLog.log("keepalive", "session failed: \(error.localizedDescription)")
            return
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000) else { return }
        silence.frameLength = 16000 // 1 秒靜音
        buffer = silence
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
        } catch {
            DebugLog.log("keepalive", "engine failed: \(error.localizedDescription)")
            return
        }
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
        isRunning = true
        DebugLog.log("keepalive", "started")
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if type == .ended {
                        DebugLog.log("keepalive", "interruption ended, restarting")
                        self.isRunning = false
                        self.start()
                    } else {
                        DebugLog.log("keepalive", "interrupted")
                    }
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        DebugLog.log("keepalive", "stopped")
    }
}
