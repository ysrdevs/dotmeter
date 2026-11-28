import SwiftUI

/// What the timeline can be drawn by.
enum TimelineMetric: String, CaseIterable, Identifiable {
    case heat, cpu, gpu, memory, network, power, fans, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heat: return "Heat"
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
        case .memory: return "Memory"
        case .network: return "Network"
        case .power: return "Power"
        case .fans: return "Fans"
        case .battery: return "Battery"
        }
    }

    /// The ones this Mac can have a history for.
    static var available: [TimelineMetric] { allCases.filter { $0 != .battery || Hardware.hasBattery } }

    /// Whether a minute has a reading for this metric at all.
    func has(_ m: TimelineMinute) -> Bool {
        switch self {
        case .heat: return m.temp > 0
        case .battery: return m.battery != nil
        default: return true
        }
    }

    var symbol: String {
        switch self {
        case .heat: return "thermometer.medium"
        case .cpu: return "cpu.fill"
        case .gpu: return "square.stack.3d.up.fill"
        case .memory: return "memorychip.fill"
        case .network: return "network"
        case .power: return "bolt.fill"
        case .fans: return "fan.fill"
        case .battery: return "battery.75percent"
        }
    }

    var rgb: RGB {
        switch self {
        case .heat: return PX.orange
        case .cpu: return PX.blue
        case .gpu: return PX.pink
        case .memory: return PX.purple
        case .network: return PX.cyan
        case .power: return PX.yellow
        case .fans: return PX.cyan
        case .battery: return PX.greenRGB
        }
    }

    /// The metric shown under it in the day view, because the two explain each other.
    var companion: TimelineMetric {
        switch self {
        case .heat: return .fans
        case .cpu: return .gpu
        case .gpu: return .cpu
        case .memory: return .cpu
        case .network: return .cpu
        case .power: return .cpu
        case .fans: return .heat
        case .battery: return .power
        }
    }

    func raw(_ m: TimelineMinute) -> Double {
        switch self {
        case .heat: return Double(m.temp)
        case .cpu: return Double(m.cpu)
        case .gpu: return Double(m.gpu)
        case .memory: return Double(m.memory)
        case .network: return Double(m.netIn + m.netOut)
        case .power: return Double(m.power)
        case .fans: return Double(m.fan)
        case .battery: return Double(m.battery ?? 0)
        }
    }

    func text(_ value: Double) -> String {
        switch self {
        case .heat: return Format.temperature(value)
        case .cpu, .gpu, .memory, .battery: return Format.percent(value)
        case .network: return Format.rate(value)
        case .power: return AppTablePanel.watts(value)
        case .fans: return "\(Format.rpm(value)) rpm"
        }
    }

    /// The bottom and top of the scale for a set of minutes.
    func range(_ minutes: [TimelineMinute]) -> (low: Double, high: Double) {
        let values = minutes.map(raw).filter { $0 > 0 }
        switch self {
        case .heat: return (30, 108)
        case .cpu, .gpu, .memory, .battery: return (0, 1)
        case .network: return (0, NetScale.ceiling(values.max() ?? 0))
        case .power: return (0, AreaMeters.wattCeiling(values.max() ?? 0))
        case .fans:
            let low = values.min() ?? 0, high = values.max() ?? 1
            return (max(0, low - 60), max(high, low + 300))
        }
    }

    func color(_ fraction: Double, range: (low: Double, high: Double)) -> RGB {
        if self == .heat { return heatColor(range.low + fraction * (range.high - range.low)) }
        return self == .battery ? BatteryLook.color(fraction) : rgb
    }
}

