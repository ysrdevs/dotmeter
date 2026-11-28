import SwiftUI

/// The Models area: what the loaded models hold, each one's details and speed, what is on disk, and the runners.
struct RunnersPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(RunnersModel.self) private var runners
    @Environment(\.pxActivity) private var activity

    var body: some View {
        let picture = runners.picture
        PageScaffold(title: "Models", subtitle: Self.subtitle(picture), section: .models, explainExtra: explainContext) { gridWidth, columns in
            if let picture, let s = monitor.snapshot {
                if picture.runners.isEmpty {
                    NoRunnersCard(width: gridWidth)
                } else {
                    MeterCard(model: RunnersMeter.model(picture, memory: memory(s.memory, holding: picture.held), now: s.timestamp, most: columns == 1 ? 7 : 16), width: gridWidth)
                    LoadedModelsPanel(loaded: picture.loaded, quiet: picture.runners.allSatisfy { !$0.answering }, now: s.timestamp, width: gridWidth)
                    InstalledModelsPanel(installed: picture.installed, loaded: Set(picture.loaded.flatMap { [$0.id, $0.model.runner.rawValue + "|" + $0.model.title] }), columns: columns, width: gridWidth)
                    RunnersPanel(runners: picture.runners, total: s.memory.total, width: gridWidth)
                }
            } else {
                HStack(spacing: 8) {
                    PXSpinner(size: 13)
                    Text("Looking for runners").font(PX.font(12)).foregroundStyle(PX.secondary)
                }
                .frame(width: gridWidth, height: 120)
                .pxCard()
            }
        }
        // The runners are asked once for each reading this page shows, and so only while it is on screen.
        .onAppear(perform: ask)
        .onChange(of: monitor.snapshot?.timestamp) { _, _ in ask() }
        .onChange(of: activity?.active) { _, _ in ask() }
    }

    private func ask() {
        guard activity?.active != false, let snapshot = monitor.snapshot else { return }
        runners.refresh(with: snapshot)
    }

    /// Made-up models hold nothing, so with them the Mac's real memory is shown as if they did.
    private func memory(_ real: MemoryStats, holding held: UInt64) -> MemoryStats {
        guard runners.demo != nil else { return real }
        var memory = real
        memory.used = min(real.total, real.used + held)
        return memory
    }

    private func explainContext() -> String? {
        runners.explainText(memory: monitor.snapshot?.memory)
    }

    static func subtitle(_ picture: RunnersModel.Picture?) -> String {
        guard let picture else { return "Looking for runners" }
        guard let first = picture.runners.first else { return "No runner found" }
        var parts = [picture.runners.count == 1 ? first.kind.title + (first.version.map { " \($0)" } ?? "") : "\(picture.runners.count) runners"]
        parts.append(picture.loaded.isEmpty ? "nothing loaded" : "\(picture.loaded.count) loaded")
        if !picture.installed.isEmpty { parts.append("\(picture.installed.count) on disk") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The headline card

enum RunnersMeter {
    private static let gib = 1_073_741_824.0

    private static func gigabytes(_ v: Double) -> String {
        v < 0.1 ? "\(Int((v * 1024).rounded())) MB" : String(format: "%.1f GB", v)
    }

    /// "70.6B · Q4_K_M"
    static func make(_ model: RunnerModel) -> String? {
        let parts = [model.parameters, model.quantization].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Memory held by models out of the Mac's total, one segment per loaded model. `most` is how many models
    /// the legend has room for; the smallest beyond that share one entry.
    static func model(_ picture: RunnersModel.Picture, memory: MemoryStats, now: Date, most: Int) -> MeterModel {
        let sized = picture.loaded.filter { $0.model.size != nil }.sorted { ($0.model.size ?? 0) > ($1.model.size ?? 0) }
        let bar = RunnerMath.bar(models: sized.map { $0.model.size ?? 0 }, used: memory.used, total: memory.total)
        var items: [MeterItem] = []
        for (index, loaded) in sized.enumerated().prefix(sized.count > most ? most - 1 : most) {
            let model = loaded.model
            let detail = [make(model), "on \(model.runner.title)", RunnerMath.unloads(model.expires, now: now)].compactMap { $0 }.joined(separator: " · ")
            items.append(MeterItem(
                id: loaded.id, name: model.title, icon: .swatch, rgb: PX.palette[loaded.tone % PX.palette.count],
                amount: Double(bar.models[index]), number: Double(model.size ?? 0) / gib, format: gigabytes, detail: detail
            ))
        }
        if sized.count > most {
            let rest = sized.count - (most - 1)
            let drawn = bar.models.dropFirst(most - 1).reduce(0, +), held = sized.dropFirst(most - 1).compactMap(\.model.size).reduce(0, +)
            items.append(MeterItem(id: "more", name: "\(rest) smaller models", icon: .swatch, rgb: PX.teal, amount: Double(drawn), number: Double(held) / gib, format: gigabytes, detail: "The smallest of the loaded models, together."))
        }
        for loaded in picture.loaded where loaded.model.size == nil {
            items.append(MeterItem(id: loaded.id, name: loaded.model.title, icon: .swatch, rgb: PX.palette[loaded.tone % PX.palette.count], amount: 0, number: 0, format: { _ in "—" }, detail: "\(loaded.model.runner.title) does not say what it holds.", inBar: false))
        }
        let free = memory.total > memory.used ? memory.total - memory.used : 0
        items.append(MeterItem(id: "others", name: "Everything else", icon: .swatch, rgb: PX.gray, amount: Double(bar.others), number: Double(bar.others) / gib, format: gigabytes, detail: "Memory in use by apps and macOS."))
        items.append(MeterItem(id: "free", name: "Free", icon: .symbol("circle.dashed"), rgb: PX.gray, amount: 0, number: Double(free) / gib, format: gigabytes, detail: "Not in use by anything.", inBar: false))

        let held = picture.held
        let count = picture.loaded.count
        // A runner seen only through an API that gives no sizes, with no process of its own to go by.
        let unknown = count > 0 && sized.isEmpty
        let status = count == 0 ? "No models loaded; \(Format.bytes(free)) free" : "\(RunnerMath.loadedPhrase(count)), \(unknown ? "size not reported" : Format.bytes(held)); \(Format.bytes(free)) free"

        var footer: MeterFooter = .success(count == 0 ? "Nothing is loaded, so no memory is held by models." : "Loaded and ready. \(Format.bytes(free)) is free for more.")
        if memory.pressure != .normal, let largest = sized.first {
            footer = .suggestion(icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.orange, text: "Memory is tight. \(largest.model.title) holds \(Format.bytes(largest.model.size ?? 0)).", action: nil)
        } else if let next = picture.loaded.filter({ ($0.model.expires ?? .distantFuture).timeIntervalSince(now) < 366 * 86_400 }).min(by: { ($0.model.expires ?? .distantFuture) < ($1.model.expires ?? .distantFuture) }),
                  let wording = RunnerMath.unloads(next.model.expires, now: now) {
            let frees = next.model.size.map { wording == "unloading" ? ", freeing \(Format.bytes($0))" : " and frees \(Format.bytes($0))" } ?? ""
            footer = .suggestion(icon: .symbol("clock.fill"), rgb: PX.teal, text: "\(next.model.title) \(wording)\(frees) unless something asks for it first.", action: nil)
        }

        return MeterModel(
            number: Double(held) / gib,
            numberFormat: { unknown ? "—" : String(format: "%.1f GB", $0) },
            caption: "of \(Format.bytes(memory.total)) held by models",
            status: .plain(status),
            items: items,
            capacity: Double(max(memory.total, 1)),
            footer: footer
        )
    }
}

// MARK: - Loaded

/// A column of a table: its heading and how wide it is.
private struct RunnerColumn {
    var title: String
    var width: CGFloat
}

private struct TableHeader: View {
    var first: String
    var columns: [RunnerColumn]

    var body: some View {
        HStack(spacing: 0) {
            Text(first).frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

private struct EmptyLine: View {
    var text: String

    var body: some View {
        Text(text)
            .font(PX.font(12))
            .foregroundStyle(PX.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 30)
    }
}

/// The name of the runner a model belongs to, set quietly after the model's own name.
private struct RunnerTag: View {
    var kind: RunnerKind

    var body: some View {
        Text(kind.title)
            .font(PX.font(11))
            .foregroundStyle(PX.tertiary)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 7)
    }
}

struct LoadedModelsPanel: View {
    var loaded: [RunnersModel.Loaded]
    /// No runner is answering, so nothing can be said about what is loaded.
    var quiet: Bool
    var now: Date
    var width: CGFloat
    @Environment(RunnersModel.self) private var runners

    private static let wide = [
        RunnerColumn(title: "Parameters", width: 140), RunnerColumn(title: "Holds", width: 84), RunnerColumn(title: "Runs on", width: 136),
        RunnerColumn(title: "Context", width: 84), RunnerColumn(title: "Unloads", width: 124), RunnerColumn(title: "Speed", width: 118),
        RunnerColumn(title: "First token", width: 92), RunnerColumn(title: "", width: 84),
    ]
    private static let narrow = [RunnerColumn(title: "Holds", width: 84), RunnerColumn(title: "", width: 84)]

    var body: some View {
        let isWide = width > 900
        PXPanel(title: "Loaded", caption: loaded.isEmpty ? nil : "in memory now", width: width) {
            VStack(spacing: 0) {
                if loaded.isEmpty {
                    PXDivider().padding(.top, 14)
                } else {
                    TableHeader(first: "Model", columns: isWide ? Self.wide : Self.narrow)
                    PXDivider()
                }
                VStack(spacing: 1) {
                    if loaded.isEmpty {
                        EmptyLine(text: quiet ? "The runner is not answering, so what it has loaded cannot be read." : "Nothing is loaded. A model loads when something asks it a question.")
                    }
                    ForEach(loaded) { entry in
                        LoadedModelRow(entry: entry, speed: runners.speeds[entry.id], busy: runners.isMeasuring, now: now, wide: isWide) {
                            runners.measureSpeed(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct LoadedModelRow: View {
    var entry: RunnersModel.Loaded
    var speed: RunnersModel.Speed?
    /// Some model is being timed, this one or another.
    var busy: Bool
    var now: Date
    var wide: Bool
    var measure: () -> Void
    @State private var hovering = false

    var body: some View {
        let model = entry.model
        let columns = LoadedModelsPanel.columnWidths(wide)
        Group {
            if wide {
                HStack(spacing: 0) {
                    name(model)
                    Spacer(minLength: 10)
                    cell(RunnersMeter.make(model), columns[0])
                    holds(model).frame(width: columns[1], alignment: .trailing)
                    cell(RunnerMath.placement(size: model.size, onGraphics: model.onGraphics), columns[2])
                    cell(model.context.map { Format.count(UInt64(max($0, 0))) }, columns[3])
                    cell(RunnerMath.unloads(model.expires, now: now).map { $0.replacingOccurrences(of: "unloads ", with: "") }, columns[4])
                    result(columns[5], columns[6])
                    button(model).frame(width: columns[7], alignment: .trailing)
                }
                .frame(height: 32)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        name(model)
                        Spacer(minLength: 10)
                        holds(model).frame(width: columns[0], alignment: .trailing)
                        button(model).frame(width: columns[1], alignment: .trailing)
                    }
                    .frame(height: 26)
                    Text(facts(model))
                        .font(PX.font(11.5))
                        .foregroundStyle(PX.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 16)
                        .frame(height: 17)
                    // A test's outcome gets a line of its own, so it never squeezes the facts above it.
                    if speed != nil {
                        outcome
                            .padding(.leading, 16)
                            .frame(height: 19)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .font(PX.font(12))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(hovering ? PX.rowHover : .clear))
        .onHover { hovering = $0 }
    }

    private func name(_ model: RunnerModel) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(PX.palette[entry.tone % PX.palette.count].color())
                .frame(width: 7, height: 7)
                .padding(.trailing, 9)
            Text(model.title)
                .font(PX.font(12, .medium))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .truncationMode(.middle)
            RunnerTag(kind: model.runner)
        }
    }

    private func cell(_ text: String?, _ width: CGFloat) -> some View {
        Text(text ?? "—")
            .foregroundStyle(text == nil ? PX.tertiary : PX.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func holds(_ model: RunnerModel) -> some View {
        Text(model.size.map(Format.bytes) ?? "—")
            .foregroundStyle(model.size == nil ? PX.tertiary : PX.label)
            .lineLimit(1)
            .help(Self.sizeNote(model))
    }

    /// Where the size comes from, since the runners do not all mean the same thing by it.
    static func sizeNote(_ model: RunnerModel) -> String {
        switch (model.size, model.sizeSource) {
        case (nil, _): return "\(model.runner.title) does not say what this model holds."
        case (_, .reported): return "What \(model.runner.title) says this model holds in memory."
        case (_, .file): return "The model's size on disk. \(model.runner.title) does not say what it holds in memory, which is a little more."
        case (_, .process): return "What \(model.runner.title)'s own processes hold. Its server does not give a size."
        }
    }

    /// The one-column row's second line: everything the wide row has columns for.
    private func facts(_ model: RunnerModel) -> String {
        [
            RunnersMeter.make(model), RunnerMath.placement(size: model.size, onGraphics: model.onGraphics),
            model.context.map { "\(Format.count(UInt64(max($0, 0)))) context" }, RunnerMath.unloads(model.expires, now: now),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// The wide row's two result columns. While it runs, and when it fails, the words take both.
    @ViewBuilder
    private func result(_ rate: CGFloat, _ first: CGFloat) -> some View {
        if case .done(let result)? = speed {
            Text(result.rateText).foregroundStyle(PX.label).lineLimit(1).frame(width: rate, alignment: .trailing)
            Text(result.firstTokenText ?? "—").foregroundStyle(PX.secondary).lineLimit(1).frame(width: first, alignment: .trailing)
        } else {
            // A stack, so the columns keep their width when there is nothing to say yet.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                outcome
            }
            .frame(width: rate + first)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch speed {
        case .running?:
            HStack(spacing: 6.5) {
                PXSpinner(size: 11.5)
                Text("Timing").foregroundStyle(PX.secondary)
            }
        case .done(let result)?:
            Text(result.text).font(PX.font(11.5)).foregroundStyle(PX.label).lineLimit(1)
        case .failed(let why)?:
            HStack(spacing: 5.5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(PX.orange.color())
                Text(why).font(PX.font(11.5)).foregroundStyle(PX.soft).lineLimit(1).truncationMode(.tail)
            }
            .help(why)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func button(_ model: RunnerModel) -> some View {
        if model.generates {
            PXButton(title: "Speed", symbol: "speedometer", enabled: !busy, height: 24, action: measure)
                .help("Sends this model one short prompt and times the answer: tokens a second, and how long the first one took. \(model.runner.title) counts it as use, so the model's unload time starts again.")
        } else {
            Text("Embedding")
                .font(PX.font(11.5))
                .foregroundStyle(PX.tertiary)
                .help("An embedding model does not answer prompts, so it cannot be timed this way.")
        }
    }
}

extension LoadedModelsPanel {
    fileprivate static func columnWidths(_ isWide: Bool) -> [CGFloat] { (isWide ? wide : narrow).map(\.width) }
}

// MARK: - Installed

struct InstalledModelsPanel: View {
    var installed: [RunnerModel]
    /// Ids of the models that are in memory, to mark them here.
    var loaded: Set<String>
    var columns: Int
    var width: CGFloat
    @State private var showAll = false

    var body: some View {
        let limit = columns == 2 ? 16 : 8
        let shown = showAll ? installed : Array(installed.prefix(limit))
        // Zero when no runner gave a size, and the rows then go without their strips.
        let largest = Double(installed.compactMap(\.size).max() ?? 0)
        PXPanel(title: "Installed", caption: caption, width: width) {
            VStack(alignment: .leading, spacing: 0) {
                if installed.isEmpty {
                    PXDivider().padding(.top, 14)
                    EmptyLine(text: "No models on disk that a runner lists.")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    let half = columns == 2 ? (shown.count + 1) / 2 : shown.count
                    HStack(alignment: .top, spacing: 0) {
                        column(Array(shown.prefix(half)), largest: largest)
                        if columns == 2 {
                            column(Array(shown.dropFirst(half)), largest: largest)
                        }
                    }
                    if installed.count > limit {
                        PXButton(title: showAll ? "Show fewer" : "Show all \(installed.count)", style: .ghost, height: 24) { showAll.toggle() }
                            .padding(.horizontal, PX.inset - 8)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private var caption: String? {
        guard !installed.isEmpty else { return nil }
        let bytes = installed.compactMap(\.size).reduce(0, +)
        let count = "\(installed.count) \(installed.count == 1 ? "model" : "models")"
        return bytes > 0 ? "\(count) · \(Format.data(bytes)) on disk" : count
    }

    private func column(_ models: [RunnerModel], largest: Double) -> some View {
        VStack(spacing: 0) {
            TableHeader(first: "Model", columns: [RunnerColumn(title: "On disk", width: 76)])
            PXDivider()
            VStack(spacing: 1) {
                ForEach(models) { model in
                    InstalledModelRow(model: model, isLoaded: loaded.contains(model.id) || loaded.contains(model.runner.rawValue + "|" + model.title), fraction: largest > 0 ? Double(model.size ?? 0) / largest : nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct InstalledModelRow: View {
    var model: RunnerModel
    var isLoaded: Bool
    /// Its size against the largest on disk; nil when no size is known for any of them.
    var fraction: Double?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(isLoaded ? PX.green : Color.white.opacity(0.16))
                .frame(width: 6, height: 6)
                .padding(.trailing, 9)
                .help(isLoaded ? "Loaded now" : "On disk, not loaded")
            Text(model.title)
                .font(PX.font(12, .medium))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .truncationMode(.middle)
            RunnerTag(kind: model.runner)
            Spacer(minLength: 10)
            if let make = RunnersMeter.make(model) {
                Text(make)
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 14)
            }
            if let fraction {
                MiniMatrixBar(fraction: model.size == nil ? 0 : max(fraction, 0.02), rgb: model.runner.rgb)
                    .frame(width: 96)
            }
            Text(model.size.map(Format.data) ?? "—")
                .foregroundStyle(model.size == nil ? PX.tertiary : PX.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .font(PX.font(12))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(hovering ? PX.rowHover : .clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - Runners

struct RunnersPanel: View {
    var runners: [RunnersModel.Runner]
    /// The Mac's memory, which each runner's own is drawn against.
    var total: UInt64
    var width: CGFloat

    private static let wide = [
        RunnerColumn(title: "Models", width: 250), RunnerColumn(title: "Processes", width: 96), RunnerColumn(title: "Memory", width: 200),
        RunnerColumn(title: "CPU", width: 76), RunnerColumn(title: "GPU", width: 76),
    ]
    private static let narrow = [RunnerColumn(title: "Memory", width: 84), RunnerColumn(title: "CPU", width: 64), RunnerColumn(title: "GPU", width: 64)]

    var body: some View {
        let isWide = width > 900
        PXPanel(title: "Runners", caption: "what each one's own processes are using", width: width) {
            VStack(spacing: 0) {
                TableHeader(first: "Runner", columns: isWide ? Self.wide : Self.narrow)
                PXDivider()
                VStack(spacing: 1) {
                    ForEach(runners) { runner in
                        row(runner, wide: isWide)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func status(_ runner: RunnersModel.Runner) -> String {
        guard runner.answering else { return "not answering on port \(runner.port)" }
        if runner.loaded == 0, runner.installed == nil, let note = runner.note { return note }
        var parts = [runner.loaded == 0 ? "none loaded" : "\(runner.loaded) loaded"]
        if let installed = runner.installed { parts.append(installed == 0 ? "none on disk" : "\(installed) on disk") }
        return parts.joined(separator: " · ")
    }

    private func row(_ runner: RunnersModel.Runner, wide: Bool) -> some View {
        let process = runner.process
        let columns = (wide ? Self.wide : Self.narrow).map(\.width)
        let about = [runner.version, "port \(runner.port)"].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 0) {
            Group {
                if let path = process?.bundlePath {
                    Image(nsImage: IconCache.icon(forBundlePath: path)).resizable().interpolation(.high)
                } else {
                    MeterIconView(icon: .symbol(runner.kind.symbol), rgb: runner.kind.rgb, size: 13)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(runner.kind.title)
                        .font(PX.font(12, .medium))
                        .foregroundStyle(PX.label)
                        .lineLimit(1)
                    Text(about)
                        .font(PX.font(11))
                        .foregroundStyle(PX.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 7)
                }
                if !wide {
                    Text(status(runner))
                        .font(PX.font(11.5))
                        .foregroundStyle(runner.answering ? PX.tertiary : PX.orange.color(0.9))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 9)
            Spacer(minLength: 10)
            if wide {
                Text(status(runner))
                    .foregroundStyle(runner.answering ? PX.secondary : PX.orange.color(0.9))
                    .lineLimit(1)
                    .frame(width: columns[0], alignment: .trailing)
                Text(process.map { "\($0.count)" } ?? "—")
                    .foregroundStyle(process == nil ? PX.tertiary : PX.secondary)
                    .frame(width: columns[1], alignment: .trailing)
                HStack(spacing: 0) {
                    MiniMatrixBar(fraction: process.map { $0.memory == 0 ? 0 : max(Double($0.memory) / Double(max(total, 1)), 0.02) } ?? 0, rgb: runner.kind.rgb)
                        .frame(width: 96)
                    Text(process.map { Format.bytes($0.memory) } ?? "—")
                        .foregroundStyle(process == nil ? PX.tertiary : PX.label)
                        .frame(width: 84, alignment: .trailing)
                }
                .frame(width: columns[2], alignment: .trailing)
                Text(process.map { Format.cpu($0.cpu) } ?? "—")
                    .foregroundStyle(process == nil ? PX.tertiary : PX.secondary)
                    .frame(width: columns[3], alignment: .trailing)
                Text(process.map { AppTablePanel.share($0.gpu) } ?? "—")
                    .foregroundStyle(process == nil ? PX.tertiary : PX.secondary)
                    .frame(width: columns[4], alignment: .trailing)
            } else {
                Text(process.map { Format.bytes($0.memory) } ?? "—")
                    .foregroundStyle(process == nil ? PX.tertiary : PX.label)
                    .frame(width: columns[0], alignment: .trailing)
                Text(process.map { Format.cpu($0.cpu) } ?? "—")
                    .foregroundStyle(process == nil ? PX.tertiary : PX.secondary)
                    .frame(width: columns[1], alignment: .trailing)
                Text(process.map { AppTablePanel.share($0.gpu) } ?? "—")
                    .foregroundStyle(process == nil ? PX.tertiary : PX.secondary)
                    .frame(width: columns[2], alignment: .trailing)
            }
        }
        .font(PX.font(12))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: wide ? 32 : 44)
        .help(process == nil ? "\(runner.kind.title) answers on its port, but none of its processes could be found among this user's." : "")
    }
}

// MARK: - Nothing found

/// A Mac with no runner on it: what is looked for, and nothing else.
struct NoRunnersCard: View {
    var width: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppSection.models.rgb.color(0.14))
                Image(systemName: AppSection.models.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppSection.models.rgb.color())
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text("No model runner found on this Mac.")
                    .font(PX.font(13, .medium))
                    .tracking(PX.tracking(13))
                    .foregroundStyle(PX.text)
                Text("\(App.name) looks for Ollama, LM Studio, llama.cpp's server and MLX's server, by their processes and on their own ports on this Mac.")
                    .font(PX.font(12))
                    .foregroundStyle(PX.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PX.inset)
        .padding(.vertical, 20)
        .frame(width: width, alignment: .leading)
        .pxCard()
    }
}
