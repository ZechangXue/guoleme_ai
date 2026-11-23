import Foundation

// MARK: - Meeting assistant models (mirrors the desktop v3.0.0 meeting assistant)

enum MeetingScene: String, Codable, CaseIterable, Identifiable {
    case weekly
    case project
    case partner
    case interviewer

    var id: String { rawValue }

    var labelZh: String {
        switch self {
        case .weekly: return "周组会进展"
        case .project: return "新项目 / 方案探讨"
        case .partner: return "合作方技术会谈"
        case .interviewer: return "面试（我是面试官）"
        }
    }

    func label(_ language: UILanguage) -> String {
        guard language == .en else { return labelZh }
        switch self {
        case .weekly: return "Weekly team update"
        case .project: return "New project discussion"
        case .partner: return "Partner technical meeting"
        case .interviewer: return "Interview (I'm the interviewer)"
        }
    }
}

enum MeetingTrigger: String, Codable, CaseIterable, Identifiable {
    case mention
    case all
    case manual

    var id: String { rawValue }

    func label(_ language: UILanguage) -> String {
        switch self {
        case .mention: return language == .en ? "Only when I'm addressed" : "点到我才弹"
        case .all: return language == .en ? "Every question" : "所有问题都弹"
        case .manual: return language == .en ? "Only when I tap" : "只按按钮"
        }
    }

    func hint(_ language: UILanguage) -> String {
        switch self {
        case .mention:
            return language == .en
                ? "Pops a card when your name / keywords or a direct cue (\"what do you think\", \"over to you\") is heard."
                : "听到你的名字 / 关键词，或「what do you think」「over to you」这类点名句式时弹卡。"
        case .all:
            return language == .en ? "Pops a card for any question-like utterance. Noisier." : "只要像问题就弹卡，比较频繁。"
        case .manual:
            return language == .en ? "Never pops automatically. Tap \"Answer that\" when needed." : "不自动弹，需要时点「回答刚才的问题」。"
        }
    }
}

enum MeetingTriggerKind: String {
    case auto
    case mention
    case manual
    case screenshot
}

struct MeetingTranscriptLine: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var at: TimeInterval
}

struct MeetingLikelyQuestion: Codable, Equatable, Identifiable {
    var id: String
    var asker: String?
    var questionEn: String
    var questionZh: String?
    var answerEn: String
}

struct MeetingPrep: Codable, Equatable {
    var updateScript: String
    var likelyQuestions: [MeetingLikelyQuestion]
    var decisionsNeeded: [String]
    var generatedAt: TimeInterval
}

struct MeetingSessionCard: Codable, Equatable {
    var questionZh: String
    var answer: String
    var at: TimeInterval
}

struct MeetingSession: Codable, Equatable, Identifiable {
    var id: String
    var scene: MeetingScene
    var startedAt: TimeInterval
    var lastActiveAt: TimeInterval
    var endedAt: TimeInterval?
    var cards: [MeetingSessionCard]
    var transcript: [MeetingTranscriptLine]
    var digestZh: String?
    var commitments: [String]?
}

struct MeetingProfileState: Codable, Equatable {
    var personaText: String = ""
    var weeklyNotes: String = ""
    var prep: MeetingPrep?
    /// Newest first.
    var sessions: [MeetingSession] = []
    var activeSessionId: String?
}

/// A live answer card shown during a meeting (not persisted as-is).
struct MeetingCard: Equatable, Identifiable {
    var id: String = UUID().uuidString
    var trigger: MeetingTriggerKind = .auto
    var questionZh: String = ""
    var qType: String = ""
    var opener: String = ""
    var points: [String] = []
    var concise: String = ""
    var expanded: String = ""
    var source: String = ""
    var caution: String = ""
    var done = false
    var error: String?
}

// MARK: - Persistence

@MainActor
final class MeetingProfileStore: ObservableObject {
    @Published private(set) var state = MeetingProfileState()

    static let sessionIdleGap: TimeInterval = 2 * 3600
    static let maxSessions = 20
    static let maxTranscriptLines = 600

