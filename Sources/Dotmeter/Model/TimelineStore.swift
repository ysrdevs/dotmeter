import Foundation
import Observation

/// One minute of the machine, averaged. A week of these is about ten thousand records.
struct TimelineMinute: Codable {
    /// Minutes since 1970.
    var t: Int
    var cpu: Float
    var cpuPeak: Float
    var gpu: Float
    var memory: Float
    /// Hottest die sensor, in °C. Zero when there was no reading.
    var temp: Float
    var fan: Float
    var netIn: Float
    var netOut: Float
    var power: Float
    var disk: Float
    /// Charge, 0...1, on a Mac with a battery. Absent on the rest, and in records from before 1.4.
    var battery: Float? = nil

    var date: Date { Date(timeIntervalSince1970: Double(t) * 60) }
}

/// What one calendar day drew, kept for good: the minute records only go back a week, and a month's or a
/// year's cost needs longer than that. One small entry a day.
struct EnergyDay: Codable {
    /// Local date, "2026-11-12".
    var day: String
    var wattHours: Double
    /// How many minutes of that day were recorded.
    var minutes: Int
}

/// The stretch of time an energy total covers.
enum EnergyPeriod: String, CaseIterable, Identifiable {
    case today, week, month, year, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "This month"
        case .year: return "This year"
        case .all: return "All time"
        }
    }

    /// As it reads after a figure: "$4.12 this month".
    var phrase: String {
        switch self {
        case .today: return "today"
        case .week: return "in the last 7 days"
        case .month: return "this month"
        case .year: return "this year"
        case .all: return "in all"
        }
    }
}

/// An energy total for a period, with the bars that make it up.
struct EnergySummary {
    struct Bar {
        var label: String
        /// nil where nothing was recorded, or the time has not come yet.
        var wattHours: Double?
        var isCurrent = false
    }

    var wattHours = 0.0
    var bars: [Bar] = []
    /// What one bar stands for: "hour", "day" or "month".
    var unit = "day"
    /// Minutes recorded inside the period.
    var minutes = 0
    /// Days in the period that have any record.
    var daysRecorded = 0
    /// The first day there is a record for, inside the period.
    var since: Date?
    /// For this month: what the month comes to if the rest of it goes like the days so far.
    var projected: Double?
}

/// Something worth remembering: the Mac ran hot, an app held the processor, the disk ran low, the line dropped.
struct TimelineEvent: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case hot, throttled, memory, disk, app, offline, battery, usb

        var title: String {
            switch self {
            case .hot: return "Ran hot"
            case .throttled: return "Throttled"
            case .memory: return "Memory pressure"
            case .disk: return "Disk nearly full"
            case .app: return "Busy app"
            case .offline: return "Offline"
            case .usb: return "Slow connection"
            case .battery: return "Battery low"
            }
        }

        var symbol: String {
            switch self {
            case .hot: return "flame.fill"
            case .throttled: return "tortoise.fill"
            case .memory: return "memorychip.fill"
            case .disk: return "internaldrive.fill"
            case .app: return "cpu.fill"
            case .offline: return "wifi.slash"
            case .usb: return "cable.connector"
            case .battery: return "battery.25percent"
            }
        }

        var rgb: RGB {
            switch self {
            case .hot: return PX.orange
            case .throttled: return PX.red
            case .memory: return PX.purple
            case .disk: return PX.yellow
            case .app: return PX.blue
            case .offline: return PX.gray
            case .usb: return PX.lime
            case .battery: return PX.red
            }
        }
    }

    struct App: Codable {
        var name: String
        var bundlePath: String?
        /// Cores in use at the worst moment.
        var cpu: Double
    }

    var id = UUID()
    var kind: Kind
    var start: Date
    var end: Date?
    /// What happened, in a sentence: "Xcode held 8 cores".
    var summary: String
    var peakCelsius: Double?
    var peakRPM: Double?
    var peakCPU: Double?
    /// What was on top when it was at its worst.
    var apps: [App] = []

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

/// The app's memory: a week of minute averages, the events inside it, and speed test results. Kept in one
/// small file in Application Support, written every five minutes and when the app quits.
@MainActor
@Observable
final class TimelineStore {
    nonisolated static let keepMinutes = 7 * 24 * 60
    nonisolated static let keepEvents = 300

