import Foundation
import Observation

/// One stretch of time a followed cable was plugged in, and how the connection came up.
struct CableSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var port: String
    var partner: String?
    var bitsPerSecond: Double?
    var family: String?
    var watts: Double?
    var verdict: String?
    /// The connection came up slower than its parts allow, or the port logged errors while it was in.
    var trouble = false
}

struct SavedCable: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var added: Date
    var marker: CableMarker
    var sessions: [CableSession] = []

    var lastUsed: Date? { sessions.map(\.end).max() }
    var troubled: Int { sessions.filter(\.trouble).count }

    /// The all-time record in a sentence.
    var record: String {
        guard !sessions.isEmpty else { return "Not seen since it was added." }
        let uses = sessions.count == 1 ? "Seen once" : "Seen \(sessions.count) times"
        let speeds = Set(sessions.compactMap(\.bitsPerSecond))
        var parts = [uses]
        if speeds.count == 1, let only = speeds.first { parts.append("always at \(Format.linkSpeed(only))") }
        else if let low = speeds.min(), let high = speeds.max() { parts.append("between \(Format.linkSpeed(low)) and \(Format.linkSpeed(high))") }
        if let watts = sessions.compactMap(\.watts).max() { parts.append("charging at up to \(Int(watts.rounded())) W") }
        return parts.joined(separator: ", ") + "."
    }

    /// What the record says about the cable.
    var verdict: (title: String, caution: Bool) {
        guard sessions.count >= 2 else { return ("Too few connections to judge yet", false) }
        if troubled == 0 { return ("Has behaved every time", false) }
        if troubled * 2 >= sessions.count { return ("Misbehaves more often than not: \(troubled) of \(sessions.count) connections", true) }
        return ("Has misbehaved \(troubled) of \(sessions.count) times", true)
    }
}

/// Cables the user chose to follow. A cable is recognised by what its marker says (maker, product, version,
/// certificate and capabilities), so two cables of the same make and model share one record: nothing in a marker
/// tells them apart. A cable with no marker cannot be followed at all.
@MainActor
@Observable
final class CableStore {
    private(set) var cables: [SavedCable] = []
    /// Called when the list goes from empty to not, or back, so the ports are only read in the background while
    /// there is a cable to follow.
    @ObservationIgnored var followingChanged: ((Bool) -> Void)?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date.distantPast

    static let sessionLimit = 300
    /// Readings closer together than this belong to one connection.
    static let sameConnection: TimeInterval = 180

    init() {
        let environment = ProcessInfo.processInfo.environment
        if USBSampler.demo != nil {
            url = nil
            cables = USBDemo.savedCables()
            return
        }
        if let override = environment["DOTMETER_CABLES_PATH"] {
            url = URL(fileURLWithPath: override)
        } else if let timeline = environment["DOTMETER_TIMELINE_PATH"] {
            // Test runs name a scratch file for the timeline; the cables go beside it, never into the real record.
            url = URL(fileURLWithPath: timeline).deletingLastPathComponent().appendingPathComponent("cables-test.json")
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            url = support.appendingPathComponent(App.supportFolder, isDirectory: true).appendingPathComponent("cables.json")
        } else {
            url = nil
        }
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder.iso.decode([SavedCable].self, from: data) { cables = saved }
    }

    nonisolated static func fingerprint(_ marker: CableMarker) -> String {
        marker.identity.fingerprint + String(format: ":%08x", marker.identity.vdos.count > 3 ? marker.identity.vdos[3] : 0)
    }

    func saved(_ marker: CableMarker?) -> SavedCable? {
        guard let marker else { return nil }
        let id = Self.fingerprint(marker)
        return cables.first { $0.id == id }
    }

    func add(_ marker: CableMarker, name: String) {
        let id = Self.fingerprint(marker)
        guard !cables.contains(where: { $0.id == id }) else { return }
        let tidy = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cables.append(SavedCable(id: id, name: tidy.isEmpty ? "\(marker.speedText) cable" : tidy, added: Date(), marker: marker))
        if cables.count == 1 { followingChanged?(true) }
        saveNow()
    }

    func rename(_ id: String, to name: String) {
        let tidy = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tidy.isEmpty, let index = cables.firstIndex(where: { $0.id == id }), cables[index].name != tidy else { return }
        cables[index].name = tidy
        saveNow()
    }

    func remove(_ id: String) {
        cables.removeAll { $0.id == id }
        if cables.isEmpty { followingChanged?(false) }
        saveNow()
    }

    /// Notes what every followed cable that is plugged in is doing now.
    func record(_ stats: USBStats, at now: Date = Date()) {
        guard !cables.isEmpty else { return }
        for port in stats.ports where port.connected {
            guard let marker = port.cable, let index = cables.firstIndex(where: { $0.id == Self.fingerprint(marker) }) else { continue }
            let diagnosis = USBDiagnostics.diagnose(port, charger: stats.charger)
            let trouble = diagnosis.speed?.title == "Running slower than expected" || (port.health?.troubles ?? 0) > 0
            let partner = port.thunderbolt?.deviceName ?? port.devices.first?.name
            let title = stats.title(port)
            if let open = cables[index].sessions.lastIndex(where: { $0.port == title && now.timeIntervalSince($0.end) < Self.sameConnection }) {
                cables[index].sessions[open].end = now
                cables[index].sessions[open].bitsPerSecond = diagnosis.negotiated ?? cables[index].sessions[open].bitsPerSecond
                cables[index].sessions[open].verdict = diagnosis.speed?.title ?? cables[index].sessions[open].verdict
                cables[index].sessions[open].trouble = cables[index].sessions[open].trouble || trouble
            } else {
                cables[index].sessions.append(CableSession(
                    start: now, end: now, port: title, partner: partner, bitsPerSecond: diagnosis.negotiated, family: diagnosis.negotiatedName,
                    watts: port.powerSource?.watts, verdict: diagnosis.speed?.title, trouble: trouble
                ))
                if cables[index].sessions.count > Self.sessionLimit { cables[index].sessions.removeFirst(cables[index].sessions.count - Self.sessionLimit) }
            }
            dirty = true
        }
        if dirty, now.timeIntervalSince(lastSave) > 120 { saveNow() }
    }

    func saveNow() {
        guard let url else { return }
        lastSave = Date()
        dirty = false
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(cables) { try? data.write(to: url, options: .atomic) }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
