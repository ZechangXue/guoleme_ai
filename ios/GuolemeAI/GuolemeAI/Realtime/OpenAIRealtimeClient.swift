import Foundation

final class OpenAIRealtimeClient {
    var onChunk: ((AssistStreamChunk) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var mic: MicCapture?
    private let parser = StreamingJSONParser()
    private var running = false
    private var receiveLoopActive = false

    func start(apiKey: String, model: String, instructions: String) {
        stop()
        running = true
        parser.reset()

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else {
            onError?("Invalid Realtime URL")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoopActive = true
        listen()

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["text"],
                "instructions": instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "turn_detection": [
                            "type": "server_vad",
                            "silence_duration_ms": 700,
                            "threshold": 0.5,
                            "create_response": true
                        ]
                    ]
                ]
            ]
        ]
        send(payload)
        startMic()
    }

    func stop() {
        running = false
        receiveLoopActive = false
        mic?.stop()
        mic = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func updateInstructions(_ instructions: String) {
        guard running else { return }
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions
            ]
        ])
    }

    private func startMic() {
        let capture = MicCapture(sampleRate: AppConstants.realtimeSampleRate)
        capture.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }
        capture.onPCM = { [weak self] data in
            guard let self, self.running else { return }
            self.send([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString()
            ])
        }
        do {
            try capture.start()
            mic = capture
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self, self.receiveLoopActive else { return }
            switch result {
            case .failure(let error):
                if self.running {
                    self.onError?(error.localizedDescription)
                }
            case .success(let message):
                self.handle(message)
                if self.receiveLoopActive {
                    self.listen()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let raw: String
        switch message {
        case .string(let text): raw = text
        case .data(let data): raw = String(data: data, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "error" {
            let err = obj["error"] as? [String: Any]
            onError?((err?["message"] as? String) ?? "Realtime error")
            return
        }

        if type == "input_audio_buffer.speech_started" {
            parser.userTranscriptTurn = ""
        }

        if type == "conversation.item.input_audio_transcription.delta",
           let delta = obj["delta"] as? String {
            parser.userTranscriptTurn += delta
        }

        if type == "conversation.item.input_audio_transcription.completed" {
            let t = (obj["transcript"] as? String) ?? (obj["text"] as? String) ?? ""
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parser.userTranscriptTurn = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if type == "response.created" {
            parser.reset()
        }

        if ["response.text.delta", "response.output_text.delta", "response.content_part.delta"].contains(type) {
            let delta = extractDelta(obj)
            if let partial = parser.appendDelta(delta) {
                onChunk?(AssistStreamChunk(partial: partial, done: false, interviewerTranscript: nil))
            }
        }

        if ["response.text.done", "response.output_text.done", "response.content_part.done", "response.done"].contains(type) {
            let finalText = extractFinal(obj)
            if let partial = parser.finish(finalText: finalText.isEmpty ? nil : finalText) {
                let tr = parser.userTranscriptTurn.trimmingCharacters(in: .whitespacesAndNewlines)
                onChunk?(AssistStreamChunk(
                    partial: partial,
                    done: true,
                    interviewerTranscript: tr.isEmpty ? nil : tr
                ))
            }
        }
    }

    private func extractDelta(_ obj: [String: Any]) -> String {
        if let delta = obj["delta"] as? String { return delta }
        if let delta = obj["delta"] as? [String: Any], let text = delta["text"] as? String { return text }
        if let text = obj["text"] as? String { return text }
        return ""
    }

    private func extractFinal(_ obj: [String: Any]) -> String {
        if let text = obj["text"] as? String { return text }
        guard let response = obj["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else { return "" }
        var texts: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let text = part["text"] as? String { texts.append(text) }
                else if let t = part["transcript"] as? String { texts.append(t) }
            }
        }
        return texts.joined()
    }
}
