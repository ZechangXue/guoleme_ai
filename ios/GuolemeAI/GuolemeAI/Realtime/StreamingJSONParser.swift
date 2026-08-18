import Foundation

final class StreamingJSONParser {
    private var accumulated = ""
    var rawText: String { accumulated }
    private var lastConciseLen = 0
    private var lastExpandedLen = 0
    private var emittedQuestion = false
    private var finalEmitted = false
    var userTranscriptTurn = ""

    func reset() {
        accumulated = ""
        lastConciseLen = 0
        lastExpandedLen = 0
        emittedQuestion = false
        finalEmitted = false
    }

    func appendDelta(_ delta: String) -> AssistJSON? {
        accumulated += delta
        return emit(done: false)
    }

    func finish(finalText: String? = nil) -> AssistJSON? {
        if finalEmitted { return nil }
        if let finalText, finalText.count > accumulated.count {
            accumulated = finalText
        }
        let result = emit(done: true)
        finalEmitted = true
        return result
    }

    private func emit(done: Bool) -> AssistJSON? {
        var partial = AssistJSON()
        var hasUpdate = false

        if !emittedQuestion, let value = completeStringField("question_zh", in: accumulated) {
            partial.questionZh = unescape(value)
            emittedQuestion = true
            hasUpdate = true
        }

        if let value = partialStringField("concise_answer_en", in: accumulated) {
            let val = unescape(value)
            if val.count > lastConciseLen {
                partial.conciseAnswerEn = val
                lastConciseLen = val.count
                hasUpdate = true
            }
        }

        if let value = partialStringField("expanded_answer_en", in: accumulated) {
            let val = unescape(value)
            if val.count > lastExpandedLen {
                partial.expandedAnswerEn = val
                lastExpandedLen = val.count
                hasUpdate = true
            }
        }

        if let value = partialStringField("thinking_zh", in: accumulated) {
            let val = unescape(value)
            if !val.isEmpty {
                partial.thinkingZh = val
                hasUpdate = true
            }
        }

        if done {
            if let json = extractObject(accumulated),
               let obj = try? JSONDecoder().decode(AssistJSON.self, from: json) {
                if let q = obj.questionZh { partial.questionZh = q.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let c = obj.conciseAnswerEn { partial.conciseAnswerEn = c.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let e = obj.expandedAnswerEn { partial.expandedAnswerEn = e.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let t = obj.thinkingZh { partial.thinkingZh = t.trimmingCharacters(in: .whitespacesAndNewlines) }
                if !obj.keywordsEn.isEmpty { partial.keywordsEn = obj.keywordsEn }
                let filled = AssistJSON(
                    questionZh: partial.questionZh,
                    conciseAnswerEn: partial.conciseAnswerEn,
                    expandedAnswerEn: partial.expandedAnswerEn,
                    keywordsEn: partial.keywordsEn,
                    thinkingZh: partial.thinkingZh
                ).fillingMissingAnswers()
                partial = filled
                hasUpdate = true
            } else if !hasUpdate {
                let answerText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                let transcript = userTranscriptTurn.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answerText.isEmpty, isLikelyActionable(transcript) {
                    let paragraphs = answerText.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    partial.questionZh = transcript.isEmpty ? "当前问题" : transcript
                    partial.conciseAnswerEn = paragraphs.first.map { String($0.prefix(220)) } ?? String(answerText.prefix(220))
                    partial.expandedAnswerEn = paragraphs.count > 1 ? paragraphs.joined(separator: "\n\n") : answerText
                    hasUpdate = true
                    emittedQuestion = true
                }
            }
        }

        if AppConstants.isNoiseOrUnrecognized(partial.questionZh) { return nil }
        if done, !userTranscriptTurn.isEmpty,
           !isLikelyActionable(userTranscriptTurn),
           !isLikelyActionable(partial.questionZh ?? "") {
            return nil
        }
        if !hasUpdate && !done { return nil }
        return partial
    }

    private func completeStringField(_ name: String, in raw: String) -> String? {
        let pattern = "\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        return firstCapture(pattern, in: raw)
    }

    private func partialStringField(_ name: String, in raw: String) -> String? {
        let pattern = "\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)"
        return firstCapture(pattern, in: raw)
    }

    private func firstCapture(_ pattern: String, in raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: raw) else { return nil }
        return String(raw[swiftRange])
    }

    private func extractObject(_ raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        return String(raw[start...end]).data(using: .utf8)
    }

    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    func isLikelyActionable(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }
        let nonQuestions = ["see you", "bye", "goodbye", "thanks", "thank you", "okay", "ok", "yeah", "yes", "no", "sure", "great", "sounds good", "go ahead", "please continue"]
        if nonQuestions.contains(s) { return false }
        if text.contains("?") || text.contains("？") { return true }
        if text.range(of: "什么|为什么|怎么|如何|哪个|哪些|是否|能否|介绍一下|描述一下|解释一下", options: .regularExpression) != nil {
            return true
        }
        return s.range(of: #"\b(what|why|how|when|where|which|who|can you|could you|would you|do you|tell me|describe|explain|walk me through|talk about|introduce|clarify|elaborate)\b"#, options: .regularExpression) != nil
    }
}
