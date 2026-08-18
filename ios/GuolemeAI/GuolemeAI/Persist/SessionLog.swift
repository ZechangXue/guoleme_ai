import Foundation

@MainActor
final class SessionLog: ObservableObject {
    @Published private(set) var entries: [SessionInterviewEntry] = []

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuolemeAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("session-log.json")
        load()
    }

    func append(
        raw: String?,
        assist: AssistJSON
    ) {
        let question = (assist.questionZh ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !AppConstants.isNoiseOrUnrecognized(question) else { return }
        let entry = SessionInterviewEntry(
            id: UUID().uuidString,
            ts: Date().timeIntervalSince1970,
            interviewerQuestionRaw: raw,
            questionZh: question,
            conciseAnswerEn: assist.conciseAnswerEn ?? "",
            expandedAnswerEn: assist.expandedAnswerEn,
            keywordsEn: assist.keywordsEn.isEmpty ? nil : assist.keywordsEn
        )
        entries.append(entry)
        persist()
    }

    func updateExpanded(questionZh: String, concise: String, expanded: String) {
        guard let idx = entries.lastIndex(where: { $0.questionZh == questionZh }) else { return }
        entries[idx].conciseAnswerEn = concise
        entries[idx].expandedAnswerEn = expanded
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    func transcriptForSummary() -> String {
        entries.enumerated().map { index, e in
            var lines = [
                "【第 \(index + 1) 轮】",
                "面试官原话（语音转写）：\(e.interviewerQuestionRaw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "（本轮无逐字转写）")",
                "卡片题摘要（中文）：\(e.questionZh)",
                "极简一句（英文）：\(e.conciseAnswerEn)"
            ]
            if let expanded = e.expandedAnswerEn?.trimmingCharacters(in: .whitespacesAndNewlines), !expanded.isEmpty {
                lines.append("可读展开（英文）：\(expanded)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SessionInterviewEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