    private(set) var minutes: [TimelineMinute] = []
    private(set) var events: [TimelineEvent] = []
    var speedTests: [SpeedResult] = [] { didSet { dirty = true } }
    private(set) var recordingSince = Date()
    /// Energy by calendar day, oldest first. Never pruned.
    private(set) var energyDays: [EnergyDay] = []

    @ObservationIgnored private var bucket = 0
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var sums = [Double](repeating: 0, count: 9)
    @ObservationIgnored private var cpuPeak = 0.0
    @ObservationIgnored private var tempCount = 0
    @ObservationIgnored private var batterySum = 0.0
    @ObservationIgnored private var batteryCount = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private let url: URL?

    /// Debug: DOTMETER_TIMELINE_DEMO=1 fills in a made-up week and never writes it down.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_TIMELINE_DEMO"] == "1"

    private struct File: Codable {
        var recordingSince: Date
        var minutes: [TimelineMinute]
        var events: [TimelineEvent]
        var speedTests: [SpeedResult]
        /// Absent in files written before 1.3.
        var days: [EnergyDay]?
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(_ date: Date) -> String { dayFormat.string(from: date) }
    static func date(ofDay key: String) -> Date? { dayFormat.date(from: key) }

    /// The ledger as it would have been, from minute records alone.
    private static func ledger(from minutes: [TimelineMinute]) -> [EnergyDay] {
        var days: [EnergyDay] = []
        for minute in minutes where minute.power > 0 {
            let key = dayKey(minute.date)
            if days.last?.day == key {
                days[days.count - 1].wattHours += Double(minute.power) / 60
                days[days.count - 1].minutes += 1
            } else {
                days.append(EnergyDay(day: key, wattHours: Double(minute.power) / 60, minutes: 1))
            }
        }
        return days
    }

    init() {
        if Self.demo {
            url = nil
            let made = TimelineDemo.make()
            minutes = made.minutes
            events = made.events
            speedTests = made.speedTests
            recordingSince = made.minutes.first?.date ?? Date()
            energyDays = TimelineDemo.ledger(endingWith: Self.ledger(from: made.minutes))
            return
        }
        // Debug: DOTMETER_TIMELINE_PATH keeps test runs out of the real history.
        if let override = ProcessInfo.processInfo.environment["DOTMETER_TIMELINE_PATH"] {
            url = URL(fileURLWithPath: override)
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            url = support.appendingPathComponent(App.supportFolder, isDirectory: true).appendingPathComponent("timeline.json")
        } else {
            url = nil
        }
        if let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            let cutoff = Int(Date().timeIntervalSince1970 / 60) - Self.keepMinutes
            minutes = file.minutes.filter { $0.t >= cutoff }
            // Whatever was still going on when the app last quit ended then, as far as anyone can say.
            events = file.events.map { event in
                var closed = event
                if closed.end == nil { closed.end = file.minutes.last?.date ?? event.start }
                return closed
            }
            speedTests = file.speedTests
            recordingSince = file.recordingSince
            // A file from before the ledger existed still holds up to a week of minutes to start it from.
            energyDays = file.days ?? Self.ledger(from: file.minutes)
            dirty = false
        }
    }

    // MARK: Recording

    /// For the test command: write whatever has been recorded, now.
    func flushForTesting() { flush() }

    /// What today has added up to so far: the traffic carried, the hottest minute, and how often and how long the
    /// Mac ran hot. Worked out again only when a minute or an event has been added.
    struct DaySoFar {
        var received = 0.0
        var sent = 0.0
        var hottest: Double?
        var hotEvents = 0
        var hotSeconds = 0.0
        var throttled = 0
        var recorded = 0
    }

    @ObservationIgnored private var todayCache: (key: String, value: DaySoFar)?

    func today() -> DaySoFar {
        let start = Calendar.current.startOfDay(for: Date())
        let key = "\(start.timeIntervalSince1970)|\(minutes.count)|\(minutes.last?.t ?? 0)|\(events.count)|\(events.last?.end == nil)"
        if let todayCache, todayCache.key == key { return todayCache.value }
        var day = DaySoFar()
        let from = Int(start.timeIntervalSince1970 / 60)
        for minute in minutes.reversed() {
            if minute.t < from { break }
            day.received += Double(minute.netIn) * 60
            day.sent += Double(minute.netOut) * 60
            if minute.temp > 0 { day.hottest = max(day.hottest ?? 0, Double(minute.temp)) }
            day.recorded += 1
        }
        for event in events where event.start >= start {
            if event.kind == .hot || event.kind == .throttled {
                day.hotEvents += 1
                day.hotSeconds += event.duration
            }
            if event.kind == .throttled { day.throttled += 1 }
        }
        todayCache = (key, day)
        return day
    }

