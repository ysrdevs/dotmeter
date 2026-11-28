import AppKit
import SwiftUI

/// This Mac and the user's other Macs, a card each.
struct MacsPage: View {
    @Environment(MacsModel.self) private var macs
    @Environment(\.pxActivity) private var activity
    @Environment(AppRouter.self) private var router
    @State private var token = UUID()

    var body: some View {
        // Explain belongs to the page only while there is something on it to explain.
        PageScaffold(title: "Macs", subtitle: subtitle, section: macs.isOn ? .macs : nil, explainExtra: { macs.summary() }, trailing: AnyView(MacsSwitch())) { gridWidth, columns in
            if macs.isOn {
                MacsCodeCard(width: gridWidth)
                MacsNotices(width: gridWidth)
                MacsGrid(columns: columns)
            } else {
                MacsOffCard(width: gridWidth)
            }
        }
        // The others are looked for, and asked for readings, only while this page can be seen.
        .onAppear { macs.pageAppeared(token, activity: activity) }
        .onDisappear { macs.pageDisappeared(token) }
        .onChange(of: activity?.active) { _, active in
            if active != false { macs.pageAppeared(token, activity: activity) }
        }
        // Debug: DOTMETER_MACS_LEAVE=<seconds> goes to the Dashboard after that long, as a click in the sidebar
        // would, to see the connections close when the page leaves the screen.
        .task {
            guard let after = ProcessInfo.processInfo.environment["DOTMETER_MACS_LEAVE"].flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(after))
            if !Task.isCancelled { router.section = .dashboard }
        }
    }

    private var subtitle: String {
        guard macs.isOn else { return "Off" }
        let others = macs.peers.count
        var parts = [others == 0 ? "Looking for your other Macs on this network" : "This Mac and \(others) \(others == 1 ? "other" : "others") on this network"]
        if macs.watcherCount > 0 { parts.append("\(macs.watcherCount) \(macs.watcherCount == 1 ? "Mac is" : "Macs are") reading this one") }
        return parts.joined(separator: " · ")
    }
}

/// The one switch: on, this Mac is shown to the others and looks for them.
struct MacsSwitch: View {
    @Environment(MacsModel.self) private var macs
    @State private var hovering = false

    var body: some View {
        let on = macs.isOn
        Button {
            macs.setOn(!on)
        } label: {
            HStack(spacing: 8) {
                Text(on ? "On" : "Off")
                    .font(PX.font(12, .medium))
                    .foregroundStyle(Color.primary.opacity(on ? 0.85 : 0.7))
                    .fixedSize()
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? AppSection.macs.rgb.color() : Color.primary.opacity(0.18))
                    Circle().fill(Color.white).padding(2)
                }
                .frame(width: 30, height: 17)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.11 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PXPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.16), value: on)
        .help(on ? "Stop showing this Mac to your other Macs, and stop looking for them" : "Show this Mac to your other Macs on this network, and look for them")
    }
}

/// With the feature off: what it does, in two lines.
private struct MacsOffCard: View {
    var width: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MacTile(symbol: "desktopcomputer", rgb: PX.gray)
            VStack(alignment: .leading, spacing: 5) {
                Text("Your other Macs running \(App.name), side by side with this one: load, memory, heat, power and what is busiest on each.")
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.label)
                Text("Switch it on here and on another Mac on this network, and give both the same code. Nothing can be read without it.")
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PX.inset)
        .padding(.vertical, 20)
        .frame(width: width, alignment: .leading)
        .pxCard()
    }
}

/// The rounded square a Mac's symbol sits in.
private struct MacTile: View {
    var symbol: String
    var rgb: RGB

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(rgb.color(0.14))
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(rgb.color())
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - The code

/// This Mac's group code, and the field that takes another Mac's.
private struct MacsCodeCard: View {
    var width: CGFloat
    @Environment(MacsModel.self) private var macs
    @State private var draft = ""
    @State private var copied = false
    @State private var rejected = false
    @FocusState private var typing: Bool

