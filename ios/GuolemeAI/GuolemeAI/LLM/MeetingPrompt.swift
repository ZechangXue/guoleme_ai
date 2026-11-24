import Foundation

/// Meeting answer-card prompts. Same layout as the desktop app: the stable part (profile, documents,
/// scene, this week, past meetings) goes into the system prompt so provider prompt caching can hit;
/// the dynamic part (trigger, earlier cards, live transcript, latest utterance) goes into the user message.
enum MeetingPrompt {
    static let docMaxChars = 120_000
    /// Cap for "This week" so an imported weekly-report PDF doesn't bloat every card prompt.
    static let weeklyNotesMaxChars = 30_000

    static func languageName(_ language: AnswerLanguage) -> String {
        language == .zh ? "Simplified Chinese" : "English"
    }

    static func fill(_ template: String, language: AnswerLanguage) -> String {
        template.replacingOccurrences(of: "{{ANSWER_LANGUAGE}}", with: languageName(language))
    }

    static func sceneInstructions(_ scene: MeetingScene) -> String {
        switch scene {
        case .weekly:
            return """
            Weekly internal team progress meeting. Participants share what they did since the last meeting, discuss results, blockers and priorities.
            Expect follow-ups on my update: progress, concrete results and numbers, why I did something, blockers, timelines and next steps. Use [THIS WEEK] first, then [PAST MEETINGS] for continuity.
            """
        case .project:
            return """
            Internal discussion of a new project, feature or technical approach.
            Expect "how would we do X", option comparisons, feasibility, effort and cost questions. Give a clear recommendation, then: feasibility for our small team, compute / cloud cost, fit with our existing architecture and data, validation needed, risks, and a concrete first step. Clearly label ideas as proposals.
            """
        case .partner:
            return """
            Technical meeting with an EXTERNAL partner or collaborator (not my internal team).
            Confidentiality: do not volunteer internal cloud costs, budgets, pricing, unreleased product plans, IP / patent details, unpublished results, team size or hiring issues, or internal disagreements. If asked about them, give a polite, non-committal answer and explain why in caution_zh.
            Use a slightly more formal tone. Emphasise validated, demonstrable capabilities; never overstate maturity or clinical validation.
            """
        case .interviewer:
            return """
            SCENE OVERRIDE — I am the INTERVIEWER assessing a candidate; the live speech is mostly the candidate.
            Do NOT answer as a candidate. Reinterpret the output fields:
            - question_zh: 候选人刚才在说什么 / 回答了什么（中文一句）
            - q_type: "other"
            - opener_en: the single best follow-up question I should ask next
            - points_en: 3 short things to probe or listen for (gaps, vague claims, depth, ownership, end-to-end ability)
            - concise_answer_en: my quick private assessment of that answer (strengths / concerns) — not to be said aloud
            - expanded_answer_en: 2-3 further follow-up questions, deeper or more practical
            - source: which part of the profile / role requirements this relates to
            - caution_zh: 需要留意的红旗或核实点
            Only use "无法确定问题" for pure noise.
            """
        }
    }

    static func truncate(_ text: String, _ max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "\n[... truncated ...]"
    }

    /// Meeting / project documents plus personal docs (resume, notes). The JD is left out.
    static func projectDocsBlock(files: [ContextFile], maxChars: Int = docMaxChars) -> String {
        let order: [ContextDocType] = [.meetingDoc, .projectNotes, .resume, .qaNotes]
        var parts: [String] = []
        for type in order {
            for file in files where file.docType == type {
                let text = file.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                parts.append("=== \(file.docType.promptLabel): \(file.fileName) ===\n\(text)")
            }
        }
        if parts.isEmpty { return "(none uploaded)" }
        return truncate(parts.joined(separator: "\n\n"), maxChars)
    }

    static func personaBlock(_ state: MeetingProfileState, maxChars: Int? = nil) -> String {
        let persona = state.personaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if persona.isEmpty { return "(not provided — rely on the documents)" }
        if let maxChars { return truncate(persona, maxChars) }
        return persona
    }

