import CryptoKit
import Foundation
import SystemConfiguration

/// What one Mac tells another about itself, once, when a connection opens.
struct MacHello: Codable, Equatable {
    /// A random id made the first time the feature is switched on. It is how a Mac knows its own advertisement
    /// from another's, and how one Mac reached two ways is listed once.
    var id: String
    /// The name the Mac calls itself (the one in Sharing).
    var name: String
    /// "Mac Studio"
    var model: String
    /// "Apple M3 Ultra"
    var chip: String
    /// The app's version.
    var app: String
}

/// One reading of a Mac, as it goes over the wire: the headline figures and nothing that identifies the network
/// or lists what is running beyond the three busiest apps.
struct MacReading: Codable, Equatable {
    struct App: Codable, Equatable {
        var name: String
        /// Cores in use: 1 is one core kept fully busy.
        var cpu: Double
    }

    struct Battery: Codable, Equatable {
        /// 0...1
        var charge: Double
        var charging: Bool
        var plugged: Bool
        /// Until empty, or until full while charging, when macOS has an estimate.
        var minutes: Int?
    }

    /// Seconds since 1970 on the sender's clock. Freshness is judged by when a reading arrives, not by this.
    var time: Double
    /// Seconds between readings, so the other side knows how long a silence means something.
    var every: Double
    /// 0...1 of all cores.
    var cpu: Double
    var gpu: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    /// "normal", "warning" or "critical".
    var pressure: String
    /// The hottest die sensor, in °C.
    var temperature: Double?
    /// Each fan's speed, in rpm. Empty on a Mac without fans.
    var fans: [Double]
    /// How far the fans are through their range on average, 0...1.
    var fanLevel: Double?
    var watts: Double?
    /// Bytes a second.
    var down: Double
    var up: Double
    var diskFree: UInt64
    var diskTotal: UInt64
    var battery: Battery?
    /// Seconds since the Mac started.
    var uptime: Double
    /// `Severity`'s raw value.
    var severity: Int
    /// The three busiest apps by processor, busiest first.
    var apps: [App]
}

extension MacReading {
    init(snapshot s: Snapshot, every: Double) {
        // The three busiest without sorting the whole list: this runs on every reading while a Mac is watching.
        var top: [AppUsage] = []
        for app in s.apps where app.cpu > 0.001 {
            guard top.count < 3 || app.cpu > (top.last?.cpu ?? 0) else { continue }
            let index = top.firstIndex { app.cpu > $0.cpu } ?? top.count
            top.insert(app, at: index)
            if top.count > 3 { top.removeLast() }
        }
        self.init(
            time: s.timestamp.timeIntervalSince1970,
            every: every,
            cpu: s.cpu.total,
            gpu: s.gpu?.utilization,
            memoryUsed: s.memory.used,
            memoryTotal: s.memory.total,
            pressure: s.memory.pressure.rawValue,
            temperature: s.thermal.hottest?.celsius,
            fans: s.thermal.fans.map { $0.rpm.rounded() },
            fanLevel: s.thermal.fans.isEmpty ? nil : s.thermal.averageFanPercent,
            watts: s.power.total,
            down: s.network.inBytesPerSecond,
            up: s.network.outBytesPerSecond,
            diskFree: s.disk.free,
            diskTotal: s.disk.total,
            battery: s.power.battery.map { Battery(charge: $0.charge, charging: $0.isCharging, plugged: $0.isPluggedIn, minutes: $0.minutesRemaining) },
            uptime: s.system.uptime,
            severity: Severity.from(s).rawValue,
            apps: top.map { App(name: String($0.name.prefix(60)), cpu: $0.cpu) }
        )
    }

    var severityLevel: Severity { Severity(rawValue: severity) ?? .nominal }
    var memoryPressure: MemoryPressure { MemoryPressure(rawValue: pressure) ?? .normal }
    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
}

/// The messages two Macs exchange: one JSON object a line.
///
/// Every message says which version of the protocol wrote it (`v`) and the oldest version able to make sense of
/// it (`needs`, 1 unless a later version has to break with this one). Fields this version does not know are
/// skipped, and kinds of message it does not know are ignored, so a later version can add both.
enum MacsWire {
    static let version = 1
    /// A line longer than this is not one of ours.
    static let lineLimit = 64 * 1024

