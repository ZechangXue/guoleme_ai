import AVFoundation
import Foundation

final class MicCapture {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Double) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isRunning = false
    private var lastLevelEmit: TimeInterval = 0
    private let targetSampleRate: Double

    init(sampleRate: Double) {
        self.targetSampleRate = sampleRate
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setPreferredSampleRate(targetSampleRate)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "麦克风格式不可用"])
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
        converter = AVAudioConverter(from: format, to: targetFormat)
        outputFormat = targetFormat
        if converter == nil {
            let alt = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )!
            converter = AVAudioConverter(from: format, to: alt)
            outputFormat = alt
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let dest = outputFormat, let data = convert(buffer, to: dest), !data.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if now - lastLevelEmit >= 0.1 {
            lastLevelEmit = now
            onLevel?(Self.rms(data))
        }
        onPCM?(data)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> Data? {
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatInt16 {
            return pcmData(from: buffer)
        }
        guard let converter else { return pcmData(from: buffer) }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let outCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }
        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        if error != nil || out.frameLength == 0 { return pcmData(from: buffer) }
        return pcmData(from: out)
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0, channels > 0 else { return nil }

        if buffer.format.commonFormat == .pcmFormatInt16 {
            if let ptr = buffer.int16ChannelData {
                if buffer.format.isInterleaved {
                    return Data(bytes: ptr[0], count: frames * channels * MemoryLayout<Int16>.size)
                }
                var mono = [Int16](repeating: 0, count: frames)
                for i in 0..<frames {
                    var sum = 0
                    for c in 0..<channels {
                        sum += Int(ptr[c][i])
                    }
                    mono[i] = Int16(sum / channels)
                }
                return mono.withUnsafeBytes { Data($0) }
            }
            let byteCount = Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize)
            guard let mData = buffer.audioBufferList.pointee.mBuffers.mData, byteCount > 0 else { return nil }
            return Data(bytes: mData, count: byteCount)
        }

        guard let ptr = buffer.floatChannelData else { return nil }
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                sum += ptr[c][i]
            }
            let v = max(-1, min(1, sum / Float(channels)))
            samples[i] = Int16((v * Float(Int16.max)).rounded())
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    static func rms(_ data: Data) -> Double {
        if data.isEmpty { return 0 }
        let count = data.count / 2
        var sum = 0.0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                sum += abs(Double(samples[i])) / 32768.0
            }
        }
        return sum / Double(max(count, 1))
    }
}
