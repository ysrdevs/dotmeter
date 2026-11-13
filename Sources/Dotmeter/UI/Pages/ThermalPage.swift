import SwiftUI

struct ThermalPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @State private var meters = AreaMeters()

    var body: some View {
        PageScaffold(title: "Thermals", subtitle: subtitle, section: .thermal) { gridWidth, columns in
            if let s = monitor.snapshot {
                PagePair(columns: columns) {
                    MeterCard(model: meters.thermal(s, askClaude: askClaude))
                } second: {
                    FansPanel(thermal: s.thermal)
                }
                PagePair(columns: columns) {
                    TemperatureHistoryPanel(history: monitor.history, snapshot: s)
                } second: {
                    FanHistoryPanel(history: monitor.history, snapshot: s)
                }
                SensorsPanel(thermal: s.thermal, width: gridWidth)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        return "\(s.thermal.sensors.count) temperature sensors · \(s.thermal.fans.count) \(s.thermal.fans.count == 1 ? "fan" : "fans") · macOS thermal state \(s.thermal.state.title.lowercased())"
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

func heatColor(_ celsius: Double) -> RGB {
    celsius >= 92 ? PX.red : (celsius >= 75 ? PX.orange : (celsius >= 55 ? PX.greenRGB : PX.blue))
}

struct FansPanel: View {
    var thermal: ThermalStats
    @Environment(TimelineStore.self) private var timeline

    var body: some View {
        let day = timeline.today()
        return PXPanel(title: "Fans", caption: thermal.fans.isEmpty ? "this Mac has none" : "\(Format.percent(thermal.averageFanPercent)) of their range", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                if thermal.fans.isEmpty {
                    Text("No fans were found. This Mac cools itself passively.")
                        .font(PX.font(12))
                        .foregroundStyle(PX.secondary)
                        .padding(.top, 16)
                }
                ForEach(thermal.fans) { fan in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            MeterIconView(icon: .symbol("fan.fill"), rgb: PX.cyan, size: 13)
                            Text(thermal.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan")
                                .font(PX.font(12, .medium))
                                .foregroundStyle(PX.label)
                            Spacer()
                            Text("\(Format.rpm(fan.rpm)) rpm")
                                .font(PX.headline(17))
                                .monospacedDigit()
                                .foregroundStyle(PX.text)
                        }
                        MiniMatrixBar(fraction: max(fan.percent, 0.012), rgb: fan.percent >= 0.75 ? PX.orange : PX.cyan, rows: 4)
                        HStack {
                            Text("\(Format.rpm(fan.minRPM)) min")
                            Spacer()
                            if let target = fan.target { Text("target \(Format.rpm(target))") }
                            Spacer()
                            Text("\(Format.rpm(fan.maxRPM)) max")
                        }
                        .font(PX.font(10.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.tertiary)
                    }
                    .padding(.top, 16)
                }
                Spacer(minLength: 12)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "macOS thermal state", value: thermal.state.title, detail: "above nominal, things get slowed down")
                    PXStatRow(label: "CPU speed limit", value: thermal.cpuSpeedLimit.map { "\($0)%" } ?? "None", detail: thermal.isThrottled ? "throttling to cool down" : "running at full speed")
                    PXStatRow(label: "Today", value: Detail.hotToday(day), detail: day.hottest.map { "peak \(Format.temperature($0))" })
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

struct TemperatureHistoryPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let cpu = recent.compactMap(\.cpuTemperature), gpu = recent.compactMap(\.gpuTemperature)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func scale(_ celsius: Double) -> Double { (celsius - 30) / 78 }
        func degrees(_ v: Double?) -> String { v.map { Format.temperature($0) } ?? "—" }
        return PXPanel(title: "Temperature", caption: "last five minutes, 30° to 108°", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "CPU, hottest core", now: degrees(snapshot.thermal.cpuTemperature), average: degrees(cpu.isEmpty ? nil : avg(cpu)), peak: degrees(cpu.max()))
                    .padding(.top, 14)
                MatrixChart(samples: recent.compactMap { p in p.cpuTemperature.map { .init(time: p.time, value: scale($0)) } }, rgb: PX.blue, rows: 14, tone: { heatColor($0 * 78 + 30) })
                    .padding(.top, 8)
                ChartHeader(name: "GPU", now: degrees(snapshot.thermal.gpuTemperature), average: degrees(gpu.isEmpty ? nil : avg(gpu)), peak: degrees(gpu.max()))
                    .padding(.top, 16)
                MatrixChart(samples: recent.compactMap { p in p.gpuTemperature.map { .init(time: p.time, value: scale($0)) } }, rgb: PX.blue, rows: 10, tone: { heatColor($0 * 78 + 30) })
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, PX.inset)
        }
    }
}

struct FanHistoryPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let rpm = recent.map(\.fanRPM)
        let ceiling = max(snapshot.thermal.fans.map(\.maxRPM).max() ?? 1, 1)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return PXPanel(title: "Fans and load", caption: "last five minutes", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Fan speed", now: Format.rpm(snapshot.thermal.averageRPM), average: Format.rpm(avg(rpm)), peak: Format.rpm(rpm.max() ?? 0))
                    .padding(.top, 14)
                MatrixChart(samples: recent.map { .init(time: $0.time, value: $0.fanRPM / ceiling) }, rgb: PX.cyan, rows: 14)
                    .padding(.top, 8)
                ChartHeader(name: "Processor load", now: Format.percent(snapshot.cpu.total), average: Format.percent(avg(recent.map(\.cpu))), peak: Format.percent(recent.map(\.cpu).max() ?? 0))
                    .padding(.top, 16)
                MatrixChart(samples: recent.map { .init(time: $0.time, value: $0.cpu) }, rgb: PX.blue, rows: 10)
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, PX.inset)
        }
    }
}

