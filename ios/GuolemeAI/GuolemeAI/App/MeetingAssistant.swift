import Foundation
import UIKit

struct MeetingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Live meeting copilot (port of the desktop MeetingEngine): segment-by-segment Whisper transcription,
/// "is this addressed to me" triggers, streamed first-person answer cards, prep, persona draft and
/// cross-meeting memory. Used by both meeting mode and translate-summary mode.
@MainActor
final class MeetingAssistant: ObservableObject {
    struct ChatTarget {
        var provider: ApiProvider
        var apiKey: String
        var model: String
    }

    /// Mutable state shared with the streaming callback (a class, so the closure captures a constant).
    private final class CardStream {
        var acc = ""
        var shownId: String?
        var skipped = false
    }

    private struct CardJob {
        var trigger: MeetingTriggerKind
        var utterance: String
        var imageBase64: String?
        var target: ChatTarget?
    }

    @Published private(set) var transcript: [MeetingTranscriptLine] = []
    @Published private(set) var cards: [MeetingCard] = []
    /// Index into `cards` of the card on screen; nil hides the card.
    @Published var cardIndex: Int?
    @Published private(set) var generating = false
    @Published var errorMessage: String?
    @Published private(set) var prepBusy = false
    @Published private(set) var personaBusy = false

    let profile: MeetingProfileStore
    private let settingsStore: SettingsStore
    private let contextStore: ContextStore
    private let sessionLog: SessionLog
    private let llm: LLMClient

    /// Cuts the VAD segment currently being recorded so it can be transcribed right away.
    var flushAudio: (() -> Void)?
    var onLine: ((MeetingTranscriptLine) -> Void)?
    var onCardShown: ((String) -> Void)?

    private var asrNextSeq = 0
    private var asrCommitSeq = 0
    private var asrResults: [Int: (text: String, at: TimeInterval)] = [:]
    private(set) var asrPending = 0
    private var warnedNoWhisperKey = false
    private var glossaryCache: (source: String, terms: String)?

    private var triggerTask: Task<Void, Never>?
    private var triggerKind: MeetingTriggerKind?
    private var triggerFromLineId: String?
    private var triggerArmedAt: TimeInterval = 0

    private var cardBusy = false
    private var pendingJob: CardJob?
    private var jobsByCard: [String: CardJob] = [:]
    private var digestRunning = false

    static let maxCards = 12
    static let minSegmentSeconds = 0.6
    static let transcriptKeepSeconds: TimeInterval = 30 * 60
    static let promptTranscriptSeconds: TimeInterval = 4 * 60
    static let promptTranscriptMaxChars = 6000

    init(settingsStore: SettingsStore, contextStore: ContextStore, sessionLog: SessionLog, profile: MeetingProfileStore, llm: LLMClient) {
        self.settingsStore = settingsStore
        self.contextStore = contextStore
        self.sessionLog = sessionLog
        self.profile = profile
        self.llm = llm
    }

    private var settings: AppSettings { settingsStore.settings }

    private func tr(_ zh: String, _ en: String) -> String {
        settings.uiLanguage == .en ? en : zh
    }

    var visibleCard: MeetingCard? {
        guard let i = cardIndex, cards.indices.contains(i) else { return nil }
        return cards[i]
    }

    // MARK: Session

    func beginSession() {
        let session = profile.ensureActiveSession(scene: settings.meetingScene)
        if transcript.isEmpty {
            transcript = Array(session.transcript.suffix(200))
        }
    }

    /// Ends the meeting: clears the live transcript and digests it into memory in the background.
    func endSession() {
        clearTrigger()
        profile.endActiveSession()
        profile.flush()
        transcript = []
        cards = []
        cardIndex = nil
        jobsByCard = [:]
        Task { await digestPendingSessions() }
    }

    // MARK: ASR

