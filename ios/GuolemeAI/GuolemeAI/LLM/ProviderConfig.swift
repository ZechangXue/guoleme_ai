import Foundation

enum ProviderConfig {
    static func defaultModel(for provider: ApiProvider) -> String {
        switch provider {
        case .openai: return "gpt-5-mini"
        case .anthropic: return "claude-opus-5-5"
        case .google: return "gemini-2.0-flash"
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-turbo"
        }
    }

    static func realtimeModel(for provider: ApiProvider) -> String? {
        provider == .openai ? "gpt-realtime-mini" : nil
    }

    static func chatBaseURL(for provider: ApiProvider) -> URL {
        switch provider {
        case .openai: return URL(string: "https://api.openai.com/v1")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1")!
        case .deepseek: return URL(string: "https://api.deepseek.com")!
        case .qwen: return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        case .google: return URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        }
    }

    static var supportsVision: (ApiProvider) -> Bool = { provider in
        provider == .openai || provider == .anthropic || provider == .google
    }

    static func isGpt5Family(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gpt-5")
    }

    /// GPT-5：省略 temperature、改用 max_completion_tokens，并加 reasoning_effort。
    static func applyOpenAIChatParams(
        to body: inout [String: Any],
        model: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        if isGpt5Family(model) {
            body.removeValue(forKey: "temperature")
            body.removeValue(forKey: "max_tokens")
            body["reasoning_effort"] = model.lowercased().hasPrefix("gpt-5.") ? "none" : "minimal"
            if let maxTokens {
                body["max_completion_tokens"] = maxTokens
            }
        } else {
            if let temperature {
                body["temperature"] = temperature
            }
            if let maxTokens {
                body["max_tokens"] = maxTokens
            }
        }
    }
}