    func record(_ s: Snapshot) {
        guard !Self.demo else { return }
        let minute = Int(s.timestamp.timeIntervalSince1970 / 60)
        if minute != bucket {
            flush()
            bucket = minute
        }
        count += 1
        sums[0] += s.cpu.total
        sums[1] += s.gpu?.utilization ?? 0
        sums[2] += s.memory.usedFraction
        if let hottest = s.thermal.hottest?.celsius { sums[3] += hottest; tempCount += 1 }
        sums[4] += s.thermal.averageRPM
        sums[5] += s.network.inBytesPerSecond
        sums[6] += s.network.outBytesPerSecond
        sums[7] += s.power.total ?? 0
        sums[8] += s.disk.readBytesPerSecond + s.disk.writeBytesPerSecond
        cpuPeak = max(cpuPeak, s.cpu.total)
        if let charge = s.power.battery?.charge {
            batterySum += charge
            batteryCount += 1
        }
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    private func flush() {
        defer {
            count = 0
            tempCount = 0
            batterySum = 0
            batteryCount = 0
            cpuPeak = 0
            sums = [Double](repeating: 0, count: 9)
        }
        guard count > 0, bucket > 0 else { return }
        let n = Double(count)
        minutes.append(TimelineMinute(
            t: bucket, cpu: Float(sums[0] / n), cpuPeak: Float(cpuPeak), gpu: Float(sums[1] / n), memory: Float(sums[2] / n),
            temp: tempCount > 0 ? Float(sums[3] / Double(tempCount)) : 0, fan: Float(sums[4] / n),
            netIn: Float(sums[5] / n), netOut: Float(sums[6] / n), power: Float(sums[7] / n), disk: Float(sums[8] / n),
            battery: batteryCount > 0 ? Float(batterySum / Double(batteryCount)) : nil
        ))
        if minutes.count > Self.keepMinutes { minutes.removeFirst(minutes.count - Self.keepMinutes) }
        let watts = sums[7] / n
        if watts > 0 {
            let key = Self.dayKey(Date(timeIntervalSince1970: Double(bucket) * 60))
            if energyDays.last?.day == key {
                energyDays[energyDays.count - 1].wattHours += watts / 60
                energyDays[energyDays.count - 1].minutes += 1
            } else {
                energyDays.append(EnergyDay(day: key, wattHours: watts / 60, minutes: 1))
            }
        }
        dirty = true
    }

    // MARK: Events

    func begin(_ event: TimelineEvent) {
        events.append(event)
        if events.count > Self.keepEvents { events.removeFirst(events.count - Self.keepEvents) }
        dirty = true
    }

    func update(_ id: UUID, _ change: (inout TimelineEvent) -> Void) {
        guard let index = events.lastIndex(where: { $0.id == id }) else { return }
        change(&events[index])
        dirty = true
    }

    func remove(_ id: UUID) {
        events.removeAll { $0.id == id }
        dirty = true
    }

    func clear() {
        minutes = []
        events = []
        energyDays = []
        recordingSince = Date()
        dirty = true
        save()
    }

    // MARK: Disk

    func save() {
        lastSave = Date()
        guard dirty, let url, !Self.demo else { return }
        dirty = false
        let file = File(recordingSince: recordingSince, minutes: minutes, events: events, speedTests: speedTests, days: energyDays)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Synchronous, for the moment before the app exits.
    func saveNow() {
        flush()
        guard dirty, let url, !Self.demo else { return }
        let file = File(recordingSince: recordingSince, minutes: minutes, events: events, speedTests: speedTests, days: energyDays)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        dirty = false
    }

    // MARK: Reading

    /// The energy drawn over a stretch of time, in watt-hours: each recorded minute contributes a sixtieth of its watts.
    func energyWh(since date: Date) -> Double {
        let from = Int(date.timeIntervalSince1970 / 60)
        return minutes.reduce(0) { $1.t >= from ? $0 + Double($1.power) / 60 : $0 }
    }

    /// The energy drawn over a period, and the bars it is made of: hours for today, days for a week or a
    /// month, months for a year. All time is days while it is short and months once it is not.
    func energy(_ period: EnergyPeriod, now: Date = Date()) -> EnergySummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let todayKey = Self.dayKey(now)
        var summary = EnergySummary()
        let byDay = Dictionary(energyDays.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })

        func dailyBars(from start: Date, through end: Date, label: (Date) -> String) {
            var day = start
            while day <= end {
                let key = Self.dayKey(day)
                let entry = byDay[key]
                summary.bars.append(.init(label: label(day), wattHours: day > today ? nil : entry?.wattHours, isCurrent: key == todayKey))
                if let entry, day <= today {
                    summary.wattHours += entry.wattHours
                    summary.minutes += entry.minutes
                    summary.daysRecorded += 1
                    if summary.since == nil { summary.since = day }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        func monthlyBars(from start: Date, through end: Date) {
            let names = DateFormatter()
            names.dateFormat = "MMM"
            var month = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
            let current = calendar.dateComponents([.year, .month], from: now)
            while month <= end {
                let parts = calendar.dateComponents([.year, .month], from: month)
                let prefix = String(format: "%04d-%02d-", parts.year ?? 0, parts.month ?? 0)
                let entries = energyDays.filter { $0.day.hasPrefix(prefix) }
                let total = entries.reduce(0) { $0 + $1.wattHours }
                summary.bars.append(.init(label: names.string(from: month), wattHours: entries.isEmpty ? nil : total, isCurrent: parts == current))
                summary.wattHours += total
                summary.minutes += entries.reduce(0) { $0 + $1.minutes }
                summary.daysRecorded += entries.count
                if summary.since == nil, let first = entries.first.flatMap({ Self.date(ofDay: $0.day) }) { summary.since = first }
                guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
                month = next
            }
        }
        let dayNumber: (Date) -> String = { "\(calendar.component(.day, from: $0))" }

        switch period {
        case .today:
            summary.unit = "hour"
            let from = Int(today.timeIntervalSince1970 / 60)
            var hours = [Double?](repeating: nil, count: 24)
            for minute in minutes where minute.t >= from && minute.power > 0 {
                let hour = min(23, (minute.t - from) / 60)
                hours[hour] = (hours[hour] ?? 0) + Double(minute.power) / 60
                summary.minutes += 1
            }
            let hourNow = calendar.component(.hour, from: now)
            summary.bars = hours.enumerated().map { .init(label: String(format: "%02d", $0.offset), wattHours: $0.element, isCurrent: $0.offset == hourNow) }
            // The ledger is the total of record; the hours are only as much of it as the minutes still cover.
            summary.wattHours = byDay[todayKey]?.wattHours ?? hours.compactMap { $0 }.reduce(0, +)
            summary.daysRecorded = summary.minutes > 0 ? 1 : 0
            summary.since = summary.minutes > 0 ? today : nil
        case .week:
            let weekday = DateFormatter()
            weekday.dateFormat = "EEE"
            dailyBars(from: calendar.date(byAdding: .day, value: -6, to: today) ?? today, through: today) { weekday.string(from: $0) }
        case .month:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
            let length = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
            dailyBars(from: start, through: calendar.date(byAdding: .day, value: length - 1, to: start) ?? today, label: dayNumber)
            // Only a guide: it assumes the rest of the month runs like the recorded days so far.
            if summary.daysRecorded > 0 { summary.projected = summary.wattHours / Double(summary.daysRecorded) * Double(length) }
        case .year:
            summary.unit = "month"
            let start = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? today
            monthlyBars(from: start, through: calendar.date(byAdding: .month, value: 11, to: start) ?? today)
        case .all:
            let first = energyDays.first.flatMap { Self.date(ofDay: $0.day) } ?? today
            if today.timeIntervalSince(first) <= 62 * 86_400 {
                dailyBars(from: first, through: today, label: dayNumber)
            } else {
                summary.unit = "month"
                monthlyBars(from: first, through: today)
            }
        }
        return summary
    }

    /// For Claude: each recorded day in a line, and the events of the week.
    func weekSummary() -> String? {
        guard !minutes.isEmpty || !events.isEmpty else { return nil }
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM"
        let stamp = DateFormatter()
        stamp.dateFormat = "EEE HH:mm"
        var lines: [String] = []
        let groups = Dictionary(grouping: minutes) { Calendar.current.startOfDay(for: $0.date) }
        for start in groups.keys.sorted() {
            let list = groups[start] ?? []
            let cpu = list.map { Double($0.cpu) }.reduce(0, +) / Double(max(list.count, 1))
            let energy = list.reduce(0.0) { $0 + Double($1.power) / 60 }
            lines.append(String(format: "%@: %.0f h recorded, processor average %.0f%% peak %.0f%%, hottest %.0f°C, fans up to %.0f rpm, %.2f kWh", day.string(from: start), Double(list.count) / 60, cpu * 100, Double(list.map(\.cpuPeak).max() ?? 0) * 100, Double(list.map(\.temp).max() ?? 0), Double(list.map(\.fan).max() ?? 0), energy / 1000))
        }
        if !events.isEmpty {
            lines.append("Events: " + events.suffix(25).map { "\($0.kind.title) \(stamp.string(from: $0.start)) for \(Format.duration($0.duration)) (\($0.summary))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// For Claude: what was recorded around a moment, and what else happened that day.
    func summary(around event: TimelineEvent) -> String {
        let from = Int(event.start.timeIntervalSince1970 / 60) - 10
        let to = Int((event.end ?? Date()).timeIntervalSince1970 / 60) + 5
        let window = minutes.filter { $0.t >= from && $0.t <= to }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        var lines = ["Per-minute averages around it (time, cpu %, peak cpu %, gpu %, hottest °C, fan rpm, watts):"]
        let step = max(1, window.count / 24)
        for (index, m) in window.enumerated() where index % step == 0 {
            lines.append(String(format: "%@ %3.0f %3.0f %3.0f %3.0f %5.0f %4.0f", time.string(from: m.date), m.cpu * 100, m.cpuPeak * 100, m.gpu * 100, m.temp, m.fan, m.power))
        }
        let day = Calendar.current.startOfDay(for: event.start)
        let others = events.filter { $0.id != event.id && $0.start >= day && $0.start < day.addingTimeInterval(86_400) }
        if !others.isEmpty {
            lines.append("Other events that day: " + others.map { "\($0.kind.title) at \(time.string(from: $0.start)) for \(Format.duration($0.duration)) (\($0.summary))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

/// A made-up week for design review: quiet nights, working days, a few hot afternoons and their events.
enum TimelineDemo {
    /// Five months of made-up days in front of the real ones, so every period has something to show.
    @MainActor
    static func ledger(endingWith recent: [EnergyDay]) -> [EnergyDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let known = Set(recent.map(\.day))
        var days: [EnergyDay] = []
        for back in stride(from: 150, to: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let key = TimelineStore.dayKey(date)
            guard !known.contains(key) else { continue }
            let weekend = calendar.isDateInWeekend(date)
            var h = UInt32(truncatingIfNeeded: back &* 2_654_435_761)
            h ^= h >> 15
            let wobble = Double(h % 1000) / 1000
            // A day off now and then, with nothing recorded.
            if h % 23 == 0 { continue }
            days.append(EnergyDay(day: key, wattHours: (weekend ? 720 : 1180) + 620 * wobble, minutes: weekend ? 900 : 1380))
        }
        return days + recent
    }

    static func make() -> (minutes: [TimelineMinute], events: [TimelineEvent], speedTests: [SpeedResult]) {
        let now = Int(Date().timeIntervalSince1970 / 60)
        let calendar = Calendar.current
        func noise(_ a: Int, _ b: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663)
            h ^= h >> 13
            h = h &* 0x5bd1_e995
            h ^= h >> 15
            return Double(h % 10_000) / 10_000
        }
        var minutes: [TimelineMinute] = []
        var hotStarts: [(Int, Int)] = []
        var running: Int?
        // A made-up laptop's charge: it drains while in use, faster under load, and charges overnight and
        // over a long lunch.
        var level = 0.86
        func charge(at t: Int, awake: Bool, heavy: Bool) -> Double {
            let minuteOfDay = ((t % 1440) + 1440) % 1440
            let pluggedIn = !awake || (minuteOfDay > 12 * 60 + 20 && minuteOfDay < 13 * 60 + 50)
            level += pluggedIn ? 0.0105 : (heavy ? -0.0026 : -0.0007)
            level = min(max(level, 0.06), 1)
            return level
        }
        for t in (now - TimelineStore.keepMinutes + 1)...now {
            let date = Date(timeIntervalSince1970: Double(t) * 60)
            let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
            let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
            let awake = hour > 8.5 && hour < 23.2
            // Work comes in blocks of about forty minutes; some blocks are builds or renders.
            let block = t / 40
            let kind = noise(block, day)
            var load = awake ? 0.06 + 0.10 * noise(t / 7, 3) : 0.012 + 0.01 * noise(t / 30, 5)
            var gpu = awake ? 0.05 + 0.06 * noise(t / 9, 7) : 0.0
            let heavy = awake && kind > 0.86
            let render = awake && kind > 0.78 && kind <= 0.86
            if heavy { load = 0.62 + 0.3 * noise(t / 3, 11) }
            if render { gpu = 0.55 + 0.35 * noise(t / 4, 13); load = max(load, 0.22) }
            let temp = 44 + load * 52 + gpu * 14 + 3 * noise(t / 5, 17)
            let fan = 1000 + max(0, temp - 70) * 46
            let net = awake ? (noise(t / 25, 19) > 0.8 ? 18e6 * noise(t / 2, 23) : 120e3 * noise(t, 29)) : 9e3
            minutes.append(TimelineMinute(
                t: t, cpu: Float(load), cpuPeak: Float(min(load * 1.5, 1)), gpu: Float(gpu), memory: Float(0.22 + (awake ? 0.08 : 0) + 0.05 * noise(t / 90, 31)),
                temp: Float(temp), fan: Float(fan), netIn: Float(net), netOut: Float(net * 0.09), power: Float(31 + load * 150 + gpu * 90), disk: Float(heavy ? 60e6 * noise(t, 37) : 0.4e6),
                battery: PowerSampler.demo == nil ? nil : Float(charge(at: t, awake: awake, heavy: heavy))
            ))
            if temp >= 86 { if running == nil { running = t } } else if let start = running {
                if t - start >= 4 { hotStarts.append((start, t)) }
                running = nil
            }
        }
        let names: [(String, String?)] = [("Xcode", "/Applications/Xcode.app"), ("Final Cut Pro", "/Applications/Final Cut Pro.app"), ("Blender", "/Applications/Blender.app"), ("Docker", "/Applications/Docker.app")]
        var events: [TimelineEvent] = []
        for (index, span) in hotStarts.suffix(14).enumerated() {
            let app = names[index % names.count]
            let peak = minutes.filter { $0.t >= span.0 && $0.t <= span.1 }
            var event = TimelineEvent(kind: .hot, start: Date(timeIntervalSince1970: Double(span.0) * 60), end: Date(timeIntervalSince1970: Double(span.1) * 60), summary: "\(app.0) was using \(8 + index % 9) cores")
            event.peakCelsius = Double(peak.map(\.temp).max() ?? 0)
            event.peakRPM = Double(peak.map(\.fan).max() ?? 0)
            event.peakCPU = Double(peak.map(\.cpuPeak).max() ?? 0)
            event.apps = [.init(name: app.0, bundlePath: app.1, cpu: Double(8 + index % 9)), .init(name: "WindowServer", bundlePath: nil, cpu: 0.6), .init(name: "Safari", bundlePath: "/Applications/Safari.app", cpu: 0.4)]
            events.append(event)
        }
        let base = Date()
        var busy = TimelineEvent(kind: .app, start: base.addingTimeInterval(-93_000), end: base.addingTimeInterval(-92_100), summary: "node held 6 cores for 15 minutes")
        busy.peakCPU = 0.21
        busy.apps = [.init(name: "node", bundlePath: nil, cpu: 6.1)]
        events.append(busy)
        var offline = TimelineEvent(kind: .offline, start: base.addingTimeInterval(-171_000), end: base.addingTimeInterval(-170_760), summary: "Wi-Fi lost its route")
        offline.apps = []
        events.append(offline)
        events.append(TimelineEvent(kind: .disk, start: base.addingTimeInterval(-260_000), end: base.addingTimeInterval(-252_000), summary: "18 GB free of 2 TB"))
        events.sort { $0.start < $1.start }
        let speeds = (0..<8).map { index in
            SpeedResult(date: base.addingTimeInterval(-Double(7 - index) * 86_400 * 0.9), down: (430 + 70 * noise(index, 41)) * 1e6, up: (62 + 16 * noise(index, 43)) * 1e6, responsiveness: 900 + 500 * noise(index, 47), baseRTT: 12 + 5 * noise(index, 53), interface: "en1")
        }
        return (minutes, events, speeds)
    }
}
