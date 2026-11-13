import AppKit
import SwiftUI

/// The dashboard's menu bar panel: every area's card, compacted into one column.
struct PopoverView: View {
    /// How tall the panel may get on the screen it opens on.
    var maxHeight: CGFloat = 1200
    /// Opens the window, on an area when one is given.
    var openApp: (AppSection?) -> Void
    var openSettings: () -> Void

    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(StorageModel.self) private var storage
    @Environment(Explainer.self) private var explainer
    @Environment(AppSettings.self) private var settings
    @State private var meters = AreaMeters()

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PXDivider()
            if let snapshot = monitor.snapshot {
                ExplainCard(section: .dashboard, width: nil, inset: 18)
                // Seven areas share one column. On a tall screen each shows its two biggest entries; on a
                // shorter one, or with Claude's read open, they fold to number and bar, and then to a
                // shorter bar still.
                let quiet = analysis.turns.isEmpty && explainer.entry(for: AppSection.dashboard.rawValue) == nil
                let legend = quiet && maxHeight >= 1280 ? 2 : 0
                let tight = maxHeight < (snapshot.power.battery == nil ? 1090 : 1215)
                // The areas come in the order the Dashboard's cards were put in, so what matters most is on top
                // here too.
                let order = DashboardOrder.resolve(saved: settings.dashboardOrder, available: DashboardCard.standard(battery: snapshot.power.battery != nil)).filter(\.inPanel)
                ForEach(order) { card in
                    section(card, snapshot: snapshot, legend: legend, tight: tight)
                    PXDivider()
                }
                ClaudeCard(layout: .compact, openSettings: openSettings)
            } else {
                HStack(spacing: 8) {
                    PXSpinner(size: 13)
                    Text("Reading sensors").font(PX.font(12)).foregroundStyle(PX.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
            }
        }
        .frame(width: Self.width)
        .animation(.easeOut(duration: 0.25), value: analysis.turns.isEmpty)
    }

    private var header: some View {
        let severity = monitor.severity
        return HStack(spacing: 10) {
            SeverityDot(color: Theme.color(for: severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(severity.title)
                    .font(PX.font(14, .medium))
                    .tracking(PX.tracking(14))
                    .foregroundStyle(PX.text)
                Text(subtitle)
                    .font(PX.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ExplainButton(section: .dashboard, onCard: true)
                .padding(.trailing, -6)
            PXButton(title: "Open", symbol: "macwindow", style: .ghost, height: 28, action: { openApp(nil) })
            PXButton(title: "", symbol: "gearshape", style: .ghost, height: 28, action: openSettings)
                .padding(.leading, -6)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 58)
        .animation(.easeInOut(duration: 0.3), value: severity)
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        var parts = ["CPU \(Format.percent(s.cpu.total))"]
        if let hottest = s.thermal.hottest { parts.append(Format.temperature(hottest.celsius)) }
        if let watts = s.power.total { parts.append("\(Int(watts.rounded())) W") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func section(_ card: DashboardCard, snapshot: Snapshot, legend: Int, tight: Bool) -> some View {
        switch card {
        case .cpu: MeterSection(model: meters.cpu(snapshot, askClaude: ask), maxItems: legend, tag: tag(.cpu), tight: tight)
        case .gpu: MeterSection(model: meters.gpu(snapshot, askClaude: ask), maxItems: legend, tag: tag(.gpu), tight: tight)
        case .memory: MeterSection(model: meters.memory(snapshot, askClaude: ask), maxItems: legend, tag: tag(.memory), tight: tight)
        case .storage: MeterSection(model: storage.meter, maxItems: 0, tag: tag(.storage), tight: tight)
        case .thermal: MeterSection(model: meters.thermal(snapshot, askClaude: ask), maxItems: legend, tag: tag(.thermal), tight: tight)
        case .network: MeterSection(model: meters.network(snapshot, history: monitor.history, askClaude: ask), maxItems: legend, tag: tag(.network), tight: tight)
        case .power: MeterSection(model: meters.power(snapshot, history: monitor.history, askClaude: ask), maxItems: legend, tag: tag(.power), tight: tight)
        case .battery: MeterSection(model: meters.battery(snapshot, history: monitor.history, askClaude: ask), maxItems: 0, tag: tag(.battery), tight: tight)
        case .throughput, .energyDay, .assistant: EmptyView()
        }
    }

    private func tag(_ section: AppSection) -> MeterTag {
        MeterTag(title: section.title, symbol: section.symbol, rgb: section.rgb) { openApp(section) }
    }

    private func ask() {
        guard let snapshot = monitor.snapshot, !analysis.isStreaming else { return }
        analysis.analyze(snapshot: snapshot, history: monitor.history)
    }
}

/// Hosting view that reports the size its SwiftUI content wants, so the panel can hug it.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSize: ((CGSize) -> Void)?
    private var reported = CGSize.zero

    // fittingSize runs a full Auto Layout pass, so it is only asked for when SwiftUI says its size changed,
    // never from layout() (which runs on every redraw inside the panel).
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    private func report() {
        let size = fittingSize
        guard size.width > 10, size.height > 10 else { return }
        if abs(size.width - reported.width) > 0.5 || abs(size.height - reported.height) > 0.5 {
            reported = size
            onFittingSize?(size)
        }
    }
}
