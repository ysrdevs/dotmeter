import SwiftUI

/// What starts by itself: the launch agents and daemons apps install, who they belong to, and which are running.
struct StartupPage: View {
    @Environment(LoginItemsModel.self) private var model
    @State private var open: String?
    @State private var filter = "all"

    var body: some View {
        PageScaffold(title: "Login Items", subtitle: subtitle, section: .startup, explainExtra: explainContext) { gridWidth, columns in
            PagePair(columns: columns) {
                MeterCard(model: meter, selected: filter) { id in
                    if LaunchItem.Scope(rawValue: id) != nil || id == "running" { filter = filter == id ? "all" : id }
                }
            } second: {
                StartupScopesPanel(items: model.items)
            }
            LaunchItemsPanel(width: gridWidth, filter: $filter, open: $open)
        }
        .onAppear { model.refresh() }
    }

    private var subtitle: String {
        if model.items.isEmpty { return model.loading ? "Reading what starts with this Mac" : "Nothing found" }
        let apps = Set(model.items.map(\.vendor)).count
        return "\(model.items.count) background items from about \(apps) vendors · apps under Open at Login are listed in System Settings"
    }

    private func explainContext() -> String? {
        guard !model.items.isEmpty else { return nil }
        let lines = model.items.map { "\($0.label) [\($0.scope.title.lowercased()), \($0.trigger), \($0.isRunning ? "running" : "not running")] \($0.program ?? "")" }
        return "Launch agents and daemons on this Mac (label, who it is for, how it starts, state, program):\n" + lines.joined(separator: "\n")
    }

    private var meter: MeterModel {
        let items = model.items
        func count(_ test: (LaunchItem) -> Bool) -> Double { Double(items.filter(test).count) }
        func whole(_ value: Double) -> String { "\(Int(value))" }
        var legend: [MeterItem] = LaunchItem.Scope.allCases.map { scope in
            MeterItem(id: scope.rawValue, name: scope.title, icon: .symbol(scope.symbol), rgb: scope.rgb, amount: count { $0.scope == scope }, number: count { $0.scope == scope }, format: whole, detail: scope.detail)
        }
        legend.append(MeterItem(id: "running", name: "Running now", icon: .symbol("play.fill"), rgb: PX.greenRGB, amount: 0, number: count(\.isRunning), format: whole, detail: "Have a process alive at this moment.", inBar: false))
        legend.append(MeterItem(id: "login", name: "At login or startup", icon: .symbol("power"), rgb: PX.cyan, amount: 0, number: count { $0.runAtLoad && !$0.keepAlive && !$0.disabled }, format: whole, detail: "Started once, when you log in or the Mac starts.", inBar: false))
        legend.append(MeterItem(id: "kept", name: "Kept running", icon: .symbol("arrow.triangle.2.circlepath"), rgb: PX.yellow, amount: 0, number: count { $0.keepAlive && !$0.disabled }, format: whole, detail: "Restarted by macOS whenever they exit.", inBar: false))
        legend.append(MeterItem(id: "scheduled", name: "On a schedule", icon: .symbol("clock.fill"), rgb: PX.pink, amount: 0, number: count { $0.scheduled && !$0.runAtLoad && !$0.keepAlive && !$0.disabled }, format: whole, detail: "Woken on a timer or at set times.", inBar: false))
        legend.append(MeterItem(id: "demand", name: "On demand", icon: .symbol("hand.tap.fill"), rgb: PX.gray, amount: 0, number: count { !$0.runAtLoad && !$0.keepAlive && !$0.scheduled && !$0.disabled }, format: whole, detail: "Only started when something asks for them.", inBar: false))
        legend.append(MeterItem(id: "disabled", name: "Disabled", icon: .symbol("nosign"), rgb: PX.gray, amount: 0, number: count(\.disabled), format: whole, detail: "Marked not to load.", inBar: false))
        return MeterModel(
            number: count(\.isRunning),
            numberFormat: whole,
            caption: "of \(items.count) background items running",
            status: model.loading && items.isEmpty ? .activity("Reading", "~/Library/LaunchAgents") : .plain("\(Int(count { ($0.runAtLoad || $0.keepAlive) && !$0.disabled })) start by themselves · click a group to filter the list"),
            items: legend,
            capacity: Double(max(items.count, 1)),
            footer: .suggestion(icon: .symbol("gearshape.fill"), rgb: PX.gray, text: "Apps that open at login, and switches for these, are in System Settings.", action: MeterAction(title: "Open Settings", symbol: "arrow.up.right", action: model.openSettings)),
            trailing: MeterAction(title: "Reload", symbol: "arrow.triangle.2.circlepath", spinning: model.loading, enabled: !model.loading, symbolRotation: 90, action: model.refresh)
        )
    }
}

struct StartupScopesPanel: View {
    var items: [LaunchItem]

