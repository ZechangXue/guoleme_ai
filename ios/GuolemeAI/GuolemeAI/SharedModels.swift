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
        case .qwen: return "千问 (Qwen)"
        }
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

    var displayName: String {
        switch self {
        case .resume: return "简历 / CV"
        case .jobDescription: return "职位描述 / JD"
        case .qaNotes: return "笔记"
        case .projectNotes: return "项目笔记"
        case .meetingDoc: return "会议 / 项目文档"
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
        questionZh = try c.decodeIfPresent(String.self, forKey: .questionZh)
        conciseAnswerEn = try c.decodeIfPresent(String.self, forKey: .conciseAnswerEn)
        expandedAnswerEn = try c.decodeIfPresent(String.self, forKey: .expandedAnswerEn)
        keywordsEn = try c.decodeIfPresent([String].self, forKey: .keywordsEn) ?? []
        thinkingZh = try c.decodeIfPresent(String.self, forKey: .thinkingZh)
    }

    var hasContent: Bool {
        !(questionZh ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(conciseAnswerEn ?? "").isEmpty
            || !(expandedAnswerEn ?? "").isEmpty
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

    static let `default` = AppSettings(
        apiProvider: .openai,
        model: "gpt-4.1-mini",
        systemPrompt: PromptCatalog.defaultSystem,
        useRealtimeAllInOne: true,
        responseStyle: .concise,
        autoDismissCardOnNewQuestion: true,
        meetingMode: false,
        answerLanguage: .en,
        translateMode: false
    )
}
