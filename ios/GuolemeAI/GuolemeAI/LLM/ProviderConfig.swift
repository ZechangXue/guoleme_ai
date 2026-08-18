import Foundation

enum ProviderConfig {
    static func defaultModel(for provider: ApiProvider) -> String {
        switch provider {
        case .openai: return "gpt-4.1-mini"
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
        case .deepseek: return URL(string: "https://api.deepseek.com")!
        case .qwen: return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        case .google: return URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        }
    }

    static var isOpenAICompatible: (ApiProvider) -> Bool = { provider in
        provider == .openai || provider == .deepseek || provider == .qwen
    }
}