    func ingest(_ pcm: Data, sampleRate: Int) {
        guard Double(pcm.count) >= Double(sampleRate) * 2 * Self.minSegmentSeconds else { return }
        guard let key = KeychainStore.load(provider: .openai) else {
            if !warnedNoWhisperKey {
                warnedNoWhisperKey = true
                errorMessage = tr("转写需要 OpenAI API Key（Whisper），请在设置里保存", "Transcription needs an OpenAI API key (Whisper). Save one in Settings.")
            }
            return
        }
        warnedNoWhisperKey = false
        let seq = asrNextSeq
        asrNextSeq += 1
        asrPending += 1
        let at = Date().timeIntervalSince1970
        let prompt = whisperPrompt()
        Task { [weak self] in
            let text = (try? await WhisperClient.transcribe(pcm: pcm, sampleRate: sampleRate, apiKey: key, prompt: prompt))?.text ?? ""
            self?.commitASR(seq: seq, text: text, at: at)
        }
    }

    /// Commits transcription results in segment order even though requests run concurrently.
    private func commitASR(seq: Int, text: String, at: TimeInterval) {
        asrPending = max(0, asrPending - 1)
        asrResults[seq] = (text, at)
        while let result = asrResults.removeValue(forKey: asrCommitSeq) {
            asrCommitSeq += 1
            let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || Self.isHallucination(cleaned) { continue }
            addLine(cleaned, at: result.at)
        }
    }

