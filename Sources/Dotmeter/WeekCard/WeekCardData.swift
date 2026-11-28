import Foundation

/// What lights the week's grid on the card.
enum WeekCardLight: String, CaseIterable, Identifiable {
    case heat, cpu, power

    var id: String { rawValue }

    /// The Timeline's own metric, so the card and the page scale and colour a reading the same way.
    var metric: TimelineMetric {
        switch self {
        case .heat: return .heat
        case .cpu: return .cpu
        case .power: return .power
        }
    }

    var title: String { metric.title }
}

/// Everything a card is made from. The card is worked out from this and nothing else, so a test can hand it a
/// week whose answers it knows.
struct WeekCardInput {
    var minutes: [TimelineMinute]
    var events: [TimelineEvent]
    /// As the sidebar's footer shows them: "Mac Studio", "M3 Ultra".
    var model: String
    var chip: String
    /// Dollars per kWh; zero when none is set.
    var price: Double
    var now = Date()
    var calendar = Calendar.current
}

/// The week in numbers: the seven days up to today, and only what was recorded inside them.
struct WeekCardFigures {
    /// A day's strip has this many columns to the hour, so one column is twelve minutes.
    static let columnsPerHour = 5
    static let columns = 24 * columnsPerHour

    struct Moment {
        var value: Double
        var at: Date
    }

    struct TopApp {
        var name: String
        /// How many events it was on top of.
        var events: Int
    }

    /// The start of each day, oldest first.
    var days: [Date] = []
    /// The end of the last day.
    var end = Date()
    /// Minutes recorded inside the seven days.
    var recorded = 0
    /// For each day, each column's highest reading of the chosen light, 0...1 on its scale. nil where nothing was recorded.
    var levels: [[Double?]] = []
    /// The scale `levels` is on.
    var range: (low: Double, high: Double) = (0, 1)
    /// The hottest minute, in °C.
    var hottest: Moment?
    /// The hour with the highest average processor load, 0...1, and when it began.
    var busiest: Moment?
    var wattHours = 0.0
    var averageWatts = 0.0
    /// nil when no price is set.
    var cost: Double?
    var received = 0.0
    var sent = 0.0
    /// Times the Mac ran hot or was throttled, and for how long in all.
    var hotEvents = 0
    var hotSeconds = 0.0
    /// The app most often on top when the Mac ran hot or an app held the processor.
    var topApp: TopApp?
    var averageLoad = 0.0
    var peakLoad = 0.0

    init(_ input: WeekCardInput, light: WeekCardLight) {
        let calendar = input.calendar
        let today = calendar.startOfDay(for: input.now)
        days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        // Day boundaries in minutes, so a minute is placed by arithmetic and a day with a clock change is still one row.
        let bounds = (days + [end]).map { Int(($0.timeIntervalSince1970 / 60).rounded()) }
        guard bounds.count == 8, let first = bounds.first, let last = bounds.last else { return }

        let inside = input.minutes.filter { $0.t >= first && $0.t < last }
        recorded = inside.count
        let metric = light.metric
        range = metric.range(inside)
        let span = max(range.high - range.low, 1e-9)
        levels = [[Double?]](repeating: [Double?](repeating: nil, count: Self.columns), count: 7)

        var hourSum = [Double](repeating: 0, count: 7 * 24)
        var hourCount = [Int](repeating: 0, count: 7 * 24)
        var cpuSum = 0.0, wattSum = 0.0, wattCount = 0
        var hot: TimelineMinute?
        for minute in inside {
            guard let day = (0..<7).last(where: { minute.t >= bounds[$0] }) else { continue }
            let offset = minute.t - bounds[day]
            // An autumn day is twenty-five hours long: its last hour shares the last cell.
            let hour = min(23, offset / 60)
            let column = hour * Self.columnsPerHour + min(Self.columnsPerHour - 1, (offset % 60) * Self.columnsPerHour / 60)
            if metric.has(minute) {
                let value = min(max((metric.raw(minute) - range.low) / span, 0), 1)
                levels[day][column] = max(levels[day][column] ?? 0, value)
            }
            hourSum[day * 24 + hour] += Double(minute.cpu)
            hourCount[day * 24 + hour] += 1
            cpuSum += Double(minute.cpu)
            peakLoad = max(peakLoad, Double(minute.cpuPeak))
            if minute.power > 0 {
                wattSum += Double(minute.power)
                wattCount += 1
            }
            received += Double(minute.netIn) * 60
            sent += Double(minute.netOut) * 60
            if minute.temp > 0, minute.temp > (hot?.temp ?? 0) { hot = minute }
        }
        if let hot { hottest = Moment(value: Double(hot.temp), at: hot.date) }
        if recorded > 0 { averageLoad = cpuSum / Double(recorded) }
        // Each recorded minute contributes a sixtieth of its watts, as the Power page counts it.
        wattHours = wattSum / 60
        if wattCount > 0 { averageWatts = wattSum / Double(wattCount) }
        if input.price > 0, wattHours > 0 { cost = wattHours / 1000 * input.price }

        // An hour that has only a minute or two on record is not a busy hour, unless the whole week is that short.
        let enough = (hourCount.max() ?? 0) >= 15 ? 15 : 1
        var best: (index: Int, load: Double)?
        for index in hourCount.indices where hourCount[index] >= enough {
            let load = hourSum[index] / Double(hourCount[index])
            if load > (best?.load ?? -1) { best = (index, load) }
        }
        if let best, let at = calendar.date(byAdding: .hour, value: best.index % 24, to: days[best.index / 24]) {
            busiest = Moment(value: best.load, at: at)
        }

        var tally: [String: (events: Int, cores: Double)] = [:]
        for event in input.events where event.start >= days[0] && event.start < end {
            switch event.kind {
            case .hot, .throttled:
                hotEvents += 1
                hotSeconds += max(0, min(event.end ?? input.now, end).timeIntervalSince(event.start))
            default:
                break
            }
            // Only the events that are about load say which app was busy; a kind added later is left out.
            switch event.kind {
            case .hot, .throttled, .app:
                if let top = event.apps.max(by: { $0.cpu < $1.cpu }) {
                    let known = tally[top.name] ?? (0, 0)
                    tally[top.name] = (known.events + 1, known.cores + top.cpu)
                }
            default:
                break
            }
        }
        // Ties go to the app that held more cores, then to the name, so the same week always names the same app.
        if let top = tally.max(by: { ($0.value.events, $0.value.cores, $1.key) < ($1.value.events, $1.value.cores, $0.key) }) {
            topApp = TopApp(name: top.key, events: top.value.events)
        }
    }
}

