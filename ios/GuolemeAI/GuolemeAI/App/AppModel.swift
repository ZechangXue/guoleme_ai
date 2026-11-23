import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let settingsStore = SettingsStore()
    let contextStore = ContextStore()
    let sessionLog = SessionLog()
    let meetingProfile = MeetingProfileStore()
    private let llm = LLMClient()
    lazy var meeting: MeetingAssistant = MeetingAssistant(
        settingsStore: settingsStore,
        contextStore: contextStore,
        sessionLog: sessionLog,
        profile: meetingProfile,
        llm: llm
    )

    @Published var listening = false
    @Published var audioLevel: Double = 0
    @Published var currentAssist: AssistJSON?
    @Published var streaming = false
    @Published var displayAsReadable = false
    @Published var statusMessage: String?
    @Published var hasApiKey = false
    @Published var translateEntries: [TranslateEntry] = []
    @Published var translateSummarizing = false
    @Published var exportBusy = false
    @Published var readableLoading = false
    @Published var imageBusy = false

    private var realtime: OpenAIRealtimeClient?
    private var fallbackMic: MicCapture?
    private var vad = VoiceActivityDetector()
    private var translateMic: MicCapture?
    /// Transcribed lines not yet summarized in translate mode.
    private var translatePending: [String] = []
    private var translateTimer: Task<Void, Never>?
    /// Meeting / translate segments are force-cut at 15 s so long speech is transcribed promptly.
    private static let meetingMaxSegmentSeconds: Double = 15
    private var streamStopped = false
    private var cancellables: Set<AnyCancellable> = []

    var settings: AppSettings { settingsStore.settings }

    func t(_ key: L10n.Key, _ args: CVarArg...) -> String {
        let template = L10n.t(key, language: settings.uiLanguage)
        if args.isEmpty { return template }
        return String(format: template, arguments: args)
    }

    /// Inline bilingual string for newer screens that are not in the L10n table.
    func tr(_ zh: String, _ en: String) -> String {
        settings.uiLanguage == .en ? en : zh
    }

    var modeLabel: String {
        if settings.translateMode { return t(.modeTranslate) }
        if settings.meetingMode { return t(.modeMeeting) }
        return t(.modeInterview)
    }

    init() {
        refreshKeyStatus()
        settingsStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        contextStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async {
                self?.refreshRealtimeInstructions()
            }
        }.store(in: &cancellables)
        sessionLog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        configureMeeting()
    }

    private func configureMeeting() {
        let vad = self.vad
        meeting.flushAudio = { vad.flush() }
        meeting.onLine = { [weak self] line in
            guard let self, self.listening, self.settings.translateMode else { return }
            self.translatePending.append(line.text)
        }
        meeting.onCardShown = { [weak self] question in
            guard let self, self.listening else { return }
            ListeningLiveActivityController.update(
                modeLabel: self.modeLabel,
                statusLine: question,
                listeningLabel: self.t(.liveListening)
            )
        }
        Task { await meeting.digestPendingSessions() }
    }

    func refreshKeyStatus() {
        hasApiKey = KeychainStore.hasKey(provider: settings.apiProvider)
    }

    private func startLiveActivity() {
        ListeningLiveActivityController.start(
            appName: t(.appName),
            modeLabel: modeLabel,
            statusLine: t(.liveHoldNearSpeaker),
            listeningLabel: t(.liveListening)
        )
    }

    func toggleListening() {
        if listening { stopListening() } else { Task { await startListening() } }
    }

    func startListening() async {
        streamStopped = false
        statusMessage = nil
        do {
            let granted = await requestMic()
            guard granted else {
                statusMessage = t(.needMic)
                return
            }
        }

        if settings.translateMode {
            startTranslateListening()
            return
        }

        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else {
            statusMessage = t(.needAPIKey)
            return
        }

        if settings.meetingMode {
            startMeetingListening()
            return
        }

        listening = true
        UIApplication.shared.isIdleTimerDisabled = true
        startLiveActivity()

        let useRealtime = settings.apiProvider == .openai && settings.useRealtimeAllInOne
        if useRealtime {
            startRealtime(apiKey: apiKey)
        } else {
            startFallback(apiKey: apiKey)
        }
    }

    func stopListening() {
        listening = false
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        realtime?.stop()
        realtime = nil
        fallbackMic?.stop()
        fallbackMic = nil
        translateMic?.stop()
        translateMic = nil
        translateTimer?.cancel()
        translateTimer = nil
        vad.reset()
        vad.maxSegmentBytes = 0
        meetingProfile.flush()
        ListeningLiveActivityController.end()
    }

    /// Ends the current meeting: clears the live transcript and saves a memory digest for next time.
    func endMeeting() {
        translatePending = []
        meeting.endSession()
    }

    func closeCurrentCard() {
        streamStopped = true
        streaming = false
        currentAssist = nil
        displayAsReadable = false
        streamStopped = false
        if listening {
            ListeningLiveActivityController.update(
                modeLabel: modeLabel,
                statusLine: t(.continueListening),
                listeningLabel: t(.liveListening)
            )
        }
    }

    func getReadableAnswer() async {
        guard let assist = currentAssist, let question = assist.questionZh else { return }
        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else { return }
        readableLoading = true
        defer { readableLoading = false }
        let system = PromptBuilder.buildSystemContent(
            systemPrompt: PromptCatalog.readableSystemPrompt(userSystemPrompt: settings.systemPrompt),
            files: contextStore.filesForPrompt(),
            questionsHistory: contextStore.questionsHistory,
            questionRaw: question,
            summaries: contextStore.answerSummaries,
            resumeText: contextStore.resumeText,
            jdText: contextStore.jdText,
            notesText: contextStore.notesText
        )
        do {
            var readable = try await llm.readableAnswer(
                provider: settings.apiProvider,
                apiKey: apiKey,
                model: settings.model,
                systemContent: system
            )
            readable = try await maybeTranslate(readable, apiKey: apiKey)
            currentAssist?.conciseAnswerEn = readable.conciseAnswerEn
            currentAssist?.expandedAnswerEn = readable.expandedAnswerEn
            displayAsReadable = true
            if let concise = readable.conciseAnswerEn, let expanded = readable.expandedAnswerEn {
                contextStore.mergeExpanded(questionZh: question, concise: concise, expanded: expanded)
                sessionLog.updateExpanded(questionZh: question, concise: concise, expanded: expanded)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func answerFromImage(_ image: UIImage) async {
        guard !imageBusy else { return }
        guard let vision = resolveVisionClient() else {
            statusMessage = t(.visionNeedKey)
            return
        }
        guard let jpeg = ImagePrep.jpegForVision(image) else {
            statusMessage = t(.imageBad)
            return
        }

        if settings.meetingMode || settings.translateMode {
            // Meeting / translate: a screenshot of slides or chat becomes a meeting answer card.
            meeting.beginSession()
            meeting.answerFromImage(
                jpegBase64: jpeg.base64EncodedString(),
                target: MeetingAssistant.ChatTarget(provider: vision.provider, apiKey: vision.apiKey, model: vision.model)
            )
            return
        }

        imageBusy = true
        defer { imageBusy = false }
        streamStopped = false
        displayAsReadable = true
        streaming = true
        let recognizing = t(.recognizingQuestion)
        currentAssist = AssistJSON(questionZh: recognizing)
        statusMessage = t(.recognizingStatus)

        let system = PromptCatalog.screenshotSystemPrompt(userSystemPrompt: settings.systemPrompt)

        do {
            try await llm.assistFromImage(
                provider: vision.provider,
                apiKey: vision.apiKey,
                model: vision.model,
                systemContent: system,
                imageJPEG: jpeg
            ) { @MainActor [weak self] chunk in
                guard let self else { return }
                var assist = chunk.partial.fillingMissingAnswers()
                if chunk.done {
                    if AppConstants.isNoiseOrUnrecognized(assist.questionZh) || !assist.hasContent {
                        self.statusMessage = self.t(.imageUnclear)
                        self.streaming = false
                        if self.currentAssist?.questionZh == recognizing {
                            self.currentAssist = nil
                        }
                        return
                    }
                    assist = (try? await self.maybeTranslate(assist, apiKey: vision.apiKey)) ?? assist
                    self.statusMessage = nil
                    self.applyAssist(assist, transcript: "[screenshot]", done: false, fromScreenshot: true)
                    return
                }
                self.applyAssist(assist, transcript: "[screenshot]", done: false, fromScreenshot: true)
            }

            if var card = currentAssist, card.needsCodingSolution {
                statusMessage = t(.generatingCode)
                streaming = true
                let language = card.inferredCodeLanguage
                let user = """
                Problem: \(card.questionZh ?? "coding problem from screenshot")
                Approach already shown: \(card.conciseAnswerEn ?? "")
                Write the complete \(language) solution now.
                """
                let code = try await llm.completePlain(
                    provider: vision.provider,
                    apiKey: vision.apiKey,
                    model: vision.model,
                    system: PromptCatalog.screenshotCode,
                    user: user,
                    maxTokens: 2500
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty {
                    card.expandedAnswerEn = Self.stripCodeFences(code)
                }
                statusMessage = nil
                applyAssist(card, transcript: "[screenshot]", done: true, fromScreenshot: true)
            } else if currentAssist != nil {
                applyAssist(currentAssist ?? AssistJSON(), transcript: "[screenshot]", done: true, fromScreenshot: true)
            }
        } catch {
            streaming = false
            if currentAssist?.questionZh == recognizing {
                currentAssist = nil
            }
            statusMessage = t(.imageFail, error.localizedDescription)
        }
    }

    private static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func resolveVisionClient() -> (provider: ApiProvider, apiKey: String, model: String)? {
        if ProviderConfig.supportsVision(settings.apiProvider),
           let apiKey = KeychainStore.load(provider: settings.apiProvider) {
            return (settings.apiProvider, apiKey, settings.model)
        }
        if let apiKey = KeychainStore.load(provider: .openai) {
            return (.openai, apiKey, ProviderConfig.defaultModel(for: .openai))
        }
        if let apiKey = KeychainStore.load(provider: .google) {
            return (.google, apiKey, ProviderConfig.defaultModel(for: .google))
        }
        return nil
    }

    func summarizeTranslate(withReply: Bool, autoTriggered: Bool = false) async {
        guard !translateSummarizing else { return }
        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else {
            if !autoTriggered { pushTranslate(t(.noAPIKey), streaming: false) }
            return
        }
        translateSummarizing = true
        defer { translateSummarizing = false }

        // Use the lines already transcribed live; a manual tap first cuts the segment in progress.
        if !autoTriggered {
            vad.flush()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await meeting.waitForPendingASR(timeout: autoTriggered ? 3 : 6)
        let transcript = translatePending.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.count >= (autoTriggered ? 15 : 5) else {
            if !autoTriggered {
                pushTranslate(KeychainStore.load(provider: .openai) == nil ? t(.noOpenAIKey) : t(.noSpeech), streaming: false)
            }
            return
        }
        translatePending = []

        do {
            let id = UUID()
            let stamp = Self.clockFormatter.string(from: Date()) + (autoTriggered ? " · \(t(.translateAuto))" : "")
            translateEntries.insert(TranslateEntry(id: id, text: withReply ? "总结：" : "", timestamp: stamp, streaming: true), at: 0)

            if withReply {
                let summary = try await llm.completePlain(
                    provider: settings.apiProvider,
                    apiKey: apiKey,
                    model: settings.model,
                    system: PromptCatalog.translateSummary,
                    user: transcript
                )
                if let idx = translateEntries.firstIndex(where: { $0.id == id }) {
                    translateEntries[idx].text = "总结：" + summary.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let reply = try await llm.completePlain(
                    provider: settings.apiProvider,
                    apiKey: apiKey,
                    model: settings.model,
                    system: translateReplySystemPrompt(),
                    user: transcript
                )
                if let idx = translateEntries.firstIndex(where: { $0.id == id }) {
                    translateEntries[idx].text += "\n回应：" + reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    translateEntries[idx].streaming = false
                }
            } else {
                try await llm.streamPlain(
                    provider: settings.apiProvider,
                    apiKey: apiKey,
                    model: settings.model,
                    system: PromptCatalog.translateSummary,
                    user: transcript
                ) { [weak self] delta, done in
                    Task { @MainActor in
                        guard let self, let idx = self.translateEntries.firstIndex(where: { $0.id == id }) else { return }
                        self.translateEntries[idx].text += delta
                        self.translateEntries[idx].streaming = !done
                    }
                }
            }
        } catch {
            pushTranslate(t(.translateFail, error.localizedDescription), streaming: false)
        }
    }

    /// Reply prompt in the chosen answer language, spoken as the user when a profile exists.
    private func translateReplySystemPrompt() -> String {
        let label = settings.answerLanguage == .zh ? "Simplified Chinese (简体中文)" : "English"
        let template = PromptCatalog.translateReplyPersona.isEmpty ? PromptCatalog.translateReply : PromptCatalog.translateReplyPersona
        var prompt = template.replacingOccurrences(of: "{{REPLY_LANGUAGE}}", with: label)
        if prompt == template {
            prompt += "\n\nReply language: \(label). Always write the reply entirely in \(label), whatever language the transcript is in."
        }
        let persona = meetingProfile.state.personaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty {
            prompt += "\n\n[MY PROFILE — reply as this person, consistent with their role and work]\n\(MeetingPrompt.truncate(persona, 6000))"
        }
        return prompt
    }

    func exportSession() async -> URL? {
        exportBusy = true
        defer { exportBusy = false }
        let transcript = sessionLog.transcriptForSummary()
        var summary = t(.noSessionContent)
        if !transcript.isEmpty, let apiKey = KeychainStore.load(provider: settings.apiProvider) {
            summary = (try? await llm.sessionSummary(
                provider: settings.apiProvider,
                apiKey: apiKey,
                model: settings.model,
                transcript: transcript
            )) ?? summary
        }
        return SessionPDFExporter.export(entries: sessionLog.entries, summaryZh: summary, language: settings.uiLanguage)
    }

    private func startRealtime(apiKey: String) {
        let client = OpenAIRealtimeClient()
        client.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
                self?.stopListening()
            }
        }
        client.onChunk = { [weak self] chunk in
            Task { @MainActor in
                self?.applyAssist(chunk.partial, transcript: chunk.interviewerTranscript, done: chunk.done)
            }
        }
        let instructions = PromptBuilder.buildRealtimeInstructions(
            systemPrompt: PromptCatalog.conciseSystemPrompt(userSystemPrompt: settings.systemPrompt),
            files: contextStore.filesForPrompt(),
            questionsHistory: contextStore.questionsHistory,
            summaries: contextStore.answerSummaries,
            meetingMode: settings.meetingMode
        )
        client.start(apiKey: apiKey, model: ProviderConfig.realtimeModel(for: .openai) ?? "gpt-realtime-mini", instructions: instructions)
        realtime = client
    }

    private func refreshRealtimeInstructions() {
        guard listening, !settings.translateMode, realtime != nil else { return }
        let instructions = PromptBuilder.buildRealtimeInstructions(
            systemPrompt: PromptCatalog.conciseSystemPrompt(userSystemPrompt: settings.systemPrompt),
            files: contextStore.filesForPrompt(),
            questionsHistory: contextStore.questionsHistory,
            summaries: contextStore.answerSummaries,
            meetingMode: settings.meetingMode
        )
        realtime?.updateInstructions(instructions)
    }

    private func startFallback(apiKey: String) {
        vad.reset()
        vad.onSegment = { [weak self] pcm in
            Task { @MainActor in
                await self?.handleFallbackSegment(pcm, apiKey: apiKey)
            }
        }
        let mic = MicCapture(sampleRate: AppConstants.realtimeSampleRate)
        mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        mic.onPCM = { [weak self] data in
            self?.vad.ingest(data)
        }
        do {
            try mic.start()
            fallbackMic = mic
        } catch {
            statusMessage = t(.micFail, error.localizedDescription)
            stopListening()
        }
    }

    private func handleFallbackSegment(_ pcm: Data, apiKey: String) async {
        guard listening, !settings.translateMode else { return }
        guard let openaiKey = KeychainStore.load(provider: .openai) ?? (settings.apiProvider == .openai ? apiKey : nil) else {
            statusMessage = t(.fallbackNeedOpenAI)
            return
        }
        do {
            let result = try await WhisperClient.transcribe(pcm: pcm, sampleRate: Int(AppConstants.realtimeSampleRate), apiKey: openaiKey)
            let text = result.text
            guard text.count >= 4, StreamingJSONParser().isLikelyActionable(text) || text.contains("?") || text.count > 12 else { return }
            let system: String
            if settings.meetingMode {
                system = PromptBuilder.buildMeetingSystemContent(
                    files: contextStore.filesForPrompt(),
                    questionRaw: text,
                    summaries: contextStore.answerSummaries
                )
            } else {
                system = PromptBuilder.buildSystemContent(
                    systemPrompt: PromptCatalog.conciseSystemPrompt(userSystemPrompt: settings.systemPrompt),
                    files: contextStore.filesForPrompt(),
                    questionsHistory: contextStore.questionsHistory,
                    questionRaw: text,
                    summaries: contextStore.answerSummaries,
                    resumeText: contextStore.resumeText,
                    jdText: contextStore.jdText,
                    notesText: contextStore.notesText
                )
            }
            streamStopped = false
            try await llm.streamAssist(
                provider: settings.apiProvider,
                apiKey: apiKey,
                model: settings.model,
                systemContent: system
            ) { [weak self] chunk in
                Task { @MainActor in
                    var assist = chunk.partial
                    if chunk.done, let self {
                        assist = (try? await self.maybeTranslate(assist, apiKey: apiKey)) ?? assist
                    }
                    self?.applyAssist(assist, transcript: text, done: chunk.done)
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startTranslateListening() {
        if KeychainStore.load(provider: .openai) == nil {
            statusMessage = t(.noOpenAIKey)
        }
        listening = true
        UIApplication.shared.isIdleTimerDisabled = true
        startLiveActivity()
        translatePending = []
        meeting.beginSession()
        guard startSegmentMic() else { return }
        translateTimer?.cancel()
        translateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppConstants.translateFlushSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.listening, self.settings.translateMode else { return }
                await self.summarizeTranslate(withReply: false, autoTriggered: true)
            }
        }
    }

    /// Meeting mode: segment-by-segment transcription feeding the meeting assistant (no Realtime).
    private func startMeetingListening() {
        guard KeychainStore.load(provider: .openai) != nil else {
            statusMessage = t(.fallbackNeedOpenAI)
            return
        }
        listening = true
        UIApplication.shared.isIdleTimerDisabled = true
        startLiveActivity()
        meeting.beginSession()
        _ = startSegmentMic()
    }

    /// Mic → VAD → MeetingAssistant transcription. Returns false if the mic could not start.
    private func startSegmentMic() -> Bool {
        let sampleRate = AppConstants.realtimeSampleRate
        let segmentVAD = self.vad
        segmentVAD.reset()
        segmentVAD.maxSegmentBytes = Int(sampleRate * 2 * Self.meetingMaxSegmentSeconds)
        segmentVAD.onSegment = { [weak self] pcm in
            Task { @MainActor in
                self?.meeting.ingest(pcm, sampleRate: Int(sampleRate))
            }
        }
        let mic = MicCapture(sampleRate: sampleRate)
        mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        mic.onPCM = { data in
            segmentVAD.ingest(data)
        }
        do {
            try mic.start()
            translateMic = mic
            return true
        } catch {
            statusMessage = t(.micFail, error.localizedDescription)
            stopListening()
            return false
        }
    }

    private func applyAssist(_ partial: AssistJSON, transcript: String?, done: Bool, fromScreenshot: Bool = false) {
        if streamStopped { return }
        if !fromScreenshot, AppConstants.isNoiseOrUnrecognized(partial.questionZh) {
            if done { streaming = false }
            return
        }
        if !fromScreenshot, settings.autoDismissCardOnNewQuestion, currentAssist != nil, done || partial.questionZh != nil {
            displayAsReadable = false
        }
        if fromScreenshot {
            displayAsReadable = true
        }
        var merged = (currentAssist ?? AssistJSON())
        if let q = partial.questionZh, !q.isEmpty { merged.questionZh = q }
        if let c = partial.conciseAnswerEn, !c.isEmpty { merged.conciseAnswerEn = c }
        if let e = partial.expandedAnswerEn, !e.isEmpty { merged.expandedAnswerEn = e }
        if let t = partial.thinkingZh, !t.isEmpty { merged.thinkingZh = t }
        if !partial.keywordsEn.isEmpty { merged.keywordsEn = partial.keywordsEn }
        merged = merged.fillingMissingAnswers()
        currentAssist = merged
        streaming = !done
        if let q = merged.questionZh {
            ListeningLiveActivityController.update(
                modeLabel: modeLabel,
                statusLine: q,
                listeningLabel: t(.liveListening)
            )
        }
        if done {
            streaming = false
            contextStore.pushQuestion(merged.questionZh ?? "")
            contextStore.pushSummary(from: merged)
            sessionLog.append(raw: transcript, assist: merged)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func maybeTranslate(_ assist: AssistJSON, apiKey: String) async throws -> AssistJSON {
        guard settings.answerLanguage == .zh else { return assist }
        let code = AssistJSON.looksLikeCode(assist.expandedAnswerEn) ? assist.expandedAnswerEn : nil
        var translated = try await llm.translateAnswersToChinese(
            provider: settings.apiProvider,
            apiKey: apiKey,
            model: settings.model,
            assist: assist
        )
        if let code {
            translated.expandedAnswerEn = code
        }
        return translated
    }

    private func pushTranslate(_ text: String, streaming: Bool) {
        translateEntries.insert(
            TranslateEntry(
                id: UUID(),
                text: text,
                timestamp: Self.clockFormatter.string(from: Date()),
                streaming: streaming
            ),
            at: 0
        )
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
