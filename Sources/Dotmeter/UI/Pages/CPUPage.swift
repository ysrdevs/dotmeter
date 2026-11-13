import SwiftUI

struct CPUPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @State private var meters = AreaMeters()
    @State private var expanded: String?

    var body: some View {
        PageScaffold(title: "Processor", subtitle: subtitle, section: .cpu) { gridWidth, columns in
            if let s = monitor.snapshot {
                MeterCard(model: meters.cpu(s, count: columns * 9 - 1, control: control, askClaude: askClaude), width: gridWidth, selected: expanded) { id in
                    expanded = expanded == id ? nil : id
                }
                PagePair(columns: columns) {
                    CoresPanel(cpu: s.cpu)
                } second: {
                    CPUHistoryPanel(history: monitor.history, snapshot: s)
                }
                AppTablePanel(title: "Apps by processor use", apps: Array(s.apps.prefix(18)), metric: .cpu, width: gridWidth, expanded: $expanded)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        return "\(s.system.chip) · \(s.cpu.performanceCores) performance and \(s.cpu.efficiencyCores) efficiency cores · \(Detail.count(s.processes.count, "processes")) · up \(Format.duration(s.system.uptime))"
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

/// One small column of cells per core, lit from the bottom by load.
struct CoresPanel: View {
    var cpu: CPUStats

    var body: some View {
        // Samples arrive efficiency cores first; show performance cores first, as people think of them.
        let efficiency = Array(cpu.perCore.prefix(cpu.efficiencyCores))
        let performance = Array(cpu.perCore.dropFirst(cpu.efficiencyCores))
        let cores: [(String, Double)] = performance.enumerated().map { ("P\($0.offset + 1)", $0.element) } + efficiency.enumerated().map { ("E\($0.offset + 1)", $0.element) }
        let busy = cpu.perCore.filter { $0 > 0.5 }.count
        PXPanel(title: "Cores", caption: ([busy == 0 ? "all below half load" : "\(busy) above half load"] + [Detail.clusters(cpu)].compactMap { $0 }).joined(separator: " · "), width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 16), spacing: 12) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { _, core in
                        VStack(spacing: 4) {
                            CoreCell(load: core.1)
                            Text(core.0)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(core.0.hasPrefix("E") ? PX.tertiary : PX.secondary)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, PX.inset - 6)

                Spacer(minLength: 14)
                PXDivider()
                VStack(spacing: 0) {
                    PXStatRow(label: "User", value: Format.percent(cpu.user), detail: "your apps")
                    PXStatRow(label: "System", value: Format.percent(cpu.system), detail: "macOS on their behalf")
                    PXStatRow(label: "Load average", value: cpu.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: "   "), detail: "1, 5 and 15 minutes")
                }
                .padding(.horizontal, PX.inset)
                .padding(.vertical, 7)
            }
        }
        .frame(height: 342.75)
    }
}

struct CoreCell: View {
    var load: Double
    var cols = 6
    var rows = 14

    private struct Spec: Hashable {
        var filled: Int
        var rgb: RGB
        var cols: Int
        var rows: Int
    }

    var body: some View {
        BitmapPicture(spec: { _ in spec }, draw: Self.draw, shared: true)
            .frame(width: CGFloat(cols) * PX.pitch, height: CGFloat(rows) * PX.pitch)
            .contentShape(Rectangle())
            .help("\(Int((load * 100).rounded()))%")
    }

