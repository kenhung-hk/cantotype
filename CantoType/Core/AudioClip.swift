import AVFoundation
import Foundation

/// 16 kHz、單聲道、Int16 PCM 嘅一段錄音。
struct AudioClip {
    let samples: [Int16]
    let sampleRate: Double

    static let sampleRate: Double = 16000
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    var duration: Double { Double(samples.count) / sampleRate }
    var isEmpty: Bool { samples.isEmpty }

    struct LevelStats {
        let peakDb: Float
        let rmsDb: Float
    }

    /// 峰值同 RMS（dBFS）。
    var stats: LevelStats {
        guard !samples.isEmpty else { return LevelStats(peakDb: -120, rmsDb: -120) }
        var peak: Float = 0
        var sum: Float = 0
        for sample in samples {
            let f = abs(Float(sample) / 32768)
            peak = max(peak, f)
            sum += f * f
        }
        let rms = sqrt(sum / Float(samples.count))
        return LevelStats(
            peakDb: 20 * log10(max(peak, 1e-6)),
            rmsDb: 20 * log10(max(rms, 1e-6))
        )
    }

    /// 細聲錄音自動增益到正常音量（最多 +maxGainDb），大聲嘅唔郁。
    func normalized(targetPeakDb: Float = -3, maxGainDb: Float = 30) -> AudioClip {
        let current = stats.peakDb
        guard current < targetPeakDb - 1 else { return self }
        let gainDb = min(targetPeakDb - current, maxGainDb)
        let gain = powf(10, gainDb / 20)
        let boosted = samples.map { Int16(clamping: Int32((Float($0) * gain).rounded())) }
        return AudioClip(samples: boosted, sampleRate: sampleRate)
    }

    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel[0].update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// 標準 44-byte header 嘅 WAV（PCM16 LE）。
    func wavData() -> Data {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)          // byte rate
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    /// 由任何 AVAudioFile 支援嘅檔案（wav／m4a／aiff…）載入並轉成 16k 單聲道。
    static func load(_ url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw TranscriptionError.emptyAudio }
        try file.read(into: source)
        let converted = try AudioConvert.convert(source, to: format)
        guard let channel = converted.int16ChannelData else { throw TranscriptionError.emptyAudio }
        let count = Int(converted.frameLength)
        return AudioClip(samples: Array(UnsafeBufferPointer(start: channel[0], count: count)), sampleRate: sampleRate)
    }
}

enum AudioConvert {
    /// 一次過將整個 buffer 轉成另一個格式。
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriptionError.backendUnavailable("音訊格式轉換失敗")
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.backendUnavailable("音訊格式轉換失敗")
        }
        var conversionError: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        if status == .error { throw TranscriptionError.backendUnavailable("音訊格式轉換失敗") }
        return output
    }
}
