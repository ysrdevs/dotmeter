import Foundation
import Observation

/// Local AI models: what is running them on this Mac, which models are loaded and what they hold.
///
/// Runners are found two ways. Their loopback ports are asked what is loaded and what is on disk, and their
/// processes are picked out of the reading the app already takes, which gives memory, processor and graphics
/// use even when a runner's API says little. Nothing is asked unless the Models area is on screen: the page
/// calls `refresh` once for each new reading it shows, and nothing else does.
@MainActor
@Observable
final class RunnersModel {
    struct Loaded: Identifiable, Equatable {
        var model: RunnerModel
        /// Its place in the palette, kept for as long as it stays loaded.
        var tone: Int
        var id: String { model.id }
    }

    struct Runner: Identifiable, Equatable {
        var kind: RunnerKind
        var port: Int
        var version: String?
        var answering: Bool
        var note: String?
        var process: RunnerProcess?
        var loaded: Int
        var installed: Int?
        var id: String { "\(kind.rawValue):\(port)" }
    }

    /// Everything the page shows, put together from the two sources.
    struct Picture: Equatable {
        var runners: [Runner] = []
        var loaded: [Loaded] = []
        var installed: [RunnerModel] = []

        /// What the loaded models hold together, counting only sizes that are known.
        var held: UInt64 { loaded.compactMap(\.model.size).reduce(0, +) }
    }

    enum Speed: Equatable {
        case running
        case done(RunnerSpeedResult)
        case failed(String)
    }

    /// Nil until the runners have been asked once.
    private(set) var readings: [RunnerReading]?
    private(set) var processes: [RunnerKind: RunnerProcess] = [:]
    /// The last speed test of each model, kept until the app quits.
    private(set) var speeds: [String: Speed] = [:]
    private(set) var loadedCount = 0

    /// Debug: DOTMETER_MODELS_DEMO=1 shows invented runners and models and asks nothing; `empty` shows the page
    /// as it is on a Mac with no runner.
    @ObservationIgnored let demo = ProcessInfo.processInfo.environment["DOTMETER_MODELS_DEMO"].flatMap { $0 == "0" ? nil : $0 }
    @ObservationIgnored let endpoints = RunnerEndpoints.from(ProcessInfo.processInfo.environment)
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var tick = 0
    /// The refresh at which each address last failed to answer.
    @ObservationIgnored private var quiet: [URL: Int] = [:]
    @ObservationIgnored private var installedAt: Int?
    @ObservationIgnored private var versionAt: Int?
    @ObservationIgnored private var lmVariant: String?
    @ObservationIgnored private var llamaDetails: [URL: RunnerReader.LlamaDetail] = [:]
    @ObservationIgnored private var tones: [String: Int] = [:]
    @ObservationIgnored private var known: [Int32: (name: String, kind: RunnerKind?, arguments: [String]?)] = [:]
    @ObservationIgnored private var bundleVersions: [String: String] = [:]
    @ObservationIgnored private var debugSpeed = ProcessInfo.processInfo.environment["DOTMETER_MODELS_SPEED"]
    @ObservationIgnored private let demoStart = Date()

    init() {
        if demo != nil { loadedCount = RunnersDemo.picture(demo, since: demoStart).loaded.count }
    }

    /// What the sidebar shows beside "Models": how many are loaded, or nothing. The runners are only asked while
    /// the area is open, so the count is shown while it is fresh and dropped once it could have changed unseen.
    var sidebarValue: String {
        guard loadedCount > 0 else { return "" }
        if demo == nil, Date().timeIntervalSince(readAt ?? .distantPast) > 30 { return "" }
        return "\(loadedCount) loaded"
    }

    var isMeasuring: Bool { speeds.values.contains(.running) }

    // MARK: Reading