/// The card as words and cells: everything the picture shows, decided, with nothing left to look up while
/// drawing. Made on the main thread, where the theme's colours are read, and drawn anywhere.
struct WeekCardSpec {
    struct Figure {
        var id: String
        var label: String
        var value: String
        /// Set smaller, after the value: "kWh", "GB".
        var unit = ""
        var detail: String
        var rgb: RGB
        /// A name rather than a number: it may be set smaller or on two lines to fit.
        var isName = false
    }

    var model: String
    var chip: String
    /// "22 - 28 Nov 2026"
    var dates: String
    /// "158 hours recorded"
    var recorded: String
    /// What a full column stands for: "Heat · 30° to 108°".
    var legend: String
    var dayNames: [String]
    /// Rows in a day's strip.
    var rows: Int
    /// Lit cells in each column, from the bottom; -1 where nothing was recorded.
    var filled: [[Int]]
    var tones: [[RGB]]
    var figures: [Figure]
    /// The colour the dates and the wordmark's mark are lit in.
    var accent: RGB
    /// "Dotmeter week 2026-11-22.png"
    var fileName: String

    static let rows = 9
    static let wordmark = "dotmeter.app"

    /// nil when nothing was recorded in the seven days: there is no card to make.
    @MainActor
    init?(_ input: WeekCardInput, light: WeekCardLight, appNames: Bool) {
        let figures = WeekCardFigures(input, light: light)
        guard figures.recorded > 0, figures.days.count == 7 else { return nil }
        self.init(figures, input: input, light: light, appNames: appNames)
    }