struct TimelinePage: View {
    @Environment(TimelineStore.self) private var store
    @State private var metric = TimelineMetric(rawValue: ProcessInfo.processInfo.environment["DOTMETER_DEBUG_METRIC"] ?? "") ?? .heat
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        PageScaffold(title: "Timeline", subtitle: subtitle, section: .timeline, trailing: AnyView(
            PXButton(title: "Week card", symbol: "square.and.arrow.up", style: .ghost) { StatusController.shared?.showWeekCard(nil) }
                .help("A picture of this Mac's week, to save or share")
        )) { gridWidth, columns in
            if store.minutes.count < 3 && store.events.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        PXSpinner(size: 13)
                        Text("Recording has just begun").font(PX.font(13, .medium)).foregroundStyle(PX.text)
                    }
                    Text("\(App.name) writes down one line a minute: load, heat, fan speed, traffic and power. Give it a few minutes and this page fills in; leave it running and it keeps a week. Each time the Mac runs hot, an app holds the processor, the disk runs low or the connection drops, that is noted here too, with what was on top at the time.")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PX.inset)
                .frame(width: gridWidth, alignment: .leading)
                .pxCard()
            } else {
                WeekPanel(metric: $metric, day: $day, width: gridWidth)
                PagePair(columns: columns) {
                    DayChartsPanel(day: day, metric: metric)
                } second: {
                    DaySummaryPanel(day: day)
                }
                EventsPanel(width: gridWidth)
            }
            RecordingPanel(width: gridWidth)
        }
    }

    private var subtitle: String {
        let today = Calendar.current.startOfDay(for: Date())
        let count = store.events.filter { $0.start >= today }.count
        let span = store.minutes.first.map { Format.duration(Date().timeIntervalSince($0.date)) } ?? "nothing"
        return "\(span) of history · \(store.events.count) events, \(count) today · one reading a minute, a week kept"
    }
}

/// Seven days, one strip each, a column for every few minutes. Events sit above the moment they began.
struct WeekPanel: View {
    @Binding var metric: TimelineMetric
    @Binding var day: Date
    var width: CGFloat
    @Environment(TimelineStore.self) private var store

    private static let rows = 7
    private static let labelWidth: CGFloat = 86
    private static let figureWidth: CGFloat = 86

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let stripWidth = width - PX.inset * 2 - Self.labelWidth - Self.figureWidth
        let cols = max(24, Int((stripWidth / PX.pitch).rounded(.down)))
        let range = metric.range(store.minutes)
        let bins = Self.bins(store.minutes, days: days, cols: cols, metric: metric, range: range)
        PXPanel(title: "This week", caption: "each column is \(Int((1440.0 / Double(cols)).rounded())) minutes, at its \(metric == .battery ? "lowest" : "highest")", width: width) {
            HStack(spacing: 2) {
                ForEach(TimelineMetric.available) { item in
                    PXPill(title: width > 700 ? item.title : "", symbol: item.symbol, rgb: item.rgb, selected: metric == item) { metric = item }
                        .help(item.title)
                }
            }
            .padding(.trailing, -6)
        } content: {
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, start in
                        let events = store.events.filter { $0.start >= start && $0.start < start.addingTimeInterval(86_400) }
                        let peak = bins[index].compactMap { $0 }.max()
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.name(start, today: today))
                                    .font(PX.font(12, start == day ? .medium : .regular))
                                    .foregroundStyle(start == day ? PX.text : PX.label)
                                Text(events.isEmpty ? "quiet" : "\(events.count) \(events.count == 1 ? "event" : "events")")
                                    .font(PX.font(10.5))
                                    .foregroundStyle(events.isEmpty ? PX.tertiary : PX.orange.color(0.9))
                            }
                            .frame(width: Self.labelWidth, alignment: .leading)
                            DayStrip(values: bins[index], marks: events.map { (Self.fraction($0.start, in: start), $0.kind.rgb) }, rows: Self.rows) { metric.color($0, range: range) }
                                .frame(width: CGFloat(cols) * PX.pitch)
                            Spacer(minLength: 0)
                            Text(Self.figure(bins[index], metric: metric, range: range))
                                .font(PX.font(11.5))
                                .monospacedDigit()
                                .foregroundStyle(peak == nil ? PX.tertiary : PX.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(start == day ? PX.rowHover : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { day = start }
                    }
                }
                .padding(.horizontal, PX.inset - 10)
                .padding(.top, 14)
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { quarter in
                        Text(String(format: "%02d:00", quarter * 6)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(PX.mono(9.5))
                .foregroundStyle(PX.tertiary)
                .frame(width: CGFloat(cols) * PX.pitch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, PX.inset + Self.labelWidth)
                .padding(.top, 5)
                .padding(.bottom, 15)
            }
        }
        .animation(.easeOut(duration: 0.15), value: day)
    }

    /// The day's figure beside its strip: the peak, or for a battery how low it got.
    private static func figure(_ values: [Double?], metric: TimelineMetric, range: (low: Double, high: Double)) -> String {
        let recorded = values.compactMap { $0 }
        guard let value = metric == .battery ? recorded.min() : recorded.max() else { return "no data" }
        return (metric == .battery ? "low " : "peak ") + metric.text(range.low + value * (range.high - range.low))
    }

    static func name(_ start: Date, today: Date) -> String {
        if start == today { return "Today" }
        if start == today.addingTimeInterval(-86_400) || Calendar.current.isDateInYesterday(start) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: start)
    }

    private static func fraction(_ date: Date, in start: Date) -> Double {
        min(max(date.timeIntervalSince(start) / 86_400, 0), 0.9999)
    }

    /// For each day, the highest value in each column, 0...1 on the metric's scale. nil where nothing was recorded.
    private static func bins(_ minutes: [TimelineMinute], days: [Date], cols: Int, metric: TimelineMetric, range: (low: Double, high: Double)) -> [[Double?]] {
        var result = [[Double?]](repeating: [Double?](repeating: nil, count: cols), count: days.count)
        guard let first = days.first else { return result }
        let span = max(range.high - range.low, 1e-9)
        for minute in minutes {
            let offset = minute.date.timeIntervalSince(first)
            guard offset >= 0 else { continue }
            let index = Int(offset / 86_400)
            guard index < days.count else { continue }
            let column = min(cols - 1, Int((offset - Double(index) * 86_400) / 86_400 * Double(cols)))
            guard metric.has(minute) else { continue }
            let value = min(max((metric.raw(minute) - range.low) / span, 0), 1)
            // A battery is read by how low it got, everything else by how high.
            result[index][column] = metric == .battery ? min(result[index][column] ?? 1, value) : max(result[index][column] ?? 0, value)
        }
        return result
    }
}