    /// Called by the Models page for each new reading it shows. Picks the runners' processes out of that reading,
    /// and asks their ports off the main thread, one round at a time.
    func refresh(with snapshot: Snapshot) {
        if demo != nil {
            pressDebugSpeed()
            return
        }
        let found = match(snapshot.processes)
        if found != processes { processes = found }
        guard !asking else { return }
        asking = true
        tick += 1
        let tick = tick

        func due(_ base: URL, present: Bool, every: Int = 5) -> Bool {
            // An address that refused, with no process behind it, is tried again every fifth refresh.
            guard !present, let failed = quiet[base] else { return true }
            return (tick - failed) % every == 0
        }
        var ollama: (base: URL, installed: Bool, version: Bool)?
        if let base = endpoints.ollama, due(base, present: found[.ollama] != nil) {
            // What is on disk changes when someone pulls a model, so that list is asked for now and then.
            ollama = (base, installedAt.map { tick - $0 >= 8 } ?? true, versionAt.map { tick - $0 >= 150 } ?? true)
        }
        var lmStudio: (base: URL, variant: String?)?
        if let base = endpoints.lmStudio, due(base, present: found[.lmStudio] != nil) { lmStudio = (base, lmVariant) }
        var local: [(base: URL, mlx: (found: Bool, model: String?), known: RunnerReader.LlamaDetail?)] = []
        let mlx = found[.mlx]
        if let base = endpoints.local {
            local.append((base, (endpoints.localKind == .mlx || mlx != nil, endpoints.localModel ?? mlx?.model), llamaDetails[base]))
        } else {
            var ports = RunnerEndpoints.localPorts
            for port in (found[.llamaCpp]?.ports ?? []) + (mlx?.ports ?? []) where !ports.contains(port) { ports.append(port) }
            for port in ports {
                let base = RunnerEndpoints.local(port: port)
                // A server with no port on its command line is on its usual one.
                let isMLX = mlx.map { $0.ports.contains(port) || ($0.ports.isEmpty && port == 8080) } ?? false
                let isLlama = found[.llamaCpp].map { $0.ports.contains(port) || $0.ports.isEmpty } ?? false
                // With no such process in sight, these ports most likely belong to something else: a look every
                // half minute is enough to find a server run by another user or in a container.
                if due(base, present: isLlama || isMLX, every: 15) { local.append((base, (isMLX, mlx?.model), llamaDetails[base])) }
            }
        }

        let askOllama = ollama, askLMStudio = lmStudio, askLocal = local
        Task.detached(priority: .utility) { [weak self] in
            async let first: RunnerReading? = askOllama == nil ? nil : await RunnerReader.ollama(base: askOllama!.base, installed: askOllama!.installed, version: askOllama!.version)
            async let second: RunnerReading? = askLMStudio == nil ? nil : await RunnerReader.lmStudio(base: askLMStudio!.base, variant: askLMStudio!.variant)
            var answers: [RunnerReading] = []
            var details: [URL: RunnerReader.LlamaDetail] = [:]
            var silent: [URL] = []
            await withTaskGroup(of: (URL, (reading: RunnerReading, detail: RunnerReader.LlamaDetail?)?).self) { group in
                for ask in askLocal {
                    group.addTask { (ask.base, await RunnerReader.local(base: ask.base, mlx: ask.mlx, known: ask.known)) }
                }
                for await (base, answer) in group {
                    if let answer {
                        answers.append(answer.reading)
                        details[base] = answer.detail
                    } else {
                        silent.append(base)
                    }
                }
            }
            let asked = [await first, await second].compactMap { $0 }
            answers.sort { $0.base.absoluteString < $1.base.absoluteString }
            let all = asked + answers
            let failed = silent + asked.filter { !$0.answered }.map(\.base)
            await self?.apply(all, details: details, silent: failed, tick: tick, askedInstalled: askOllama?.installed == true, askedVersion: askOllama?.version == true)
        }
    }

