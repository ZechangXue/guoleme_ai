import Foundation

enum LLMError: LocalizedError {
    case missingKey
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey: return "未配置 API Key"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .empty: return "模型返回为空"
        }
    }
}

final class LLMClient {
    func testConnection(provider: ApiProvider, apiKey: String, model: String) async throws {
        if provider == .google {
            _ = try await geminiGenerate(apiKey: apiKey, model: model, system: "Reply with JSON {\"ok\":true}", user: "ping", json: true)
            return
        }
        _ = try await chatCompletion(
            provider: provider,
            apiKey: apiKey,
            model: model,
            messages: [
                ["role": "user", "content": "Reply with the single word pong."]
            ],
            json: false,
            stream: false,
            maxTokens: 64
        )
    }

    func streamAssist(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        systemContent: String,
        onChunk: @escaping (AssistStreamChunk) -> Void
    ) async throws {
        try await streamJSON(provider: provider, apiKey: apiKey, model: model, system: systemContent, onChunk: onChunk)
    }

    func readableAnswer(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        systemContent: String
    ) async throws -> AssistJSON {
        let raw = try await completeJSON(provider: provider, apiKey: apiKey, model: model, system: systemContent)
        return decodeAssist(raw)
    }

    func translateAnswersToChinese(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        assist: AssistJSON
    ) async throws -> AssistJSON {
        let payload: [String: String] = [
            "question_zh": assist.questionZh ?? "",
            "concise_answer_en": assist.conciseAnswerEn ?? "",
            "expanded_answer_en": assist.expandedAnswerEn ?? ""
        ]
        let raw = try await completeJSON(
            provider: provider,
            apiKey: apiKey,
            model: model,
            system: PromptCatalog.answerTranslateZh,
            user: String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
        )
        var next = assist
        let decoded = decodeAssist(raw)
        if let q = decoded.questionZh, !q.isEmpty { next.questionZh = q }
        if let c = decoded.conciseAnswerEn, !c.isEmpty { next.conciseAnswerEn = c }
        if let e = decoded.expandedAnswerEn, !e.isEmpty { next.expandedAnswerEn = e }
        return next
    }

    func streamPlain(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        system: String,
        user: String,
        onDelta: @escaping (String, Bool) -> Void
    ) async throws {
        if provider == .google {
            let text = try await geminiGenerate(apiKey: apiKey, model: model, system: system, user: user, json: false)
            onDelta(text, true)
            return
        }
        try await streamChatSSE(
            provider: provider,
            apiKey: apiKey,
            model: model,
            body: {
                var body: [String: Any] = [
                    "model": model,
                    "stream": true,
                    "messages": [
                        ["role": "system", "content": system],
                        ["role": "user", "content": user]
                    ]
                ]
                ProviderConfig.applyOpenAIChatParams(to: &body, model: model, temperature: 0.3)
                return body
            }()
        ) { delta, done in
            onDelta(delta, done)
        }
    }

    func completePlain(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        system: String,
        user: String,
        maxTokens: Int = 2500
    ) async throws -> String {
        if provider == .google {
            return try await geminiGenerate(apiKey: apiKey, model: model, system: system, user: user, json: false)
        }
        return try await chatCompletion(
            provider: provider,
            apiKey: apiKey,
            model: model,
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            json: false,
            stream: false,
            maxTokens: maxTokens
        )
    }

    func sessionSummary(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        transcript: String
    ) async throws -> String {
        let user = "以下为本次面试多轮实录。每轮中「面试官原话」来自语音转写（可能为中英混说或口误），「卡片题摘要」为模型提炼的中文要点；「英文回答」为提词卡上的极简一句与展开。请仅根据这些内容输出中文复盘总结：\n\n\(transcript)"
        if provider == .google {
            return try await geminiGenerate(apiKey: apiKey, model: model, system: PromptCatalog.sessionSummary, user: user, json: false)
        }
        return try await chatCompletion(
            provider: provider,
            apiKey: apiKey,
            model: model,
            messages: [
                ["role": "system", "content": PromptCatalog.sessionSummary],
                ["role": "user", "content": user]
            ],
            json: false,
            stream: false
        )
    }

