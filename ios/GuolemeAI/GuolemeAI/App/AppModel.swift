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

    private var realtime: OpenAIRealtimeClient?
    private var fallbackMic: MicCapture?
    private var vad = VoiceActivityDetector()
    private var translateMic: MicCapture?
    private var translateVad = VoiceActivityDetector()
    private var translateBuffers: [Data] = []
    private var streamStopped = false
    private var cancellables: Set<AnyCancellable> = []

    var settings: AppSettings { settingsStore.settings }

    init() {
        refreshKeyStatus()
        settingsStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        contextStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        sessionLog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    func refreshKeyStatus() {
        hasApiKey = KeychainStore.hasKey(provider: settings.apiProvider)
    }

    var modeLabel: String {
        if settings.translateMode { return "翻译总结" }
        if settings.meetingMode { return "会议模式" }
        return "面试提词"
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
                statusMessage = "需要麦克风权限才能听电脑外放的声音"
                return
            }
        }

        if settings.translateMode {
            startTranslateListening()
            return
        }

        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else {
            statusMessage = "请先在设置中保存 API Key"
            return
        }

        listening = true
        UIApplication.shared.isIdleTimerDisabled = true
        ListeningLiveActivityController.start(modeLabel: modeLabel)

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
        translateVad.flush()
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
            ListeningLiveActivityController.update(modeLabel: modeLabel, statusLine: "继续监听")
        }
    }

    func getReadableAnswer() async {
        guard let assist = currentAssist, let question = assist.questionZh else { return }
        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else { return }
        readableLoading = true
        defer { readableLoading = false }
        let system = PromptBuilder.buildSystemContent(
            systemPrompt: PromptCatalog.readableSystemPrompt(userSystemPrompt: settings.systemPrompt),
            files: contextStore.files,
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
        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else {
            statusMessage = "请先配置 API Key"
            return
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
        statusMessage = "正在识图出题…"
        let meeting = PromptBuilder.meetingDocContent(files: contextStore.files)
        let system: String
        if settings.meetingMode {
            system = PromptBuilder.buildMeetingSystemContent(
                files: contextStore.files,
                questionRaw: "[SCREENSHOT INPUT]\nUse the screenshot image as the current question/input.",
                summaries: contextStore.answerSummaries
            )
        } else {
            system = PromptBuilder.buildSystemContent(
                systemPrompt: PromptCatalog.conciseSystemPrompt(userSystemPrompt: settings.systemPrompt),
                files: contextStore.files,
                questionsHistory: contextStore.questionsHistory,
                questionRaw: "[SCREENSHOT INPUT]\nUse the screenshot image as the current question/input.",
                summaries: contextStore.answerSummaries,
                resumeText: contextStore.resumeText,
                jdText: contextStore.jdText,
                notesText: contextStore.notesText
            )
        }
        do {
            var assist = try await llm.assistFromImage(
                provider: settings.apiProvider,
                apiKey: apiKey,
                model: settings.model,
                systemContent: system,
                imageJPEG: jpeg
            )
            assist = try await maybeTranslate(assist, apiKey: apiKey)
            applyAssist(assist, transcript: nil, done: true)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func summarizeTranslate(withReply: Bool) async {
        translateVad.flush()
        guard !translateBuffers.isEmpty else {
            pushTranslate("（未检测到有效语音）", streaming: false)
            return
        }
        let pcm = translateBuffers.reduce(into: Data()) { $0.append($1) }
        translateBuffers.removeAll()
        guard let openaiKey = KeychainStore.load(provider: .openai) else {
            pushTranslate("（未配置 OpenAI API Key，无法转写音频）", streaming: false)
            return
        }
        guard let apiKey = KeychainStore.load(provider: settings.apiProvider) else {
            pushTranslate("（未配置 API Key，无法翻译）", streaming: false)
            return
        }
        translateSummarizing = true
        defer { translateSummarizing = false }
        do {
            let result = try await WhisperClient.transcribe(pcm: pcm, sampleRate: Int(AppConstants.asrSampleRate), apiKey: openaiKey)
            let transcript = result.text
            if transcript.count < 5 {
                pushTranslate("（未检测到有效语音）", streaming: false)
                return
            }
            let replyLanguage = inferReplyLanguage(transcript: transcript, whisperLanguage: result.language)
            let system = withReply ? PromptCatalog.translateReply(language: replyLanguage) : PromptCatalog.translateSummary
            let user = withReply
                ? "回应语言：\(replyLanguage)\n\n对方原始语音转写（不是翻译后的内容）：\n\(transcript)"
                : transcript
            let id = UUID()
            let stamp = Self.clockFormatter.string(from: Date())
            translateEntries.insert(TranslateEntry(id: id, text: "", timestamp: stamp, streaming: true), at: 0)
            try await llm.streamPlain(
                provider: settings.apiProvider,
                apiKey: apiKey,
                model: settings.model,
                system: system,
                user: user
            ) { [weak self] delta, done in
                Task { @MainActor in
                    guard let self, let idx = self.translateEntries.firstIndex(where: { $0.id == id }) else { return }
                    self.translateEntries[idx].text += delta
                    self.translateEntries[idx].streaming = !done
                }
            }
        } catch {
            pushTranslate("（翻译失败：\(error.localizedDescription)）", streaming: false)
        }
    }

    func exportSession() async -> URL? {
        exportBusy = true
        defer { exportBusy = false }
        let transcript = sessionLog.transcriptForSummary()
        var summary = "（无实录内容）"
        if !transcript.isEmpty, let apiKey = KeychainStore.load(provider: settings.apiProvider) {
            summary = (try? await llm.sessionSummary(
                provider: settings.apiProvider,
                apiKey: apiKey,
                model: settings.model,
                transcript: transcript
            )) ?? summary
        }
        return SessionPDFExporter.export(entries: sessionLog.entries, summaryZh: summary)
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
            files: contextStore.files,
            questionsHistory: contextStore.questionsHistory,
            summaries: contextStore.answerSummaries,
            meetingMode: settings.meetingMode
        )
        client.start(apiKey: apiKey, model: ProviderConfig.realtimeModel(for: .openai) ?? "gpt-realtime-mini", instructions: instructions)
        realtime = client
    }

    private func startFallback(apiKey: String) {
        vad.reset()
        vad.onSegment = { [weak self] pcm in
            Task { @MainActor in
                await self?.handleFallbackSegment(pcm, apiKey: apiKey)
            }
        }
        let mic = MicCapture(sampleRate: AppConstants.asrSampleRate)
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
            statusMessage = "无法启动麦克风：\(error.localizedDescription)"
            stopListening()
        }
    }

    private func handleFallbackSegment(_ pcm: Data, apiKey: String) async {
        guard listening, !settings.translateMode else { return }
        guard let openaiKey = KeychainStore.load(provider: .openai) ?? (settings.apiProvider == .openai ? apiKey : nil) else {
            statusMessage = "备用路径需要 OpenAI Key 做 Whisper 转写"
            return
        }
        do {
            let result = try await WhisperClient.transcribe(pcm: pcm, sampleRate: Int(AppConstants.asrSampleRate), apiKey: openaiKey)
            let text = result.text
            guard text.count >= 4, StreamingJSONParser().isLikelyActionable(text) || text.contains("?") || text.count > 12 else { return }
            let system: String
            if settings.meetingMode {
                system = PromptBuilder.buildMeetingSystemContent(
                    files: contextStore.files,
                    questionRaw: text,
                    summaries: contextStore.answerSummaries
                )
            } else {
                system = PromptBuilder.buildSystemContent(
                    systemPrompt: PromptCatalog.conciseSystemPrompt(userSystemPrompt: settings.systemPrompt),
                    files: contextStore.files,
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
        ListeningLiveActivityController.start(modeLabel: modeLabel)
        translateVad.reset()
        translateVad.onSegment = { [weak self] pcm in
            Task { @MainActor in
                self?.translateBuffers.append(pcm)
            }
        }
        let mic = MicCapture(sampleRate: AppConstants.asrSampleRate)
        mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        mic.onPCM = { [weak self] data in
            self?.translateVad.ingest(data)
        }
        do {
            try mic.start()
            translateMic = mic
        } catch {
            statusMessage = "无法启动麦克风：\(error.localizedDescription)"
            stopListening()
        }
    }

    private func applyAssist(_ partial: AssistJSON, transcript: String?, done: Bool) {
        if streamStopped { return }
        if AppConstants.isNoiseOrUnrecognized(partial.questionZh) {
            if done { streaming = false }
            return
        }
        if settings.autoDismissCardOnNewQuestion, currentAssist != nil, done || partial.questionZh != nil {
            displayAsReadable = false
        }
        var merged = currentAssist ?? AssistJSON()
        if let q = partial.questionZh, !q.isEmpty { merged.questionZh = q }
        if let c = partial.conciseAnswerEn, !c.isEmpty { merged.conciseAnswerEn = c }
        if let e = partial.expandedAnswerEn, !e.isEmpty { merged.expandedAnswerEn = e }
        if !partial.keywordsEn.isEmpty { merged.keywordsEn = partial.keywordsEn }
        currentAssist = merged
        streaming = !done
        if let q = merged.questionZh {
            ListeningLiveActivityController.update(modeLabel: modeLabel, statusLine: q)
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
        return try await llm.translateAnswersToChinese(
            provider: settings.apiProvider,
            apiKey: apiKey,
            model: settings.model,
            assist: assist
        )
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

    private func inferReplyLanguage(transcript: String, whisperLanguage: String?) -> String {
        let detected = (whisperLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if detected == "en" || detected == "eng" || detected == "english" || detected.contains("english") {
            return "English"
        }
        if detected == "zh" || detected == "zho" || detected == "chi" || detected == "chinese"
            || detected.contains("chinese") || detected.contains("mandarin") || detected.contains("cantonese") {
            return "Chinese"
        }
        if !(whisperLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return whisperLanguage!.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cjk = transcript.range(of: "[\\u{3400}-\\u{9fff}]", options: .regularExpression) != nil
        let latin = (transcript.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil)
        if latin && !cjk { return "English" }
        if cjk { return "Chinese" }
        return "English"
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