    func waitForPendingASR(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while asrPending > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static let hallucinationPattern =
        #"^(thank you( (so much|very much))?[.!]*|thanks( for watching)?[.!]*|thank you for watching[.!]*|you[.!]*|bye[.!]*|subtitles? by.*|transcribed by.*|字幕.*|请不吝点赞.*|謝謝觀看.*|谢谢观看.*|[.。…\s]*)$"#

    static func isHallucination(_ text: String) -> Bool {
        text.range(of: hallucinationPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whisper prompt: proper nouns from the persona + trigger keywords, plus the tail of the last line.
    private func whisperPrompt() -> String {
        let keywords = settings.meetingTriggerKeywords
        let source = "\(profile.state.personaText)\n\(keywords)"
        if glossaryCache?.source != source {
            var counts: [String: Int] = [:]
            var order: [String] = []
            let pattern = #"\b([A-Z][a-zA-Z0-9]+(?:[-\s][A-Z0-9][a-zA-Z0-9]+)?|[A-Z]{2,}[0-9]*|[A-Za-z]+[0-9]+[A-Za-z0-9]*)\b"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                for match in regex.matches(in: source, range: range) {
                    guard let r = Range(match.range, in: source) else { continue }
                    let token = String(source[r])
                    guard token.count >= 3 else { continue }
                    if counts[token] == nil { order.append(token) }
                    counts[token, default: 0] += 1
                }
            }
            let ranked = order.enumerated()
                .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
                .map(\.element)
            var terms: [String] = []
            for term in Self.splitKeywords(keywords) + ranked where !terms.contains(term) {
                terms.append(term)
                if terms.count >= 40 { break }
            }
            glossaryCache = (source, terms.joined(separator: ", "))
        }
        let terms = glossaryCache?.terms ?? ""
        let tail = transcript.last.map { String($0.text.suffix(160)) } ?? ""
        let prompt = [terms.isEmpty ? "" : "Terms: \(terms).", tail].filter { !$0.isEmpty }.joined(separator: " ")
        return String(prompt.prefix(700))
    }

    private func addLine(_ text: String, at: TimeInterval) {
        let line = MeetingTranscriptLine(id: UUID().uuidString, text: text, at: at)
        transcript.append(line)
        let cutoff = Date().timeIntervalSince1970 - Self.transcriptKeepSeconds
        if transcript.count > 400 || (transcript.first.map { $0.at < cutoff } ?? false) {
            transcript = Array(transcript.filter { $0.at >= cutoff }.suffix(400))
        }
        profile.appendTranscript(line)
        onLine?(line)
        evaluateTrigger(line)
    }

    // MARK: Triggers

    private static let strongCuePattern =
        #"\b(over to you|your turn|what do you think|what[’']s your (view|take|opinion|thought)|what is your (view|take|opinion)|your thoughts|any thoughts on|how about you|from your side|on your side|can you (explain|share|walk us|tell us|clarify|elaborate|give us|update us)|could you (explain|share|walk us|tell us|clarify|elaborate|give us|update us)|would you (explain|share|walk us|tell us|clarify|elaborate))\b"#
    private static let questionLikeEnPattern =
        #"\?|^\s*(what|where|when|why|how|who|which|can|could|would|will|do|does|did|is|are|have|has|should|shall)\b|\b(can|could|would|will|do|did) you\b|\b(tell|explain|walk|share|clarify|elaborate)\b"#
    private static let questionLikeZhPattern = #"[吗呢？?]|为什么|怎么|如何|什么|哪些|能不能|可不可以|是不是|有没有"#

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func wordCount(_ text: String) -> Int {
        var cjk = 0
        var latin = ""
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                cjk += 1
                latin.append(" ")
            } else {
                latin.unicodeScalars.append(scalar)
            }
        }
        let words = latin.split(whereSeparator: { $0.isWhitespace }).count
        return words + (cjk + 1) / 2
    }

    static func splitKeywords(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func mentionHit(_ text: String) -> Bool {
        for keyword in Self.splitKeywords(settings.meetingTriggerKeywords) where keyword.count >= 2 {
            let escaped = NSRegularExpression.escapedPattern(for: keyword)
            let ascii = keyword.unicodeScalars.allSatisfy { $0.isASCII }
            if Self.matches(text, ascii ? "\\b\(escaped)\\b" : escaped) { return true }
        }
        return false
    }

    private func evaluateTrigger(_ line: MeetingTranscriptLine) {
        let mode = settings.meetingTrigger
        if mode == .manual { return }

        // Already waiting (the speaker may still be finishing the question): push the timer out.
        if triggerTask != nil {
            armTrigger(triggerKind ?? .auto, fromLineId: triggerFromLineId ?? line.id)
            return
        }

        let text = line.text
        if settings.meetingScene == .interviewer {
            // Interviewer scene: suggest follow-ups after a substantial candidate answer.
            if mode == .all && Self.wordCount(text) >= 12 { armTrigger(.auto, fromLineId: line.id) }
            return
        }

        if mode == .all {
            if Self.wordCount(text) >= 4,
               Self.matches(text, Self.questionLikeEnPattern) || Self.matches(text, Self.questionLikeZhPattern) || Self.matches(text, Self.strongCuePattern) {
                armTrigger(.auto, fromLineId: line.id)
            }
            return
        }

        if mentionHit(text) || Self.matches(text, Self.strongCuePattern) {
            armTrigger(.mention, fromLineId: line.id)
        }
    }

    private func armTrigger(_ kind: MeetingTriggerKind, fromLineId: String) {
        let now = Date().timeIntervalSince1970
        if triggerTask == nil {
            triggerKind = kind
            triggerFromLineId = fromLineId
            triggerArmedAt = now
        }
        triggerTask?.cancel()
        // Wait for the speaker to finish: each new segment pushes it out, up to 8 s in total.
        let settle = kind == .mention ? 2.2 : 1.6
        let remaining = max(0, 8 - (now - triggerArmedAt))
        let delay = min(settle, remaining)
        triggerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fireTrigger()
        }
    }

    private func clearTrigger() {
        triggerTask?.cancel()
        triggerTask = nil
        triggerKind = nil
        triggerFromLineId = nil
    }

    private func fireTrigger() {
        let kind = triggerKind ?? .auto
        let fromId = triggerFromLineId
        clearTrigger()
        guard !transcript.isEmpty else { return }
        // Include the line before the trigger: questions are often split across two segments.
        let idx = transcript.firstIndex { $0.id == fromId } ?? (transcript.count - 1)
        let start = max(0, idx - 1)
        let utterance = transcript[start...].map(\.text).joined(separator: " ")
        enqueue(CardJob(trigger: kind, utterance: utterance))
    }

    // MARK: Answer requests

    /// "Answer that": answers whatever was said in the last ~45 s.
    func answerNow() async {
        clearTrigger()
        flushAudio?()
        // The flushed segment needs a moment to reach the transcription queue.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await waitForPendingASR(timeout: 5)
        guard !transcript.isEmpty else {
            errorMessage = tr("还没有听到任何发言，请先开始监听", "Nothing heard yet — start listening first.")
            return
        }
        let now = Date().timeIntervalSince1970
        var recent = transcript.filter { now - $0.at <= 45 }
        if recent.isEmpty { recent = Array(transcript.suffix(3)) }
        enqueue(CardJob(trigger: .manual, utterance: recent.map(\.text).joined(separator: " ")))
    }

    func answerFromImage(jpegBase64: String, target: ChatTarget) {
        enqueue(CardJob(trigger: .screenshot, utterance: "", imageBase64: jpegBase64, target: target))
    }

    // MARK: Cards

    func closeCard() { cardIndex = nil }

    func showPreviousCard() {
        guard let i = cardIndex, i > 0 else { return }
        cardIndex = i - 1
    }

    func showNextCard() {
        guard let i = cardIndex, i < cards.count - 1 else { return }
        cardIndex = i + 1
    }

    func showLatestCard() {
        guard !cards.isEmpty else { return }
        cardIndex = cards.count - 1
    }

    func retry(cardId: String) {
        guard let job = jobsByCard[cardId] else { return }
        removeCard(cardId)
        enqueue(job)
    }

    /// Generates cards one at a time; while busy only the newest request is kept.
    private func enqueue(_ job: CardJob) {
        if cardBusy {
            pendingJob = job
            return
        }
        cardBusy = true
        Task { [weak self] in
            var current: CardJob? = job
            while let next = current {
                guard let strong = self else { return }
                await strong.generateCard(next)
                current = strong.pendingJob
                strong.pendingJob = nil
            }
            self?.cardBusy = false
        }
    }

    private func promptTranscript() -> [MeetingTranscriptLine] {
        let now = Date().timeIntervalSince1970
        var out: [MeetingTranscriptLine] = []
        var total = 0
        for line in transcript.reversed() {
            if now - line.at > Self.promptTranscriptSeconds { break }
            total += line.text.count
            if total > Self.promptTranscriptMaxChars { break }
            out.insert(line, at: 0)
        }
        return out
    }

    private func chatTarget() throws -> ChatTarget {
        guard let key = KeychainStore.load(provider: settings.apiProvider) else {
            throw MeetingError(message: tr("请先在设置中保存 API Key", "Save an API key in Settings first."))
        }
        return ChatTarget(provider: settings.apiProvider, apiKey: key, model: settings.model)
    }

    private func generateCard(_ job: CardJob) async {
        let target: ChatTarget
        do {
            target = try job.target ?? chatTarget()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let s = settings
        let system = MeetingPrompt.systemPrompt(
            state: profile.state,
            files: contextStore.filesForPrompt(),
            scene: s.meetingScene,
            language: s.answerLanguage,
            pastSessions: profile.recentDigestedSessions(limit: 3)
        )
        let user = MeetingPrompt.userPrompt(
            trigger: job.trigger,
            earlierCards: profile.activeSession?.cards ?? [],
            transcript: promptTranscript(),
            utterance: job.utterance
        )

        let st = CardStream()
        generating = true
        defer { generating = false }

        do {
            try await llm.streamText(
                provider: target.provider,
                apiKey: target.apiKey,
                model: target.model,
                system: system,
                user: user,
                imageJPEGBase64: job.imageBase64,
                json: true,
                maxTokens: 1400
            ) { @MainActor [weak self] delta in
                guard let self, !st.skipped else { return }
                st.acc += delta
                let parsed = MeetingCardParser.parse(st.acc)
                if let id = st.shownId {
                    self.updateCard(id, with: parsed.card, done: false)
                    return
                }
                // Decide whether to pop a card only once question_zh is complete.
                guard parsed.questionComplete else { return }
                if AppConstants.isNoiseOrUnrecognized(parsed.card.questionZh) {
                    st.skipped = true
                    return
                }
                st.shownId = self.showNewCard(parsed.card, job: job)
            }

            if st.skipped { return }
            let final = MeetingCardParser.parseFinal(st.acc)
            if final.questionZh.isEmpty || AppConstants.isNoiseOrUnrecognized(final.questionZh) {
                if let id = st.shownId { removeCard(id) }
                return
            }
            let id = st.shownId ?? showNewCard(final, job: job)
            updateCard(id, with: final, done: true)

            let answer = final.concise.isEmpty ? final.opener : final.concise
            if !answer.isEmpty {
                profile.appendCard(questionZh: final.questionZh, answer: answer)
            }
            sessionLog.append(
                raw: job.utterance.isEmpty ? "[screenshot]" : job.utterance,
                assist: AssistJSON(
                    questionZh: final.questionZh,
                    conciseAnswerEn: answer,
                    expandedAnswerEn: final.expanded.isEmpty ? nil : final.expanded
                )
            )
        } catch {
            if let id = st.shownId, let idx = cards.firstIndex(where: { $0.id == id }) {
                cards[idx].error = error.localizedDescription
                cards[idx].done = true
            } else {
                var card = MeetingCard()
                let fallback = String(job.utterance.prefix(60))
                card.questionZh = fallback.isEmpty ? tr("回答生成失败", "Could not generate an answer") : fallback
                card.error = error.localizedDescription
                card.done = true
                _ = showNewCard(card, job: job)
            }
        }
    }

    @discardableResult
    private func showNewCard(_ card: MeetingCard, job: CardJob) -> String {
        var c = card
        c.trigger = job.trigger
        cards.append(c)
        jobsByCard[c.id] = job
        if cards.count > Self.maxCards {
            let dropped = cards.removeFirst()
            jobsByCard[dropped.id] = nil
        }
        cardIndex = cards.count - 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCardShown?(c.questionZh)
        return c.id
    }

    private func updateCard(_ id: String, with parsed: MeetingCard, done: Bool) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        var c = parsed
        c.id = id
        c.trigger = cards[idx].trigger
        c.done = done
        c.error = nil
        if cards[idx] != c { cards[idx] = c }
    }

    private func removeCard(_ id: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let wasVisible = cardIndex == idx
        cards.remove(at: idx)
        jobsByCard[id] = nil
        if cards.isEmpty {
            cardIndex = nil
        } else if let current = cardIndex {
            if wasVisible {
                cardIndex = nil
            } else if current > idx {
                cardIndex = current - 1
            }
        }
    }

    // MARK: Quick Chinese → spoken English

    func quickTranslate(_ text: String) async throws -> (say: String, shorter: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return ("", "") }
        let target = try chatTarget()
        let recent = promptTranscript().suffix(12).map(\.text).joined(separator: "\n")
        let system = """
        \(MeetingPrompt.fill(PromptCatalog.meetingQuickEn, language: settings.answerLanguage))

        [MY PROFILE]
        \(MeetingPrompt.personaBlock(profile.state, maxChars: 12_000))
        """
        let user = "[LIVE TRANSCRIPT — recent]\n\(recent.isEmpty ? "(none)" : recent)\n\n[MY THOUGHT]\n\(input)"
        let dict = try await llm.completeJSONObject(
            provider: target.provider, apiKey: target.apiKey, model: target.model,
            system: system, user: user, maxTokens: 500
        )
        let say = (dict["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shorter = (dict["shorter"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !say.isEmpty else { throw MeetingError(message: tr("模型返回为空", "The model returned nothing.")) }
        return (say, shorter)
    }

    // MARK: Prep

    func generatePrep() async throws {
        let state = profile.state
        let notes = state.weeklyNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            throw MeetingError(message: tr("请先填写「本周进展」", "Write this week's notes first."))
        }
        let target = try chatTarget()
        prepBusy = true
        defer { prepBusy = false }
        let user = """
        [MEETING TYPE] \(settings.meetingScene.labelZh)

        [MY PROFILE]
        \(MeetingPrompt.personaBlock(state))

        [PROJECT DOCUMENTS]
        \(MeetingPrompt.projectDocsBlock(files: contextStore.filesForPrompt(), maxChars: 60_000))

        [PAST MEETINGS]
        \(MeetingPrompt.pastMeetingsBlock(profile.recentDigestedSessions(limit: 3)))

        [MY NOTES FOR THIS MEETING]
        \(notes)
        """
        let dict = try await llm.completeJSONObject(
            provider: target.provider, apiKey: target.apiKey, model: target.model,
            system: MeetingPrompt.fill(PromptCatalog.meetingPrep, language: settings.answerLanguage),
            user: user, maxTokens: 3000
        )
        let questions: [MeetingLikelyQuestion] = (dict["likely_questions"] as? [[String: Any]] ?? []).compactMap { q in
            let question = (q["question_en"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            return MeetingLikelyQuestion(
                id: UUID().uuidString,
                asker: (q["asker"] as? String)?.nilIfBlank,
                questionEn: question,
                questionZh: (q["question_zh"] as? String)?.nilIfBlank,
                answerEn: (q["answer_en"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let decisions = (dict["decisions_needed_en"] as? [Any] ?? [])
            .map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let script = (dict["update_script_en"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty || !questions.isEmpty else {
            throw MeetingError(message: tr("模型返回为空", "The model returned nothing."))
        }
        profile.setPrep(MeetingPrep(
            updateScript: script,
            likelyQuestions: questions,
            decisionsNeeded: decisions,
            generatedAt: Date().timeIntervalSince1970
        ))
    }

    // MARK: Persona draft

    func draftPersona() async throws -> String {
        let files = contextStore.filesForPrompt().filter {
            $0.docType != .jobDescription && !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !files.isEmpty else {
            throw MeetingError(message: tr("资料库里还没有文档，请先上传项目文档 / 简历", "The library is empty. Add project docs or a resume first."))
        }
        let target = try chatTarget()
        personaBusy = true
        defer { personaBusy = false }
        let docs = String(files.map { "=== \($0.fileName) ===\n\($0.rawText.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n").prefix(100_000))
        let text = try await llm.completePlain(
            provider: target.provider, apiKey: target.apiKey, model: target.model,
            system: PromptCatalog.meetingPersonaDraft, user: docs, maxTokens: 3000
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Memory

    func digestPendingSessions() async {
        guard !digestRunning else { return }
        digestRunning = true
        defer { digestRunning = false }
        for session in profile.undigestedEndedSessions() {
            do {
                try await digest(session)
            } catch {
                break // usually a key / network issue — retry next time
            }
        }
    }

    private func digest(_ session: MeetingSession) async throws {
        let target = try chatTarget()
        let transcriptText = String(session.transcript.map(\.text).joined(separator: "\n").suffix(30_000))
        let cardsText = session.cards.map { "Q: \($0.questionZh)\nMy answer: \($0.answer)" }.joined(separator: "\n\n")
        let user = """
        [MEETING TYPE] \(session.scene.labelZh)
        [DATE] \(MeetingPrompt.dateString(session.startedAt, withTime: true))

        [MY PROFILE — for names and context]
        \(MeetingPrompt.personaBlock(profile.state, maxChars: 6000))

        [ANSWER CARDS I WAS SHOWN]
        \(cardsText.isEmpty ? "(none)" : cardsText)

        [TRANSCRIPT — other participants]
        \(transcriptText.isEmpty ? "(none)" : transcriptText)
        """
        let dict = try await llm.completeJSONObject(
            provider: target.provider, apiKey: target.apiKey, model: target.model,
            system: PromptCatalog.meetingMemoryDigest, user: user, maxTokens: 1200
        )
        let digest = (dict["digest_zh"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let commitments = (dict["commitments"] as? [Any] ?? [])
            .map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        profile.setDigest(
            sessionId: session.id,
            digest: digest.isEmpty ? "（本场没有与我相关的内容）" : digest,
            commitments: commitments
        )
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