    func assistFromImage(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        systemContent: String,
        imageJPEG: Data,
        onChunk: @escaping (AssistStreamChunk) async -> Void
    ) async throws {
        let b64 = imageJPEG.base64EncodedString()
        if provider == .google {
            let raw = try await geminiImage(apiKey: apiKey, model: model, system: systemContent, jpegBase64: b64)
            let assist = decodeAssist(raw).fillingMissingAnswers()
            await onChunk(AssistStreamChunk(partial: assist, done: true, interviewerTranscript: nil))
            return
        }

        let parser = StreamingJSONParser()
        try await streamChatSSE(
            provider: provider,
            apiKey: apiKey,
            model: model,
            body: {
                var body: [String: Any] = [
                    "model": model,
                    "stream": true,
                    "response_format": ["type": "json_object"],
                    "messages": [
                        ["role": "system", "content": systemContent],
                        [
                            "role": "user",
                            "content": [
                                ["type": "text", "text": PromptCatalog.imageQuestion],
                                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "high"]]
                            ]
                        ]
                    ]
                ]
                ProviderConfig.applyOpenAIChatParams(to: &body, model: model, temperature: 0.2, maxTokens: 4000)
                return body
            }(),
            timeout: 180
        ) { [self] delta, done in
            if !delta.isEmpty, let partial = parser.appendDelta(delta) {
                await onChunk(AssistStreamChunk(partial: partial, done: false, interviewerTranscript: nil))
            }
            if done {
                if let finished = parser.finish() {
                    await onChunk(AssistStreamChunk(partial: finished.fillingMissingAnswers(), done: true, interviewerTranscript: nil))
                } else {
                    await onChunk(AssistStreamChunk(partial: self.decodeAssist(parser.rawText).fillingMissingAnswers(), done: true, interviewerTranscript: nil))
                }
            }
        }
    }

    /// Streams a system + user chat (optionally with an image) and returns the full text.
    /// Gemini is not streamed: its full answer arrives as one delta.
    @discardableResult
    func streamText(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        system: String,
        user: String,
        imageJPEGBase64: String? = nil,
        json: Bool,
        maxTokens: Int,
        onDelta: @escaping (String) async -> Void
    ) async throws -> String {
        if provider == .google {
            var parts: [[String: Any]] = [["text": user]]
            if let imageJPEGBase64 {
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": imageJPEGBase64]])
            }
            let text = try await geminiGenerateParts(apiKey: apiKey, model: model, system: system, parts: parts, json: json, maxTokens: maxTokens)
            await onDelta(text)
            return text
        }

        let userContent: Any
        if let imageJPEGBase64 {
            let parts: [[String: Any]] = [
                ["type": "text", "text": user],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageJPEGBase64)", "detail": "high"]]
            ]
            userContent = parts
        } else {
            userContent = user
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent]
            ]
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        ProviderConfig.applyOpenAIChatParams(to: &body, model: model, temperature: 0.3, maxTokens: maxTokens)

        var full = ""
        try await streamChatSSE(provider: provider, apiKey: apiKey, model: model, body: body, timeout: 120) { delta, _ in
            guard !delta.isEmpty else { return }
            full += delta
            await onDelta(delta)
        }
        return full
    }

    /// Non-streaming JSON completion parsed into a dictionary (empty if the model returned no object).
    func completeJSONObject(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        system: String,
        user: String,
        maxTokens: Int
    ) async throws -> [String: Any] {
        let raw: String
        if provider == .google {
            raw = try await geminiGenerateParts(apiKey: apiKey, model: model, system: system, parts: [["text": user]], json: true, maxTokens: maxTokens)
        } else {
            raw = try await chatCompletion(
                provider: provider,
                apiKey: apiKey,
                model: model,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ],
                json: true,
                stream: false,
                maxTokens: maxTokens
            )
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
              let data = String(trimmed[start...end]).data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func geminiGenerateParts(
        apiKey: String,
        model: String,
        system: String,
        parts: [[String: Any]],
        json: Bool,
        maxTokens: Int
    ) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var generation: [String: Any] = ["temperature": 0.3, "maxOutputTokens": maxTokens]
        if json { generation["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": parts]],
            "generationConfig": generation
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return extractGeminiText(data)
    }

    private func streamJSON(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        system: String,
        onChunk: @escaping (AssistStreamChunk) -> Void
    ) async throws {
        if provider == .google {
            let raw = try await geminiGenerate(apiKey: apiKey, model: model, system: system, user: "Return JSON only.", json: true)
            let parser = StreamingJSONParser()
            if let partial = parser.finish(finalText: raw) {
                onChunk(AssistStreamChunk(partial: partial, done: true, interviewerTranscript: nil))
            }
            return
        }

        let parser = StreamingJSONParser()
        try await streamChatSSE(
            provider: provider,
            apiKey: apiKey,
            model: model,
            body: {
                var body: [String: Any] = [
                    "model": model,
                    "stream": true,
                    "response_format": ["type": "json_object"],
                    "messages": [["role": "system", "content": system]]
                ]
                ProviderConfig.applyOpenAIChatParams(to: &body, model: model, temperature: 0.2, maxTokens: 1000)
                return body
            }()
        ) { delta, done in
            if !delta.isEmpty, let partial = parser.appendDelta(delta) {
                onChunk(AssistStreamChunk(partial: partial, done: false, interviewerTranscript: nil))
            }
            if done, let partial = parser.finish() {
                onChunk(AssistStreamChunk(partial: partial, done: true, interviewerTranscript: nil))
            }
        }
    }

    private func completeJSON(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        system: String,
        user: String? = nil
    ) async throws -> String {
        if provider == .google {
            return try await geminiGenerate(apiKey: apiKey, model: model, system: system, user: user ?? "Return JSON only.", json: true)
        }
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        if let user {
            messages.append(["role": "user", "content": user])
        }
        return try await chatCompletion(
            provider: provider,
            apiKey: apiKey,
            model: model,
            messages: messages,
            json: true,
            stream: false
        )
    }

    private func chatCompletion(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        json: Bool,
        stream: Bool,
        maxTokens: Int? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        ProviderConfig.applyOpenAIChatParams(
            to: &body,
            model: model,
            temperature: 0.2,
            maxTokens: maxTokens
        )
        let url = ProviderConfig.chatBaseURL(for: provider).appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = obj?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String, !content.isEmpty else {
            throw LLMError.empty
        }
        return content
    }

    private func streamChatSSE(
        provider: ApiProvider,
        apiKey: String,
        model: String,
        body: [String: Any],
        timeout: TimeInterval = 90,
        onDelta: @escaping (String, Bool) async -> Void
    ) async throws {
        let url = ProviderConfig.chatBaseURL(for: provider).appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var err = ""
            for try await line in bytes.lines {
                err += line
                if err.count > 2500 { break }
            }
            throw LLMError.http(code, err.isEmpty ? "stream failed" : err)
        }

        var finished = false
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    if !finished {
                        finished = true
                        await onDelta("", true)
                    }
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }
                let text = delta["content"] as? String ?? ""
                let done = choices.first?["finish_reason"] != nil && !(choices.first?["finish_reason"] is NSNull)
                if !text.isEmpty || done {
                    await onDelta(text, done)
                }
                if done { finished = true }
            }
        }
        if !finished {
            await onDelta("", true)
        }
    }

    private func geminiGenerate(apiKey: String, model: String, system: String, user: String, json: Bool) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var generation: [String: Any] = ["temperature": 0.2]
        if json {
            generation["responseMimeType"] = "application/json"
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]],
            "generationConfig": generation
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return extractGeminiText(data)
    }

    private func geminiImage(apiKey: String, model: String, system: String, jpegBase64: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [[
                "parts": [
                    ["text": PromptCatalog.imageQuestion],
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpegBase64]]
                ]
            ]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 4096, "responseMimeType": "application/json"]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return extractGeminiText(data)
    }

    private func extractGeminiText(_ data: Data) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let candidates = obj?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private func decodeAssist(_ raw: String) -> AssistJSON {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let obj = try? JSONDecoder().decode(AssistJSON.self, from: data) {
            return obj.fillingMissingAnswers()
        }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
           let data = String(trimmed[start...end]).data(using: .utf8),
           let obj = try? JSONDecoder().decode(AssistJSON.self, from: data) {
            return obj.fillingMissingAnswers()
        }
        if let data = trimmed.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return AssistJSON(
                questionZh: dict["question_zh"] as? String,
                conciseAnswerEn: dict["concise_answer_en"] as? String,
                expandedAnswerEn: dict["expanded_answer_en"] as? String,
                keywordsEn: (dict["keywords_en"] as? [Any])?.map { String(describing: $0) } ?? [],
                thinkingZh: dict["thinking_zh"] as? String
            ).fillingMissingAnswers()
        }
        return AssistJSON()
    }
}