    var body: some View {
        PXPanel(title: "Who they belong to", caption: "three places macOS looks", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 13) {
                    ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                        let mine = items.filter { $0.scope == scope }
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(scope.rgb.color(0.14))
                                Image(systemName: scope.symbol)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(scope.rgb.color())
                            }
                            .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(scope.title).font(PX.font(12.5, .medium)).foregroundStyle(PX.text)
                                    Text("\(mine.count) items, \(mine.filter(\.isRunning).count) running")
                                        .font(PX.font(11.5))
                                        .monospacedDigit()
                                        .foregroundStyle(PX.secondary)
                                }
                                Text(scope.detail)
                                    .font(PX.font(11.5))
                                    .foregroundStyle(PX.tertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                MiniMatrixBar(fraction: mine.isEmpty ? 0 : max(Double(mine.filter(\.isRunning).count) / Double(mine.count), 0.012), rgb: scope.rgb, rows: 2)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.top, 16)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                HStack(spacing: 8.5) {
                    MeterIconView(icon: .symbol("info.circle.fill"), rgb: PX.gray, size: 13)
                    Text("Only your own agents can be removed here. The rest need an administrator.")
                        .font(PX.font(12))
                        .foregroundStyle(PX.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 50)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

struct LaunchItemsPanel: View {
    var width: CGFloat
    @Binding var filter: String
    @Binding var open: String?
    @Environment(LoginItemsModel.self) private var model

    var body: some View {
        let wide = width > 700
        let shown = model.items.filter { item in
            switch filter {
            case "all": return true
            case "running": return item.isRunning
            default: return item.scope.rawValue == filter
            }
        }
        PXPanel(title: "Background items", caption: "\(shown.count) shown · click one for what it runs", width: width) {
            HStack(spacing: 2) {
                PXPill(title: "All", symbol: nil, rgb: PX.gray, selected: filter == "all") { filter = "all" }
                ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                    PXPill(title: wide ? scope.title : "", symbol: scope.symbol, rgb: scope.rgb, selected: filter == scope.rawValue) { filter = scope.rawValue }
                }
                PXPill(title: wide ? "Running" : "", symbol: "play.fill", rgb: PX.greenRGB, selected: filter == "running") { filter = "running" }
            }
            .padding(.trailing, -6)
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                    if wide { Text("Runs").frame(width: 360, alignment: .leading) }
                    Text("Starts").frame(width: 104, alignment: .leading)
                    Text("State").frame(width: 78, alignment: .trailing)
                }
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .padding(.horizontal, PX.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                PXDivider()
                if let notice = model.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").font(.system(size: 10.5)).foregroundStyle(PX.cyan.color())
                        Text(notice).font(PX.font(12)).foregroundStyle(PX.soft).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.vertical, 8)
                    .background(PX.cyan.color(0.06))
                }
                VStack(spacing: 1) {
                    if shown.isEmpty {
                        HStack(spacing: 8) {
                            if model.loading { PXSpinner(size: 12) }
                            Text(model.loading ? "Reading the launch folders" : "Nothing here.")
                                .font(PX.font(12))
                                .foregroundStyle(PX.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                    }
                    ForEach(shown) { item in
                        row(item, wide: wide)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .animation(.snappy(duration: 0.25), value: open)
    }

    private func row(_ item: LaunchItem, wide: Bool) -> some View {
        let isOpen = open == item.id
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Circle()
                    .fill(item.isRunning ? PX.green : Color.white.opacity(0.16))
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 9)
                if item.appPath != nil {
                    Image(nsImage: IconCache.icon(forBundlePath: item.appPath))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    MeterIconView(icon: .symbol(item.scope.symbol), rgb: item.scope.rgb, size: 13)
                        .frame(width: 16, height: 16)
                }
                Text(item.title)
                    .font(PX.font(12, .medium))
                    .foregroundStyle(item.disabled ? PX.secondary : PX.label)
                    .lineLimit(1)
                    .padding(.leading, 9)
                Text(item.vendor)
                    .font(PX.font(11))
                    .foregroundStyle(PX.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 7)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(PX.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .padding(.leading, 6)
                Spacer(minLength: 10)
                if wide {
                    Text(item.program.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "—")
                        .font(PX.mono(10.5))
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.trailing, 14)
                        .frame(width: 360, alignment: .leading)
                }
                Text(item.trigger)
                    .foregroundStyle(item.keepAlive ? PX.yellow.color(0.95) : PX.secondary)
                    .frame(width: 104, alignment: .leading)
                Text(verbatim: item.pid.map { "pid \($0)" } ?? "idle")
                    .foregroundStyle(item.isRunning ? PX.label : PX.tertiary)
                    .frame(width: 78, alignment: .trailing)
            }
            .font(PX.font(12))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(isOpen ? PX.rowHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { open = isOpen ? nil : item.id }

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    fact("Label", item.label)
                    fact("Runs", ([item.program ?? "—"] + item.arguments).joined(separator: " "))
                    fact("File", (item.path as NSString).abbreviatingWithTildeInPath)
                    if let loaded = item.loaded { fact("Loaded", loaded ? "yes, launchd has it" : "no, it is on disk but not loaded") }
                    HStack(spacing: 7) {
                        PXButton(title: "Show in Finder", symbol: "folder", style: .ghost, height: 24) { model.reveal(item) }
                            .padding(.leading, -8)
                        if model.canRemove(item) {
                            PXConfirmButton(title: "Remove", armedTitle: "Confirm: stop it and move it to the Trash", symbol: "trash", armed: model.armed == item.id, busy: model.busy == item.id) {
                                model.requestRemove(item)
                            }
                        } else {
                            Text("Installed for \(item.scope == .system ? "the system" : "every account"): removing it needs an administrator.")
                                .font(PX.font(11.5))
                                .foregroundStyle(PX.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 30)
                    .padding(.top, 2)
                }
                .padding(.leading, 40)
                .padding(.trailing, 10)
                .padding(.top, 3)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(PX.font(11.5))
                .foregroundStyle(PX.tertiary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(PX.mono(10.5))
                .foregroundStyle(PX.soft)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 21)
    }
}
