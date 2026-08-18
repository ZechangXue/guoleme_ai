import Foundation

enum PromptBuilder {
    static func cap(_ raw: String?, max: Int) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "(none)" }
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return "\(s[..<idx])\n…[truncated \(s.count - max) chars]"
    }

    static func conversationBlock(_ summaries: [AnswerSummary]) -> String {
        let recent = summaries.suffix(3)
        if recent.isEmpty { return "(none)" }
        var lines: [String] = []
        for turn in recent {
            let concise = turn.conciseAnswerEn.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = (turn.expandedAnswerEn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let assistant: String
            if !concise.isEmpty && !expanded.isEmpty {
                assistant = "\(concise)\n\n\(expanded)"
            } else {
                assistant = expanded.isEmpty ? concise : expanded
            }
            lines.append("User: \(turn.questionZh)")
            lines.append("Assistant: \(assistant)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func interviewDocContent(files: [ContextFile]) -> String {
        let types: Set<ContextDocType> = [.resume, .jobDescription, .qaNotes, .projectNotes]
        let maxChars = 200_000
        var parts: [String] = []
        var total = 0
        for file in files where types.contains(file.docType) {
            let text = file.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let block = "=== \(file.docType.promptLabel): \(file.fileName) ===\n\(text)"
            if total + block.count > maxChars {
                parts.append("=== \(file.docType.promptLabel): \(file.fileName) ===\n[Content truncated — file too large]")
                break
            }
            parts.append(block)
            total += block.count
        }
        return parts.joined(separator: "\n\n")
    }

    static func meetingDocContent(files: [ContextFile]) -> (full: String, hasDocuments: Bool) {
        let maxChars = 500_000
        var parts: [String] = []
        var total = 0
        for file in files where file.docType == .meetingDoc {
            let text = file.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let block = "=== 文档: \(file.fileName) ===\n\(text)"
            if total + block.count > maxChars {
                parts.append("=== 文档: \(file.fileName) ===\n[文档过大，已截断至安全上限]")
                break
            }
            parts.append(block)
            total += block.count
        }
        return (parts.joined(separator: "\n\n"), !parts.isEmpty)
    }

    static func buildSystemContent(
        systemPrompt: String,
        files: [ContextFile],
        questionsHistory: [String],
        questionRaw: String,
        summaries: [AnswerSummary],
        resumeText: String,
        jdText: String,
        notesText: String
    ) -> String {
        let documentContent = interviewDocContent(files: files)
        let historyJoined = questionsHistory.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let recentConversation = conversationBlock(summaries)
        let currentQuestion = questionRaw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(none)"
        let instructionBlock = PromptCatalog.contextInstructionChat
        let historyBlock = summaries.suffix(3).isEmpty
            ? "\n[HISTORY]\n\(historyJoined.nilIfEmpty ?? "(none)")\n"
            : ""

        let ctx: String
        if !documentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ctx = """
            [DOCUMENT CONTENT]
            \(documentContent)
            \(historyBlock)
            \(instructionBlock)

            [CONVERSATION]
            \(recentConversation)

            [CURRENT_QUESTION]
            \(currentQuestion)
            """
        } else {
            ctx = """
            [RESUME]
            \(cap(resumeText, max: 14000))

            [JD]
            \(cap(jdText, max: 10000))

            [NOTES]
            \(cap(notesText, max: 8000))
            \(historyBlock)
            \(instructionBlock)

            [CONVERSATION]
            \(recentConversation)

            [CURRENT_QUESTION]
            \(currentQuestion)
            """
        }

        return """
        \(systemPrompt)

        ====================
        \(ctx)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildRealtimeInstructions(
        systemPrompt: String,
        files: [ContextFile],
        questionsHistory: [String],
        summaries: [AnswerSummary],
        meetingMode: Bool
    ) -> String {
        if meetingMode {
            let meeting = meetingDocContent(files: files)
            let docBlock = meeting.hasDocuments
                ? "[DOCUMENT CONTENT]\n\(meeting.full)"
                : "[DOCUMENT CONTENT]\n(No documents uploaded yet. Please upload your project documents first.)"
            return """
            \(PromptCatalog.meetingSystem)

            ====================
            \(docBlock)

            [CONVERSATION HISTORY]
            Use this to understand the ongoing discussion context. If the current question is a follow-up, build on what was already said.
            \(conversationBlock(summaries))

            \(PromptCatalog.meetingOutput)

            [CURRENT_QUESTION]
            (The attendee's utterance in the live audio — respond after each pause.)

            \(PromptCatalog.realtimeOutputRule)
            """
        }

        let documentContent = interviewDocContent(files: files)
        let historyJoined = questionsHistory.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let historyBlock = summaries.suffix(3).isEmpty
            ? "\n[HISTORY]\n\(historyJoined.nilIfEmpty ?? "(none)")"
            : ""
        let resume = files.first(where: { $0.docType == .resume })?.rawText
        let jd = files.first(where: { $0.docType == .jobDescription })?.rawText
        let notes = files.filter { $0.docType == .qaNotes || $0.docType == .projectNotes }.map(\.rawText).joined(separator: "\n\n")
        let docContextBlock: String
        if !documentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            docContextBlock = "[DOCUMENT CONTENT]\n\(documentContent)"
        } else {
            docContextBlock = """
            [RESUME]
            \(cap(resume, max: 14000))

            [JD]
            \(cap(jd, max: 10000))

            [NOTES]
            \(cap(notes, max: 8000))
            """
        }

        return """
        \(systemPrompt)

        ====================
        [MODE]
        Realtime audio: interviewer speaks; after a pause, respond with JSON only (see [OUTPUT] in system prompt).

        \(docContextBlock)

        \(PromptCatalog.contextInstructionRealtime)

        [CONVERSATION]
        \(conversationBlock(summaries))\(historyBlock)

        [CURRENT_QUESTION]
        (The interviewer's utterance in the **live audio** for this turn—respond to what they just said after each pause.)

        \(PromptCatalog.realtimeOutputRule)
        """
    }

    static func buildMeetingSystemContent(
        files: [ContextFile],
        questionRaw: String,
        summaries: [AnswerSummary]
    ) -> String {
        let meeting = meetingDocContent(files: files)
        let docBlock = meeting.hasDocuments
            ? "[DOCUMENT CONTENT]\n\(meeting.full)"
            : "[DOCUMENT CONTENT]\n(No documents uploaded yet. Please upload your project documents first.)"
        let currentQuestion = questionRaw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(none)"
        return """
        \(PromptCatalog.meetingSystem)

        ====================
        \(docBlock)

        [CONVERSATION HISTORY]
        Use this to understand the ongoing discussion context. If the current question is a follow-up, build on what was already said.
        \(conversationBlock(summaries))

        [CURRENT QUESTION]
        \(currentQuestion)

        ====================
        \(PromptCatalog.meetingOutput)
        """
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
