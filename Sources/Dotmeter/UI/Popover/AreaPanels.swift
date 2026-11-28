import AppKit
import SwiftUI

/// What a menu bar item opens: the dashboard's overview, or one area in more detail.
struct PanelRootView: View {
    var section: AppSection
    var maxHeight: CGFloat
    var openApp: (AppSection?) -> Void
    var openSettings: () -> Void

    var body: some View {
        switch section {
        case .dashboard, .claude, .timeline, .startup, .models, .macs:
            PopoverView(maxHeight: maxHeight, openApp: openApp, openSettings: openSettings)
        default:
            AreaPanelView(section: section, openApp: { openApp(section) }, openSettings: openSettings)
        }
    }
}

/// One area's own menu bar panel: its meter with a fuller legend, the detail that area is about,
/// five minutes of history and the figures that explain it.
struct AreaPanelView: View {
    var section: AppSection
    var openApp: () -> Void
    var openSettings: () -> Void

    @Environment(SystemMonitor.self) private var monitor
    @Environment(StorageModel.self) private var storage
    @Environment(AnalysisSession.self) private var analysis
    @Environment(TimelineStore.self) private var timeline
    @Environment(AppSettings.self) private var settings
    @State private var meters = AreaMeters()
    @State private var hoveredKind: String?