    static func thisWeekBlock(_ state: MeetingProfileState) -> String {
        let notes = state.weeklyNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = (state.prep?.updateScript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty && script.isEmpty { return "(no notes for this week)" }
        var parts: [String] = []
        if !notes.isEmpty { parts.append("My notes (raw, may be Chinese):\n\(truncate(notes, weeklyNotesMaxChars))") }
        if !script.isEmpty { parts.append("My prepared spoken update:\n\(script)") }
        return parts.joined(separator: "\n\n")
    }

    static func pastMeetingsBlock(_ sessions: [MeetingSession]) -> String {
        if sessions.isEmpty { return "(none yet)" }
        return sessions.map { s in
            var block = "--- \(dateString(s.startedAt)) · \(s.scene.labelZh) ---\n\(s.digestZh ?? "")"
            let commitments = s.commitments ?? []
            if !commitments.isEmpty {
                block += "\nMy commitments: " + commitments.map { "- \($0)" }.joined(separator: "\n")
            }
            return block
        }.joined(separator: "\n\n")
    }

    static func systemPrompt(
        state: MeetingProfileState,
        files: [ContextFile],
        scene: MeetingScene,
        language: AnswerLanguage,
        pastSessions: [MeetingSession]
    ) -> String {
        """
        \(PromptCatalog.meetingAssistSystem)

        ====================
        [MY PROFILE]
        \(personaBlock(state))

        ====================
        [PROJECT DOCUMENTS]
        \(projectDocsBlock(files: files))

        ====================
        [MEETING TYPE] \(scene.labelZh)
        \(sceneInstructions(scene))

        ====================
        [THIS WEEK]
        \(thisWeekBlock(state))

        ====================
        [PAST MEETINGS]
        \(pastMeetingsBlock(pastSessions))

        ====================
        \(fill(PromptCatalog.meetingAssistOutput, language: language))
        """
    }

    static func triggerText(_ kind: MeetingTriggerKind) -> String {
        switch kind {
        case .auto:
            return "auto — a question was detected in the live speech. Answer only if it is something I am expected to respond to."
        case .mention:
            return "mention — my name or a direct cue to me was heard. Answer what I am being asked."
        case .manual:
            return "manual — I pressed \"answer now\". Always answer the most recent question or topic, even if it was not addressed to me."
        case .screenshot:
            return "screenshot — I captured the screen (slides, chat or shared doc). Treat the image as the current question / topic and answer it."
        }
    }

    static func userPrompt(
        trigger: MeetingTriggerKind,
        earlierCards: [MeetingSessionCard],
        transcript: [MeetingTranscriptLine],
        utterance: String
    ) -> String {
        let now = Date().timeIntervalSince1970
        let cards = earlierCards.suffix(4)
        let cardsBlock = cards.isEmpty
            ? "(none)"
            : cards.map { "Q: \($0.questionZh)\nMy answer: \($0.answer)" }.joined(separator: "\n\n")
        let transcriptBlock = transcript.isEmpty
            ? "(no transcript yet)"
            : transcript.map { "[\(ago(now - $0.at))] \($0.text)" }.joined(separator: "\n")
        let latest = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        [TRIGGER] \(triggerText(trigger))

        [EARLIER IN THIS MEETING — answer cards I was shown]
        \(cardsBlock)

        [LIVE TRANSCRIPT — other participants, oldest first]
        \(transcriptBlock)

        [LATEST UTTERANCE]
        \(latest.isEmpty ? "(see transcript / image)" : latest)
        """
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d ago", s / 60, s % 60)
    }

    static func dateString(_ ts: TimeInterval, withTime: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = withTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - Streaming parser for the meeting card JSON

enum MeetingCardParser {
    struct Result {
        var card: MeetingCard
        /// True once the "question_zh" string has been fully received.
        var questionComplete: Bool
    }

    private static let stringFields = [
        "question_zh", "q_type", "opener_en", "concise_answer_en", "expanded_answer_en", "source", "caution_zh"
    ]

    /// Parses a possibly-incomplete JSON object streamed from the model.
    static func parse(_ raw: String) -> Result {
        var values: [String: String] = [:]
        var questionComplete = false
        for field in stringFields {
            if let (value, complete) = stringField(field, in: raw) {
                values[field] = value
                if field == "question_zh" { questionComplete = complete }
            }
        }
        var card = MeetingCard()
        card.questionZh = values["question_zh"] ?? ""
        card.qType = values["q_type"] ?? ""
        card.opener = values["opener_en"] ?? ""
        card.concise = values["concise_answer_en"] ?? ""
        card.expanded = values["expanded_answer_en"] ?? ""
        card.source = values["source"] ?? ""
        card.caution = values["caution_zh"] ?? ""
        card.points = stringArray("points_en", in: raw)
        return Result(card: card, questionComplete: questionComplete)
    }

    /// Parses the finished response; falls back to the streaming parser if it is not valid JSON.
    static func parseFinal(_ raw: String) -> MeetingCard {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
           let data = String(trimmed[start...end]).data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            func str(_ key: String) -> String {
                (dict[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var card = MeetingCard()
            card.questionZh = str("question_zh")
            card.qType = str("q_type")
            card.opener = str("opener_en")
            card.concise = str("concise_answer_en")
            card.expanded = str("expanded_answer_en")
            card.source = str("source")
            card.caution = str("caution_zh")
            if let arr = dict["points_en"] as? [Any] {
                card.points = arr.map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            } else if let one = dict["points_en"] as? String, !one.isEmpty {
                card.points = one.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            return card
        }
        return parse(raw).card
    }

    /// Finds `"name": "..."` and returns the decoded (possibly partial) value and whether it is complete.
    private static func stringField(_ name: String, in raw: String) -> (String, Bool)? {
        guard let valueStart = valueStart(of: name, opening: "\"", in: raw) else { return nil }
        let (value, end) = readString(raw, from: valueStart)
        return (value, end != nil)
    }

    private static func stringArray(_ name: String, in raw: String) -> [String] {
        guard var i = valueStart(of: name, opening: "[", in: raw) else { return [] }
        var items: [String] = []
        while i < raw.endIndex {
            let c = raw[i]
            if c == "]" { break }
            if c == "\"" {
                let (value, end) = readString(raw, from: raw.index(after: i))
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { items.append(trimmed) }
                guard let end else { break }
                i = raw.index(after: end)
                continue
            }
            i = raw.index(after: i)
        }
        return items
    }

    /// Index just after the opening character of the field's value, e.g. after `"name": "`.
    private static func valueStart(of name: String, opening: Character, in raw: String) -> String.Index? {
        guard let keyRange = raw.range(of: "\"\(name)\"") else { return nil }
        var i = keyRange.upperBound
        var sawColon = false
        while i < raw.endIndex {
            let c = raw[i]
            if c == ":" && !sawColon {
                sawColon = true
            } else if c == opening && sawColon {
                return raw.index(after: i)
            } else if !c.isWhitespace {
                return nil
            }
            i = raw.index(after: i)
        }
        return nil
    }

    /// Reads a JSON string body starting after its opening quote. Returns the decoded text and the
    /// index of the closing quote (nil if the string is still incomplete).
    private static func readString(_ raw: String, from start: String.Index) -> (String, String.Index?) {
        var out = ""
        var i = start
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\"" { return (out, i) }
            if c == "\\" {
                let next = raw.index(after: i)
                guard next < raw.endIndex else { return (out, nil) }
                switch raw[next] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": break
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "u":
                    let hexStart = raw.index(after: next)
                    guard let hexEnd = raw.index(hexStart, offsetBy: 4, limitedBy: raw.endIndex),
                          hexEnd <= raw.endIndex else { return (out, nil) }
                    if let code = UInt32(raw[hexStart..<hexEnd], radix: 16), let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                    }
                    i = hexEnd
                    continue
                default: out.append(raw[next])
                }
                i = raw.index(after: next)
                continue
            }
            out.append(c)
            i = raw.index(after: i)
        }
        return (out, nil)
    }
}
