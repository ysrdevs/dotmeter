import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, cpu, gpu, memory, storage, thermal, network, usb, power, battery, timeline, startup, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
        case .power: return "Power"
        case .battery: return "Battery"
        case .timeline: return "Timeline"
        case .startup: return "Login Items"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .thermal: return "Thermals"
        case .network: return "Network"
        case .usb: return "USB"
        case .claude: return "Ask \(AIProvider.current.assistant)"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .cpu: return "cpu.fill"
        case .gpu: return "square.stack.3d.up.fill"
        case .power: return "bolt.fill"
        case .battery: return "battery.75percent"
        case .timeline: return "calendar.day.timeline.left"
        case .startup: return "power"
        case .memory: return "memorychip.fill"
        case .storage: return "internaldrive.fill"
        case .thermal: return "thermometer.medium"
        case .network: return "network"
        case .usb: return "cable.connector"
        case .claude: return "sparkles"
        }
    }

    var rgb: RGB {
        switch self {
        case .dashboard: return PX.gray
        case .cpu: return PX.blue
        case .gpu: return PX.pink
        case .power: return PX.yellow
        case .battery: return PX.greenRGB
        case .timeline: return PX.cyan
        case .startup: return PX.gray
        case .memory: return PX.purple
        case .storage: return PX.orange
        case .thermal: return PX.red
        case .network: return PX.cyan
        case .usb: return PX.lime
        case .claude: return AIProvider.current == .anthropic ? RGB(0xD97757) : RGB(0x19C37D)
        }
    }

    /// Areas that read live figures and can explain themselves; the last group in the sidebar looks back instead.
    var isLive: Bool { self != .timeline && self != .startup && self != .claude }
}

@MainActor
@Observable
final class AppRouter {
    var section: AppSection = AppSection(rawValue: ProcessInfo.processInfo.environment["DOTMETER_SECTION"] ?? "") ?? .dashboard
}

/// The window: a sidebar of areas on the left, the selected area on the right.
struct MainView: View {
    var openSettings: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var scheme

    static let sidebarWidth: CGFloat = 208

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(openSettings: openSettings)
            Group {
                switch router.section {
                case .dashboard: DashboardPage(openSettings: openSettings)
                case .cpu: CPUPage()
                case .gpu: GraphicsPage()
                case .power: PowerPage()
                case .battery: BatteryPage()
                case .timeline: TimelinePage()
                case .startup: StartupPage()
                case .memory: MemoryPage()
                case .storage: StoragePage()
                case .thermal: ThermalPage()
                case .network: NetworkPage()
                case .usb: USBPage()
                case .claude: ClaudePage(openSettings: openSettings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background((scheme == .dark ? Color(hex: 0x0B0C0D) : Color.white).ignoresSafeArea())
        }
        .frame(minWidth: Self.sidebarWidth + PX.cardWidth + 48, minHeight: 480)
    }
}

struct Sidebar: View {
    var openSettings: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(SystemMonitor.self) private var monitor
    @Environment(StorageModel.self) private var storage
    @Environment(AnalysisSession.self) private var analysis
    @Environment(TimelineStore.self) private var timeline