    private let url: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuolemeAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("meeting-profile.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(MeetingProfileState.self, from: data) {
            state = decoded
        }
    }

    var activeSession: MeetingSession? {
        guard let id = state.activeSessionId else { return nil }
        return state.sessions.first { $0.id == id }
    }

    func setPersona(_ text: String) {
        state.personaText = text
        scheduleSave()
    }

    func setWeeklyNotes(_ text: String) {
        state.weeklyNotes = text
        scheduleSave()
    }

    func setPrep(_ prep: MeetingPrep?) {
        state.prep = prep
        scheduleSave()
    }

    /// Reuses the active session when it was active recently, otherwise starts a new one.
    @discardableResult
    func ensureActiveSession(scene: MeetingScene) -> MeetingSession {
        let now = Date().timeIntervalSince1970
        if let idx = activeIndex(), now - state.sessions[idx].lastActiveAt < Self.sessionIdleGap {
            state.sessions[idx].lastActiveAt = now
            state.sessions[idx].scene = scene
            scheduleSave()
            return state.sessions[idx]
        }
        _ = endActiveSession()
        let session = MeetingSession(
            id: UUID().uuidString,
            scene: scene,
            startedAt: now,
            lastActiveAt: now,
            endedAt: nil,
            cards: [],
            transcript: [],
            digestZh: nil,
            commitments: nil
        )
        state.sessions.insert(session, at: 0)
        if state.sessions.count > Self.maxSessions {
            state.sessions = Array(state.sessions.prefix(Self.maxSessions))
        }
        state.activeSessionId = session.id
        scheduleSave()
        return session
    }

    func appendTranscript(_ line: MeetingTranscriptLine) {
        guard let idx = activeIndex() else { return }
        state.sessions[idx].transcript.append(line)
        if state.sessions[idx].transcript.count > Self.maxTranscriptLines {
            state.sessions[idx].transcript.removeFirst(state.sessions[idx].transcript.count - Self.maxTranscriptLines)
        }
        state.sessions[idx].lastActiveAt = line.at
        scheduleSave()
    }

    func appendCard(questionZh: String, answer: String) {
        guard let idx = activeIndex() else { return }
        let now = Date().timeIntervalSince1970
        state.sessions[idx].cards.append(MeetingSessionCard(questionZh: questionZh, answer: answer, at: now))
        state.sessions[idx].lastActiveAt = now
        scheduleSave()
    }

    /// Ends the active session. Returns it if it had any content (empty sessions are dropped).
    @discardableResult
    func endActiveSession() -> MeetingSession? {
        guard let idx = activeIndex() else {
            state.activeSessionId = nil
            return nil
        }
        state.activeSessionId = nil
        if state.sessions[idx].cards.isEmpty && state.sessions[idx].transcript.isEmpty {
            state.sessions.remove(at: idx)
            scheduleSave()
            return nil
        }
        state.sessions[idx].endedAt = Date().timeIntervalSince1970
        scheduleSave()
        return state.sessions[idx]
    }

    func setDigest(sessionId: String, digest: String, commitments: [String]) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        state.sessions[idx].digestZh = digest
        state.sessions[idx].commitments = commitments
        scheduleSave()
    }

    func deleteSession(id: String) {
        state.sessions.removeAll { $0.id == id }
        if state.activeSessionId == id { state.activeSessionId = nil }
        scheduleSave()
    }

    func clearSessions() {
        state.sessions = []
        state.activeSessionId = nil
        scheduleSave()
    }

    func undigestedEndedSessions() -> [MeetingSession] {
        state.sessions.filter { $0.id != state.activeSessionId && $0.endedAt != nil && ($0.digestZh ?? "").isEmpty }
    }

    func recentDigestedSessions(limit: Int) -> [MeetingSession] {
        Array(state.sessions.filter { !($0.digestZh ?? "").isEmpty }.prefix(limit))
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func activeIndex() -> Int? {
        guard let id = state.activeSessionId else { return nil }
        return state.sessions.firstIndex { $0.id == id }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
