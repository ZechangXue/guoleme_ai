import Foundation

enum ApiProvider: String, Codable, CaseIterable, Identifiable {
    case openai
    case google
    case deepseek
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .google: return "Google (Gemini)"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        }
    }

    func displayName(for language: UILanguage) -> String {
        if self == .qwen { return L10n.t(.qwen, language: language) }
        return displayName
    }
}

enum ResponseStyle: String, Codable, CaseIterable, Identifiable {
    case concise
    case readable
    var id: String { rawValue }
}

enum AnswerLanguage: String, Codable, CaseIterable, Identifiable {
    case en
    case zh
    var id: String { rawValue }
    var label: String { self == .en ? "English" : "中文" }
}

enum ContextDocType: String, Codable, CaseIterable, Identifiable {
    case resume
    case jobDescription = "job_description"
    case qaNotes = "qa_notes"
    case projectNotes = "project_notes"
    case meetingDoc = "meeting_doc"

    var id: String { rawValue }

    var displayName: String { displayName(for: .zh) }

    func displayName(for language: UILanguage) -> String {
        switch self {
        case .resume: return L10n.t(.pasteResume, language: language)
        case .jobDescription: return L10n.t(.pasteJD, language: language)
        case .qaNotes: return L10n.t(.pasteNotes, language: language)
        case .projectNotes: return L10n.t(.docNotes, language: language)
        case .meetingDoc: return L10n.t(.docMeeting, language: language)
        }
    }

    var promptLabel: String {
        switch self {
        case .resume: return "CV / Resume"
        case .jobDescription: return "Job Description"
        case .qaNotes: return "Notes"
        case .projectNotes: return "Project Notes"
        case .meetingDoc: return "Meeting Document"
        }
    }
}

struct AssistJSON: Codable, Equatable {
    var questionZh: String?
    var conciseAnswerEn: String?
    var expandedAnswerEn: String?
    var keywordsEn: [String]
    var thinkingZh: String?

    enum CodingKeys: String, CodingKey {
        case questionZh = "question_zh"
        case conciseAnswerEn = "concise_answer_en"
        case expandedAnswerEn = "expanded_answer_en"
        case keywordsEn = "keywords_en"
        case thinkingZh = "thinking_zh"
    }

    init(
        questionZh: String? = nil,
        conciseAnswerEn: String? = nil,
        expandedAnswerEn: String? = nil,
        keywordsEn: [String] = [],
        thinkingZh: String? = nil
    ) {
        self.questionZh = questionZh
        self.conciseAnswerEn = conciseAnswerEn
        self.expandedAnswerEn = expandedAnswerEn
        self.keywordsEn = keywordsEn
        self.thinkingZh = thinkingZh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionZh = Self.decodeString(c, .questionZh)
        conciseAnswerEn = Self.decodeString(c, .conciseAnswerEn)
        expandedAnswerEn = Self.decodeString(c, .expandedAnswerEn)
        thinkingZh = Self.decodeString(c, .thinkingZh)
        keywordsEn = Self.decodeStringArray(c, .keywordsEn)
    }