    /// Live areas, then the two that look back or around, then Claude.
    private static let groups: [[AppSection]] = [
        [.dashboard, .cpu, .gpu, .memory, .storage, .thermal, .network, .usb, .power] + (Hardware.hasBattery ? [.battery] : []),
        [.timeline, .startup],
        [.claude],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 9).padding(.vertical, 7)
                }
                ForEach(group) { section in
                    SidebarItem(section: section, value: value(for: section), selected: router.section == section) {
                        router.section = section
                    }
                }
            }
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(width: MainView.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0x141517).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 0.5).ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }

    private func value(for section: AppSection) -> String {
        guard let s = monitor.snapshot else { return "" }
        switch section {
        case .dashboard: return ""
        case .cpu: return Format.percent(s.cpu.total)
        case .gpu: return s.gpu.map { Format.percent($0.utilization) } ?? ""
        case .power: return s.power.total.map { $0 < 99.5 ? String(format: "%.0f W", $0) : "\(Int($0.rounded())) W" } ?? ""
        case .battery: return s.power.battery.map { Format.percent($0.charge) } ?? ""
        case .timeline:
            let today = Calendar.current.startOfDay(for: Date())
            let count = timeline.events.filter { $0.start >= today }.count
            return count == 0 ? "" : "\(count) today"
        case .startup: return ""
        case .memory: return Format.bytes(s.memory.used)
        case .storage: return StorageModel.gb(storage.usedBytes)
        case .thermal: return s.thermal.hottest.map { Format.temperature($0.celsius) } ?? s.thermal.state.title
        case .network: return s.network.online ? Format.shortRate(s.network.total) : "Offline"
        case .usb: return s.usb.map { "\($0.connectedPorts.count) of \($0.ports.count)" } ?? ""
        case .claude: return analysis.isStreaming ? "…" : (analysis.turns.first?.report?.status?.title ?? "")
        }
    }

    private var footer: some View {
        let severity = monitor.severity
        return VStack(alignment: .leading, spacing: 9) {
            PXDivider().padding(.horizontal, -10)
            HStack(spacing: 8) {
                SeverityDot(color: Theme.color(for: severity))
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(severity.title)
                        .font(PX.font(12.5, .medium))
                        .foregroundStyle(PX.text)
                    if let system = monitor.snapshot?.system {
                        Text("\(system.modelName) · \(system.chip.replacingOccurrences(of: "Apple ", with: ""))")
                            .font(PX.font(11))
                            .foregroundStyle(PX.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                PXButton(title: "", symbol: "gearshape", style: .ghost, height: 26, action: openSettings)
                    .help("Settings")
                    .padding(.trailing, -4)
            }
            .padding(.leading, 6)
            .padding(.top, 3)
        }
    }
}

struct SidebarItem: View {
    var section: AppSection
    var value: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? section.rgb.color() : PX.secondary)
                    .frame(width: 18)
                Text(section.title)
                    .font(PX.font(13, selected ? .medium : .regular))
                    .tracking(PX.tracking(13))
                    .foregroundStyle(selected ? PX.text : PX.label.opacity(hovering ? 1 : 0.82))
                Spacer(minLength: 6)
                Text(value)
                    .font(PX.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(selected ? PX.secondary : PX.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 7.5, style: .continuous).fill(selected ? PX.rowHover : (hovering ? PX.ghostHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// Shared page chrome: title, subtitle, and a grid that is one or two reference cards wide.
struct PageScaffold<Content: View>: View {
    var title: String
    var subtitle: String
    /// The area this page shows: it gets Explain, and a menu bar toggle when it can have its own item.
    var section: AppSection?
    /// What only this page knows, handed to Claude along with the question.
    var explainExtra: () -> String? = { nil }
    @ViewBuilder var content: (_ gridWidth: CGFloat, _ columns: Int) -> Content

    static var gap: CGFloat { 20 }

    var body: some View {
        GeometryReader { geo in
            let gap = Self.gap
            let columns = max(1, min(2, Int((geo.size.width - 48 + gap) / (PX.cardWidth + gap))))
            let gridWidth = CGFloat(columns) * PX.cardWidth + CGFloat(columns - 1) * gap
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: gap) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(PX.font(20, .semibold))
                                .tracking(-0.4)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(PX.font(12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let section, section != .claude {
                            ExplainButton(section: section, extra: explainExtra)
                            if AppSettings.menuBarSections.contains(section) {
                                MenuBarToggle(section: section).padding(.leading, -4)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    if let section { ExplainCard(section: section, width: gridWidth, extra: explainExtra) }
                    content(gridWidth, columns)
                }
                .frame(width: gridWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 34)
                .offset(y: -PX.debugScroll)
            }
            // A card can ask to be brought into view (an app dropped on the page lands in a list at the bottom).
            .onChange(of: PageScroll.shared.request) { _, request in
                guard let request else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(request.id, anchor: .center) }
            }
            }
        }
    }
}

/// Lets a card ask the page it sits on to scroll to it.
@MainActor
@Observable
final class PageScroll {
    static let shared = PageScroll()

    struct Request: Equatable {
        var id: String
        var serial: Int
    }

    private(set) var request: Request?

    func go(to id: String) {
        request = Request(id: id, serial: (request?.serial ?? 0) + 1)
    }
}

/// Puts an area in the menu bar, or takes it out again, from the top of its page.
struct MenuBarToggle: View {
    var section: AppSection
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        let shown = settings.isInMenuBar(section)
        let locked = shown && !settings.canRemoveFromMenuBar(section)
        Button {
            settings.setInMenuBar(section, !shown)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: shown ? "checkmark" : "plus")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(shown ? section.rgb.mixed(with: RGB(0x808080), 0.15).color() : Color.secondary)
                Text(shown ? "In menu bar" : "Add to menu bar")
                    .font(PX.font(12, .medium))
                    .foregroundStyle(Color.primary.opacity(shown ? 0.85 : 0.7))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering && !locked ? 0.11 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PXPressStyle())
        .disabled(locked)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.18), value: shown)
        .help(locked ? "This is the only item in the menu bar, so it stays." : (shown ? "Remove \(section.title) from the menu bar" : "Show \(section.title) in the menu bar, with its own panel"))
    }
}

/// Two half-width cards side by side, or stacked when the window is one card wide.
struct PagePair<First: View, Second: View>: View {
    var columns: Int
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    var body: some View {
        if columns >= 2 {
            HStack(alignment: .top, spacing: PageScaffold<EmptyView>.gap) {
                first
                second
            }
        } else {
            VStack(alignment: .leading, spacing: PageScaffold<EmptyView>.gap) {
                first
                second
            }
        }
    }
}

struct LoadingCard: View {
    var width: CGFloat
    var body: some View {
        HStack(spacing: 8) {
            PXSpinner(size: 13)
            Text("Reading sensors").font(PX.font(12)).foregroundStyle(PX.secondary)
        }
        .frame(width: width, height: 120)
        .pxCard()
    }
}