    @MainActor
    init(_ week: WeekCardFigures, input: WeekCardInput, light: WeekCardLight, appNames: Bool) {
        let metric = light.metric
        model = input.model
        chip = input.chip.replacingOccurrences(of: "Apple ", with: "")
        dates = Self.dates(from: week.days.first ?? input.now, to: week.days.last ?? input.now, calendar: input.calendar)
        recorded = Self.recorded(week.recorded)
        legend = "\(metric.title) · \(Self.scale(metric, week.range))"
        rows = Self.rows
        accent = metric.rgb
        fileName = "\(App.name) week \(Self.stamp("yyyy-MM-dd", week.days.first ?? input.now, input.calendar)).png"
        dayNames = week.days.map { Self.stamp("EEE", $0, input.calendar) }
        let rows = Self.rows
        filled = week.levels.map { day in
            day.map { level in level.map { $0 <= 0.001 ? 1 : max(1, Int(($0 * Double(rows)).rounded())) } ?? -1 }
        }
        tones = week.levels.map { day in day.map { $0.map { metric.color($0, range: week.range) } ?? .white } }

        var list: [Figure] = []
        if let hottest = week.hottest {
            list.append(Figure(id: "hottest", label: "Hottest", value: Format.temperature(hottest.value), detail: Self.stamp("EEE HH:mm", hottest.at, input.calendar), rgb: heatColor(hottest.value)))
        }
        if let busiest = week.busiest {
            list.append(Figure(id: "busiest", label: "Busiest hour", value: Format.percent(busiest.value), detail: Self.stamp("EEE HH:mm", busiest.at, input.calendar), rgb: PX.blue))
        }
        if week.wattHours > 0 {
            let energy = Self.energy(week.wattHours)
            list.append(Figure(id: "energy", label: "Energy", value: energy.value, unit: energy.unit, detail: "average \(Int(week.averageWatts.rounded())) W", rgb: PX.yellow))
        }
        if let cost = week.cost {
            list.append(Figure(id: "cost", label: "Cost", value: Self.dollars(cost), detail: "at \(Format.price(input.price)) per kWh", rgb: PX.greenRGB))
        }
        let moved = Self.split(Format.data(UInt64(max(0, week.received + week.sent))))
        list.append(Figure(id: "data", label: "Data moved", value: moved.value, unit: moved.unit, detail: "↓\(Format.data(UInt64(max(0, week.received)))) ↑\(Format.data(UInt64(max(0, week.sent))))", rgb: PX.cyan))
        if appNames, let app = week.topApp {
            list.append(Figure(id: "app", label: "Busiest app", value: app.name, detail: app.events == 1 ? "on top once" : "on top \(app.events) times", rgb: PX.pink, isName: true))
        }
        list.append(Figure(id: "hot", label: "Ran hot", value: "\(week.hotEvents)×", detail: week.hotEvents == 0 ? "not once" : "\(Self.span(week.hotSeconds)) in all", rgb: PX.orange))
        list.append(Figure(id: "load", label: "Average load", value: Format.percent(week.averageLoad), detail: "peak \(Format.percent(week.peakLoad))", rgb: PX.indigo))
        self.figures = Array(list.prefix(6))
    }

    /// Every word on the card is in English and in the dot font's letters, whatever the Mac's own language.
    private static func stamp(_ format: String, _ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func dates(from first: Date, to last: Date, calendar: Calendar) -> String {
        let a = calendar.dateComponents([.year, .month], from: first), b = calendar.dateComponents([.year, .month], from: last)
        let whole = stamp("d MMM yyyy", last, calendar)
        if a.year != b.year { return "\(stamp("d MMM yyyy", first, calendar)) - \(whole)" }
        if a.month != b.month { return "\(stamp("d MMM", first, calendar)) - \(whole)" }
        return "\(stamp("d", first, calendar)) - \(whole)"
    }

    /// How much of the week there is a record of, said plainly: a card made from ten minutes says ten minutes.
    static func recorded(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) \(minutes == 1 ? "minute" : "minutes") recorded" }
        let hours = Int((Double(minutes) / 60).rounded())
        return "\(hours) \(hours == 1 ? "hour" : "hours") recorded"
    }

    private static func scale(_ metric: TimelineMetric, _ range: (low: Double, high: Double)) -> String {
        switch metric {
        case .heat: return "\(Format.temperature(range.low)) to \(Format.temperature(range.high))"
        case .power: return "0 to \(Int(range.high.rounded())) W"
        default: return "0 to 100%"
        }
    }

    /// kWh once there is one; before that, watt-hours, so a short record does not read as "0.00".
    static func energy(_ wattHours: Double) -> (value: String, unit: String) {
        if wattHours >= 1000 { return (String(format: wattHours >= 100_000 ? "%.0f" : (wattHours >= 10_000 ? "%.1f" : "%.2f"), wattHours / 1000), "kWh") }
        return (wattHours >= 10 ? "\(Int(wattHours.rounded()))" : String(format: "%.1f", wattHours), "Wh")
    }

    /// Money always carries its dollar sign.
    static func dollars(_ value: Double) -> String {
        value > 0 && value < 0.005 ? "<$0.01" : Format.dollars(value)
    }

    private static func split(_ text: String) -> (value: String, unit: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (text, "")
    }

    private static func span(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : Format.duration(seconds)
    }
}

extension TimelineStore {
    /// What a week card is made from, as things stand now.
    func weekCardInput(price: Double) -> WeekCardInput {
        WeekCardInput(minutes: minutes, events: events, model: SystemInfoProvider.modelName, chip: SystemInfoProvider.chip, price: price)
    }
}