    var hasContent: Bool {
        !(questionZh ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(conciseAnswerEn ?? "").isEmpty
            || !(expandedAnswerEn ?? "").isEmpty
            || !(thinkingZh ?? "").isEmpty
            || !keywordsEn.isEmpty
    }

    func fillingMissingAnswers() -> AssistJSON {
        var next = self
        if (next.conciseAnswerEn ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let thinking = next.thinkingZh?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
                next.conciseAnswerEn = thinking
            } else if let expanded = next.expandedAnswerEn?.trimmingCharacters(in: .whitespacesAndNewlines), !expanded.isEmpty {
                next.conciseAnswerEn = String(expanded.prefix(240))
            } else if !next.keywordsEn.isEmpty {
                next.conciseAnswerEn = next.keywordsEn.joined(separator: "; ")
            }
        }
        if (next.expandedAnswerEn ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let thinking = next.thinkingZh?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty,
           thinking != next.conciseAnswerEn {
            next.expandedAnswerEn = thinking
        }
        if (next.questionZh ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, next.hasContent {
            next.questionZh = "屏幕题目"
        }
        return next
    }

    var needsCodingSolution: Bool {
        isCodingProblem && !Self.looksLikeCode(expandedAnswerEn)
    }

    var isCodingProblem: Bool {
        let blob = "\(questionZh ?? "") \(conciseAnswerEn ?? "") \(expandedAnswerEn ?? "") \(keywordsEn.joined(separator: " "))"
        let keys = [
            "leetcode", "listnode", "class solution", "c++",
            "链表", "二叉树", "动态规划", "单调栈",
            "linked list", "binary tree", "two sum", "add two numbers",
            "vector<", "treenode", "hackerrank"
        ]
        let lower = blob.lowercased()
        return keys.contains { lower.contains($0) }
    }

    var inferredCodeLanguage: String {
        let blob = "\(questionZh ?? "") \(conciseAnswerEn ?? "")"
        if blob.contains("C++") || blob.localizedCaseInsensitiveContains("c++") { return "C++" }
        if blob.localizedCaseInsensitiveContains("python") { return "Python" }
        if blob.localizedCaseInsensitiveContains("java") { return "Java" }
        if blob.localizedCaseInsensitiveContains("golang") || blob.range(of: "\\bGo\\b", options: .regularExpression) != nil { return "Go" }
        if blob.localizedCaseInsensitiveContains("javascript") || blob.localizedCaseInsensitiveContains("typescript") { return "JavaScript" }
        if blob.localizedCaseInsensitiveContains("sql") { return "SQL" }
        return "the language shown in the screenshot"
    }

    static func looksLikeCode(_ raw: String?) -> Bool {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 40 else { return false }
        let keys = [
            "class Solution", "ListNode", "TreeNode", "#include", "vector<",
            "def ", "public ", "func ", "SELECT ", "```", "->", "for (", "while ("
        ]
        return keys.contains { text.contains($0) }
    }

    private static func decodeString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? c.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func decodeStringArray(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        if let arr = try? c.decodeIfPresent([String].self, forKey: key) {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let one = try? c.decodeIfPresent(String.self, forKey: key) {
            return one
                .split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

struct AssistStreamChunk {
    var partial: AssistJSON
    var done: Bool
    var interviewerTranscript: String?
}

struct AnswerSummary: Codable, Equatable {
    var questionZh: String
    var conciseAnswerEn: String
    var expandedAnswerEn: String?
    var keywordsEn: [String]?
    var createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case questionZh = "question_zh"
        case conciseAnswerEn = "concise_answer_en"
        case expandedAnswerEn = "expanded_answer_en"
        case keywordsEn = "keywords_en"
        case createdAt
    }
}

struct ContextFile: Codable, Identifiable, Equatable {
    var id: String
    var fileName: String
    var docType: ContextDocType
    var rawText: String
    var createdAt: TimeInterval
}

struct SessionInterviewEntry: Codable, Identifiable {
    var id: String
    var ts: TimeInterval
    var interviewerQuestionRaw: String?
    var questionZh: String
    var conciseAnswerEn: String
    var expandedAnswerEn: String?
    var keywordsEn: [String]?
}

struct TranslateEntry: Identifiable, Equatable {
    var id: UUID
    var text: String
    var timestamp: String
    var streaming: Bool
}

enum AppConstants {
    static let skipTurnQuestionZh = "无法确定问题"
    static let realtimeSampleRate: Double = 24_000
    static let asrSampleRate: Double = 16_000
    /// Translate-summary keeps at most this much audio; unused clicks auto-summarize at this mark.
    static let translateFlushSeconds: Double = 90
    static let keychainService = "InterviewTeleprompterAI"

    static func isNoiseOrUnrecognized(_ question: String?) -> Bool {
        (question ?? "").contains(skipTurnQuestionZh)
    }
}

struct AppSettings: Codable, Equatable {
    var apiProvider: ApiProvider
    var model: String
    var systemPrompt: String
    var useRealtimeAllInOne: Bool
    var responseStyle: ResponseStyle
    var autoDismissCardOnNewQuestion: Bool
    var meetingMode: Bool
    var answerLanguage: AnswerLanguage
    var translateMode: Bool
    var uiLanguage: UILanguage
    var didChooseUILanguage: Bool

    static let `default` = AppSettings(
        apiProvider: .openai,
        model: "gpt-4.1-mini",
        systemPrompt: PromptCatalog.defaultSystem,
        useRealtimeAllInOne: true,
        responseStyle: .concise,
        autoDismissCardOnNewQuestion: true,
        meetingMode: false,
        answerLanguage: .en,
        translateMode: false,
        uiLanguage: .zh,
        didChooseUILanguage: false
    )

    enum CodingKeys: String, CodingKey {
        case apiProvider, model, systemPrompt, useRealtimeAllInOne, responseStyle
        case autoDismissCardOnNewQuestion, meetingMode, answerLanguage, translateMode
        case uiLanguage, didChooseUILanguage
    }

    init(
        apiProvider: ApiProvider,
        model: String,
        systemPrompt: String,
        useRealtimeAllInOne: Bool,
        responseStyle: ResponseStyle,
        autoDismissCardOnNewQuestion: Bool,
        meetingMode: Bool,
        answerLanguage: AnswerLanguage,
        translateMode: Bool,
        uiLanguage: UILanguage,
        didChooseUILanguage: Bool
    ) {
        self.apiProvider = apiProvider
        self.model = model
        self.systemPrompt = systemPrompt
        self.useRealtimeAllInOne = useRealtimeAllInOne
        self.responseStyle = responseStyle
        self.autoDismissCardOnNewQuestion = autoDismissCardOnNewQuestion
        self.meetingMode = meetingMode
        self.answerLanguage = answerLanguage
        self.translateMode = translateMode
        self.uiLanguage = uiLanguage
        self.didChooseUILanguage = didChooseUILanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiProvider = try c.decodeIfPresent(ApiProvider.self, forKey: .apiProvider) ?? .openai
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ProviderConfig.defaultModel(for: .openai)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? PromptCatalog.defaultSystem
        useRealtimeAllInOne = try c.decodeIfPresent(Bool.self, forKey: .useRealtimeAllInOne) ?? true
        responseStyle = try c.decodeIfPresent(ResponseStyle.self, forKey: .responseStyle) ?? .concise
        autoDismissCardOnNewQuestion = try c.decodeIfPresent(Bool.self, forKey: .autoDismissCardOnNewQuestion) ?? true
        meetingMode = try c.decodeIfPresent(Bool.self, forKey: .meetingMode) ?? false
        answerLanguage = try c.decodeIfPresent(AnswerLanguage.self, forKey: .answerLanguage) ?? .en
        translateMode = try c.decodeIfPresent(Bool.self, forKey: .translateMode) ?? false
        uiLanguage = try c.decodeIfPresent(UILanguage.self, forKey: .uiLanguage) ?? .zh
        didChooseUILanguage = try c.decodeIfPresent(Bool.self, forKey: .didChooseUILanguage) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiProvider, forKey: .apiProvider)
        try c.encode(model, forKey: .model)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(useRealtimeAllInOne, forKey: .useRealtimeAllInOne)
        try c.encode(responseStyle, forKey: .responseStyle)
        try c.encode(autoDismissCardOnNewQuestion, forKey: .autoDismissCardOnNewQuestion)
        try c.encode(meetingMode, forKey: .meetingMode)
        try c.encode(answerLanguage, forKey: .answerLanguage)
        try c.encode(translateMode, forKey: .translateMode)
        try c.encode(uiLanguage, forKey: .uiLanguage)
        try c.encode(didChooseUILanguage, forKey: .didChooseUILanguage)
    }
}
