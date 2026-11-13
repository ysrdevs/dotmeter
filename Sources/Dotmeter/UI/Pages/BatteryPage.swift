import SwiftUI

/// Shared look of a charge level.
enum BatteryLook {
    static func color(_ charge: Double) -> RGB {
        charge > 0.5 ? PX.greenRGB : (charge > 0.2 ? PX.yellow : PX.red)
    }

    /// The system symbol nearest a level.
    static func symbol(_ battery: BatteryInfo) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.charge {
        case 0.88...: return "battery.100percent"
        case 0.63...: return "battery.75percent"
        case 0.38...: return "battery.50percent"
        case 0.13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    static func time(_ minutes: Int?) -> String {
        minutes.map { Format.duration(Double($0) * 60) } ?? "—"
    }
}

struct BatteryPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @State private var meters = AreaMeters()
    @State private var expanded: String?

    var body: some View {
        PageScaffold(title: "Battery", subtitle: subtitle, section: .battery) { gridWidth, columns in
            if let s = monitor.snapshot, let battery = s.power.battery {
                PagePair(columns: columns) {
                    MeterCard(model: meters.battery(s, history: monitor.history, control: control, askClaude: askClaude), selected: expanded) { id in
                        expanded = expanded == id ? nil : id
                    }
                } second: {
                    BatteryHealthPanel(battery: battery, power: s.power)
                }
                PagePair(columns: columns) {
                    BatteryChargePanel(battery: battery)
                } second: {
                    BatteryRatePanel(battery: battery, history: monitor.history, snapshot: s)
                }
                AppTablePanel(title: battery.isPluggedIn ? "Apps by energy" : "What is draining it", apps: Array(s.apps.filter { $0.power > 0.005 }.sorted { $0.power > $1.power }.prefix(18)), metric: .power, width: gridWidth, expanded: $expanded)
            } else if monitor.snapshot != nil {
                HStack(spacing: 9) {
                    MeterIconView(icon: .symbol("battery.0percent"), rgb: PX.gray, size: 15)
                    Text("This Mac has no battery.").font(PX.font(12.5)).foregroundStyle(PX.label)
                    Spacer()
                }
                .padding(.horizontal, PX.inset)
                .frame(width: gridWidth, height: 64)
                .pxCard()
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let battery = monitor.snapshot?.power.battery else { return "Reading sensors" }
        var parts = [battery.state.prefix(1).uppercased() + battery.state.dropFirst()]
        if let health = battery.health { parts.append("holds \(Format.percent(health)) of what it did new") }
        if let cycles = battery.cycles { parts.append("\(cycles) cycles") }
        return parts.joined(separator: " · ")
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

/// What the battery can still hold, against what it held when it was new.
struct BatteryHealthPanel: View {
    var battery: BatteryInfo
    var power: PowerStats

    var body: some View {
        let health = battery.health ?? 1
        let rgb = health >= 0.8 ? PX.greenRGB : (health >= 0.7 ? PX.yellow : PX.orange)
        PXPanel(title: "Health", caption: "what it can still hold", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6.5) {
                    Text(battery.health.map { Format.percent($0) } ?? "—")
                        .font(PX.font(22.5, .medium))
                        .tracking(PX.tracking(22.5))
                        .foregroundStyle(PX.text)
                    Text(health >= 0.8 ? "of the capacity it was built with" : "of the capacity it was built with: service is worth considering under 80%")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 16)
                MiniMatrixBar(fraction: max(health, 0.012), rgb: rgb, rows: 6)
                    .padding(.top, 14)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Holds when full", value: battery.fullCapacity.map { "\(Format.count(UInt64($0))) mAh" } ?? "—", detail: battery.designCapacity.map { "\(Format.count(UInt64($0))) mAh when new" })
                    PXStatRow(label: "Cycles", value: battery.cycles.map { "\($0)" } ?? "—", detail: "full discharges added up; Apple rates these for 1,000")
                    PXStatRow(label: "Temperature", value: battery.celsius.map { String(format: "%.1f°", $0) } ?? "—", detail: "of the battery itself")
                    PXStatRow(label: "Voltage", value: battery.volts.map { String(format: "%.2f V", $0) } ?? "—", detail: battery.fullWattHours.map { String(format: "a full charge is %.0f Wh", $0) })
                    PXStatRow(label: "Power adapter", value: power.adapter.map { "\(Int($0)) W" } ?? (battery.isPluggedIn ? "Connected" : "Not connected"), detail: battery.adapterName)
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

/// The charge over the last day, from the timeline, colored by how full it was.
struct BatteryChargePanel: View {
    var battery: BatteryInfo
    @Environment(TimelineStore.self) private var store

    var body: some View {
        let now = Date()
        let from = Int(now.timeIntervalSince1970 / 60) - 1440
        let day = store.minutes.filter { $0.t >= from && $0.battery != nil }
        let levels = day.compactMap { $0.battery.map { Double($0) } }
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return PXPanel(title: "Charge", caption: day.isEmpty ? "the last 24 hours fill in as \(App.name) runs" : "last 24 hours, \(Format.duration(Double(day.count) * 60)) recorded", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Level", now: Format.percent(battery.charge), average: levels.isEmpty ? "—" : Format.percent(avg(levels)), peak: levels.isEmpty ? "—" : Format.percent(levels.max() ?? 0), swatch: BatteryLook.color(battery.charge))
                    .padding(.top, 14)
                MatrixChart(samples: day.compactMap { m in m.battery.map { .init(time: m.date, value: Double($0)) } }, rgb: PX.greenRGB, rows: 34, span: 86_400, tone: { BatteryLook.color($0) }, anchor: now)
                    .padding(.top, 8)
                ChartAxis(span: "24 hours ago")
                    .padding(.top, 7)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Lowest in that time", value: levels.min().map { Format.percent($0) } ?? "—", detail: day.min { ($0.battery ?? 1) < ($1.battery ?? 1) }.map { Self.clock($0.date) })
                    PXStatRow(label: "Now", value: Format.percent(battery.charge), detail: battery.state)
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "'at' HH:mm"
        return formatter.string(from: date)
    }
}

/// How fast it is draining or charging, and what that means for the time left.
struct BatteryRatePanel: View {
    var battery: BatteryInfo
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let rates = recent.compactMap { $0.batteryWatts.map(abs) }
        let top = AreaMeters.wattCeiling(rates.max() ?? 0, floor: 10)
        let rgb = battery.isCharging ? PX.greenRGB : PX.orange
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func power(_ v: Double?) -> String { v.map { AppTablePanel.watts($0) } ?? "—" }
        let lasts = battery.fullWattHours.flatMap { full -> String? in
            let draw = avg(rates)
            guard !battery.isCharging, draw > 0.5 else { return nil }
            return Format.duration(full / draw * 3600)
        }
        return PXPanel(title: battery.isCharging ? "Charging" : "Drain", caption: "last five minutes, to \(Int(top)) W", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: battery.isCharging ? "Going in" : "Coming out", now: power(battery.watts.map(abs)), average: power(rates.isEmpty ? nil : avg(rates)), peak: power(rates.max()), swatch: rgb)
                    .padding(.top, 14)
                MatrixChart(samples: recent.compactMap { p in p.batteryWatts.map { .init(time: p.time, value: abs($0) / top) } }, rgb: rgb, rows: 26)
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: battery.isCharging ? "Full in" : "Time left", value: battery.isPluggedIn && !battery.isCharging ? "On mains" : BatteryLook.time(battery.minutesRemaining), detail: battery.minutesRemaining == nil && !battery.isPluggedIn ? "macOS is still working it out" : "as macOS estimates it")
                    PXStatRow(label: "A full charge at this rate", value: lasts ?? "—", detail: lasts == nil ? nil : "the average of the last five minutes")
                    PXStatRow(label: "The whole Mac is drawing", value: power(snapshot.power.total), detail: battery.isCharging ? "the rest of the adapter's output goes into the battery" : nil)
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}