    enum Message: Equatable {
        case hello(MacHello)
        case reading(MacReading)
        /// The watching side, every few seconds: it is still there.
        case watching
        /// A kind of message a later version sends. Skipped.
        case unknown(String)
        /// Written by a version this one cannot read: the other Mac runs a newer copy.
        case tooNew(needs: Int)
    }

    private struct Envelope: Codable {
        var v: Int
        var needs: Int?
        var type: String
        var hello: MacHello?
        var reading: MacReading?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// One message as one line, newline included.
    static func line(_ message: Message) -> Data {
        var envelope = Envelope(v: version, needs: nil, type: "")
        switch message {
        case .hello(let hello):
            envelope.type = "hello"
            envelope.hello = hello
        case .reading(let reading):
            envelope.type = "reading"
            envelope.reading = reading
        case .watching:
            envelope.type = "watching"
        case .unknown(let type):
            envelope.type = type
        case .tooNew:
            // Only ever read, never written: this version has nothing it needs a newer reader for.
            envelope.type = "unknown"
        }
        // JSON never holds a raw newline (one inside a string is written as \n), so a line is a message.
        var data = (try? encoder.encode(envelope)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Reads one line. Nil when it is not a message at all.
    static func message(from line: Data) -> Message? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return nil }
        if let needs = envelope.needs, needs > version { return .tooNew(needs: needs) }
        switch envelope.type {
        case "hello": return envelope.hello.map(Message.hello)
        case "reading": return envelope.reading.map(Message.reading)
        case "watching": return .watching
        default: return .unknown(envelope.type)
        }
    }
}

/// Cuts a stream of bytes into lines, however the network delivered it.
struct MacsLineBuffer {
    private var pending = Data()
    /// A line ran past the limit: whatever is on the other end is not speaking this protocol.
    private(set) var overflowed = false

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        if pending.count > MacsWire.lineLimit {
            overflowed = true
            pending.removeAll()
        }
        return lines
    }
}

/// The group code: what the user reads from one Mac and types into another. Macs with the same code can read
/// each other; without it nothing can be read.
enum MacsCode {
    /// Letters and digits that cannot be taken for one another when read aloud or copied by hand: no 0 or O,
    /// no 1, I or L, no 2 or Z, no 5 or S, no 8 or B.
    static let alphabet = Array("ACDEFGHJKMNPQRTUVWXY34679")
    static let length = 12

    /// A new code, such as "KQ4M-7TXA-9HWE". Twelve characters of this alphabet are about 55 bits.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return grouped(String(characters))
    }

    /// A typed code in the form it is kept and shown, or nil when it cannot be one. Case, spaces and dashes are
    /// forgiven; a character outside the alphabet is not, since no code contains one.
    static func normalized(_ text: String) -> String? {
        let characters = text.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "–" && $0 != "—" }
        guard characters.count == length, characters.allSatisfy(alphabet.contains) else { return nil }
        return grouped(characters)
    }

    private static func grouped(_ characters: String) -> String {
        stride(from: 0, to: characters.count, by: 4).map { start in
            String(characters.dropFirst(start).prefix(4))
        }.joined(separator: "-")
    }

    /// The key both ends prove they hold when a connection opens: HKDF-SHA256 over the code's twelve characters.
    /// A new label here would be a new protocol: Macs on either side of the change could not read each other.
    static func key(for code: String) -> Data {
        let characters = code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(characters.utf8)),
            salt: Data("Dotmeter Macs".utf8),
            info: Data("group key v1".utf8),
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

/// What this Mac says about itself.
enum MacsIdentity {
    /// The name in System Settings › General › Sharing. Asking the configuration store is immediate, where
    /// `Host.current()` can wait on a name lookup.
    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return SystemInfoProvider.modelName
    }

    static func hello(id: String, name: String? = nil) -> MacHello {
        MacHello(
            id: id,
            name: String((name ?? computerName).prefix(80)),
            model: SystemInfoProvider.modelName,
            chip: SystemInfoProvider.chip,
            app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
    }

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
