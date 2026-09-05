import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "搵唔到麥克風，或者未授權"
        }
    }
}

/// 用 AVAudioEngine 錄音，即時轉成 16 kHz 單聲道 Int16。
final class AudioRecorder {
    /// 0…1 嘅音量，喺 audio thread 回傳。
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat = AudioClip.format
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> AudioClip {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let captured = samples
        lock.unlock()
        return AudioClip(samples: captured, sampleRate: AudioClip.sampleRate)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channel = output.int16ChannelData else { return }

        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let pointer = UnsafeBufferPointer(start: channel[0], count: count)

        var sum: Float = 0
        for sample in pointer {
            let f = Float(sample) / 32768
            sum += f * f
        }
        let rms = sqrt(sum / Float(count))

        lock.lock()
        samples.append(contentsOf: pointer)
        lock.unlock()

        onLevel?(min(1, rms * 8))
    }
}
