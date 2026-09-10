import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persist() }
    }

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuolemeAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
            migrateLegacySystemPromptIfNeeded()
            migrateDefaultChatModelIfNeeded()
        } else {
            settings = .default
        }
    }

    private func migrateLegacySystemPromptIfNeeded() {
        let prompt = settings.systemPrompt
        guard prompt.contains("thinking_zh"), prompt.contains("keywords_en"), prompt.contains("强制输出格式") else { return }
        update { $0.systemPrompt = PromptCatalog.defaultSystem }
    }

    private func migrateDefaultChatModelIfNeeded() {
        let model = settings.model
        let legacy = ["instant", "gpt-4.1-mini", "gpt-4o-mini", "gpt-4o", "gpt-4.1"]
        guard legacy.contains(model) else { return }
        update { $0.model = ProviderConfig.defaultModel(for: .openai) }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = next
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
