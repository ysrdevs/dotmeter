import SwiftUI

struct GraphicsPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @State private var meters = AreaMeters()
    @State private var expanded: String?

    var body: some View {
        PageScaffold(title: "Graphics", subtitle: subtitle, section: .gpu) { gridWidth, columns in
            if let s = monitor.snapshot {
                PagePair(columns: columns) {
                    MeterCard(model: meters.gpu(s, control: control, askClaude: askClaude), selected: expanded) { id in
                        expanded = expanded == id ? nil : id
                    }
                } second: {
                    GraphicsCoresPanel(snapshot: s)
                }
                PagePair(columns: columns) {
                    GraphicsHistoryPanel(history: monitor.history, snapshot: s)
                } second: {
                    GraphicsHeatPanel(history: monitor.history, snapshot: s)
                }
                AppTablePanel(title: "Apps by graphics use", apps: Array(s.apps.filter { $0.gpu > 0.0005 }.sorted { $0.gpu > $1.gpu }.prefix(18)), metric: .gpu, width: gridWidth, expanded: $expanded)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        guard let gpu = s.gpu else { return "This Mac does not report graphics load" }
        var parts = [gpu.model ?? "Graphics"]
        if let cores = gpu.cores, cores > 0 { parts.append("\(cores) cores") }
        parts.append("memory shared with the rest of the Mac")
        return parts.joined(separator: " · ")
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

/// The three loads the graphics cores report, their memory, and what they draw.
struct GraphicsCoresPanel: View {
    var snapshot: Snapshot

    var body: some View {
        let gpu = snapshot.gpu
        let used = Double(gpu?.memoryInUse ?? 0), reserved = Double(gpu?.memoryAllocated ?? 0)
        PXPanel(title: "Graphics cores", caption: gpu?.model, width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 11) {
                    gauge("Overall", "the busiest of the two below", gpu?.utilization ?? 0, PX.pink)
                    gauge("Renderer", "shading pixels", gpu?.rendererUtilization ?? 0, PX.purple)
                    gauge("Tiler", "sorting geometry into tiles", gpu?.tilerUtilization ?? 0, PX.blue)
                    gauge("Memory", "\(Format.bytes(UInt64(used))) in use of \(Format.bytes(UInt64(reserved))) set aside", reserved > 0 ? used / reserved : 0, PX.cyan, text: Format.bytes(UInt64(used)))
                }
                .padding(.top, 15)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Cores", value: gpu?.cores.map { "\($0)" } ?? "—", detail: "set aside memory grows on demand, out of main memory")
                    PXStatRow(label: "Drawing", value: snapshot.power.gpu.map { AppTablePanel.watts($0) } ?? "Not reported", detail: snapshot.power.total.map { "of \(AppTablePanel.watts($0)) for the whole Mac" })
                    PXStatRow(label: "Hottest sensor", value: snapshot.thermal.gpuTemperature.map { Format.temperature($0) } ?? "—", detail: "\(snapshot.thermal.sensors.filter { $0.group == "GPU" }.count) graphics sensors")
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private func gauge(_ name: String, _ note: String, _ fraction: Double, _ rgb: RGB, text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(name).font(PX.font(12, .medium)).foregroundStyle(PX.label)
                Text(note).font(PX.font(11.5)).foregroundStyle(PX.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text(text ?? Format.percent(fraction))
                    .font(PX.font(12))
                    .monospacedDigit()
                    .foregroundStyle(PX.soft)
            }
            MiniMatrixBar(fraction: fraction > 0.004 ? max(fraction, 0.012) : 0, rgb: fraction >= 0.85 ? PX.orange : rgb, rows: 3)
        }
    }
}

struct GraphicsHistoryPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let load = recent.map(\.gpu), memory = recent.compactMap(\.gpuMemory)
        let top = max(memory.max() ?? 0, Double(snapshot.gpu?.memoryAllocated ?? 0), 1)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func size(_ v: Double) -> String { Format.bytes(UInt64(v)) }
        return PXPanel(title: "Last five minutes", caption: "\(recent.count) readings", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Load", now: Format.percent(snapshot.gpu?.utilization ?? 0), average: Format.percent(avg(load)), peak: Format.percent(load.max() ?? 0), swatch: PX.pink)
                    .padding(.top, 14)
                MatrixChart(samples: recent.map { .init(time: $0.time, value: $0.gpu) }, rgb: PX.pink, rows: 26)
                    .padding(.top, 8)
                ChartHeader(name: "Memory in use", now: size(Double(snapshot.gpu?.memoryInUse ?? 0)), average: size(avg(memory)), peak: size(memory.max() ?? 0), swatch: PX.cyan)
                    .padding(.top, 18)
                MatrixChart(samples: recent.compactMap { p in p.gpuMemory.map { .init(time: p.time, value: $0 / top) } }, rgb: PX.cyan, rows: 16)
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

struct GraphicsHeatPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let temperatures = recent.compactMap(\.gpuTemperature), watts = recent.compactMap(\.gpuPower)
        let top = AreaMeters.wattCeiling(watts.max() ?? 0, floor: 2)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func degrees(_ v: Double?) -> String { v.map { Format.temperature($0) } ?? "—" }
        func power(_ v: Double?) -> String { v.map { AppTablePanel.watts($0) } ?? "—" }
        return PXPanel(title: "Heat and power", caption: "last five minutes", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Temperature, 30° to 108°", now: degrees(snapshot.thermal.gpuTemperature), average: degrees(temperatures.isEmpty ? nil : avg(temperatures)), peak: degrees(temperatures.max()))
                    .padding(.top, 14)
                MatrixChart(samples: recent.compactMap { p in p.gpuTemperature.map { .init(time: p.time, value: ($0 - 30) / 78) } }, rgb: PX.blue, rows: 22, tone: { heatColor($0 * 78 + 30) })
                    .padding(.top, 8)
                ChartHeader(name: "Power, to \(Int(top)) W", now: power(snapshot.power.gpu), average: power(watts.isEmpty ? nil : avg(watts)), peak: power(watts.max()), swatch: PX.yellow)
                    .padding(.top, 18)
                MatrixChart(samples: recent.compactMap { p in p.gpuPower.map { .init(time: p.time, value: $0 / top) } }, rgb: PX.yellow, rows: 20)
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

// MARK: - Power

struct PowerPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @Environment(TimelineStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var meters = AreaMeters()
    @State private var expanded: String?

    var body: some View {
        PageScaffold(title: "Power", subtitle: subtitle, section: .power) { gridWidth, columns in
            if let s = monitor.snapshot {
                PagePair(columns: columns) {
                    MeterCard(model: meters.power(s, history: monitor.history, control: control, askClaude: askClaude), selected: expanded) { id in
                        expanded = expanded == id ? nil : id
                    }
                } second: {
                    PowerPartsPanel(snapshot: s)
                }
                PagePair(columns: columns) {
                    PowerHistoryPanel(history: monitor.history, snapshot: s)
                } second: {
                    if let battery = s.power.battery {
                        BatteryPanel(battery: battery, power: s.power)
                    } else {
                        EnergyDayPanel(snapshot: s, width: PX.cardWidth)
                    }
                }
                if s.power.battery != nil { EnergyDayPanel(snapshot: s, width: gridWidth) }
                if let accessories = s.accessories, !accessories.isEmpty { AccessoriesPanel(accessories: accessories, width: gridWidth) }
                EnergyCostPanel(width: gridWidth)
                AppTablePanel(title: "Apps by energy", apps: Array(s.apps.filter { $0.power > 0.005 }.sorted { $0.power > $1.power }.prefix(18)), metric: .power, width: gridWidth, expanded: $expanded)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        guard s.power.total != nil else { return "This Mac does not report what it draws" }
        let today = store.energyWh(since: Calendar.current.startOfDay(for: Date()))
        var parts = [s.power.battery == nil ? "On mains power" : (s.power.battery?.isPluggedIn == true ? "Plugged in" : "On battery")]
        parts.append("\(Self.energy(today)) today while \(App.name) was running")
        if settings.energyPrice > 0 {
            let month = store.energy(.month).wattHours / 1000 * settings.energyPrice
            parts.append("\(Format.dollars(month)) this month")
        }
        return parts.joined(separator: " · ")
    }

    static func energy(_ wattHours: Double) -> String {
        wattHours >= 1000 ? String(format: "%.2f kWh", wattHours / 1000) : (wattHours >= 10 ? "\(Int(wattHours.rounded())) Wh" : String(format: "%.1f Wh", wattHours))
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

/// The whole draw split into the parts that can be told apart, each as a strip of cells.
struct PowerPartsPanel: View {
    var snapshot: Snapshot
    @Environment(TimelineStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let p = snapshot.power
        let total = max(p.total ?? 0, 0.001)
        let apps = snapshot.apps.reduce(0) { $0 + $1.power }
        // Where the processor's total is reported, apps sit inside it; otherwise their billed energy stands in.
        let processor = p.cpu ?? min(apps, max(0, total - (p.gpu ?? 0)))
        let known = processor + (p.gpu ?? 0) + (p.neural ?? 0) + (p.memory ?? 0)
        let today = store.energyWh(since: Calendar.current.startOfDay(for: Date()))
        PXPanel(title: "Where it goes", caption: p.total.map { "of \(AppTablePanel.watts($0))" } ?? "not reported by this Mac", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 10) {
                    part(p.cpu == nil ? "Processor work" : "Processor", p.cpu == nil ? "what apps are billed for" : "all cores", "cpu.fill", PX.blue, processor, total)
                    part("Graphics cores", p.gpu == nil ? "not reported" : "the GPU itself", "square.stack.3d.up.fill", PX.pink, p.gpu ?? 0, total)
                    if let neural = p.neural { part("Neural engine", "on-device machine learning", "brain", PX.purple, neural, total) }
                    if let memory = p.memory { part("Memory", "keeping the chips powered", "memorychip.fill", PX.cyan, memory, total) }
                    if p.system != nil { part("Everything else", "supply losses, storage, fans, ports", "powerplug.fill", PX.gray, max(0, total - known), total) }
                }
                .padding(.top, 15)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Today", value: PowerPage.energy(today), detail: cost(today) ?? "counted while \(App.name) runs")
                    PXStatRow(label: "This session", value: PowerPage.energy(p.energyWh), detail: p.countingSince.map { "since \(App.name) started \(Format.duration(Date().timeIntervalSince($0))) ago" })
                    if let adapter = p.adapter { PXStatRow(label: "Power adapter", value: "\(Int(adapter)) W", detail: "what it can supply") }
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private func cost(_ wattHours: Double) -> String? {
        guard settings.energyPrice > 0 else { return nil }
        return "about \(Format.dollars(wattHours / 1000 * settings.energyPrice)) at \(Format.price(settings.energyPrice)) per kWh"
    }

    private func part(_ name: String, _ note: String, _ symbol: String, _ rgb: RGB, _ watts: Double, _ total: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                MeterIconView(icon: .symbol(symbol), rgb: rgb, size: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                Text(name).font(PX.font(12, .medium)).foregroundStyle(PX.label)
                Text(note).font(PX.font(11.5)).foregroundStyle(PX.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text(Format.percent(watts / total)).font(PX.font(11.5)).monospacedDigit().foregroundStyle(PX.tertiary)
                Text(AppTablePanel.watts(watts))
                    .font(PX.font(12))
                    .monospacedDigit()
                    .foregroundStyle(PX.soft)
                    .frame(width: 58, alignment: .trailing)
            }
            MiniMatrixBar(fraction: watts / total > 0.004 ? max(watts / total, 0.012) : 0, rgb: rgb, rows: 2)
        }
    }
}

struct PowerHistoryPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let whole = recent.compactMap(\.power), graphics = recent.compactMap(\.gpuPower)
        let top = AreaMeters.wattCeiling(whole.max() ?? 0), graphicsTop = AreaMeters.wattCeiling(graphics.max() ?? 0, floor: 2)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func power(_ v: Double?) -> String { v.map { AppTablePanel.watts($0) } ?? "—" }
        return PXPanel(title: "Last five minutes", caption: "\(recent.count) readings", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Whole Mac, to \(Int(top)) W", now: power(snapshot.power.total), average: power(whole.isEmpty ? nil : avg(whole)), peak: power(whole.max()), swatch: PX.yellow)
                    .padding(.top, 14)
                MatrixChart(samples: recent.compactMap { p in p.power.map { .init(time: p.time, value: $0 / top) } }, rgb: PX.yellow, rows: 26)
                    .padding(.top, 8)
                ChartHeader(name: "Graphics cores, to \(Int(graphicsTop)) W", now: power(snapshot.power.gpu), average: power(graphics.isEmpty ? nil : avg(graphics)), peak: power(graphics.max()), swatch: PX.pink)
                    .padding(.top, 18)
                MatrixChart(samples: recent.compactMap { p in p.gpuPower.map { .init(time: p.time, value: $0 / graphicsTop) } }, rgb: PX.pink, rows: 16)
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

/// A day of draw from the timeline, and what it added up to.
struct EnergyDayPanel: View {
    var snapshot: Snapshot
    var width: CGFloat
    @Environment(TimelineStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let now = Date()
        let from = Int(now.timeIntervalSince1970 / 60) - 1440
        let day = store.minutes.filter { $0.t >= from && $0.power > 0 }
        let watts = day.map { Double($0.power) }
        let top = AreaMeters.wattCeiling(watts.max() ?? snapshot.power.total ?? 0)
        let start = Calendar.current.startOfDay(for: now)
        let today = store.energyWh(since: start)
        let yesterday = store.energyWh(since: start.addingTimeInterval(-86_400)) - today
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func power(_ v: Double?) -> String { v.map { AppTablePanel.watts($0) } ?? "—" }
        return PXPanel(title: "Last 24 hours", caption: day.isEmpty ? "nothing recorded yet" : "\(Format.duration(Double(day.count) * 60)) recorded", width: width) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Draw, to \(Int(top)) W", now: power(snapshot.power.total), average: power(watts.isEmpty ? nil : avg(watts)), peak: power(watts.max()), swatch: PX.yellow)
                    .padding(.top, 14)
                MatrixChart(samples: day.map { .init(time: $0.date, value: Double($0.power) / top) }, rgb: PX.yellow, rows: 30, span: 86_400, anchor: now)
                    .padding(.top, 8)
                ChartAxis(span: "24 hours ago")
                    .padding(.top, 7)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Today so far", value: PowerPage.energy(today), detail: price(today))
                    PXStatRow(label: "Yesterday", value: yesterday > 0.05 ? PowerPage.energy(yesterday) : "Not recorded", detail: yesterday > 0.05 && settings.energyPrice > 0 ? price(yesterday) : nil)
                    PXStatRow(label: "If it ran like this all year", value: watts.isEmpty ? "—" : String(format: "%.0f kWh", avg(watts) * 8.76), detail: "at the recorded average")
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private func price(_ wattHours: Double) -> String? {
        guard settings.energyPrice > 0 else { return "set a price per kWh below to see cost" }
        return "about \(Format.dollars(wattHours / 1000 * settings.energyPrice))"
    }
}

struct BatteryPanel: View {
    var battery: BatteryInfo
    var power: PowerStats

    var body: some View {
        let rgb = battery.charge > 0.5 ? PX.greenRGB : (battery.charge > 0.2 ? PX.yellow : PX.red)
        let state = battery.isCharging ? "charging" : (battery.isPluggedIn ? "plugged in, holding" : "on battery")
        PXPanel(title: "Battery", caption: state, width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6.5) {
                    Text(Format.percent(battery.charge))
                        .font(PX.font(22.5, .medium))
                        .tracking(PX.tracking(22.5))
                        .foregroundStyle(PX.text)
                    Text(battery.minutesRemaining.map { "\(Format.duration(Double($0) * 60)) \(battery.isCharging ? "until full" : "left at this rate")" } ?? "no estimate yet")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                }
                .padding(.top, 16)
                MiniMatrixBar(fraction: max(battery.charge, 0.012), rgb: rgb, rows: 8)
                    .padding(.top, 14)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: battery.isCharging ? "Charging at" : "Draining at", value: battery.watts.map { AppTablePanel.watts(abs($0)) } ?? "—", detail: power.adapter.map { "adapter can supply \(Int($0)) W" })
                    PXStatRow(label: "Health", value: battery.health.map { Format.percent($0) } ?? "—", detail: "full charge against the capacity it was built with")
                    PXStatRow(label: "Cycles", value: battery.cycles.map { "\($0)" } ?? "—", detail: "full discharges, added up")
                    PXStatRow(label: "Temperature", value: battery.celsius.map { String(format: "%.1f°", $0) } ?? "—", detail: "of the battery itself")
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

// MARK: - Energy and cost

/// The price of a kilowatt-hour, typed where it is used.
struct PriceField: View {
    @Environment(AppSettings.self) private var settings
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var settings = settings
        HStack(spacing: 7) {
            Text("Price")
                .font(PX.font(11.5))
                .foregroundStyle(PX.tertiary)
            HStack(spacing: 3) {
                Text("$").foregroundStyle(PX.secondary)
                TextField("0.00", value: $settings.energyPrice, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.plain)
                    .frame(width: 44)
                    .focused($focused)
                    .onSubmit { focused = false }
            }
            .font(PX.font(12))
            .monospacedDigit()
            .foregroundStyle(PX.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PX.button))
            Text("per kWh")
                .font(PX.font(11.5))
                .foregroundStyle(PX.tertiary)
        }
        .help("What you pay for a kilowatt-hour, in dollars. It is on your electricity bill.")
        // A window that opens on this page hands its first text field the keyboard; this one should wait to be clicked.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = false } }
    }
}

/// What the Mac has drawn over a period you choose, and what that cost: this month unless you pick another.
/// The totals come from a ledger of one entry per day that is never trimmed, so a year and all time work
/// long after the minute records have rolled off.
struct EnergyCostPanel: View {
    var width: CGFloat
    @Environment(TimelineStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let period = settings.energyPeriod
        let summary = store.energy(period)
        let price = settings.energyPrice
        let recorded = summary.bars.compactMap(\.wattHours)
        let highest = summary.bars.filter { $0.wattHours != nil }.max { ($0.wattHours ?? 0) < ($1.wattHours ?? 0) }
        let wide = width > 700
        PXPanel(title: "Energy and cost", caption: wide ? Self.caption(summary, period) : nil, width: width) {
            HStack(spacing: 2) {
                ForEach(EnergyPeriod.allCases) { item in
                    PXPill(title: item.title, symbol: nil, rgb: PX.yellow, selected: period == item) { settings.energyPeriod = item }
                }
            }
            .padding(.trailing, -6)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6.5) {
                    Text(price > 0 ? Format.dollars(summary.wattHours / 1000 * price) : PowerPage.energy(summary.wattHours))
                        .font(PX.font(22.5, .medium))
                        .tracking(PX.tracking(22.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.text)
                    Text(price > 0 ? "for \(PowerPage.energy(summary.wattHours)) \(period.phrase)" : "drawn \(period.phrase)")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    PriceField()
                }
                .padding(.top, 16)
                EnergyBarsChart(bars: summary.bars, rgb: PX.yellow, rows: wide ? 20 : 16)
                    .padding(.top, 14)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    if recorded.isEmpty {
                        PXStatRow(label: "Nothing recorded \(period.phrase)", value: "—", detail: "energy is counted while \(App.name) is running")
                    } else {
                        let average = recorded.reduce(0, +) / Double(recorded.count)
                        PXStatRow(label: "Average per \(summary.unit)", value: amount(average, price), detail: price > 0 ? PowerPage.energy(average) : "over \(recorded.count) recorded")
                        if let projected = summary.projected {
                            PXStatRow(label: "The whole month, at this rate", value: amount(projected, price), detail: price > 0 ? "\(PowerPage.energy(projected)), from the \(summary.daysRecorded) \(summary.daysRecorded == 1 ? "day" : "days") recorded" : "from the \(summary.daysRecorded) recorded")
                        } else if let highest {
                            PXStatRow(label: "Highest \(summary.unit)", value: amount(highest.wattHours ?? 0, price), detail: Self.name(highest, unit: summary.unit))
                        }
                        PXStatRow(label: "Recorded", value: Format.duration(Double(summary.minutes) * 60), detail: "only the time \(App.name) was running is counted")
                    }
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
    }

    private func amount(_ wattHours: Double, _ price: Double) -> String {
        price > 0 ? Format.dollars(wattHours / 1000 * price) : PowerPage.energy(wattHours)
    }

    private static func name(_ bar: EnergySummary.Bar, unit: String) -> String {
        switch unit {
        case "hour": return "from \(bar.label):00"
        case "month": return "in \(bar.label)"
        default: return bar.isCurrent ? "today" : (Int(bar.label) == nil ? "on \(bar.label)" : "on the \(bar.label)\(ordinal(bar.label))")
        }
    }

    private static func ordinal(_ label: String) -> String {
        guard let number = Int(label) else { return "" }
        if (11...13).contains(number % 100) { return "th" }
        switch number % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func caption(_ summary: EnergySummary, _ period: EnergyPeriod) -> String {
        guard let since = summary.since else { return "nothing recorded yet" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        switch period {
        case .today: return "by the hour"
        case .week: return "by the day"
        case .month: return "by the day, \(summary.daysRecorded) recorded"
        case .year: return "by the month"
        case .all: return "since \(formatter.string(from: since))"
        }
    }
}

/// Bars of energy as columns of cells: one bar an hour, a day or a month, the current one capped in white.
struct EnergyBarsChart: View {
    var bars: [EnergySummary.Bar]
    var rgb: RGB
    var rows = 18

    private static let labels: CGFloat = 15

    private struct Spec: Hashable {
        struct Bar: Hashable {
            /// Lit cells from the bottom.
            var filled: Int
            var isCurrent: Bool
        }

        var rows: Int
        var rgb: RGB
        var bars: [Bar]
    }

    /// Where the bars sit on the grid: each as wide as fits, up to eight columns, with one empty column between.
    private struct Grid {
        var cols: Int
        var gx: CGFloat
        var barWidth: Int
        var stride: Int
        var first: Int

        init(width: CGFloat, count: Int) {
            let p = PX.pitch
            cols = max(1, Int((width / p).rounded(.down)))
            gx = (width - CGFloat(cols) * p) / 2
            barWidth = max(1, min(8, (cols + 1) / count - 1))
            stride = barWidth + 1
            first = max(0, (cols - (count * stride - 1)) / 2)
        }

        func center(of index: Int) -> CGFloat {
            gx + (CGFloat(first + index * stride) + CGFloat(barWidth) / 2) * PX.pitch
        }
    }

    private var trackHeight: CGFloat { CGFloat(rows) * PX.pitch + 6 }

    var body: some View {
        BitmapPicture(spec: { _ in spec }, draw: Self.draw)
            .frame(height: trackHeight)
            .frame(height: trackHeight + Self.labels, alignment: .top)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    let grid = Grid(width: geo.size.width, count: max(bars.count, 1))
                    ForEach(labelled, id: \.self) { index in
                        let bar = bars[index]
                        Text(bar.label)
                            .font(.system(size: 9.5, weight: bar.isCurrent ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(bar.isCurrent ? PX.soft : PX.tertiary)
                            .fixedSize()
                            .frame(width: 0, height: 0, alignment: .top)
                            .offset(x: grid.center(of: index), y: trackHeight + 4)
                    }
                }
                .allowsHitTesting(false)
            }
    }

    private var spec: Spec {
        let top = max(bars.compactMap(\.wattHours).max() ?? 0, 1e-9)
        return Spec(rows: rows, rgb: rgb, bars: bars.map { bar in
            Spec.Bar(filled: bar.wattHours.map { $0 <= 0 ? 0 : max(1, Int(($0 / top * Double(rows)).rounded())) } ?? 0, isCurrent: bar.isCurrent)
        })
    }

    /// A label under the first bar, the last, and enough in between to read the scale.
    private var labelled: [Int] {
        let count = max(bars.count, 1)
        let step = max(1, Int((Double(count) / 9).rounded(.up)))
        return bars.indices.filter { index in
            guard index % step == 0 || index == count - 1 else { return false }
            if index == count - 1, (count - 1) % step != 0, (count - 1) % step < max(1, step / 2 + 1), step > 1 { return false }
            return true
        }
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        let rows = spec.rows
        let grid = Grid(width: size.width, count: max(spec.bars.count, 1))
        let frame = CGRect(origin: .zero, size: size)
        pen.fill(rounded: frame, radius: 8, continuous: true, PX.trackRGB)

        let side = p - 1.15
        var lit: [CGRect] = [], now: [CGRect] = [], caps: [CGRect] = []
        var occupied = Set<Int>()
        for (index, bar) in spec.bars.enumerated() {
            for offset in 0..<grid.barWidth {
                let column = grid.first + index * grid.stride + offset
                guard column < grid.cols else { continue }
                let cx = grid.gx + (CGFloat(column) + 0.5) * p
                for row in 0..<bar.filled {
                    let cy = 3 + (CGFloat(rows - 1 - row) + 0.5) * p
                    let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                    occupied.insert(column * 1000 + row)
                    if row == bar.filled - 1 { caps.append(rect) } else if bar.isCurrent { now.append(rect) } else { lit.append(rect) }
                }
            }
        }
        var dim: [CGRect] = []
        for column in 0..<grid.cols {
            let cx = grid.gx + (CGFloat(column) + 0.5) * p
            for row in 0..<rows where !occupied.contains(column * 1000 + row) {
                let cy = 3 + (CGFloat(rows - 1 - row) + 0.5) * p
                dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
            }
        }
        pen.clip(rounded: frame, radius: 8, continuous: true)
        pen.fill(dim, .white, 0.085)
        pen.fill(lit, spec.rgb, 0.74)
        pen.fill(now, spec.rgb.mixed(with: .white, 0.25), 0.95)
        pen.fill(caps, spec.rgb.mixed(with: .white, 0.55), 0.98)
    }
}
