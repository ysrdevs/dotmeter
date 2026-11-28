import Foundation

/// Who is using the microphone or the camera: an app, or nobody in particular when macOS does not say.
struct ActivityUser: Hashable {
    /// What its uses are counted under: the app's bundle, or the process's own name.
    var key: String
    /// nil when macOS does not say who (the camera, and the microphone before macOS 14.2).
    var name: String?
    var bundlePath: String?
}

/// Turns "who is using it right now" into Timeline events. One use is one event, from the moment it began to
/// the moment it stopped. A use shorter than a couple of seconds is never written down, and an app that stops
/// and starts again within a few seconds carries on with the event it had.
@MainActor
final class UseLog {
    /// A use has to last this long before it is an event: apps open the microphone for a moment to look at it.
    static let minimum: TimeInterval = 2
    /// Stopping and starting again within this long is one use.
    static let mergeGap: TimeInterval = 5

    private struct Use {
        var user: ActivityUser
        var start: Date
        var stopped: Date?
        var event: UUID?
    }

    let kind: TimelineEvent.Kind
    private let store: TimelineStore
    private var uses: [String: Use] = [:]
    /// Called with each event as it is written down, for the notification.
    var began: (TimelineEvent) -> Void = { _ in }

    init(kind: TimelineEvent.Kind, store: TimelineStore) {
        self.kind = kind
        self.store = store
    }

    /// The users whose use has lasted long enough to count, in the order they began.
    var current: [ActivityUser] {
        uses.values.filter { $0.event != nil && $0.stopped == nil }.sorted { $0.start < $1.start }.map(\.user)
    }

    /// Takes who is using it at this moment. Returns when it wants to be asked again without a change: the moment
    /// a use that has just begun becomes long enough to write down.
    @discardableResult
    func update(_ users: [ActivityUser], at now: Date) -> Date? {
        var present: [String: ActivityUser] = [:]
        for user in users where present[user.key] == nil { present[user.key] = user }

        for (key, use) in uses where use.stopped == nil && present[key] == nil {
            uses[key]?.stopped = now
            if let id = use.event {
                let summary = ActivityWords.finished(kind, user: use.user, seconds: now.timeIntervalSince(use.start))
                store.update(id) { $0.end = now; $0.summary = summary }
            }
        }
        // Past the gap a use is over for good; one that never became an event was too short to mention.
        for (key, use) in uses {
            if let stopped = use.stopped, now.timeIntervalSince(stopped) > Self.mergeGap { uses[key] = nil }
        }
        for (key, user) in present {
            guard var use = uses[key] else {
                uses[key] = Use(user: user, start: now)
                continue
            }
            guard use.stopped != nil else { continue }
            use.stopped = nil
            uses[key] = use
            if let id = use.event {
                let summary = ActivityWords.going(kind, user: use.user)
                store.update(id) { $0.end = nil; $0.summary = summary }
            }
        }

        var next: Date?
        for (key, use) in uses where use.event == nil && use.stopped == nil {
            let due = use.start.addingTimeInterval(Self.minimum)
            if now >= due {
                var event = TimelineEvent(kind: kind, start: use.start, summary: ActivityWords.going(kind, user: use.user))
                if let name = use.user.name { event.apps = [.init(name: name, bundlePath: use.user.bundlePath, cpu: 0)] }
                store.begin(event)
                uses[key]?.event = event.id
                began(event)
            } else {
                next = min(next ?? due, due)
            }
        }
        return next
    }
}

/// The sentences the watch writes.
enum ActivityWords {
    static func going(_ kind: TimelineEvent.Kind, user: ActivityUser) -> String {
        if kind == .camera { return "The camera is on" }
        return user.name.map { "\($0) is using the microphone" } ?? "The microphone is in use"
    }

    static func finished(_ kind: TimelineEvent.Kind, user: ActivityUser, seconds: TimeInterval) -> String {
        let span = span(seconds)
        if kind == .camera { return "The camera was on for \(span)" }
        return user.name.map { "\($0) used the microphone for \(span)" } ?? "The microphone was in use for \(span)"
    }

    /// An event that was still open when the app last quit was closed by the store when it was read back, but
    /// its sentence still says "is". The same sentence in the past, or nil if it is not one of these.
    static func settled(_ event: TimelineEvent) -> String? {
        guard event.kind == .microphone || event.kind == .camera, let end = event.end else { return nil }
        let user = ActivityUser(key: "", name: event.apps.first?.name, bundlePath: nil)
        guard event.summary == going(event.kind, user: user) else { return nil }
        return finished(event.kind, user: user, seconds: end.timeIntervalSince(event.start))
    }

    /// "6 seconds", "31 minutes", "2 hours 5 minutes".
    static func span(_ seconds: TimeInterval) -> String {
        func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
        let whole = max(0, Int(seconds.rounded()))
        if whole < 90 { return count(max(whole, 1), "second") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return count(minutes, "minute") }
        let rest = minutes % 60
        return count(minutes / 60, "hour") + (rest > 0 ? " " + count(rest, "minute") : "")
    }

    static func crashed(_ name: String, times: Int) -> String {
        times > 1 ? "\(name) crashed \(times) times" : "\(name) crashed"
    }
}