    static let width: CGFloat = PopoverView.width
    private static let inset: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PXDivider()
            ExplainCard(section: section, width: nil, inset: Self.inset)
            if let snapshot = monitor.snapshot {
                switch section {
                case .cpu: processor(snapshot)
                case .gpu: graphics(snapshot)
                case .memory: memory(snapshot)
                case .storage: disk(snapshot)
                case .thermal: thermal(snapshot)
                case .network: network(snapshot)
                case .power: power(snapshot)
                case .battery: battery(snapshot)
                case .usb: ports(snapshot)
                case .dashboard, .claude, .timeline, .startup, .models, .macs: EmptyView()
                }
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
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8.5, style: .continuous).fill(section.rgb.color(0.15))
                RoundedRectangle(cornerRadius: 8.5, style: .continuous).strokeBorder(section.rgb.color(0.22), lineWidth: 0.5)
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(section.rgb.color())
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
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
            ExplainButton(section: section, onCard: true)
                .padding(.trailing, -6)
            PXButton(title: "Open", symbol: "macwindow", style: .ghost, height: 28, action: openApp)
                .help("Open \(section.title) in the \(App.name) window")
            PXButton(title: "", symbol: "gearshape", style: .ghost, height: 28, action: openSettings)
                .padding(.leading, -6)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 58)
    }

    private var subtitle: String {
        guard let s = monitor.snapshot else { return "Reading sensors" }
        switch section {
        case .cpu:
            return "\(s.system.chip.replacingOccurrences(of: "Apple ", with: "")) · \(s.cpu.performanceCores)P + \(s.cpu.efficiencyCores)E cores"
        case .memory:
            return "\(Format.bytes(s.memory.total)) installed · \(s.memory.pressure.title.lowercased()) pressure"
        case .storage:
            let name = storage.volume.name.isEmpty ? "Startup disk" : storage.volume.name
            return storage.volume.format.isEmpty ? name : "\(name) · \(storage.volume.format)"
        case .thermal:
            return "\(s.thermal.sensors.count) sensors · \(s.thermal.fans.count) \(s.thermal.fans.count == 1 ? "fan" : "fans") · \(s.thermal.state.title.lowercased())"
        case .network:
            guard let primary = s.network.primaryInterface else { return "Offline" }
            return ([primary.title] + [primary.address].compactMap { $0 }).joined(separator: " · ")
        case .gpu:
            return ([(s.gpu?.model ?? "Graphics").replacingOccurrences(of: "Apple ", with: "")] + [s.gpu?.cores].compactMap { $0.map { "\($0) cores" } }).joined(separator: " · ")
        case .power:
            guard let battery = s.power.battery else { return "On mains power" }
            return battery.isPluggedIn ? "Plugged in · battery \(Format.percent(battery.charge))" : "On battery · \(Format.percent(battery.charge))"
        case .battery:
            guard let battery = s.power.battery else { return "This Mac has none" }
            return ([battery.state] + [battery.health].compactMap { $0.map { "health \(Format.percent($0))" } }).joined(separator: " · ")
        case .usb:
            guard let usb = s.usb else { return "Reading the ports" }
            let overview = USBOverview.of(usb)
            let devices = overview.deviceCount
            return "\(overview.connected.count) of \(overview.ports.count) in use" + (devices > 0 ? " · \(devices) \(devices == 1 ? "device" : "devices")" : "")
        case .dashboard, .claude, .timeline, .startup, .models, .macs:
            return ""
        }
    }

    private func block<Content: View>(_ title: String, _ caption: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title)
                    .font(PX.font(12, .medium))
                    .foregroundStyle(PX.text)
                if let caption {
                    Text(caption)
                        .font(PX.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 13)
        .padding(.bottom, 14)
    }

    private func rows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 6)
    }

    private func ask() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        openApp()
    }

    private func recent(_ s: Snapshot) -> [HistoryPoint] {
        monitor.history.filter { s.timestamp.timeIntervalSince($0.time) <= 300 }
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func degrees(_ value: Double?) -> String {
        value.map { Format.temperature($0) } ?? "—"
    }

    // MARK: Processor

    @ViewBuilder
    private func processor(_ s: Snapshot) -> some View {
        let points = recent(s)
        let load = points.map(\.cpu)
        let busy = s.cpu.perCore.filter { $0 > 0.5 }.count
        MeterSection(model: meters.cpu(s, count: 6, askClaude: ask), maxItems: 6)
        PXDivider()
        block("Cores", busy == 0 ? "all below half load" : "\(busy) above half load") {
            CompactCores(cpu: s.cpu)
                .padding(.top, 11)
        }
        PXDivider()
        block("Last five minutes") {
            ChartHeader(name: "Load", now: Format.percent(s.cpu.total), average: Format.percent(average(load)), peak: Format.percent(load.max() ?? 0))
                .padding(.top, 9)
            MatrixChart(samples: points.map { .init(time: $0.time, value: $0.cpu) }, rgb: PX.blue, rows: 12)
                .padding(.top, 7)
        }
        PXDivider()
        rows {
            PXStatRow(label: "User", value: Format.percent(s.cpu.user), detail: "your apps")
            PXStatRow(label: "System", value: Format.percent(s.cpu.system), detail: "macOS on their behalf")
            PXStatRow(label: "Load average", value: s.cpu.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: "   "), detail: "1, 5, 15 min")
            if let clusters = Detail.clusters(s.cpu) {
                PXStatRow(label: "By kind of core", value: clusters, detail: "performance, efficiency")
            }
            PXStatRow(label: "Running", value: Detail.count(s.processes.count, "processes"), detail: "up \(Format.duration(s.system.uptime))")
        }
    }

    // MARK: Graphics

    private func gauge(_ name: String, _ fraction: Double, _ rgb: RGB, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(PX.font(11.5))
                .foregroundStyle(PX.label)
                .frame(width: 104, alignment: .leading)
            MiniMatrixBar(fraction: fraction > 0.004 ? max(fraction, 0.012) : 0, rgb: rgb, rows: 3)
            Text(text)
                .font(PX.font(11.5))
                .monospacedDigit()
                .foregroundStyle(PX.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func graphics(_ s: Snapshot) -> some View {
        let points = recent(s)
        let load = points.map(\.gpu)
        let used = Double(s.gpu?.memoryInUse ?? 0), reserved = Double(s.gpu?.memoryAllocated ?? 0)
        MeterSection(model: meters.gpu(s, count: 6, askClaude: ask), maxItems: 6)
        PXDivider()
        block("Cores", s.gpu?.cores.map { "\($0) of them" }) {
            VStack(spacing: 9) {
                gauge("Overall", s.gpu?.utilization ?? 0, PX.pink, Format.percent(s.gpu?.utilization ?? 0))
                gauge("Renderer", s.gpu?.rendererUtilization ?? 0, PX.purple, Format.percent(s.gpu?.rendererUtilization ?? 0))
                gauge("Tiler", s.gpu?.tilerUtilization ?? 0, PX.blue, Format.percent(s.gpu?.tilerUtilization ?? 0))
                gauge("Memory in use", reserved > 0 ? used / reserved : 0, PX.cyan, Format.bytes(UInt64(used)))
            }
            .padding(.top, 11)
        }
        PXDivider()
        block("Last five minutes") {
            ChartHeader(name: "Load", now: Format.percent(s.gpu?.utilization ?? 0), average: Format.percent(average(load)), peak: Format.percent(load.max() ?? 0))
                .padding(.top, 9)
            MatrixChart(samples: points.map { .init(time: $0.time, value: $0.gpu) }, rgb: PX.pink, rows: 12)
                .padding(.top, 7)
        }
        PXDivider()
        rows {
            PXStatRow(label: "Drawing", value: s.power.gpu.map { AppTablePanel.watts($0) } ?? "Not reported")
            PXStatRow(label: "Hottest sensor", value: degrees(s.thermal.gpuTemperature))
        }
    }

    // MARK: Power

    @ViewBuilder
    private func power(_ s: Snapshot) -> some View {
        let points = recent(s)
        let watts = points.compactMap(\.power)
        let top = AreaMeters.wattCeiling(watts.max() ?? 0)
        let p = s.power
        let total = max(p.total ?? 0, 0.001)
        let apps = s.apps.reduce(0) { $0 + $1.power }
        let processor = p.cpu ?? min(apps, max(0, total - (p.gpu ?? 0)))
        MeterSection(model: meters.power(s, history: monitor.history, count: 5, askClaude: ask), maxItems: 6)
        PXDivider()
        block("Where it goes", p.total.map { "of \(AppTablePanel.watts($0))" }) {
            VStack(spacing: 9) {
                gauge(p.cpu == nil ? "Processor work" : "Processor", processor / total, PX.blue, AppTablePanel.watts(processor))
                gauge("Graphics cores", (p.gpu ?? 0) / total, PX.pink, p.gpu.map { AppTablePanel.watts($0) } ?? "—")
                if p.system != nil {
                    let rest = max(0, total - processor - (p.gpu ?? 0) - (p.neural ?? 0) - (p.memory ?? 0))
                    gauge("Everything else", rest / total, PX.gray, AppTablePanel.watts(rest))
                }
            }
            .padding(.top, 11)
        }
        PXDivider()
        block("Last five minutes", "to \(Int(top)) W") {
            ChartHeader(name: "Whole Mac", now: p.total.map { AppTablePanel.watts($0) } ?? "—", average: watts.isEmpty ? "—" : AppTablePanel.watts(average(watts)), peak: watts.max().map { AppTablePanel.watts($0) } ?? "—")
                .padding(.top, 9)
            MatrixChart(samples: points.compactMap { point in point.power.map { .init(time: point.time, value: $0 / top) } }, rgb: PX.yellow, rows: 12)
                .padding(.top, 7)
        }
        PXDivider()
        rows {
            if let battery = p.battery {
                PXStatRow(label: "Battery", value: Format.percent(battery.charge), detail: battery.minutesRemaining.map { "\(Format.duration(Double($0) * 60)) \(battery.isCharging ? "to full" : "left")" })
                PXStatRow(label: "Health", value: battery.health.map { Format.percent($0) } ?? "—", detail: battery.cycles.map { "\($0) cycles" })
            }
            let today = timeline.energyWh(since: Calendar.current.startOfDay(for: Date()))
            let chosen = timeline.energy(settings.energyPeriod).wattHours
            PXStatRow(label: "Today", value: PowerPage.energy(today), detail: settings.energyPrice > 0 ? Format.dollars(today / 1000 * settings.energyPrice) : "while \(App.name) ran")
            if settings.energyPeriod != .today {
                PXStatRow(label: settings.energyPeriod.title, value: PowerPage.energy(chosen), detail: settings.energyPrice > 0 ? Format.dollars(chosen / 1000 * settings.energyPrice) : nil)
            }
            PXStatRow(label: "This session", value: PowerPage.energy(p.energyWh))
        }
    }

    // MARK: Battery

    @ViewBuilder
    private func battery(_ s: Snapshot) -> some View {
        if let b = s.power.battery {
            let now = Date()
            let from = Int(now.timeIntervalSince1970 / 60) - 1440
            let day = timeline.minutes.filter { $0.t >= from && $0.battery != nil }
            let levels = day.compactMap { $0.battery.map { Double($0) } }
            MeterSection(model: meters.battery(s, history: monitor.history, askClaude: ask), maxItems: 8)
            PXDivider()
            block("Last 24 hours", day.isEmpty ? "fills in as \(App.name) runs" : nil) {
                ChartHeader(name: "Charge", now: Format.percent(b.charge), average: levels.isEmpty ? "—" : Format.percent(average(levels)), peak: levels.isEmpty ? "—" : Format.percent(levels.max() ?? 0))
                    .padding(.top, 9)
                MatrixChart(samples: day.compactMap { m in m.battery.map { .init(time: m.date, value: Double($0)) } }, rgb: PX.greenRGB, rows: 14, span: 86_400, tone: { BatteryLook.color($0) }, anchor: now)
                    .padding(.top, 7)
            }
            PXDivider()
            rows {
                PXStatRow(label: b.isCharging ? "Full in" : "Time left", value: b.isPluggedIn && !b.isCharging ? "On mains" : BatteryLook.time(b.minutesRemaining), detail: b.state)
                PXStatRow(label: "Holds when full", value: b.fullCapacity.map { "\(Format.count(UInt64($0))) mAh" } ?? "—", detail: b.designCapacity.map { "\(Format.count(UInt64($0))) new" })
                PXStatRow(label: "The whole Mac is drawing", value: s.power.total.map { AppTablePanel.watts($0) } ?? "—")
            }
        } else {
            Text("This Mac has no battery.")
                .font(PX.font(12))
                .foregroundStyle(PX.secondary)
                .padding(Self.inset)
        }
    }

    // MARK: Memory

    @ViewBuilder
    private func memory(_ s: Snapshot) -> some View {
        let points = recent(s)
        let used = points.map(\.memory)
        let total = Double(max(s.memory.total, 1))
        // Apps only up here; wired and compressed memory are in the breakdown underneath.
        MeterSection(model: meters.memory(s, count: 5, askClaude: ask), maxItems: 6)
        PXDivider()
        block("What kind", "\(s.memory.pressure.title.lowercased()) pressure") {
            MeterLegend(items: meters.memoryComposition(s).items, hovered: $hoveredKind, columns: 2, rowHeight: 24, columnGap: 4, rowGap: 1, size: 11.5)
                .padding(.top, 7)
                .padding(.horizontal, -8)
                .padding(.bottom, -5)
        }
        PXDivider()
        block("Last five minutes") {
            ChartHeader(name: "Used", now: Format.bytes(s.memory.used), average: Format.bytes(UInt64(average(used) * total)), peak: Format.bytes(UInt64((used.max() ?? 0) * total)))
                .padding(.top, 9)
            MatrixChart(samples: points.map { .init(time: $0.time, value: $0.memory) }, rgb: PX.purple, rows: 12)
                .padding(.top, 7)
        }
        PXDivider()
        rows {
            PXStatRow(label: "Swap", value: Detail.swap(s.memory), detail: Detail.memoryActivity(s.memory.activity) ?? (s.memory.swapUsed > 0 ? "at rest" : "nothing pushed to disk"))
            PXStatRow(label: "Paging", value: Detail.paging(s.memory.activity), detail: "files read in, written back")
            if let heat = Detail.temperature(of: "Memory", in: s.thermal) {
                PXStatRow(label: "Memory temperature", value: Format.temperature(heat))
            }
        }
    }

    // MARK: Storage

    @ViewBuilder
    private func disk(_ s: Snapshot) -> some View {
        let model = storage.meter
        let volume = storage.volume
        MeterSection(model: model, maxItems: 10)
        PXDivider()
        // The card's own footer: scan, or the one suggestion it has. Deleting still takes two clicks.
        MeterFooterView(footer: model.footer, size: 11.5, leading: Self.inset, trailing: 12)
            .frame(height: 52)
        PXDivider()
        rows {
            PXStatRow(label: "Capacity", value: StorageModel.gb(volume.capacity))
            PXStatRow(label: "Free now", value: StorageModel.gb(volume.free))
            PXStatRow(label: "Reclaimable by macOS", value: StorageModel.gb(volume.purgeable), detail: "snapshots, caches")
            PXStatRow(label: "Reading and writing", value: "\(Format.rate(s.disk.readBytesPerSecond)) · \(Format.rate(s.disk.writeBytesPerSecond))", detail: "right now")
            PXStatRow(label: "Requests", value: Detail.requests(s.disk), detail: Detail.requestTime(s.disk))
            PXStatRow(label: "Since startup", value: "\(Format.data(s.disk.bytesRead)) read · \(Format.data(s.disk.bytesWritten)) written", detail: Detail.diskErrors(s.disk))
            if let heat = Detail.temperature(of: "Storage", in: s.thermal) {
                PXStatRow(label: "Drive temperature", value: Format.temperature(heat))
            }
        }
    }

    // MARK: Thermals

    @ViewBuilder
    private func thermal(_ s: Snapshot) -> some View {
        let points = recent(s)
        let temperatures = points.compactMap(\.cpuTemperature)
        MeterSection(model: meters.thermal(s, askClaude: ask), maxItems: 6)
        if !s.thermal.fans.isEmpty {
            PXDivider()
            block("Fans", "\(Format.percent(s.thermal.averageFanPercent)) of their range") {
                VStack(spacing: 9) {
                    ForEach(s.thermal.fans) { fan in
                        HStack(spacing: 10) {
                            Text(s.thermal.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan")
                                .font(PX.font(11.5))
                                .foregroundStyle(PX.label)
                                .frame(width: 40, alignment: .leading)
                            MiniMatrixBar(fraction: max(fan.percent, 0.012), rgb: fan.percent >= 0.75 ? PX.orange : PX.cyan, rows: 3)
                            Text("\(Format.rpm(fan.rpm)) rpm")
                                .font(PX.font(11.5))
                                .monospacedDigit()
                                .foregroundStyle(PX.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 11)
            }
        }
        PXDivider()
        block("Last five minutes", "30° to 108°") {
            ChartHeader(name: "CPU", now: degrees(s.thermal.cpuTemperature), average: degrees(temperatures.isEmpty ? nil : average(temperatures)), peak: degrees(temperatures.max()))
                .padding(.top, 9)
            MatrixChart(samples: points.compactMap { p in p.cpuTemperature.map { .init(time: p.time, value: ($0 - 30) / 78) } }, rgb: PX.blue, rows: 12, tone: { heatColor($0 * 78 + 30) })
                .padding(.top, 7)
        }
        PXDivider()
        rows {
            PXStatRow(label: "macOS thermal state", value: s.thermal.state.title)
            PXStatRow(label: "CPU speed limit", value: s.thermal.cpuSpeedLimit.map { "\($0)%" } ?? "None", detail: s.thermal.isThrottled ? "throttling" : "full speed")
            let day = timeline.today()
            PXStatRow(label: "Today", value: Detail.hotToday(day), detail: day.hottest.map { "peak \(Format.temperature($0))" })
        }
    }

    // MARK: USB

    @ViewBuilder
    private func ports(_ s: Snapshot) -> some View {
        if let usb = s.usb {
            let overview = USBOverview.of(usb)
            if overview.connected.isEmpty {
                Text(overview.ports.isEmpty ? "This Mac does not publish its ports the way \(App.name) reads them." : "Nothing is plugged in.")
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.secondary)
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(overview.connected) { port in
                        USBPanelRow(port: port, action: openApp)
                    }
                }
                .padding(.horizontal, Self.inset - 8)
                .padding(.vertical, 8)
            }
            if !overview.empty.isEmpty, !overview.ports.isEmpty {
                PXDivider()
                rows {
                    PXStatRow(label: "Empty", value: Self.list(overview.empty.map(\.title)))
                    if let charger = usb.charger?.name ?? usb.ports.compactMap({ $0.powerSource?.name }).first {
                        PXStatRow(label: "Charger", value: charger)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                PXSpinner(size: 13)
                Text("Reading the ports").font(PX.font(12)).foregroundStyle(PX.secondary)
            }
            .padding(Self.inset)
        }
    }

    /// "USB-C 1, 4 and 5 · HDMI": ports of one kind share the name.
    private static func list(_ titles: [String]) -> String {
        var groups: [(name: String, numbers: [String])] = []
        for title in titles {
            let parts = title.split(separator: " ")
            let numbered = parts.count > 1 && Int(parts.last ?? "") != nil
            let name = numbered ? parts.dropLast().joined(separator: " ") : title
            if let index = groups.firstIndex(where: { $0.name == name }) {
                if numbered { groups[index].numbers.append(String(parts.last ?? "")) }
            } else {
                groups.append((name, numbered ? [String(parts.last ?? "")] : []))
            }
        }
        return groups.map { group in
            switch group.numbers.count {
            case 0: return group.name
            case 1: return "\(group.name) \(group.numbers[0])"
            default: return "\(group.name) \(group.numbers.dropLast().joined(separator: ", ")) and \(group.numbers.last ?? "")"
            }
        }.joined(separator: " · ")
    }

    // MARK: Network

    @ViewBuilder
    private func network(_ s: Snapshot) -> some View {
        let points = recent(s)
        let down = points.map(\.networkIn), up = points.map(\.networkOut)
        let downTop = NetScale.ceiling(down.max() ?? 0), upTop = NetScale.ceiling(up.max() ?? 0)
        let n = s.network
        let primary = n.primaryInterface
        MeterSection(model: meters.network(s, history: monitor.history, count: 6, askClaude: ask), maxItems: 6)
        PXDivider()
        block("Last five minutes", "each direction on its own scale") {
            ChartHeader(name: "Download", now: Format.rate(n.inBytesPerSecond), average: Format.rate(average(down)), peak: Format.rate(down.max() ?? 0), swatch: NetScale.down)
                .padding(.top, 9)
            DuplexMatrixChart(
                upper: points.map { .init(time: $0.time, value: $0.networkIn / downTop) },
                lower: points.map { .init(time: $0.time, value: $0.networkOut / upTop) },
                upperRGB: NetScale.down, lowerRGB: NetScale.up, upperRows: 12, lowerRows: 8
            )
            .padding(.top, 7)
            ChartHeader(name: "Upload", now: Format.rate(n.outBytesPerSecond), average: Format.rate(average(up)), peak: Format.rate(up.max() ?? 0), swatch: NetScale.up)
                .padding(.top, 7)
        }
        PXDivider()
        rows {
            PXStatRow(label: "Connection", value: primary.map { "\($0.title) (\($0.name))" } ?? "None", detail: primary?.linkSpeed.map { Format.linkSpeed($0) })
            PXCopyRow(label: "Local IP", value: primary?.address ?? "None", copy: primary?.address)
            ExternalAddressRow(network: n)
            PXStatRow(label: "Router", value: n.router ?? "None")
            PXStatRow(label: "DNS", value: n.dns.first ?? "None", detail: n.dns.count > 1 ? "and \(n.dns.count - 1) more" : nil)
            if let latency = Detail.latency(n.latency) {
                PXStatRow(label: "Latency", value: latency, detail: Detail.loss(n.latency))
            }
            if let wifi = n.wifi {
                // "Wi-Fi 6E (802.11ax)" is the page's wording; the panel has room for the name only.
                PXStatRow(label: "Wi-Fi", value: "\(wifi.standard.components(separatedBy: " (").first ?? wifi.standard) · channel \(wifi.channel) · \(wifi.band)",
                          detail: ([wifi.qualityTitle?.lowercased()] + [wifi.rssi.map { "\($0) dBm" }]).compactMap { $0 }.joined(separator: ", "))
            }
            let day = timeline.today()
            PXStatRow(label: "Today", value: "\(Format.data(UInt64(day.received))) in · \(Format.data(UInt64(day.sent))) out", detail: "since midnight")
            PXStatRow(label: "Carried", value: "\(Format.data(n.inBytes)) in · \(Format.data(n.outBytes)) out", detail: "since \(App.name) started")
        }
    }
}

/// One port in use, in the USB item's panel: what is on it, how fast, and the finding that matters most.
struct USBPanelRow: View {
    var port: USBOverview.Port
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let rgb = port.slow != nil ? USBLook.caution : USBLook.live
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rgb.color(0.15))
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(rgb.color(0.24), lineWidth: 0.5)
                    Image(systemName: USBLook.symbol(port.kind))
                        .font(.system(size: 12.5, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(rgb.color())
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 6) {
                        Text(port.title)
                            .font(PX.font(12.5, .medium))
                            .foregroundStyle(PX.text)
                        Text(port.attached)
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(caption)
                        .font(PX.font(11.5))
                        .foregroundStyle(port.slow != nil ? USBLook.caution.color(0.95) : PX.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let figure = port.figure {
                    Text(figure)
                        .font(PX.font(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(rgb.color())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? PX.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(port.headline?.detail ?? "")
    }

    /// The finding, then what hangs off the port.
    private var caption: String {
        var parts: [String] = []
        if let headline = port.headline { parts.append(headline.title) }
        if port.screens > 0 { parts.append("\(port.screens) \(port.screens == 1 ? "screen" : "screens")") }
        if port.devices > 0 { parts.append("\(port.devices) \(port.devices == 1 ? "device" : "devices")") }
        return parts.isEmpty ? "connected" : parts.joined(separator: " · ")
    }
}

/// Every core as a short column of cells, performance cores first.
struct CompactCores: View {
    var cpu: CPUStats

    var body: some View {
        let efficiency = Array(cpu.perCore.prefix(cpu.efficiencyCores))
        let performance = Array(cpu.perCore.dropFirst(cpu.efficiencyCores))
        let cores: [(String, Double)] = performance.enumerated().map { ("P\($0.offset + 1)", $0.element) } + efficiency.enumerated().map { ("E\($0.offset + 1)", $0.element) }
        let perRow = min(max(cores.count, 1), 16)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: perRow), spacing: 9) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, core in
                VStack(spacing: 3) {
                    CoreCell(load: core.1, cols: 5, rows: 8)
                    Text(core.0)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(core.0.hasPrefix("E") ? PX.tertiary : PX.secondary)
                }
            }
        }
    }
}
