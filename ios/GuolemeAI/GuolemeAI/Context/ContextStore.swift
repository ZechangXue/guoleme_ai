import Foundation

@MainActor
final class ContextStore: ObservableObject {
    @Published private(set) var files: [ContextFile] = []
    @Published private(set) var questionsHistory: [String] = []
    @Published private(set) var answerSummaries: [AnswerSummary] = []
    @Published var pasteResume: String = ""
    @Published var pasteJD: String = ""
    @Published var pasteNotes: String = ""

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuolemeAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("context.json")
        load()
    }

    var resumeText: String {
        files.filter { $0.docType == .resume }.map(\.rawText).joined(separator: "\n\n").nilIfEmpty ?? pasteResume
    }

    var jdText: String {
        files.filter { $0.docType == .jobDescription }.map(\.rawText).joined(separator: "\n\n").nilIfEmpty ?? pasteJD
    }

    var notesText: String {
        let fromFiles = files.filter { $0.docType == .qaNotes || $0.docType == .projectNotes }.map(\.rawText).joined(separator: "\n\n")
        return fromFiles.nilIfEmpty ?? pasteNotes
    }

    func addFile(name: String, docType: ContextDocType, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        files.append(ContextFile(
            id: UUID().uuidString,
            fileName: name,
            docType: docType,
            rawText: trimmed,
            createdAt: Date().timeIntervalSince1970
        ))
        persist()
    }

    func remove(id: String) {
        files.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        files.removeAll()
        persist()
    }

    func savePasteFields() {
        if !pasteResume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            files.removeAll { $0.fileName == "粘贴的简历" && $0.docType == .resume }
            addFile(name: "粘贴的简历", docType: .resume, text: pasteResume)
        }
        if !pasteJD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            files.removeAll { $0.fileName == "粘贴的JD" && $0.docType == .jobDescription }
            addFile(name: "粘贴的JD", docType: .jobDescription, text: pasteJD)
        }
        if !pasteNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            files.removeAll { $0.fileName == "粘贴的笔记" && $0.docType == .qaNotes }
            addFile(name: "粘贴的笔记", docType: .qaNotes, text: pasteNotes)
        }
        persist()
    }

    func pushQuestion(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !AppConstants.isNoiseOrUnrecognized(q) else { return }
        questionsHistory.append(q)
        if questionsHistory.count > 30 {
            questionsHistory = Array(questionsHistory.suffix(30))
        }
        persist()
    }

    func pushSummary(from assist: AssistJSON) {
        let q = (assist.questionZh ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !AppConstants.isNoiseOrUnrecognized(q) else { return }
        answerSummaries.append(AnswerSummary(
            questionZh: q,
            conciseAnswerEn: assist.conciseAnswerEn ?? "",
            expandedAnswerEn: assist.expandedAnswerEn,
            keywordsEn: assist.keywordsEn,
            createdAt: Date().timeIntervalSince1970
        ))
        if answerSummaries.count > 12 {
            answerSummaries = Array(answerSummaries.suffix(12))
        }
        persist()
    }

    func mergeExpanded(questionZh: String, concise: String, expanded: String) {
        guard let idx = answerSummaries.lastIndex(where: { $0.questionZh == questionZh }) else { return }
        answerSummaries[idx].conciseAnswerEn = concise
        answerSummaries[idx].expandedAnswerEn = expanded
        persist()
    }

    private struct Disk: Codable {
        var files: [ContextFile]
        var questionsHistory: [String]
        var answerSummaries: [AnswerSummary]
        var pasteResume: String
        var pasteJD: String
        var pasteNotes: String
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let disk = try? JSONDecoder().decode(Disk.self, from: data) else { return }
        files = disk.files
        questionsHistory = disk.questionsHistory
        answerSummaries = disk.answerSummaries
        pasteResume = disk.pasteResume
        pasteJD = disk.pasteJD
        pasteNotes = disk.pasteNotes
    }

    private func persist() {
        let disk = Disk(
            files: files,
            questionsHistory: questionsHistory,
            answerSummaries: answerSummaries,
            pasteResume: pasteResume,
            pasteJD: pasteJD,
            pasteNotes: pasteNotes
        )
        if let data = try? JSONEncoder().encode(disk) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