/// Every temperature sensor, grouped, one cell per sensor colored by how hot it is.
struct SensorsPanel: View {
    var thermal: ThermalStats
    var width: CGFloat

    private static let order = ["CPU", "GPU", "SoC", "Memory", "Storage", "Power", "Airflow", "Enclosure", "Battery", "Wireless", "Other"]
    private static let symbols = ["CPU": "cpu.fill", "GPU": "rectangle.3.group.fill", "SoC": "square.grid.3x3.fill", "Memory": "memorychip.fill", "Storage": "internaldrive.fill", "Power": "bolt.fill", "Airflow": "wind", "Enclosure": "macstudio.fill", "Battery": "battery.75percent", "Wireless": "wifi", "Other": "sensor.fill"]
    private static let notes = ["SoC": "does not follow load on this chip", "Airflow": "air moving through the case", "Enclosure": "the case itself"]

    var body: some View {
        let groups = Dictionary(grouping: thermal.sensors, by: \.group)
        let names = Self.order.filter { groups[$0] != nil } + groups.keys.filter { !Self.order.contains($0) }.sorted()
        PXPanel(title: "Sensors", caption: "\(thermal.sensors.count) readings, hottest first in each group", width: width) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Group").frame(width: 150, alignment: .leading)
                    Text("Each cell is one sensor").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Low").frame(width: 52, alignment: .trailing)
                    Text("Avg").frame(width: 52, alignment: .trailing)
                    Text("High").frame(width: 52, alignment: .trailing)
                }
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .padding(.horizontal, PX.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                PXDivider()
                VStack(spacing: 0) {
                    ForEach(names, id: \.self) { name in
                        let readings = (groups[name] ?? []).map(\.celsius).sorted(by: >)
                        let high = readings.first ?? 0, low = readings.last ?? 0
                        let average = readings.isEmpty ? 0 : readings.reduce(0, +) / Double(readings.count)
                        HStack(alignment: .center, spacing: 0) {
                            HStack(spacing: 8) {
                                MeterIconView(icon: .symbol(Self.symbols[name] ?? "sensor.fill"), rgb: heatColor(high), size: 13)
                                Text(name).font(PX.font(12, .medium)).foregroundStyle(PX.label)
                                Text("\(readings.count)").font(PX.font(11)).monospacedDigit().foregroundStyle(PX.tertiary)
                            }
                            .frame(width: 150, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                HeatStrip(readings: readings)
                                if let note = Self.notes[name] {
                                    Text(note).font(PX.font(10.5)).foregroundStyle(PX.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Group {
                                Text(Format.temperature(low)).frame(width: 52, alignment: .trailing)
                                Text(Format.temperature(average)).frame(width: 52, alignment: .trailing)
                                Text(Format.temperature(high)).foregroundStyle(PX.label).frame(width: 52, alignment: .trailing)
                            }
                            .font(PX.font(12))
                            .monospacedDigit()
                            .foregroundStyle(PX.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, PX.inset)
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }
}

/// One small square per sensor, hottest first, wrapping onto further rows.
struct HeatStrip: View {
    var readings: [Double]
    private static let cell: CGFloat = 5.2
    private static let gap: CGFloat = 1.8

    private struct Spec: Hashable {
        var perRow: Int
        var readings: [Double]
    }

    var body: some View {
        BitmapPicture(
            spec: { size in Spec(perRow: max(1, Int((size.width + Self.gap) / (Self.cell + Self.gap))), readings: readings) },
            draw: Self.draw
        )
        .frame(height: height)
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        for (i, value) in spec.readings.enumerated() {
            let rect = CGRect(x: CGFloat(i % spec.perRow) * (cell + gap), y: CGFloat(i / spec.perRow) * (cell + gap), width: cell, height: cell)
            let strength = min(max((value - 25) / 70, 0.25), 1)
            pen.fill(rounded: rect, radius: 1.2, heatColor(value), 0.35 + 0.65 * strength)
        }
    }

    /// Rows needed at the narrowest layout this is used in (about 60 cells per row); extra space is harmless.
    private var height: CGFloat {
        let rows = max(1, Int(ceil(Double(readings.count) / 60)))
        return CGFloat(rows) * (Self.cell + Self.gap) - Self.gap
    }
}
