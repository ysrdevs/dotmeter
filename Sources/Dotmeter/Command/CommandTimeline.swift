import Foundation

/// The week the app has recorded, read from its file and never written. The app owns the file and saves it every
/// five minutes and when it quits, so what is read here can be that far behind. Nothing is created, trimmed or
/// brought up to date: a command asked about the past must leave the past alone.
struct RecordedWeek {
    var minutes: [TimelineMinute] = []
    var events: [TimelineEvent] = []
    var recordingSince: Date?
    /// The newest minute in the file, before any narrowing: an event with no end was still going on then.
    var lastMinute: Date?
    /// False when there is no file, or nothing in it that can be read.
    var found = false

    /// Where the app keeps it. Debug: DOTMETER_TIMELINE_PATH names another file, as it does for the app.
    static var url: URL? {
        if let override = ProcessInfo.processInfo.environment["DOTMETER_TIMELINE_PATH"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(App.supportFolder, isDirectory: true).appendingPathComponent("timeline.json")
    }

    /// The parts of the file this needs. Each is optional and each event is read on its own, so a file from a newer
    /// version with a kind of event this one has not heard of still gives up the rest.
    private struct File: Decodable {
        var recordingSince: Date?
        var minutes: [TimelineMinute]?
        var events: [Lenient<TimelineEvent>]?
    }

    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Debug: DOTMETER_TIMELINE_DEMO=1 gives the made-up week the app shows under the same switch.
    static func load(from url: URL? = RecordedWeek.url, demo: Bool = ProcessInfo.processInfo.environment["DOTMETER_TIMELINE_DEMO"] == "1") -> RecordedWeek {
        if demo {
            let made = TimelineDemo.make()
            return RecordedWeek(minutes: made.minutes, events: made.events, recordingSince: made.minutes.first?.date, lastMinute: made.minutes.last?.date, found: true)
        }
        guard let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return RecordedWeek() }
        let minutes = file.minutes ?? []
        return RecordedWeek(minutes: minutes, events: (file.events ?? []).compactMap(\.value), recordingSince: file.recordingSince, lastMinute: minutes.last?.date, found: true)
    }

    // MARK: A stretch of it

    struct Day {
        var start: Date
        var minutes: Int
        var cpu: Double
        var cpuPeak: Double
        var hottest: Double?
        var fanPeak: Double
        var wattHours: Double
    }

    struct Event {
        var event: TimelineEvent
        var end: Date?
        var ongoing: Bool

        var duration: TimeInterval { (end ?? Date()).timeIntervalSince(event.start) }
    }

    struct Summary {
        var hours: Int
        var from: Date
        var to: Date
        var minutes = 0
        var cpu = 0.0
        var cpuPeak = 0.0
        var gpu = 0.0
        var memory = 0.0
        var hottest: Double?
        var fanPeak = 0.0
        var wattHours = 0.0
        var averageWatts: Double?
        var received = 0.0
        var sent = 0.0
        var days: [Day] = []
        /// Newest first, and no more than `eventLimit` of them.
        var events: [Event] = []
        var eventsTotal = 0
        var kinds: [(kind: TimelineEvent.Kind, count: Int)] = []
    }

    /// The most events one answer lists. A busy week can hold three hundred, which is more than anyone reads and
    /// more than a model should be handed; `--hours` narrows the stretch to see the earlier ones.
    static let eventLimit = 40
    static let weekHours = TimelineStore.keepMinutes / 60

