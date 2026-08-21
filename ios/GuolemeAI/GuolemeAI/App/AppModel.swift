import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let settingsStore = SettingsStore()
    let contextStore = ContextStore()
    let sessionLog = SessionLog()
    private let llm = LLMClient()

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
    private var translateAudio = TranslateAudioBuffer()
    private var streamStopped = false
    private var cancellables: Set<AnyCancellable> = []

    var settings: AppSettings { settingsStore.settings }

    func t(_ key: L10n.Key, _ args: CVarArg...) -> String {
        let template = L10n.t(key, language: settings.uiLanguage)
        if args.isEmpty { return template }
        return String(format: template, arguments: args)
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
        translateAudio.reset()
        vad.reset()
        ListeningLiveActivityController.end()
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
        guard let openaiKey = KeychainStore.load(provider: .openai) else {
            if !autoTriggered { pushTranslate(t(.noOpenAIKey), streaming: false) }
            return
        }
        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else {
            if !autoTriggered { pushTranslate(t(.noAPIKey), streaming: false) }
            return
        }
        let pcm = translateAudio.takeAll()
        let minBytes = Int(AppConstants.realtimeSampleRate * 2 * 0.4)
        guard pcm.count >= minBytes else {
            if !autoTriggered { pushTranslate(t(.noSpeech), streaming: false) }
            return
        }
        translateSummarizing = true
        defer { translateSummarizing = false }
        do {
            let result = try await WhisperClient.transcribe(pcm: pcm, sampleRate: Int(AppConstants.realtimeSampleRate), apiKey: openaiKey)
            let transcript = result.text
            if transcript.count < 5 {
                if !autoTriggered { pushTranslate(t(.noSpeech), streaming: false) }
                return
            }
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
                    system: PromptCatalog.translateReply,
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

    private func flushTranslateIfNeeded() async {
        guard listening, settings.translateMode, !translateSummarizing else { return }
        guard translateAudio.reachedFlushLimit else { return }
        await summarizeTranslate(withReply: false, autoTriggered: true)
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
        listening = true
        UIApplication.shared.isIdleTimerDisabled = true
        startLiveActivity()
        translateAudio.reset()
        let mic = MicCapture(sampleRate: AppConstants.realtimeSampleRate)
        let audio = translateAudio
        mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        mic.onPCM = { [weak self] data in
            audio.append(data)
            guard audio.reachedFlushLimit else { return }
            Task { @MainActor in
                await self?.flushTranslateIfNeeded()
            }
        }
        do {
            try mic.start()
            translateMic = mic
        } catch {
            statusMessage = t(.micFail, error.localizedDescription)
            stopListening()
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