    private var spec: Spec {
        Spec(
            filled: load > 0.015 ? max(1, Int((min(load, 1) * Double(rows)).rounded())) : 0,
            rgb: load >= 0.85 ? PX.red : (load >= 0.6 ? PX.orange : PX.blue),
            cols: cols, rows: rows
        )
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        var lit: [CGRect] = [], dim: [CGRect] = []
        let side = p - 1.15
        for c in 0..<spec.cols {
            for r in 0..<spec.rows {
                let cx = (CGFloat(c) + 0.5) * p, cy = (CGFloat(r) + 0.5) * p
                if spec.rows - 1 - r < spec.filled {
                    lit.append(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
                } else {
                    dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                }
            }
        }
        pen.fill(rounded: CGRect(origin: .zero, size: size), radius: 3.5, spec.rgb, spec.filled > 0 ? 0.10 : 0.0)
        pen.fill(dim, .white, 0.12)
        pen.fill(lit, spec.rgb, 0.95)
    }
}

/// Chart header: a name on the left, now / average / peak on the right.
struct ChartHeader: View {
    var name: String
    var now: String
    var average: String
    var peak: String
    /// A small square in the series color, for charts that carry more than one.
    var swatch: RGB?
    /// What the first figure is called. A chart of a past day has a low, not a now.
    var first = "now"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(swatch.color())
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 6.5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            }
            Text(name)
                .font(PX.font(12))
                .foregroundStyle(PX.label)
            Spacer(minLength: 8)
            Text(first + " ").foregroundStyle(PX.tertiary)
            Text(now).foregroundStyle(PX.soft)
            Text("   avg ").foregroundStyle(PX.tertiary)
            Text(average).foregroundStyle(PX.secondary)
            Text("   peak ").foregroundStyle(PX.tertiary)
            Text(peak).foregroundStyle(PX.secondary)
        }
        .font(PX.font(11.5))
        .monospacedDigit()
        .lineLimit(1)
    }
}

struct ChartAxis: View {
    var span: String
    var body: some View {
        HStack {
            Text(span)
            Spacer()
            Text("now")
        }
        .font(PX.font(10.5))
        .foregroundStyle(PX.tertiary)
    }
}