    func summary(hours asked: Int?, now: Date = Date()) -> Summary {
        let hours = min(max(asked ?? Self.weekHours, 1), Self.weekHours)
        let from = now.addingTimeInterval(-Double(hours) * 3600)
        var summary = Summary(hours: hours, from: from, to: now)
        let cutoff = Int(from.timeIntervalSince1970 / 60)
        let inside = minutes.filter { $0.t >= cutoff }
        summary.minutes = inside.count

        var powered = 0
        var groups: [Date: [TimelineMinute]] = [:]
        let calendar = Calendar.current
        for minute in inside {
            summary.cpu += Double(minute.cpu)
            summary.gpu += Double(minute.gpu)
            summary.memory += Double(minute.memory)
            summary.cpuPeak = max(summary.cpuPeak, Double(minute.cpuPeak))
            if minute.temp > 0 { summary.hottest = max(summary.hottest ?? 0, Double(minute.temp)) }
            summary.fanPeak = max(summary.fanPeak, Double(minute.fan))
            if minute.power > 0 {
                summary.wattHours += Double(minute.power) / 60
                powered += 1
            }
            summary.received += Double(minute.netIn) * 60
            summary.sent += Double(minute.netOut) * 60
            groups[calendar.startOfDay(for: minute.date), default: []].append(minute)
        }
        if !inside.isEmpty {
            let count = Double(inside.count)
            summary.cpu /= count
            summary.gpu /= count
            summary.memory /= count
        }
        if powered > 0 { summary.averageWatts = summary.wattHours * 60 / Double(powered) }
        summary.days = groups.keys.sorted().map { start in
            let list = groups[start] ?? []
            let temperatures = list.map { Double($0.temp) }.filter { $0 > 0 }
            return Day(
                start: start, minutes: list.count,
                cpu: list.reduce(0.0) { $0 + Double($1.cpu) } / Double(max(list.count, 1)),
                cpuPeak: Double(list.map(\.cpuPeak).max() ?? 0), hottest: temperatures.max(),
                fanPeak: Double(list.map(\.fan).max() ?? 0), wattHours: list.reduce(0.0) { $0 + Double($1.power) / 60 }
            )
        }

        // An event with no end was going on when the file was last saved. If that was a moment ago it still is;
        // otherwise it ended, as far as anyone can say, with the last minute recorded.
        let fresh = lastMinute.map { now.timeIntervalSince($0) < 600 } ?? false
        let all = events.map { event -> Event in
            if event.end != nil { return Event(event: event, end: event.end, ongoing: false) }
            return fresh ? Event(event: event, end: nil, ongoing: true) : Event(event: event, end: lastMinute ?? event.start, ongoing: false)
        }.filter { ($0.end ?? now) >= from && $0.event.start <= now }
        summary.eventsTotal = all.count
        summary.events = Array(all.sorted { $0.event.start > $1.event.start }.prefix(Self.eventLimit))
        summary.kinds = TimelineEvent.Kind.allCases.compactMap { kind in
            let count = all.filter { $0.event.kind == kind }.count
            return count > 0 ? (kind, count) : nil
        }
        return summary
    }

    // MARK: As JSON

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func json(hours: Int?, now: Date = Date()) -> JSON {
        guard found, !(minutes.isEmpty && events.isEmpty) else {
            return .record(["recorded": .bool(false), "note": .string("Nothing has been recorded yet. \(App.name) records while it is running.")])
        }
        let s = summary(hours: hours, now: now)
        return .record([
            "recorded": .bool(true),
            "recording_since": JSON.time(recordingSince),
            "last_recorded": JSON.time(lastMinute),
            "hours": .int(Int64(s.hours)),
            "from": JSON.time(s.from),
            "to": JSON.time(s.to),
            "summary": .record([
                "minutes_recorded": .int(Int64(s.minutes)),
                "processor_average": JSON.fraction(s.cpu),
                "processor_peak": JSON.fraction(s.cpuPeak),
                "graphics_average": JSON.fraction(s.gpu),
                "memory_average": JSON.fraction(s.memory),
                "hottest_celsius": JSON.celsius(s.hottest),
                "fan_peak_rpm": JSON.rounded(s.fanPeak),
                "energy_watt_hours": JSON.figure(s.wattHours, places: 1),
                "average_watts": JSON.watts(s.averageWatts),
                "received_bytes": JSON.rounded(s.received),
                "sent_bytes": JSON.rounded(s.sent),
            ]),
            "days": .array(s.days.map { day in
                .record([
                    "day": .string(Self.dayKey.string(from: day.start)),
                    "minutes_recorded": .int(Int64(day.minutes)),
                    "processor_average": JSON.fraction(day.cpu),
                    "processor_peak": JSON.fraction(day.cpuPeak),
                    "hottest_celsius": JSON.celsius(day.hottest),
                    "fan_peak_rpm": JSON.rounded(day.fanPeak),
                    "energy_watt_hours": JSON.figure(day.wattHours, places: 1),
                ])
            }),
            "events_total": .int(Int64(s.eventsTotal)),
            "event_counts": .object(s.kinds.map { ($0.kind.rawValue, .int(Int64($0.count))) }),
            // Newest first.
            "events": .array(s.events.map { item in
                .record([
                    "kind": .string(item.event.kind.rawValue),
                    "title": .string(item.event.kind.title),
                    "start": JSON.time(item.event.start),
                    "end": JSON.time(item.end),
                    "ongoing": item.ongoing ? .bool(true) : nil,
                    "duration_seconds": JSON.rounded(item.duration),
                    "summary": .string(item.event.summary),
                    "peak_celsius": JSON.celsius(item.event.peakCelsius),
                    "peak_fan_rpm": JSON.rounded(item.event.peakRPM),
                    "peak_processor": JSON.fraction(item.event.peakCPU),
                    "apps": item.event.apps.isEmpty ? nil : .array(item.event.apps.map { app in
                        .record(["name": .string(app.name), "cpu_cores": JSON.figure(app.cpu, places: 2)])
                    }),
                ])
            }),
        ])
    }
}
