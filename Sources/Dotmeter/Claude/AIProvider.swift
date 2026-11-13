import Foundation

/// Who answers when the app asks for an analysis or an explanation. Each has its own key in the Keychain, its
/// own models and its own endpoint; the prompts, the report and everything on screen are the same for both.
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openai

    var id: String { rawValue }

    /// The company, for keys and bills.
    var company: String { self == .anthropic ? "Anthropic" : "OpenAI" }
    /// What the buttons call it: "Ask Claude", "Ask GPT".
    var assistant: String { self == .anthropic ? "Claude" : "GPT" }
    var host: String { self == .anthropic ? "api.anthropic.com" : "api.openai.com" }
    var keyAccount: String { self == .anthropic ? "anthropic-api-key" : "openai-api-key" }
    var keyPrompt: String { self == .anthropic ? "sk-ant-…" : "sk-…" }
    var keyHelp: String { self == .anthropic ? "From console.anthropic.com → API Keys." : "From platform.openai.com → API keys." }
    /// Debug: this environment variable stands in for the Keychain.
    var keyOverride: String { self == .anthropic ? "DOTMETER_API_KEY" : "DOTMETER_OPENAI_API_KEY" }

    struct Model: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
    }

    var models: [Model] {
        switch self {
        case .anthropic:
            return [
                Model(id: "claude-opus-5-5", title: "Claude Opus 5.5", detail: "Best judgment. Recommended."),
                Model(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", detail: "Fast and sharp."),
                Model(id: "claude-haiku-5-5", title: "Claude Haiku 5.5", detail: "Fastest and cheapest."),
            ]
        case .openai:
            return [Model(id: "gpt-6.1-sol", title: "GPT-6.1 Sol", detail: "OpenAI's GPT-6.1 Sol, through the Responses API.")]
        }
    }

    var defaultModel: String { models[0].id }
    /// Where the chosen model is remembered. Claude keeps the key it always had.
    var modelDefaultsKey: String { self == .anthropic ? "model" : "model.openai" }

    /// The provider in use, readable from anywhere. Settings keeps it in step.
    /// Debug: DOTMETER_PROVIDER=openai chooses for one run without saving the choice.
    nonisolated(unsafe) static var current: AIProvider = AIProvider(rawValue: ProcessInfo.processInfo.environment["DOTMETER_PROVIDER"] ?? UserDefaults.standard.string(forKey: "provider") ?? "") ?? .anthropic
}

/// One way to ask whichever provider is chosen: the same stream of text back from either.
struct AIClient {
    var provider: AIProvider
    var apiKey: String
    var model: String
    var effort: String

    /// The client for the provider chosen in Settings, or nil when it has no key yet.
    @MainActor
    static func current() -> AIClient? {
        let settings = AppSettings.shared
        let provider = settings.provider
        let override = ProcessInfo.processInfo.environment[provider.keyOverride]
        guard let key = override ?? Keychain.read(provider.keyAccount), !key.isEmpty else { return nil }
        return AIClient(provider: provider, apiKey: key, model: settings.activeModel, effort: settings.effort)
    }

    /// `format` is an optional JSON schema for a structured answer.
    func stream(system: String, messages: [ClaudeMessage], format: [String: Any]? = nil) -> AsyncThrowingStream<String, Error> {
        switch provider {
        case .anthropic: return ClaudeClient(apiKey: apiKey, model: model, effort: effort).stream(system: system, messages: messages, format: format)
        case .openai: return OpenAIClient(apiKey: apiKey, model: model, effort: effort).stream(system: system, messages: messages, format: format)
        }
    }
}
