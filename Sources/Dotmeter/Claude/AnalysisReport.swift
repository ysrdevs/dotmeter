import Foundation

/// The structured answer Claude returns for the first analysis. Every field is optional here so a half-streamed
/// JSON document can be rendered progressively; the schema sent to the API requires all of them.
struct AnalysisReport {
    enum Status: String {
        case normal, busy, hot, problem

        var title: String {
            switch self {
            case .normal: return "Normal"
            case .busy: return "Busy"
            case .hot: return "Running hot"
            case .problem: return "Needs attention"
            }
        }
    }

    enum Concern: String {
        case none, watch, fix
    }

    struct Culprit: Identifiable {
        var id: String { name + usage }
        var name: String
        var usage: String
        var reason: String
        var processes: [String]
        var concern: Concern
    }

    struct Action: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        /// The app this step would quit, by the name it has in the snapshot. Empty for any other kind of step.
        var quit: String = ""
    }

    var status: Status?
    var verdict: String?
    var culprits: [Culprit] = []
    var actions: [Action] = []
    var thermal: String?

    var isEmpty: Bool { status == nil && verdict == nil && culprits.isEmpty && actions.isEmpty }

    /// Parses complete or partial JSON. Partial documents are closed off so whatever has fully arrived shows up.
    static func parse(_ text: String) -> AnalysisReport? {
        guard let object = PartialJSON.object(from: text) else { return nil }
        var report = AnalysisReport()
        if let s = object["status"] as? String { report.status = Status(rawValue: s) }
        if let v = object["verdict"] as? String, !v.isEmpty { report.verdict = v }
        if let culprits = object["culprits"] as? [[String: Any]] {
            report.culprits = culprits.compactMap { c in
                guard let name = c["name"] as? String, !name.isEmpty,
                      let usage = c["usage"] as? String,
                      let reason = c["reason"] as? String else { return nil }
                return Culprit(
                    name: name,
                    usage: usage,
                    reason: reason,
                    processes: (c["processes"] as? [String]) ?? [],
                    concern: Concern(rawValue: c["concern"] as? String ?? "") ?? .none
                )
            }
        }
        if let actions = object["actions"] as? [[String: Any]] {
            report.actions = actions.compactMap { a in
                guard let title = a["title"] as? String, !title.isEmpty, let detail = a["detail"] as? String else { return nil }
                return Action(title: title, detail: detail, quit: (a["quit"] as? String) ?? "")
            }
        }
        if let t = object["thermal"] as? String, !t.isEmpty { report.thermal = t }
        return report.isEmpty ? nil : report
    }

    /// Plain-text rendering for the clipboard.
    var plainText: String {
        var lines: [String] = []
        if let status { lines.append(status.title.uppercased()) }
        if let verdict { lines.append(verdict) }
        if !culprits.isEmpty {
            lines.append("")
            lines.append("What's using it")
            for c in culprits {
                var line = "- \(c.name) — \(c.usage): \(c.reason)"
                if !c.processes.isEmpty { line += " (\(c.processes.joined(separator: ", ")))" }
                lines.append(line)
            }
        }
        if !actions.isEmpty {
            lines.append("")
            lines.append("What to do")
            for (i, a) in actions.enumerated() { lines.append("\(i + 1). \(a.title): \(a.detail)") }
        }
        if let thermal { lines.append(""); lines.append(thermal) }
        return lines.joined(separator: "\n")
    }

    /// JSON schema sent as `output_config.format`. Mirrors the struct above; all fields required, no extra keys.
    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["status", "verdict", "culprits", "actions", "thermal"],
        "properties": [
            "status": [
                "type": "string",
                "enum": ["normal", "busy", "hot", "problem"],
                "description": "normal = nothing unusual; busy = legitimately working hard; hot = fans or temperatures are high; problem = something is wrong and the user should act",
            ],
            "verdict": [
                "type": "string",
                "description": "One or two plain sentences: what is going on and whether it is normal, with the key numbers",
            ],
            "culprits": [
                "type": "array",
                "description": "The 3 to 5 biggest resource consumers right now, biggest first, even when everything is normal",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["name", "usage", "reason", "processes", "concern"],
                    "properties": [
                        "name": ["type": "string", "description": "App or process name exactly as it appears in the snapshot"],
                        "usage": ["type": "string", "description": "Headline figure, for example \"167% CPU\", \"14.4 GB\" or \"49% GPU\""],
                        "reason": ["type": "string", "description": "Why it is busy and whether that is expected, one short sentence"],
                        "processes": ["type": "array", "items": ["type": "string"], "description": "Specific helper processes involved, taken from the snapshot; empty when the app is a single process"],
                        "concern": ["type": "string", "enum": ["none", "watch", "fix"], "description": "none = expected; watch = worth re-checking later; fix = the user should act on it"],
                    ],
                ],
            ],
            "actions": [
                "type": "array",
                "description": "1 to 4 concrete steps, most effective first. If nothing is needed, a single entry that says so",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "detail", "quit"],
                    "properties": [
                        "quit": ["type": "string", "description": "If this step is to quit one app, that app's name exactly as it appears in top_apps, so the app can offer a Quit button; otherwise an empty string"],
                        "title": ["type": "string", "description": "Three to six words, imperative, for example \"Quit the stuck helper\" or \"Nothing to do\""],
                        "detail": ["type": "string", "description": "One sentence of specifics: what, where, and what it will change"],
                    ],
                ],
            ],
            "thermal": [
                "type": "string",
                "description": "One sentence on fans and temperature, saying whether the current fan speed is justified by the load; empty string if unremarkable",
            ],
        ],
    ]
}

/// Closes an unfinished JSON document (open strings, arrays, objects) so it can be parsed while still streaming.
enum PartialJSON {
    static func object(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{") else { return nil }
        var candidate = String(trimmed[start...])
        for _ in 0..<12 {
            if let data = completed(candidate).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            // Drop back to the last comma so a half-written key/value pair does not poison the parse.
            guard let comma = candidate.lastIndex(of: ",") else { return nil }
            candidate = String(candidate[..<comma])
        }
        return nil
    }

    private static func completed(_ text: String) -> String {
        var closers: [Character] = []
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": closers.append("}")
            case "[": closers.append("]")
            case "}", "]": if !closers.isEmpty { closers.removeLast() }
            default: break
            }
        }
        var result = text
        if escaped { result.removeLast() }
        if inString { result += "\"" }
        // A trailing comma or colon leaves the document invalid; strip them before closing.
        while let last = result.last, last == "," || last == ":" || last == " " || last == "\n" {
            if last == ":" {
                // Remove the dangling key as well.
                result.removeLast()
                if let quote = result.lastIndex(of: "\"") {
                    let before = result[..<quote]
                    if let keyStart = before.lastIndex(of: "\"") { result = String(result[..<keyStart]) }
                }
                while let l = result.last, l == "," || l == " " || l == "\n" { result.removeLast() }
                break
            }
            result.removeLast()
        }
        return result + String(closers.reversed())
    }
}