/// One day as columns of cells lit from the bottom, with a small mark above each event.
struct DayStrip: View {
    var values: [Double?]
    var marks: [(Double, RGB)]
    var rows: Int
    var tone: (Double) -> RGB

    private static let markSpace: CGFloat = 6

    private struct Spec: Hashable {
        struct Mark: Hashable {
            var fraction: Double
            var rgb: RGB
        }

        var rows: Int
        /// Lit cells in each column from the bottom; -1 where nothing was recorded.
        var filled: [Int16]
        var tones: [RGB]
        var marks: [Mark]
    }

    var body: some View {
        BitmapPicture(spec: { _ in spec }, draw: Self.draw)
            .frame(height: CGFloat(rows) * PX.pitch + Self.markSpace)
    }

    private var spec: Spec {
        Spec(
            rows: rows,
            filled: values.map { value in value.map { $0 <= 0.001 ? 1 : Int16(max(1, Int(($0 * Double(rows)).rounded()))) } ?? -1 },
            tones: values.map { $0.map(tone) ?? .white },
            marks: marks.map { Spec.Mark(fraction: $0.0, rgb: $0.1) }
        )
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        let side = p - 1.15
        let top = markSpace
        let rows = spec.rows
        var dim: [CGRect] = []
        var lit: [RGB: [CGRect]] = [:]
        var caps: [CGRect] = []
        for (column, count) in spec.filled.enumerated() {
            let cx = (CGFloat(column) + 0.5) * p
            let recorded = count >= 0
            let filled = max(0, Int(count))
            for row in 0..<rows {
                let cy = top + (CGFloat(rows - 1 - row) + 0.5) * p
                if row < filled {
                    let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                    if row == filled - 1, filled > 1 { caps.append(rect) } else { lit[spec.tones[column], default: []].append(rect) }
                } else if recorded || row == 0 {
                    dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                }
            }
        }
        pen.fill(dim, .white, 0.09)
        for (rgb, rects) in lit { pen.fill(rects, rgb, 0.82) }
        pen.fill(caps, .white, 0.72)
        for mark in spec.marks {
            let x = mark.fraction * Double(size.width)
            pen.fill(rounded: CGRect(x: x - 1.6, y: 0, width: 3.2, height: 3.2), radius: 0.8, mark.rgb)
        }
    }
}