    private func apply(_ fresh: [RunnerReading], details: [URL: RunnerReader.LlamaDetail], silent: [URL], tick: Int, askedInstalled: Bool, askedVersion: Bool) {
        asking = false
        readAt = Date()
        let old = readings ?? []
        var next = fresh.map { reading -> RunnerReading in
            var reading = reading
            // What was not asked for this time still stands.
            if let before = old.first(where: { $0.base == reading.base && $0.kind == reading.kind }), reading.answered {
                if reading.installed == nil { reading.installed = before.installed }
                if reading.version == nil { reading.version = before.version }
            }
            return reading
        }
        // An address that was not due this time keeps what it last said.
        let untouched = Set(next.map(\.base)).union(silent)
        next += old.filter { !untouched.contains($0.base) }

        for base in silent { if quiet[base] == nil { quiet[base] = tick } }
        for reading in next where reading.answered { quiet[reading.base] = nil }
        for (base, detail) in details { llamaDetails[base] = detail }
        lmVariant = next.first { $0.kind == .lmStudio && $0.answered }?.variant

        if let ollama = fresh.first(where: { $0.kind == .ollama }), ollama.answered {
            if askedInstalled { installedAt = tick }
            if askedVersion, ollama.version != nil { versionAt = tick }
            // A model that has just appeared may have just been pulled: ask for the list on disk again.
            if let before = old.first(where: { $0.kind == .ollama && $0.answered }), !Set(ollama.loaded.map(\.id)).isSubset(of: before.loaded.map(\.id)) {
                installedAt = nil
            }
        } else {
            installedAt = nil
            versionAt = nil
        }

        // Colours are handed out largest first, the order the bar and the list show them in.
        let ids = next.flatMap(\.loaded).sorted { ($0.size ?? 0) > ($1.size ?? 0) }.map(\.id)
        for key in tones.keys where !ids.contains(key) { tones[key] = nil }
        for id in ids where tones[id] == nil {
            let used = Set(tones.values)
            tones[id] = (0..<PX.palette.count).first { !used.contains($0) } ?? tones.count
        }
        if readings != next { readings = next }
        if loadedCount != ids.count { loadedCount = ids.count }
        pressDebugSpeed()
    }

