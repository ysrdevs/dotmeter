import SwiftUI

/// The overview: one reference-size card per area, and Claude.
struct DashboardPage: View {
    var openSettings: () -> Void

    @Environment(SystemMonitor.self) private var monitor
    @Environment(StorageModel.self) private var storage
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @State private var meters = AreaMeters()

    @Environment(AppSettings.self) private var settings
    /// The card being dragged, so the card it passes over knows what to make room for.
    @State private var dragging: DashboardCard?
    @State private var lastMove = Date.distantPast

    var body: some View {
        PageScaffold(title: "Dashboard", subtitle: subtitle, section: .dashboard) { gridWidth, columns in
            if let snapshot = monitor.snapshot {
                let order = DashboardOrder.resolve(saved: settings.dashboardOrder, available: DashboardCard.standard(battery: snapshot.power.battery != nil))
                // Every card can be dragged onto another to take its place, or moved from its right-click menu.
                // The order is the user's: what matters most goes on top, and the menu bar panel follows it.
                CardFlow(columns: columns, gap: PageScaffold<EmptyView>.gap, cardWidth: PX.cardWidth) {
                    ForEach(order) { card in
                        cardView(card, snapshot: snapshot, gridWidth: gridWidth)
                            .layoutValue(key: WideCardKey.self, value: card.isWide)
                            .overlay(alignment: .top) { DragGrip().padding(.top, 5) }
                            .onDrag {
                                dragging = card
                                return NSItemProvider(object: card.rawValue as NSString)
                            } preview: {
                                DragChip(card: card)
                            }
                            .onDrop(of: [.plainText], delegate: CardDrop(card: card, dragging: $dragging) { moved, target in
                                // One move per pass: a wide card changes the rows, and without the pause the
                                // pointer would land on a third card and move things again.
                                guard Date().timeIntervalSince(lastMove) > 0.28 else { return }
                                lastMove = Date()
                                settings.dashboardOrder = DashboardOrder.moving(moved, onto: target, in: order).map(\.rawValue)
                            })
                            .contextMenu { moveMenu(card, order: order) }
                    }
                }
                .animation(.snappy(duration: 0.3), value: order)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: DashboardCard, snapshot: Snapshot, gridWidth: CGFloat) -> some View {
        let ask = { askClaude() }
        switch card {
        case .cpu: MeterCard(model: meters.cpu(snapshot, details: { router.section = .cpu }, control: control, askClaude: ask))
        case .gpu: MeterCard(model: meters.gpu(snapshot, details: { router.section = .gpu }, control: control, askClaude: ask))
        case .memory: MeterCard(model: meters.memory(snapshot, details: { router.section = .memory }, control: control, askClaude: ask))
        case .storage: MeterCard(model: storage.meter)
        case .thermal: MeterCard(model: meters.thermal(snapshot, details: { router.section = .thermal }, askClaude: ask))
        case .power: MeterCard(model: meters.power(snapshot, history: monitor.history, details: { router.section = .power }, control: control, askClaude: ask))
        case .battery: MeterCard(model: meters.battery(snapshot, history: monitor.history, details: { router.section = .battery }, control: control, askClaude: ask))
        case .network: MeterCard(model: meters.network(snapshot, history: monitor.history, details: { router.section = .network }, control: control, askClaude: ask))
        case .throughput: ThroughputPanel(history: monitor.history, snapshot: snapshot, compact: true)
        case .energyDay: EnergyDayPanel(snapshot: snapshot, width: PX.cardWidth)
        case .assistant:
            ClaudeCard(layout: .wide, openSettings: openSettings)
                .frame(width: gridWidth)
                .pxCard()
        }
    }

    @ViewBuilder
    private func moveMenu(_ card: DashboardCard, order: [DashboardCard]) -> some View {
        let index = order.firstIndex(of: card) ?? 0
        Button("Move \(card.title) to the Top") { move(card, .top, order) }.disabled(index == 0)
        Button("Move Up") { move(card, .up, order) }.disabled(index == 0)
        Button("Move Down") { move(card, .down, order) }.disabled(index == order.count - 1)
        Button("Move to the Bottom") { move(card, .bottom, order) }.disabled(index == order.count - 1)
        Divider()
        Button("Put the Cards Back in Their Usual Order") { settings.dashboardOrder = [] }.disabled(settings.dashboardOrder.isEmpty)
    }

    private func move(_ card: DashboardCard, _ step: DashboardOrder.Step, _ order: [DashboardCard]) {
        settings.dashboardOrder = DashboardOrder.moving(card, step, in: order).map(\.rawValue)
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        return "\(monitor.severity.title) · up \(Format.duration(s.system.uptime)) · \(s.system.osVersion.replacingOccurrences(of: "Version ", with: "macOS "))"
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

struct ClaudePage: View {
    var openSettings: () -> Void
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(StorageModel.self) private var storage
    @Environment(AppSettings.self) private var settings

    var body: some View {
        PageScaffold(title: "Ask \(settings.provider.assistant)", subtitle: "Ask anything about this Mac, or run a full check-up") { gridWidth, _ in
            ClaudeCard(layout: .wide, openSettings: openSettings)
                .frame(width: gridWidth)
                .pxCard()
            if let s = monitor.snapshot {
                PXPanel(title: "What \(settings.provider.assistant) is sent", caption: "a snapshot like this, nothing else", width: gridWidth) {
                    VStack(spacing: 0) {
                        PXStatRow(label: "Processor", value: "\(Format.percent(s.cpu.total)) of \(s.cpu.perCore.count) cores", detail: "load \(String(format: "%.1f", s.cpu.loadAverage.first ?? 0))")
                        PXDivider()
                        PXStatRow(label: "Memory", value: "\(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total))", detail: "\(s.memory.pressure.title.lowercased()) pressure")
                        PXDivider()
                        PXStatRow(label: "Thermals", value: s.thermal.hottest.map { Format.temperature($0.celsius) } ?? s.thermal.state.title, detail: s.thermal.fans.isEmpty ? nil : "fans \(Format.rpm(s.thermal.averageRPM)) rpm")
                        PXDivider()
                        PXStatRow(label: "Top apps and processes", value: "\(min(s.apps.count, 12)) apps, \(min(s.processes.count, 15)) processes", detail: "names, CPU and memory only")
                        PXDivider()
                        PXStatRow(label: "Network", value: s.network.primaryInterface.map { "\($0.title), \(Format.rate(s.network.total))" } ?? "Offline", detail: "link type and rates, never addresses or names")
                        PXDivider()
                        PXStatRow(label: "Storage", value: storage.claudeSummary == nil ? "Not scanned" : "9 categories", detail: storage.claudeSummary == nil ? "scan the disk to ask storage questions" : "sizes and the largest items in each")
                        PXDivider()
                        PXStatRow(label: "Recent trend", value: "\(monitor.history.count) samples", detail: "average and peak CPU, average temperature")
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

// MARK: - Moving cards

/// Marks a card that takes the whole width of the page.
struct WideCardKey: LayoutValueKey {
    static let defaultValue = false
}

/// The Dashboard's grid: one-column cards side by side, a wide card on a row of its own, in the order given.
/// A layout of its own, not rows of stacks, so that a card keeps its identity when the order changes and
/// slides to its new place.
struct CardFlow: Layout {
    var columns: Int
    var gap: CGFloat
    var cardWidth: CGFloat

    private var fullWidth: CGFloat { CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap }

    /// Rows of subview indices, by the same rule as `DashboardOrder.rows`.
    private func rows(_ subviews: Subviews) -> [[Int]] {
        guard columns > 1 else { return subviews.indices.map { [$0] } }
        var rows: [[Int]] = [], pending: [Int] = [], waiting: [Int] = []
        for index in subviews.indices {
            if subviews[index][WideCardKey.self] {
                if pending.isEmpty { rows.append([index]) } else { waiting.append(index) }
            } else {
                pending.append(index)
                if pending.count == columns {
                    rows.append(pending)
                    pending = []
                    rows.append(contentsOf: waiting.map { [$0] })
                    waiting = []
                }
            }
        }
        if !pending.isEmpty { rows.append(pending) }
        rows.append(contentsOf: waiting.map { [$0] })
        return rows
    }

    private func height(of row: [Int], _ subviews: Subviews) -> CGFloat {
        row.map { index in
            let wide = subviews[index][WideCardKey.self]
            return subviews[index].sizeThatFits(ProposedViewSize(width: wide ? fullWidth : cardWidth, height: nil)).height
        }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let all = rows(subviews)
        let total = all.reduce(0) { $0 + height(of: $1, subviews) } + CGFloat(max(all.count - 1, 0)) * gap
        return CGSize(width: fullWidth, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews) {
            let rowHeight = height(of: row, subviews)
            for (column, index) in row.enumerated() {
                let wide = subviews[index][WideCardKey.self]
                let width = wide ? fullWidth : cardWidth
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cardWidth + gap), y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            }
            y += rowHeight + gap
        }
    }
}

/// Makes room as a dragged card passes over this one.
struct CardDrop: DropDelegate {
    let card: DashboardCard
    @Binding var dragging: DashboardCard?
    let move: (_ moved: DashboardCard, _ onto: DashboardCard) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != card else { return }
        move(dragging, card)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Six small dots at the top of a card, shown while the pointer is over it: this can be picked up.
struct DragGrip: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 0.6).fill(PX.secondary).frame(width: 2.4, height: 2.4)
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(hovering ? 0.9 : 0.22)
        .onHover { hovering = $0 }
        .help("Drag the card to move it, or right-click for more")
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// What follows the pointer while a card is dragged: its name, not a picture of the whole card.
struct DragChip: View {
    var card: DashboardCard

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 11, weight: .semibold))
            Text(card.title)
                .font(PX.font(12.5, .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0x2A2C30)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
    }
}
