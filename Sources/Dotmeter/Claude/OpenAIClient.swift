import Foundation

enum OpenAIError: LocalizedError {
    case http(Int, String, code: String?)
    case stream(String)
    case refused(String)
    case cutOff

    var errorDescription: String? {
        switch self {
        case .http(let status, let message, let code):
            switch status {
            case 401: return "That API key was rejected. Check it in Settings."
            case 403: return "OpenAI will not serve this account or region. \(message)"
            case 404: return "This model isn't available to your OpenAI account."
            case 429:
                // Out of money and going too fast share a status; only one of them is worth retrying.
                return OpenAIClient.isBilling(code: code, message: message)
                    ? "Your OpenAI account is out of credit or over its spending limit."
                    : "Rate limited. Try again in a moment."
            case 500: return "OpenAI had an error on its side. Try again shortly."
            case 503: return "OpenAI is overloaded right now. Try again shortly."
            default: return "OpenAI returned \(status): \(message)"
            }
        case .stream(let message): return message
        case .refused(let text): return text.isEmpty ? "GPT declined to answer this one." : "GPT declined to answer this one: \(text)"
        case .cutOff: return "The answer was cut off before it finished. Try a lower effort."
        }
    }
}

/// Streams `POST /v1/responses` over Server-Sent Events: OpenAI's Responses API, which is where its current
/// models take structured output and reasoning effort. Raw URLSession, like the Claude client beside it.
struct OpenAIClient {
    var apiKey: String
    var model: String
    var effort: String

    /// Reasoning is paid for out of the same allowance as the answer, so the limit is well above what an
    /// answer needs: a report is a few hundred tokens, the thinking before it can be several thousand.
    static let maxOutputTokens = 16_384

    /// Debug: DOTMETER_OPENAI_BASE=http://127.0.0.1:<port>/v1 sends requests to a stand-in on this Mac. Only this
    /// Mac is accepted, so the key can never be pointed anywhere else.
    static var endpoint: URL {
        if let base = ProcessInfo.processInfo.environment["DOTMETER_OPENAI_BASE"], let url = URL(string: base + "/responses"),
           ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") {
            return url
        }
        return URL(string: "https://api.openai.com/v1/responses")!
    }

    func stream(system: String, messages: [ClaudeMessage], format: [String: Any]? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, messages: messages, format: format, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The request body. Nothing is kept on OpenAI's side (`store` is off), and the whole conversation is sent
    /// each time, as with Claude.
    static func body(model: String, effort: String, system: String, messages: [ClaudeMessage], format: [String: Any]?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "store": false,
            "max_output_tokens": maxOutputTokens,
            "reasoning": ["effort": effort],
        ]
        if let format {
            // The report's schema already names every field as required and closes every object, which is
            // what strict mode asks for.
            body["text"] = ["format": ["type": "json_schema", "name": "dotmeter_report", "schema": format, "strict": true]]
        }
        return body
    }

    private func run(system: String, messages: [ClaudeMessage], format: [String: Any]?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, effort: effort, system: system, messages: messages, format: format))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.stream("No response from OpenAI.") }
        if http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            let (message, code) = Self.errorDetail(in: text)
            throw OpenAIError.http(http.statusCode, message ?? text, code: code)
        }
        var refusal = ""
        for try await line in bytes.lines {
            switch try Self.event(in: line) {
            case .text(let text): continuation.yield(text)
            case .refusal(let text): refusal += text
            case .finished:
                if !refusal.isEmpty { throw OpenAIError.refused(refusal) }
                return
            case .nothing: break
            }
        }
        if !refusal.isEmpty { throw OpenAIError.refused(refusal) }
    }

    enum Event: Equatable {
        case text(String)
        case refusal(String)
        case finished
        case nothing
    }

    /// One line of the stream. Each event is an `event:` line naming it and a `data:` line of JSON that names it
    /// again in `type`; only the JSON is read. Text arrives as `response.output_text.delta`, a refusal as
    /// `response.refusal.delta`, and the end as `response.completed`, or as `response.failed`,
    /// `response.incomplete` or `error`, which are thrown.
    static func event(in line: String) throws -> Event {
        guard line.hasPrefix("data:") else { return .nothing }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return .nothing }
        let response = json["response"] as? [String: Any]
        switch type {
        case "response.output_text.delta":
            return (json["delta"] as? String).map(Event.text) ?? .nothing
        case "response.refusal.delta":
            return (json["delta"] as? String).map(Event.refusal) ?? .nothing
        case "response.completed":
            return .finished
        case "response.incomplete":
            let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
            if reason == "content_filter" { throw OpenAIError.refused("") }
            throw OpenAIError.cutOff
        case "response.failed":
            let error = response?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "OpenAI could not finish the answer."
            if isBilling(code: error?["code"] as? String, message: message) { throw OpenAIError.http(429, message, code: error?["code"] as? String) }
            throw OpenAIError.stream(message)
        case "error":
            let nested = json["error"] as? [String: Any]
            throw OpenAIError.stream(json["message"] as? String ?? nested?["message"] as? String ?? "Stream error")
        default:
            return .nothing
        }
    }

    static func isBilling(code: String?, message: String) -> Bool {
        let billing = ["credit_balance_exhausted", "insufficient_quota", "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "billing_hard_limit_reached"]
        if let code, billing.contains(code) { return true }
        return message.localizedCaseInsensitiveContains("quota") || message.localizedCaseInsensitiveContains("billing")
    }

    /// The message and code from an error body: `{"error": {"message": …, "type": …, "code": …}}`. A billing
    /// error may name itself in either `code` or `type`.
    static func errorDetail(in text: String) -> (message: String?, code: String?) {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return (nil, nil) }
        let code = error["code"] as? String, type = error["type"] as? String
        let named = [code, type].compactMap { $0 }.first { isBilling(code: $0, message: "") } ?? code ?? type
        return (error["message"] as? String, named)
    }
}