    /// The runners' processes among everything running. A process is classified once and remembered by its pid.
    private func match(_ all: [ProcessUsage]) -> [RunnerKind: RunnerProcess] {
        if tick % 30 == 29 {
            let alive = Set(all.map(\.pid))
            known = known.filter { alive.contains($0.key) }
        }
        var mine: [(process: ProcessUsage, kind: RunnerKind, arguments: [String]?)] = []
        for process in all {
            var entry = known[process.pid]
            if entry?.name != process.name {
                var arguments: [String]?
                let kind = RunnerMatch.kind(name: process.name, path: process.path) {
                    arguments = ProcessArguments.read(process.pid)
                    return arguments
                }
                // A server with no fixed port says on its command line where it listens and what it has loaded.
                if kind == .llamaCpp || kind == .mlx, arguments == nil { arguments = ProcessArguments.read(process.pid) }
                entry = (process.name, kind, kind == nil ? nil : arguments)
                known[process.pid] = entry
            }
            if let kind = entry?.kind { mine.append((process, kind, entry?.arguments)) }
        }
        let found = RunnerMatch.usage(of: mine)
        for path in found.values.compactMap(\.bundlePath) where bundleVersions[path] == nil {
            bundleVersions[path] = (NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? ""
        }
        return found
    }

    // MARK: What the page shows

    var picture: Picture? {
        if demo != nil { return RunnersDemo.picture(demo, since: demoStart) }
        guard let readings else { return nil }
        return Self.picture(readings: readings, processes: processes, tones: tones, bundleVersions: bundleVersions)
    }

    static func picture(readings: [RunnerReading], processes: [RunnerKind: RunnerProcess], tones: [String: Int] = [:], bundleVersions: [String: String] = [:]) -> Picture {
        var picture = Picture()
        for kind in RunnerKind.allCases {
            let process = processes[kind]
            let answered = readings.filter { $0.kind == kind && $0.answered }
            // LM Studio's API has no version in it; its app does.
            let appVersion = process?.bundlePath.flatMap { bundleVersions[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            for reading in answered {
                picture.runners.append(Runner(
                    kind: kind, port: reading.port, version: reading.version ?? appVersion, answering: true, note: reading.note,
                    process: process, loaded: reading.loaded.count, installed: reading.installed?.count
                ))
                let held = RunnerMath.held(sizes: reading.loaded.map(\.size), process: process?.memory)
                for (index, model) in reading.loaded.enumerated() {
                    var model = model
                    if model.size == nil, held[index] != nil {
                        model.size = held[index]
                        model.sizeSource = .process
                    }
                    picture.loaded.append(Loaded(model: model, tone: tones[model.id] ?? picture.loaded.count))
                }
                picture.installed += reading.installed ?? []
            }
            if answered.isEmpty, let process {
                let port: Int
                switch kind {
                case .ollama: port = 11434
                case .lmStudio: port = 1234
                case .llamaCpp, .mlx: port = process.ports.first ?? 8080
                }
                picture.runners.append(Runner(kind: kind, port: port, version: appVersion, answering: false, process: process, loaded: 0))
            }
        }
        picture.installed.sort { ($0.size ?? 0, $1.title) > ($1.size ?? 0, $0.title) }
        // Largest first, the order the bar draws them in.
        picture.loaded.sort { ($0.model.size ?? 0, $1.id) > ($1.model.size ?? 0, $0.id) }
        return picture
    }

    // MARK: Speed

    /// One short prompt to a model that is in memory, on the user's click. One test at a time, since two at once
    /// would slow each other.
    func measureSpeed(_ id: String) {
        guard !isMeasuring, let model = picture?.loaded.first(where: { $0.id == id })?.model, model.generates else { return }
        speeds[id] = .running
        if demo != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1400))
                self?.speeds[id] = .done(RunnersDemo.speed(for: id))
            }
            return
        }
        guard let reading = readings?.first(where: { reading in reading.answered && reading.loaded.contains { $0.id == id } }),
              let asked = reading.loaded.first(where: { $0.id == id }) else {
            speeds[id] = .failed("No longer loaded")
            return
        }
        let base = reading.base, variant = reading.variant
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await RunnerSpeed.measure(asked, base: base, variant: variant)
            await self?.finish(id, outcome)
        }
    }

    private func finish(_ id: String, _ outcome: RunnerSpeed.Outcome) {
        switch outcome {
        case .done(let result): speeds[id] = .done(result)
        case .failed(let why): speeds[id] = .failed(why)
        }
        if ProcessInfo.processInfo.environment["DOTMETER_MODELS_SPEED"] != nil {
            print("SPEED \(id) \(speeds[id].map { "\($0)" } ?? "")")
            fflush(stdout)
        }
    }

    /// Debug: DOTMETER_MODELS_SPEED=<model name> presses that model's Speed button once it shows as loaded
    /// (`first` presses the first). Only with made-up data or a stand-in: a test never sends a prompt to a real
    /// runner by itself.
    private func pressDebugSpeed() {
        guard let wanted = debugSpeed, let loaded = picture?.loaded, !loaded.isEmpty else { return }
        debugSpeed = nil
        guard let target = wanted == "first" ? loaded.first : loaded.first(where: { $0.model.name == wanted || $0.model.title == wanted }) else {
            print("SPEED not pressed: \(wanted) is not loaded")
            return
        }
        let standIn: Bool
        switch target.model.runner {
        case .ollama: standIn = endpoints.standIns.contains("ollama")
        case .lmStudio: standIn = endpoints.standIns.contains("lmStudio")
        case .llamaCpp, .mlx: standIn = endpoints.standIns.contains("local")
        }
        guard demo != nil || standIn else {
            print("SPEED not pressed: \(target.model.runner.title) is not a stand-in")
            return
        }
        measureSpeed(target.id)
    }

    // MARK: Explain

    /// What is loaded and what it holds, as text for the assistant.
    func explainText(memory: MemoryStats?) -> String? {
        Self.explain(picture, speeds: speeds, memory: memory, now: Date())
    }

    static func explain(_ picture: Picture?, speeds: [String: Speed], memory: MemoryStats?, now: Date) -> String? {
        guard let picture else { return nil }
        guard !picture.runners.isEmpty else {
            return "Local AI models: no model runner was found on this Mac (\(App.name) looks for Ollama, LM Studio, llama.cpp's server and MLX's server)."
        }
        var lines: [String] = []
        lines.append("Model runners found: " + picture.runners.map { runner in
            var text = runner.kind.title + (runner.version.map { " \($0)" } ?? "") + (runner.answering ? "" : " (not answering on port \(runner.port))")
            if let process = runner.process {
                text += ", its \(process.count == 1 ? "process holds" : "\(process.count) processes hold") \(Format.bytes(process.memory)) and use \(Format.cpu(process.cpu)) CPU and \(Format.percent(process.gpu)) of the graphics cores' time"
            }
            if let note = runner.note { text += ", \(note)" }
            return text
        }.joined(separator: "; ") + ".")
        if picture.loaded.isEmpty {
            lines.append("No model is loaded right now.")
        } else {
            var total = "Loaded models hold \(Format.bytes(picture.held)) together"
            if let memory { total += " of this Mac's \(Format.bytes(memory.total)), with \(Format.bytes(memory.total > memory.used ? memory.total - memory.used : 0)) free" }
            lines.append(total + ":")
            for loaded in picture.loaded {
                let model = loaded.model
                var facts = [model.parameters.map { "\($0) parameters" }, model.quantization]
                switch (model.size, model.sizeSource) {
                case (let size?, .reported): facts.append("holds \(Format.bytes(size))")
                case (let size?, .file): facts.append("\(Format.bytes(size)) on disk (the runner does not say what it holds in memory)")
                case (let size?, .process): facts.append("about \(Format.bytes(size)), going by its runner's processes")
                case (nil, _): facts.append("size unknown")
                }
                facts.append(RunnerMath.placement(size: model.size, onGraphics: model.onGraphics))
                facts.append(model.context.map { "context \($0) tokens" })
                facts.append(RunnerMath.unloads(model.expires, now: now))
                if case .done(let result)? = speeds[model.id] { facts.append("last speed test \(result.text)") }
                lines.append("- \(model.title) on \(model.runner.title): " + facts.compactMap { $0 }.joined(separator: ", "))
            }
        }
        if !picture.installed.isEmpty {
            let onDisk = picture.installed.compactMap(\.size).reduce(0, +)
            lines.append("Installed: \(picture.installed.count) models\(onDisk > 0 ? ", \(Format.data(onDisk)) on disk" : ""). Largest: " + picture.installed.prefix(8).map { "\($0.title)\($0.size.map { " \(Format.data($0))" } ?? "")" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Made-up data

/// Invented runners and models for captures. The products are real; every model name, size and figure is made up.
enum RunnersDemo {
    private static func model(_ runner: RunnerKind, _ name: String, _ parameters: String?, _ quantization: String?, _ gigabytes: Double,
                              graphics: Double? = nil, context: Int? = nil, expires: Date? = nil, generates: Bool = true, source: RunnerModel.SizeSource = .reported) -> RunnerModel {
        let size = UInt64(gigabytes * 1_073_741_824)
        return RunnerModel(runner: runner, name: name, title: name, parameters: parameters, quantization: quantization, size: size, sizeSource: source,
                           onGraphics: graphics.map { UInt64(Double(size) * $0) }, context: context, expires: expires, generates: generates)
    }

    static func picture(_ kind: String?, since start: Date) -> RunnersModel.Picture {
        guard kind != "empty" else { return RunnersModel.Picture() }
        var picture = RunnersModel.Picture()
        let loaded = [
            model(.ollama, "aurora:70b", "70.6B", "Q4_K_M", 46.2, graphics: 1, context: 32_768, expires: start.addingTimeInterval(262)),
            model(.lmStudio, "Meridian 120B", "120B", "6bit", 85.0, context: 65_536, source: .file),
            model(.ollama, "lantern-coder:32b", "32.8B", "Q5_K_M", 24.9, graphics: 1, context: 16_384, expires: start.addingTimeInterval(1_740)),
            model(.ollama, "tidepool:8b", "8.0B", "Q4_K_M", 6.1, graphics: 0.71, context: 8_192, expires: start.addingTimeInterval(4 * 3600)),
            model(.llamaCpp, "quartz-mini-3b-Q5_K_M", "3.2B", "Q5_K_M", 2.2, context: 8_192, source: .file),
        ]
        picture.loaded = loaded.enumerated().map { RunnersModel.Loaded(model: $1, tone: $0) }.sorted { ($0.model.size ?? 0) > ($1.model.size ?? 0) }
        let onDisk: [(RunnerKind, String, String?, String?, Double)] = [
            (.lmStudio, "Meridian 120B", "120B", "6bit", 91.3), (.ollama, "aurora:70b", "70.6B", "Q4_K_M", 42.5), (.ollama, "glacier:72b", "72.7B", "Q4_K_M", 47.4),
            (.lmStudio, "Quince 27B", "27B", "Q4_K_M", 18.0), (.ollama, "lantern-coder:32b", "32.8B", "Q5_K_M", 23.2), (.ollama, "ember-vision:11b", "10.7B", "Q4_K_M", 7.9),
            (.ollama, "tidepool:8b", "8.0B", "Q4_K_M", 4.9), (.lmStudio, "Sorrel 14B", "14B", "8bit", 15.6), (.llamaCpp, "quartz-mini-3b-Q5_K_M", "3.2B", "Q5_K_M", 2.3),
            (.ollama, "wren:3b", "3.2B", "Q4_K_M", 2.0), (.ollama, "pebble-embed:latest", "137M", "F16", 0.27), (.lmStudio, "Pebble Embed v2", nil, "F16", 0.27),
        ]
        picture.installed = onDisk.map { runner, name, parameters, quantization, gigabytes in
            var entry = model(runner, name, parameters, quantization, 0, source: .file)
            entry.size = UInt64(gigabytes * 1e9)
            return entry
        }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        func gib(_ value: Double) -> UInt64 { UInt64(value * 1_073_741_824) }
        picture.runners = [
            RunnersModel.Runner(kind: .ollama, port: 11434, version: "0.15.4", answering: true, process: RunnerProcess(memory: gib(78.6), cpu: 2.12, gpu: 0.64, count: 4), loaded: 3, installed: 7),
            RunnersModel.Runner(kind: .lmStudio, port: 1234, version: "0.4.2", answering: true, process: RunnerProcess(memory: gib(87.3), cpu: 0.06, gpu: 0, count: 7), loaded: 1, installed: 4),
            RunnersModel.Runner(kind: .llamaCpp, port: 8080, version: "b6123", answering: true, process: RunnerProcess(memory: gib(2.6), cpu: 0.004, gpu: 0, count: 1), loaded: 1, installed: 1),
        ]
        return picture
    }

    /// A made-up result, different for each model and the same every time.
    static func speed(for id: String) -> RunnerSpeedResult {
        let seed = Double(id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 })
        return RunnerSpeedResult(tokensPerSecond: 18 + seed.truncatingRemainder(dividingBy: 61), firstToken: 0.18 + seed.truncatingRemainder(dividingBy: 7) / 10, tokens: RunnerSpeed.tokens)
    }
}