struct CPUHistoryPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let cpu = recent.map(\.cpu), gpu = recent.map(\.gpu)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return PXPanel(title: "Last five minutes", caption: "\(recent.count) readings", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Processor", now: Format.percent(snapshot.cpu.total), average: Format.percent(avg(cpu)), peak: Format.percent(cpu.max() ?? 0))
                    .padding(.top, 14)
                MatrixChart(samples: recent.map { .init(time: $0.time, value: $0.cpu) }, rgb: PX.blue, rows: 26)
                    .padding(.top, 8)
                ChartHeader(name: "Graphics", now: Format.percent(snapshot.gpu?.utilization ?? 0), average: Format.percent(avg(gpu)), peak: Format.percent(gpu.max() ?? 0))
                    .padding(.top, 18)
                MatrixChart(samples: recent.map { .init(time: $0.time, value: $0.gpu) }, rgb: PX.purple, rows: 16)
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

/// Every app on the list, sorted by one measure, with its helpers and what can be done to it one click away.
struct AppTablePanel: View {
    enum Metric { case cpu, memory, gpu, power, disk }

    var title: String
    var apps: [AppUsage]
    var metric: Metric
    var width: CGFloat
    @Binding var expanded: String?

    private struct Column {
        var title: String
        var width: CGFloat
        var strong: Bool
        var app: (AppUsage) -> String
        var process: (ProcessUsage) -> String
    }

    static func share(_ fraction: Double) -> String {
        let value = fraction * 100
        return value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    static func watts(_ value: Double) -> String {
        value < 0.995 ? String(format: "%.2f W", value) : (value < 99.5 ? String(format: "%.1f W", value) : "\(Int(value.rounded())) W")
    }

    private var columns: [Column] {
        let cpu = Column(title: "CPU", width: 70, strong: metric == .cpu, app: { Format.cpu($0.cpu) }, process: { Format.cpu($0.cpu) })
        let memory = Column(title: "Memory", width: 86, strong: metric == .memory, app: { Format.bytes($0.memory) }, process: { Format.bytes($0.memory) })
        let processes = Column(title: "Processes", width: 78, strong: false, app: { "\($0.processCount)" }, process: { _ in "" })
        let gpu = Column(title: "GPU", width: 70, strong: metric == .gpu, app: { Self.share($0.gpu) }, process: { Self.share($0.gpu) })
        let power = Column(title: "Power", width: 78, strong: true, app: { Self.watts($0.power) }, process: { Self.watts($0.power) })
        let read = Column(title: "Read", width: 92, strong: true, app: { Format.rate($0.diskRead) }, process: { Format.rate($0.diskRead) })
        let write = Column(title: "Write", width: 92, strong: true, app: { Format.rate($0.diskWrite) }, process: { Format.rate($0.diskWrite) })
        let all: [Column]
        switch metric {
        case .cpu, .memory: all = [cpu, memory, processes]
        case .gpu: all = [gpu, cpu, memory]
        case .power: all = [power, cpu, gpu]
        case .disk: all = [read, write, cpu]
        }
        // One card wide there is room for two figures beside the name.
        return width > 700 ? all : Array(all.prefix(2))
    }

    private func value(_ app: AppUsage) -> Double {
        switch metric {
        case .cpu: return app.cpu
        case .memory: return Double(app.memory)
        case .gpu: return app.gpu
        case .power: return app.power
        case .disk: return app.disk
        }
    }

    private func barColor(_ app: AppUsage) -> RGB {
        switch metric {
        case .cpu: return app.cpu >= 4 ? PX.orange : PX.blue
        case .memory: return PX.purple
        case .gpu: return PX.pink
        case .power: return PX.yellow
        case .disk: return app.diskWrite > app.diskRead ? PX.orange : PX.cyan
        }
    }

    var body: some View {
        let top = max(apps.map(value).max() ?? 0, 1e-9)
        let columns = columns
        PXPanel(title: title, caption: "click an app for its processes, and to quit it", width: width) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("App").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns, id: \.title) { column in
                        Text(column.title).frame(width: column.width, alignment: .trailing)
                    }
                }
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .padding(.horizontal, PX.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                PXDivider()
                QuitNoticeLine()
                VStack(spacing: 1) {
                    ForEach(apps) { app in
                        row(app, fraction: value(app) / top, columns: columns)
                    }
                    if apps.isEmpty {
                        Text("Nothing to list right now.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    private func row(_ app: AppUsage, fraction: Double, columns: [Column]) -> some View {
        let isOpen = expanded == app.id
        let barWidth: CGFloat = width > 700 ? 300 : 84
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(nsImage: IconCache.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text(app.name)
                    .font(PX.font(12, .medium))
                    .foregroundStyle(PX.label)
                    .lineLimit(1)
                    .padding(.leading, 9)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(PX.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .padding(.leading, 6)
                Spacer(minLength: 12)
                MiniMatrixBar(fraction: fraction > 0.004 ? max(fraction, 0.02) : 0, rgb: barColor(app))
                    .frame(width: barWidth)
                    .padding(.trailing, 6)
                ForEach(columns, id: \.title) { column in
                    Text(column.app(app))
                        .foregroundStyle(column.strong ? PX.label : (column.title == "Processes" ? PX.tertiary : PX.secondary))
                        .frame(width: column.width, alignment: .trailing)
                }
            }
            .font(PX.font(12))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(isOpen ? PX.rowHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { expanded = isOpen ? nil : app.id }

            if isOpen {
                let children = metric == .cpu ? app.children : app.children.sorted { processValue($0) > processValue($1) }
                VStack(spacing: 0) {
                    if app.processCount == 1, let only = app.children.first {
                        Text(verbatim: "One process, pid \(only.pid)\(only.parentName.map { ", started by \($0)" } ?? "").")
                            .font(PX.font(11.5))
                            .foregroundStyle(PX.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 22)
                    } else {
                        ForEach(children.prefix(8)) { child in
                            HStack(spacing: 0) {
                                Text(child.name)
                                    .font(PX.mono(10.5))
                                    .foregroundStyle(PX.secondary)
                                    .lineLimit(1)
                                Text(verbatim: "pid \(child.pid)")
                                    .font(PX.mono(10))
                                    .foregroundStyle(PX.tertiary)
                                    .padding(.leading, 8)
                                Spacer(minLength: 8)
                                ForEach(columns, id: \.title) { column in
                                    Text(column.process(child)).frame(width: column.width, alignment: .trailing)
                                }
                            }
                            .font(PX.font(11.5))
                            .monospacedDigit()
                            .foregroundStyle(PX.secondary)
                            .frame(height: 22)
                        }
                        if app.processCount > 8 {
                            Text("and \(app.processCount - 8) more")
                                .font(PX.font(11))
                                .foregroundStyle(PX.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 20)
                        }
                    }
                    AppActionRow(app: app)
                        .padding(.top, 3)
                }
                .padding(.leading, 35)
                .padding(.trailing, 10)
                .padding(.bottom, 7)
                .transition(.opacity)
            }
        }
    }

    private func processValue(_ process: ProcessUsage) -> Double {
        switch metric {
        case .cpu: return process.cpu
        case .memory: return Double(process.memory)
        case .gpu: return process.gpu
        case .power: return process.power
        case .disk: return process.diskRead + process.diskWrite
        }
    }
}