    var body: some View {
        let wide = width > 700
        Group {
            if wide {
                HStack(spacing: 12) {
                    code
                    Spacer(minLength: 12)
                    entry
                }
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    code
                    entry
                }
            }
        }
        .padding(.horizontal, PX.inset)
        .frame(width: width, height: wide ? 62 : 104, alignment: .leading)
        .pxCard()
    }

    private var code: some View {
        HStack(spacing: 10) {
            MeterIconView(icon: .symbol("key.fill"), rgb: AppSection.macs.rgb, size: 13)
            Text("Group code")
                .font(PX.font(13, .medium))
                .tracking(PX.tracking(13))
                .foregroundStyle(PX.text)
            Text(macs.code)
                .font(PX.mono(15))
                .tracking(1.1)
                .foregroundStyle(PX.text)
                .textSelection(.enabled)
                .padding(.leading, 4)
            PXButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", style: .ghost, tint: copied ? PX.green : nil, height: 26) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(macs.code, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1300))
                    copied = false
                }
            }
        }
        .help("Macs with the same code can read each other. Nothing can be read without it.")
    }

    private var entry: some View {
        let typed = MacsCode.normalized(draft)
        return HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text("Use a code from another Mac").foregroundStyle(PX.tertiary))
                .textFieldStyle(.plain)
                // The prompt is a sentence; what is typed is a code.
                .font(draft.isEmpty ? PX.font(12.5) : PX.mono(12.5))
                .foregroundStyle(PX.text)
                .focused($typing)
                .autocorrectionDisabled()
                // A window that opens on this page hands its first text field the keyboard; this one waits to be clicked.
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { typing = false } }
                .onSubmit(use)
                .onChange(of: draft) { _, _ in rejected = false }
                .padding(.horizontal, 10)
                .frame(width: 248, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PX.button))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(rejected ? PX.red.color(0.8) : (typing ? AppSection.macs.rgb.color(0.6) : Color.clear), lineWidth: 1))
                .help(rejected ? "A code is twelve letters and digits, like \(MacsDemo.code)." : "Type the code another Mac shows, and both Macs see each other.")
            PXButton(title: "Use", symbol: nil, enabled: typed != nil && typed != macs.code, height: 28, action: use)
        }
    }

    private func use() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if macs.useCode(draft) {
            draft = ""
            typing = false
        } else {
            rejected = true
        }
    }
}

/// What stands in the way, one line each. Nothing is shown when nothing does.
private struct MacsNotices: View {
    var width: CGFloat
    @Environment(MacsModel.self) private var macs

    var body: some View {
        if macs.blocked {
            notice("macOS is not letting \(App.name) use the local network, so the other Macs cannot be found.", action: ("Open Settings", {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
            }))
        }
        if let problem = macs.problem { notice(problem) }
        if macs.otherCodes > 0 {
            notice(macs.otherCodes == 1 ? "A Mac on this network has another code. Type one Mac's code into the other and they see each other." : "\(macs.otherCodes) Macs on this network have another code. Type this Mac's code into them, or one of theirs here.")
        }
        if macs.newerNearby { notice("A Mac here runs a newer \(App.name). Update this one to read it.") }
    }

    private func notice(_ text: String, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(PX.orange.color())
            Text(text)
                .font(PX.font(12.5))
                .foregroundStyle(PX.soft)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let action { PXButton(title: action.0, symbol: "arrow.up.right", height: 26, action: action.1) }
        }
        .padding(.horizontal, PX.inset)
        .frame(width: width, height: 48, alignment: .leading)
        .pxCard()
    }
}

// MARK: - The cards

/// This Mac first, then the others, as many to a row as the page has columns.
private struct MacsGrid: View {
    var columns: Int
    @Environment(MacsModel.self) private var macs

