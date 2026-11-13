import SwiftUI

struct MemoryPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @State private var meters = AreaMeters()
    @State private var expanded: String?

    var body: some View {
        PageScaffold(title: "Memory", subtitle: subtitle, section: .memory) { gridWidth, columns in
            if let s = monitor.snapshot {
                MeterCard(model: meters.memory(s, count: columns * 9 - 3, control: control, askClaude: askClaude), width: gridWidth, selected: expanded) { id in
                    expanded = expanded == id ? nil : id
                }
                PagePair(columns: columns) {
                    MeterCard(model: meters.memoryComposition(s))
                } second: {
                    MemoryHistoryPanel(history: monitor.history, snapshot: s)
                }
                AppTablePanel(title: "Apps by memory", apps: Array(s.apps.sorted { $0.memory > $1.memory }.prefix(18)), metric: .memory, width: gridWidth, expanded: $expanded)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        return "\(Format.bytes(s.memory.total)) installed · \(s.memory.pressure.title.lowercased()) pressure"
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

struct MemoryHistoryPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let used = recent.map(\.memory)
        let total = Double(max(snapshot.memory.total, 1))
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func size(_ fraction: Double) -> String { Format.bytes(UInt64(fraction * total)) }
        let swapPeak = recent.map(\.swap).max() ?? 0
        return PXPanel(title: "Last five minutes", caption: "\(recent.count) readings", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Memory used", now: size(snapshot.memory.usedFraction), average: size(avg(used)), peak: size(used.max() ?? 0))
                    .padding(.top, 14)
                MatrixChart(samples: recent.map { .init(time: $0.time, value: $0.memory) }, rgb: PX.purple, rows: 30)
                    .padding(.top, 8)
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                Spacer(minLength: 12)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Swap", value: Detail.swap(snapshot.memory), detail: Detail.memoryActivity(snapshot.memory.activity) ?? (swapPeak > 0 ? "peak \(Format.bytes(UInt64(swapPeak)))" : "nothing pushed to disk"))
                    PXStatRow(label: "Cached files", value: Format.bytes(snapshot.memory.cached), detail: "paging \(Detail.paging(snapshot.memory.activity))")
                    PXStatRow(label: "Pressure", value: snapshot.memory.pressure.title, detail: Detail.temperature(of: "Memory", in: snapshot.thermal).map { "memory at \(Format.temperature($0))" } ?? "what macOS itself reports")
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}
