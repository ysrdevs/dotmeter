import Foundation

struct ClaudeMessage: Codable {
    let role: String
    let content: String
}

enum ClaudeError: LocalizedError {
    case http(Int, String)
    case stream(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            switch code {
            case 401: return "That API key was rejected. Check it in Settings."
            case 402: return "Billing problem on your Anthropic account."
            case 404: return "This model isn't available to your account. Pick another in Settings."
            case 429: return "Rate limited. Try again in a moment."
            case 529: return "Anthropic is overloaded right now. Try again shortly."
            default: return "Anthropic returned \(code): \(message)"
            }
        case .stream(let message): return message
        case .refused: return "Claude declined to answer this one."
        }
    }
}

/// Streams `POST /v1/messages` over Server-Sent Events. Raw URLSession because there is no Swift SDK.
struct ClaudeClient {
    var apiKey: String
    var model: String
    var effort: String

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    /// Server-side refusal fallbacks exist on these models; the request is harmless but the param is rejected elsewhere.
    static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable")
    }

    /// `format` is an optional JSON schema for structured output (`output_config.format`).
    func stream(system: String, messages: [ClaudeMessage], format: [String: Any]? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, messages: messages, format: format, useFallbacks: Self.supportsFallbacks(model), continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(system: String, messages: [ClaudeMessage], format: [String: Any]?, useFallbacks: Bool, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if useFallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }

        var outputConfig: [String: Any] = ["effort": effort]
        if let format { outputConfig["format"] = ["type": "json_schema", "schema": format] }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "output_config": outputConfig,
        ]
        if useFallbacks { body["fallbacks"] = "default" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.stream("No response from Anthropic.") }

        if http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            let message = Self.errorMessage(in: text) ?? text
            // If the fallback beta is not enabled for this org, retry once without it rather than failing the whole feature.
            if useFallbacks, http.statusCode == 400, message.contains("anthropic-beta") || message.contains("fallbacks") {
                try await run(system: system, messages: messages, format: format, useFallbacks: false, continuation: continuation)
                return
            }
            throw ClaudeError.http(http.statusCode, message)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    continuation.yield(text)
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                    throw ClaudeError.refused
                }
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Stream error"
                throw ClaudeError.stream(message)
            default:
                break
            }
        }
    }

    private static func errorMessage(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
