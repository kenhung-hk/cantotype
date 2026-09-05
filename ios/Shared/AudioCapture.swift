import AVFoundation
import Foundation

enum CaptureError: LocalizedError {
    case sessionUnavailable(String)
    case noInput

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable(let reason): return "開唔到麥克風：\(reason)"
        case .noInput: return "冇麥克風輸入"
        }
    }
}

/// 錄音 → 16 kHz 單聲道 Int16 WAV（同 Mac 版一樣嘅格式）。
final class AudioCapture {
    /// 0…1 音量（對數刻度），喺 audio thread 回傳
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // 鍵盤 extension 冇麥克風權限時會落到呢度
            throw CaptureError.sessionUnavailable(error.localizedDescription)
        }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInput }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.sessionUnavailable(error.localizedDescription)
        }
        isRecording = true
    }

    /// 回傳 WAV 資料同秒數。
    func stop() -> (wav: Data, seconds: Double, peakDb: Float) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        let captured = samples
        lock.unlock()
        return (Self.wav(from: Self.normalized(captured)), Double(captured.count) / 16000, Self.peakDb(captured))
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let pointer = UnsafeBufferPointer(start: channel[0], count: count)
        var sum: Float = 0
        for sample in pointer {
            let f = Float(sample) / 32768
            sum += f * f
        }
        let db = 20 * log10(max(sqrt(sum / Float(count)), 1e-6))
        lock.lock()
        samples.append(contentsOf: pointer)
        lock.unlock()
        onLevel?(max(0, min(1, (db + 50) / 50)))
    }

    private static func peakDb(_ samples: [Int16]) -> Float {
        guard let peak = samples.map({ abs(Int32($0)) }).max(), peak > 0 else { return -120 }
        return 20 * log10(Float(peak) / 32768)
    }

    /// 細聲自動增益到 -3 dBFS（最多 +30 dB）
    private static func normalized(_ samples: [Int16]) -> [Int16] {
        let peak = peakDb(samples)
        guard peak < -4, peak > -120 else { return samples }
        let gain = powf(10, min(-3 - peak, 30) / 20)
        return samples.map { Int16(clamping: Int32((Float($0) * gain).rounded())) }
    }

    private static func wav(from samples: [Int16]) -> Data {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