    var body: some View {
        let peers = macs.peers
        // With nobody found, the place beside this Mac says how to get somebody there.
        let slots = 1 + max(peers.count, 1)
        let gap = PageScaffold<EmptyView>.gap
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(stride(from: 0, to: slots, by: columns)), id: \.self) { start in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(start..<min(start + columns, slots)), id: \.self) { slot in
                        if slot == 0 {
                            ThisMacCard()
                        } else if peers.isEmpty {
                            MacsLookingCard()
                        } else {
                            PeerCard(peer: peers[slot - 1]).id(peers[slot - 1].id)
                        }
                    }
                }
            }
        }
    }
}

private struct ThisMacCard: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(MacsModel.self) private var macs

    var body: some View {
        if let s = monitor.snapshot {
            let recent = monitor.history.suffix(150)
            MacCard(
                hello: macs.hello,
                reading: MacReading(snapshot: s, every: AppSettings.shared.refreshInterval),
                own: true,
                peakWatts: recent.compactMap(\.power).max() ?? 0,
                peakRate: recent.map(\.networkBytesPerSecond).max() ?? 0
            )
        } else {
            LoadingCard(width: PX.cardWidth).frame(height: MacCard.height)
        }
    }
}

/// Reads its own Mac, so a reading from one Mac redraws one card.
private struct PeerCard: View {
    var peer: MacPeer

    var body: some View {
        MacCard(hello: peer.hello, reading: peer.reading, answering: peer.answering, seen: peer.seen, peakWatts: peer.peakWatts, peakRate: peer.peakRate)
    }
}

/// Where the first other Mac will go.
private struct MacsLookingCard: View {
    var body: some View {
        VStack(spacing: 12) {
            PXSpinner(size: 15)
            Text("Looking on this network")
                .font(PX.font(13, .medium))
                .tracking(PX.tracking(13))
                .foregroundStyle(PX.label)
            Text("On another Mac, open \(App.name), switch Macs on and type this Mac's code.")
                .font(PX.font(12.5))
                .foregroundStyle(PX.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 60)
        .frame(width: PX.cardWidth, height: MacCard.height)
        .pxCard()
    }
}

/// One Mac: who it is, how it is doing, six strips, and the figures a strip cannot carry.
struct MacCard: View {
    var hello: MacHello
    var reading: MacReading?
    var own = false
    var answering = true
    var seen = ""
    var peakWatts = 0.0
    var peakRate = 0.0

    static let height: CGFloat = 342.75

    var body: some View {
        let quiet = !own && !answering
        VStack(alignment: .leading, spacing: 0) {
            header(quiet: quiet)
                .padding(.top, 18)
            Group {
                gauges
                    .padding(.top, 20)
                Spacer(minLength: 10)
                PXDivider().padding(.horizontal, -PX.inset)
                rows
                    .padding(.vertical, 7)
            }
            // A Mac that has stopped answering keeps its last figures, dimmed: they are old.
            .opacity(quiet ? 0.38 : 1)
        }
        .padding(.horizontal, PX.inset)
        .frame(width: PX.cardWidth, height: Self.height, alignment: .topLeading)
        .pxCard()
        .animation(.easeOut(duration: 0.25), value: quiet)
    }

    // MARK: Header

