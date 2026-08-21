import Foundation

final class VoiceActivityDetector {
    var onSegment: ((Data) -> Void)?

    private let enterRms: Double
    private let exitRms: Double
    private let silenceMs: Double
    private var buffers: [Data] = []
    private var lastVoiceTime: TimeInterval = Date().timeIntervalSince1970
    private var voiceLatch = false

    init(enterRms: Double = 0.028, exitRms: Double = 0.012, silenceMs: Double = 1000) {
        self.enterRms = enterRms
        self.exitRms = exitRms
        self.silenceMs = silenceMs
    }

    func reset() {
        buffers.removeAll()
        voiceLatch = false
        lastVoiceTime = Date().timeIntervalSince1970
    }

    func ingest(_ chunk: Data) {
        let rms = MicCapture.rms(chunk)
        if rms >= enterRms {
            voiceLatch = true
        } else if rms <= exitRms {
            voiceLatch = false
        }

        let now = Date().timeIntervalSince1970
        if voiceLatch {
            buffers.append(chunk)
            lastVoiceTime = now
            return
        }

        let silentMs = (now - lastVoiceTime) * 1000
        if silentMs >= silenceMs, !buffers.isEmpty {
            flush()
        }
    }

    func flush() -> Data {
        guard !buffers.isEmpty else { return Data() }
        let segment = buffers.reduce(into: Data()) { $0.append($1) }
        buffers.removeAll()
        lastVoiceTime = Date().timeIntervalSince1970
        onSegment?(segment)
        return segment
    }
}

/// Thread-safe PCM accumulator for translate-summary (audio tap is not on the main thread).
final class TranslateAudioBuffer {
    private let lock = NSLock()
    private var pcm = Data()
    private let bytesPerSecond: Double
    let flushSeconds: Double

    init(maxSeconds: Double = AppConstants.translateFlushSeconds, sampleRate: Double = AppConstants.realtimeSampleRate) {
        self.flushSeconds = maxSeconds
        self.bytesPerSecond = max(sampleRate * 2, 1)
    }

    var durationSeconds: Double {
        lock.lock()
        let count = pcm.count
        lock.unlock()
        return Double(count) / bytesPerSecond
    }

    var reachedFlushLimit: Bool {
        durationSeconds >= flushSeconds
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        pcm.append(chunk)
        lock.unlock()
    }

    func takeAll() -> Data {
        lock.lock()
        let out = pcm
        pcm.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    func reset() {
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
