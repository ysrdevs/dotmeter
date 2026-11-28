import Foundation

/// A JSON value that keeps its keys in the order they were written and its numbers to the digits that mean
/// something. The system's encoder sorts keys by the alphabet or not at all, and prints a load of 0.1 as
/// 0.10000000000000001 on some versions of macOS; a script or a model reading the command's output should see the
/// same shape and the same figures everywhere.
indirect enum JSON {
    case null
    case bool(Bool)
    case int(Int64)
    /// A figure, rounded to that many decimal places when written.
    case number(Double, places: Int)
    case string(String)
    case array([JSON])
    case object([(key: String, value: JSON)])

    // MARK: Building

    /// An object from pairs, leaving out the ones with no value: a key is absent where the Mac does not report it.
    static func record(_ pairs: KeyValuePairs<String, JSON?>) -> JSON {
        .object(pairs.compactMap { pair in pair.value.map { (pair.key, $0) } })
    }

    static func text(_ value: String?) -> JSON? { value.map { .string($0) } }
    static func whole(_ value: Int?) -> JSON? { value.map { .int(Int64($0)) } }
    static func flag(_ value: Bool?) -> JSON? { value.map { .bool($0) } }
    /// A count of bytes.
    static func bytes(_ value: UInt64?) -> JSON? { value.map { .int(Int64(clamping: $0)) } }
    /// Bytes a second, or any other figure that reads best whole.
    static func rounded(_ value: Double?) -> JSON? { value.map { .number($0, places: 0) } }
    /// A share from 0 to 1.
    static func fraction(_ value: Double?) -> JSON? { value.map { .number($0, places: 4) } }
    static func watts(_ value: Double?) -> JSON? { value.map { .number($0, places: 2) } }
    static func celsius(_ value: Double?) -> JSON? { value.map { .number($0, places: 1) } }
    static func figure(_ value: Double?, places: Int = 2) -> JSON? { value.map { .number($0, places: places) } }
    /// A moment, as ISO 8601 in UTC.
    static func time(_ value: Date?) -> JSON? { value.map { .string(stamp.string(from: $0)) } }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: Reading back

    subscript(key: String) -> JSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var keys: [String] {
        guard case .object(let pairs) = self else { return [] }
        return pairs.map(\.key)
    }

    var items: [JSON] {
        guard case .array(let items) = self else { return [] }
        return items
    }

    /// Something parsed by the system's reader, as one of these. Object keys come out sorted, since the reader
    /// does not keep their order.
    init(parsed value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if value.doubleValue == value.doubleValue.rounded(), abs(value.doubleValue) < 9e15 {
                self = .int(value.int64Value)
            } else {
                self = .number(value.doubleValue, places: 6)
            }
        case let value as [Any]:
            self = .array(value.map(JSON.init(parsed:)))
        case let value as [String: Any]:
            self = .object(value.keys.sorted().map { ($0, JSON(parsed: value[$0] as Any)) })
        default:
            self = .null
        }
    }

    // MARK: Writing

    /// On one line, with nothing between the parts: what goes down a pipe to a program.
    var compact: String {
        var out = ""
        write(into: &out, indent: nil, depth: 0)
        return out
    }

    /// Spread over lines, two spaces a level: what a person reads.
    var pretty: String {
        var out = ""
        write(into: &out, indent: "  ", depth: 0)
        return out
    }

    private func write(into out: inout String, indent: String?, depth: Int) {
        func newline(_ depth: Int) {
            guard let indent else { return }
            out += "\n" + String(repeating: indent, count: depth)
        }
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .number(let value, let places):
            out += Self.digits(value, places: places)
        case .string(let value):
            Self.quote(value, into: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            // A row of plain figures stays on its line: the load of each of 28 cores is one thing to look at.
            let plain = items.allSatisfy { if case .array = $0 { return false }; if case .object = $0 { return false }; return true }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += plain && indent != nil ? ", " : "," }
                if !plain { newline(depth + 1) }
                item.write(into: &out, indent: indent, depth: depth + 1)
            }
            if !plain { newline(depth) }
            out += "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { out += "{}"; return }
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                newline(depth + 1)
                Self.quote(pair.key, into: &out)
                out += indent == nil ? ":" : ": "
                pair.value.write(into: &out, indent: indent, depth: depth + 1)
            }
            newline(depth)
            out += "}"
        }
    }

    /// A figure to so many places, without the zeros that say nothing. What is not a number at all is null.
    static func digits(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "null" }
        if places <= 0 {
            let whole = value.rounded()
            return abs(whole) < 9e15 ? String(Int64(whole)) : String(format: "%.0f", whole)
        }
        var text = String(format: "%.\(places)f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func quote(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Control characters, and the two line separators that some readers take for the end of a line.
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