    private func header(quiet: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MacTile(symbol: Self.symbol(for: hello.model), rgb: quiet ? PX.gray : AppSection.macs.rgb)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(hello.name)
                        .font(PX.font(13, .medium))
                        .tracking(PX.tracking(13))
                        .foregroundStyle(quiet ? PX.soft : PX.text)
                        .lineLimit(1)
                    if own {
                        Text("This Mac")
                            .font(PX.font(10.5, .medium))
                            .foregroundStyle(PX.soft)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
                            .fixedSize()
                    }
                }
                Text("\(hello.model) · \(hello.chip.replacingOccurrences(of: "Apple ", with: ""))")
                    .font(PX.font(12))
                    .tracking(PX.tracking(12))
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    SeverityDot(color: quiet || reading == nil ? Color(hex: 0x6A6B6E) : Theme.color(for: reading?.severityLevel ?? .nominal))
                    Text(quiet ? "Not answering" : (reading?.severityLevel.title ?? "Connecting"))
                        .font(PX.font(12.5, .medium))
                        .foregroundStyle(quiet ? PX.soft : PX.text)
                }
                Text(freshness(quiet: quiet))
                    .font(PX.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.tertiary)
            }
            .fixedSize()
        }
        .frame(height: 36)
    }

    private func freshness(quiet: Bool) -> String {
        if quiet { return seen.isEmpty ? "last seen just now" : seen }
        guard let reading else { return "waiting for a reading" }
        let every = reading.every
        let pace = every < 1.5 ? "every second" : "every \(Int(every.rounded())) s"
        return own ? "read \(pace)" : "live, \(pace)"
    }

    static func symbol(for model: String) -> String {
        let name = model.lowercased()
        if name.contains("macbook") { return "laptopcomputer" }
        if name.contains("mini") { return "macmini.fill" }
        if name.contains("studio") { return "macstudio.fill" }
        if name.contains("mac pro") { return "macpro.gen3.fill" }
        return "desktopcomputer"
    }

    // MARK: Strips

    private var gauges: some View {
        let r = reading
        let watts = r?.watts
        let rate = r.map { $0.down + $0.up }
        let memory: RGB = r.map { $0.memoryPressure == .critical ? PX.red : ($0.memoryPressure == .warning ? PX.orange : AppSection.memory.rgb) } ?? AppSection.memory.rgb
        return HStack(alignment: .top, spacing: 14) {
            MacGauge(label: "Processor", value: r.map { Format.percent($0.cpu) }, fraction: r?.cpu, rgb: AppSection.cpu.rgb,
                     help: "Share of all its cores in use")
            MacGauge(label: "Graphics", value: r?.gpu.map { Format.percent($0) }, fraction: r?.gpu, rgb: AppSection.gpu.rgb,
                     help: "How busy its graphics cores are")
            MacGauge(label: "Memory", value: r.map { Format.bytes($0.memoryUsed) }, fraction: r?.memoryFraction, rgb: memory,
                     help: r.map { "\(Format.bytes($0.memoryUsed)) of \(Format.bytes($0.memoryTotal)) in use, \($0.memoryPressure.title.lowercased()) pressure" } ?? "")
            MacGauge(label: "Heat", value: r?.temperature.map { Format.temperature($0) }, fraction: r?.temperature.map { ($0 - 30) / 78 }, rgb: r?.temperature.map(heatColor) ?? AppSection.thermal.rgb,
                     help: "Its hottest sensor, drawn from 30° to 108°")
            MacGauge(label: "Power", value: watts.map { $0 < 99.5 ? String(format: "%.0f W", $0) : "\(Int($0.rounded())) W" }, fraction: watts.map { $0 / AreaMeters.wattCeiling(max(peakWatts, $0), floor: 20) }, rgb: AppSection.power.rgb,
                     help: watts == nil ? "This Mac does not report what it draws" : "What the whole Mac is drawing, against \(Int(AreaMeters.wattCeiling(max(peakWatts, watts ?? 0), floor: 20))) W")
            MacGauge(label: "Network", value: rate.map { Format.shortRate($0) }, fraction: rate.map { $0 / AreaMeters.wattCeiling(max(peakRate, $0), floor: 1e6) }, rgb: AppSection.network.rgb,
                     help: r.map { "Down \(Format.rate($0.down)), up \(Format.rate($0.up))" } ?? "")
        }
    }

    // MARK: Rows

    private var rows: some View {
        let r = reading
        return VStack(spacing: 0) {
            PXStatRow(label: "Busiest app", value: r?.apps.first.map { "\($0.name) \(Format.cpu($0.cpu))" } ?? "—", detail: r.flatMap(Self.runnersUp))
            PXStatRow(label: "Memory", value: r.map { "\(Format.bytes($0.memoryUsed)) of \(Format.bytes($0.memoryTotal))" } ?? "—", detail: r.map { "\($0.memoryPressure.title.lowercased()) pressure" })
            PXStatRow(label: "Disk", value: r.map { "\(StorageModel.gb(Double($0.diskFree))) free" } ?? "—", detail: r.map { "of \(StorageModel.gb(Double($0.diskTotal)))" })
            PXStatRow(label: "Battery", value: r.map { $0.battery.map { Format.percent($0.charge) } ?? "None" } ?? "—", detail: r.map { Self.battery($0.battery) })
            PXStatRow(label: "Fans", value: r.map(Self.fans) ?? "—", detail: r.flatMap(Self.fanDetail))
            PXStatRow(label: "Uptime", value: r.map { Format.duration($0.uptime) } ?? "—", detail: "running \(App.name) \(hello.app)")
        }
    }

    private static func runnersUp(_ reading: MacReading) -> String? {
        let rest = reading.apps.dropFirst()
        return rest.isEmpty ? nil : "then " + rest.map { "\($0.name) \(Format.cpu($0.cpu))" }.joined(separator: ", ")
    }

    private static func battery(_ battery: MacReading.Battery?) -> String {
        guard let battery else { return "runs on mains power" }
        let time = battery.minutes.map { Format.duration(Double($0) * 60) }
        if battery.charging { return time.map { "charging, full in \($0)" } ?? "charging" }
        if battery.plugged { return "plugged in" }
        return time.map { "on battery, \($0) left" } ?? "on battery"
    }

    private static func fans(_ reading: MacReading) -> String {
        guard !reading.fans.isEmpty else { return "None" }
        return "\(Format.rpm(reading.fans.reduce(0, +) / Double(reading.fans.count))) rpm"
    }

    private static func fanDetail(_ reading: MacReading) -> String? {
        guard !reading.fans.isEmpty else { return "cools itself without" }
        let count = reading.fans.count == 1 ? "one fan" : "\(reading.fans.count) fans"
        return reading.fanLevel.map { "\(count), \(Format.percent($0)) of their range" } ?? count
    }
}