/// The chosen day, midnight to midnight, by the chosen metric and the one that explains it.
struct DayChartsPanel: View {
    var day: Date
    var metric: TimelineMetric
    @Environment(TimelineStore.self) private var store

    var body: some View {
        let from = Int(day.timeIntervalSince1970 / 60)
        let minutes = store.minutes.filter { $0.t >= from && $0.t < from + 1440 }
        let end = day.addingTimeInterval(86_400)
        let today = Calendar.current.startOfDay(for: Date())
        PXPanel(title: WeekPanel.name(day, today: today), caption: "midnight to midnight, \(Format.duration(Double(minutes.count) * 60)) recorded", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                chart(metric, minutes: minutes, end: end, rows: 30)
                    .padding(.top, 14)
                chart(metric.companion, minutes: minutes, end: end, rows: 18)
                    .padding(.top, 16)
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { quarter in
                        Text(String(format: "%02d:00", quarter * 6)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(PX.mono(9.5))
                .foregroundStyle(PX.tertiary)
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private func chart(_ metric: TimelineMetric, minutes: [TimelineMinute], end: Date, rows: Int) -> some View {
        let range = metric.range(store.minutes)
        let values = minutes.filter(metric.has).map(metric.raw)
        let span = max(range.high - range.low, 1e-9)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return VStack(alignment: .leading, spacing: 8) {
            ChartHeader(
                name: metric.title, now: values.min().map(metric.text) ?? "—", average: values.isEmpty ? "—" : metric.text(avg(values)), peak: values.max().map(metric.text) ?? "—",
                swatch: metric == .heat || metric == .battery ? nil : metric.rgb, first: "low"
            )
            MatrixChart(
                samples: minutes.compactMap { m in
                    guard metric.has(m) else { return nil }
                    return .init(time: m.date, value: min(max((metric.raw(m) - range.low) / span, 0), 1))
                },
                rgb: metric.rgb, rows: rows, span: 86_400,
                tone: metric == .heat ? { heatColor(range.low + $0 * span) } : (metric == .battery ? { BatteryLook.color($0) } : nil), anchor: end
            )
        }
    }
}

struct DaySummaryPanel: View {
    var day: Date
    @Environment(TimelineStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let from = Int(day.timeIntervalSince1970 / 60)
        let minutes = store.minutes.filter { $0.t >= from && $0.t < from + 1440 }
        let events = store.events.filter { $0.start >= day && $0.start < day.addingTimeInterval(86_400) }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        func avg(_ v: [Float]) -> Double { v.isEmpty ? 0 : Double(v.reduce(0, +)) / Double(v.count) }
        let hottest = minutes.max { $0.temp < $1.temp }
        let busiest = minutes.max { $0.cpuPeak < $1.cpuPeak }
        let energy = minutes.reduce(0.0) { $0 + Double($1.power) / 60 }
        let received = minutes.reduce(0.0) { $0 + Double($1.netIn) * 60 }, sent = minutes.reduce(0.0) { $0 + Double($1.netOut) * 60 }
        return PXPanel(title: "The day in figures", caption: events.isEmpty ? "no events" : "\(events.count) \(events.count == 1 ? "event" : "events")", width: PX.cardWidth) {
            VStack(spacing: 0) {
                if minutes.isEmpty {
                    Text("Nothing was recorded on this day. \(App.name) was not running.")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 18)
                } else {
                    PXStatRow(label: "Recorded", value: Format.duration(Double(minutes.count) * 60), detail: "of 24 hours")
                    PXStatRow(label: "Processor", value: "\(Format.percent(avg(minutes.map(\.cpu)))) average", detail: busiest.map { "peak \(Format.percent(Double($0.cpuPeak))) at \(time.string(from: $0.date))" })
                    PXStatRow(label: "Graphics", value: "\(Format.percent(avg(minutes.map(\.gpu)))) average", detail: "peak \(Format.percent(Double(minutes.map(\.gpu).max() ?? 0)))")
                    PXStatRow(label: "Hottest", value: hottest.map { $0.temp > 0 ? Format.temperature(Double($0.temp)) : "—" } ?? "—", detail: hottest.map { "at \(time.string(from: $0.date))" })
                    PXStatRow(label: "Fans", value: "\(Format.rpm(Double(minutes.map(\.fan).max() ?? 0))) rpm at most", detail: "average \(Format.rpm(avg(minutes.map(\.fan))))")
                    PXStatRow(label: "Energy", value: PowerPage.energy(energy), detail: settings.energyPrice > 0 ? "about \(Format.dollars(energy / 1000 * settings.energyPrice))" : "average \(AppTablePanel.watts(avg(minutes.map(\.power))))")
                    PXStatRow(label: "Network", value: "\(Format.data(UInt64(received))) in", detail: "\(Format.data(UInt64(sent))) out")
                    PXStatRow(label: "Disk activity", value: Format.data(UInt64(minutes.reduce(0.0) { $0 + Double($1.disk) * 60 })), detail: "read and written")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PX.inset)
            .padding(.top, 9)
        }
        .frame(height: 342.75)
    }
}

/// Everything the timeline noted, newest first. A row opens to show what was on top, and Claude can be asked why.
struct EventsPanel: View {
    var width: CGFloat
    @Environment(TimelineStore.self) private var store
    @Environment(Explainer.self) private var explainer
    @Environment(SystemMonitor.self) private var monitor
    @State private var open: UUID?
    @State private var filter: TimelineEvent.Kind?

    var body: some View {
        let kinds = TimelineEvent.Kind.allCases.filter { kind in store.events.contains { $0.kind == kind } }
        let events = Array(store.events.filter { filter == nil || $0.kind == filter }.reversed().prefix(40))
        PXPanel(title: "Events", caption: store.events.isEmpty ? "nothing yet" : "\(store.events.count) noted · click one for what was running", width: width) {
            HStack(spacing: 2) {
                PXPill(title: "All", symbol: nil, rgb: PX.gray, selected: filter == nil) { filter = nil }
                ForEach(kinds, id: \.self) { kind in
                    PXPill(title: width > 700 ? kind.title : "", symbol: kind.symbol, rgb: kind.rgb, selected: filter == kind) { filter = kind }
                }
            }
            .padding(.trailing, -6)
        } content: {
            VStack(spacing: 1) {
                if events.isEmpty {
                    Text("Nothing has needed noting. When the Mac runs hot, an app holds the processor for minutes, the disk runs low or the connection drops, it appears here.")
                        .font(PX.font(12))
                        .foregroundStyle(PX.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                ForEach(events) { event in
                    row(event)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .animation(.snappy(duration: 0.25), value: open)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }()

    private func row(_ event: TimelineEvent) -> some View {
        let isOpen = open == event.id
        let key = "event:" + event.id.uuidString
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(event.kind.rgb.color(0.15))
                    Image(systemName: event.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(event.kind.rgb.color())
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 7) {
                        Text(event.kind.title)
                            .font(PX.font(12.5, .medium))
                            .foregroundStyle(PX.text)
                        if event.end == nil {
                            Text("now")
                                .font(PX.font(10, .medium))
                                .foregroundStyle(event.kind.rgb.color())
                                .padding(.horizontal, 5.5)
                                .frame(height: 15)
                                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(event.kind.rgb.color(0.16)))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(PX.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    Text(event.summary)
                        .font(PX.font(11.5))
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if width > 700, event.kind == .hot || event.kind == .throttled {
                    Text(Self.peaks(event))
                        .font(PX.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.secondary)
                        .padding(.trailing, 14)
                }
                VStack(alignment: .trailing, spacing: 1.5) {
                    Text(Self.stamp.string(from: event.start))
                        .font(PX.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.label)
                    Text(event.end == nil ? "still going" : "for \(event.duration < 90 ? "\(Int(event.duration)) s" : Format.duration(event.duration))")
                        .font(PX.font(11))
                        .foregroundStyle(PX.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 7.5, style: .continuous).fill(isOpen ? PX.rowHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { open = isOpen ? nil : event.id }

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if !event.apps.isEmpty {
                        HStack(spacing: 16) {
                            Text("On top at its worst").font(PX.font(11.5)).foregroundStyle(PX.tertiary)
                            ForEach(Array(event.apps.prefix(4).enumerated()), id: \.offset) { _, app in
                                HStack(spacing: 6) {
                                    Image(nsImage: IconCache.icon(forBundlePath: app.bundlePath))
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 14, height: 14)
                                    Text(app.name).font(PX.font(11.5, .medium)).foregroundStyle(PX.label).lineLimit(1)
                                    Text(Format.cpu(app.cpu)).font(PX.font(11.5)).monospacedDigit().foregroundStyle(PX.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 24)
                    }
                    if width <= 700, event.kind == .hot || event.kind == .throttled {
                        Text(Self.peaks(event)).font(PX.font(11.5)).monospacedDigit().foregroundStyle(PX.secondary).frame(height: 20)
                    }
                    HStack(spacing: 7) {
                        PXButton(title: "Ask \(AIProvider.current.assistant) why", symbol: "sparkles", enabled: !explainer.isStreaming(key) && monitor.snapshot != nil, height: 26) { ask(event, key: key) }
                        PXButton(title: "Forget", symbol: "trash", style: .ghost, height: 26) {
                            explainer.dismiss(key)
                            store.remove(event.id)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                    ExplainCard(section: .timeline, key: key, heading: "\(AIProvider.current.assistant) on this event", width: nil, inset: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 9)
                }
                .padding(.leading, 47)
                .padding(.trailing, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
    }

    private static func peaks(_ event: TimelineEvent) -> String {
        var parts: [String] = []
        if let celsius = event.peakCelsius, celsius > 0 { parts.append("peak \(Format.temperature(celsius))") }
        if let rpm = event.peakRPM, rpm > 0 { parts.append("\(Format.rpm(rpm)) rpm") }
        if let cpu = event.peakCPU, cpu > 0 { parts.append("\(Format.percent(cpu)) processor") }
        return parts.joined(separator: " · ")
    }

    private func ask(_ event: TimelineEvent, key: String) {
        guard let snapshot = monitor.snapshot else { return }
        var lines = ["The user is asking about one event \(App.name) recorded: \(event.kind.title), starting \(Self.stamp.string(from: event.start)), \(event.end == nil ? "still going on" : "lasting \(Format.duration(event.duration))"). \(event.summary)."]
        lines.append(Self.peaks(event))
        if !event.apps.isEmpty { lines.append("Apps on top at its worst: " + event.apps.map { "\($0.name) \(Format.cpu($0.cpu)) CPU" }.joined(separator: ", ") + ".") }
        lines.append(store.summary(around: event))
        lines.append("The snapshot above is the Mac as it is now, which may be long after the event; use the recorded figures for what happened then.")
        explainer.explain(.timeline, key: key, snapshot: snapshot, history: monitor.history, question: "Why did this event happen, was it normal for this Mac, and is there anything worth doing so it does not repeat?", extra: lines.joined(separator: "\n"))
    }
}

/// Where the history lives, how far back it goes, and the way to clear it.
struct RecordingPanel: View {
    var width: CGFloat
    @Environment(TimelineStore.self) private var store
    @State private var armed = false

    var body: some View {
        HStack(spacing: 10) {
            MeterIconView(icon: .symbol("internaldrive.fill"), rgb: PX.gray, size: 13)
            Text(TimelineStore.demo ? "Showing a made-up week for review. Nothing is being written." : "Kept in Application Support/\(App.supportFolder) on this Mac and nowhere else. \(store.minutes.count) minutes and \(store.events.count) events so far.")
                .font(PX.font(12))
                .foregroundStyle(PX.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            PXConfirmButton(title: "Clear history", armedTitle: "Confirm: clear it all", symbol: "trash", armed: armed, height: 27) {
                if armed {
                    armed = false
                    store.clear()
                } else {
                    armed = true
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        armed = false
                    }
                }
            }
        }
        .padding(.horizontal, PX.inset)
        .frame(width: width, height: 52)
        .pxCard()
    }
}
