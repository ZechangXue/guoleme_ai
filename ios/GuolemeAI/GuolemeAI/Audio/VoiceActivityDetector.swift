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

    func flush() {
        guard !buffers.isEmpty else { return }
        let combined = buffers.reduce(into: Data()) { $0.append($1) }
        buffers.removeAll()
        lastVoiceTime = Date().timeIntervalSince1970
        onSegment?(combined)
    }
}