/// One figure with a strip of dots under it.
private struct MacGauge: View {
    var label: String
    var value: String?
    /// 0...1, or nil when the Mac does not report it.
    var fraction: Double?
    var rgb: RGB
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .lineLimit(1)
            Text(value ?? "—")
                .font(PX.headline(17))
                .tracking(PX.tracking(17))
                .monospacedDigit()
                .foregroundStyle(value == nil ? PX.tertiary : PX.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 6)
            MiniMatrixBar(fraction: fraction.map { $0 > 0 ? max(min($0, 1), 0.012) : 0 } ?? 0, rgb: rgb, rows: 5)
                .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }
}

// MARK: - Settings

/// The section Settings shows for this feature: the same switch as the page, and the code.
struct MacsSettingsSection: View {
    @Environment(MacsModel.self) private var macs
    @State private var draft = ""

    var body: some View {
        Section {
            Toggle("Show this Mac to your other Macs, and look for them", isOn: Binding(get: { macs.isOn }, set: { macs.setOn($0) }))
                .id("macs")
            if macs.isOn {
                LabeledContent("Group code") {
                    HStack(spacing: 8) {
                        Text(macs.code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(macs.code, forType: .string)
                        }
                        Button("New Code") { macs.newCode() }
                            .help("Makes a new code. The other Macs stop seeing this one until they are given it.")
                    }
                }
                LabeledContent("Use a code from another Mac") {
                    HStack(spacing: 8) {
                        TextField("Code", text: $draft, prompt: Text("XXXX-XXXX-XXXX"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .frame(width: 150)
                            .onSubmit(use)
                        Button("Use", action: use)
                            .disabled(MacsCode.normalized(draft) == nil || MacsCode.normalized(draft) == macs.code)
                    }
                }
            }
        } header: {
            Text("Macs")
        } footer: {
            Text("Your other Macs running \(App.name) on this network appear on the Macs page, and this Mac on theirs. Macs with the same code can read each other's figures; nothing can be read without it. Readings are sent only while another Mac has its Macs page open, and this Mac looks for the others only while its own is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func use() {
        if macs.useCode(draft) { draft = "" }
    }
}
