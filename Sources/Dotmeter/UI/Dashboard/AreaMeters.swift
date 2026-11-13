import AppKit
import SwiftUI

/// Turns a system snapshot into card models. Keeps each app's color stable while it stays on screen.
@MainActor
final class AreaMeters {
    private var cpuColors: [String: Int] = [:]
    private var memoryColors: [String: Int] = [:]
    private var networkColors: [String: Int] = [:]
    private var gpuColors: [String: Int] = [:]
    private var powerColors: [String: Int] = [:]

    /// The footer's button when it names an app: quit it, in two clicks. nil when the app cannot be quit
    /// from here, so the caller can offer something else.
    private func quitAction(_ app: AppUsage?, _ control: QuitModel?) -> MeterAction? {
        guard let app, let control, ProcessControl.canQuit(app) else { return nil }
        if control.pending[app.id] != nil {
            return MeterAction(title: "Quitting", symbol: "arrow.triangle.2.circlepath", spinning: true, enabled: false) {}
        }
        let armed = control.isArmed(app.id, force: false)
        return MeterAction(title: armed ? "Confirm quit" : "Quit", symbol: armed ? nil : "xmark", destructive: armed) {
            control.request(app, force: false)
        }
    }

    private static func percent(_ v: Double) -> String {
        v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }

    private static func gigabytes(_ v: Double) -> String {
        v < 0.1 ? "\(Int((v * 1024).rounded())) MB" : String(format: "%.1f GB", v)
    }

    private func color(for id: String, among ids: [String], table: inout [String: Int]) -> RGB {
        for key in table.keys where !ids.contains(key) { table[key] = nil }
        if let index = table[id] { return PX.palette[index % PX.palette.count] }
        let used = Set(table.values)
        let index = (0..<PX.palette.count).first { !used.contains($0) } ?? table.count
        table[id] = index
        return PX.palette[index % PX.palette.count]
    }

    // MARK: CPU

    func cpu(_ s: Snapshot, count: Int = 8, details: (() -> Void)? = nil, control: QuitModel? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        let cores = max(s.cpu.perCore.count, 1)
        let top = Array(s.apps.prefix(count))
        let ids = top.map(\.id)
        var items: [MeterItem] = top.map { app in
            var detail = "A single process holding \(Format.bytes(app.memory))."
            if app.processCount > 1, let busiest = app.children.first {
                detail = "\(app.processCount) processes. \(busiest.name) is the busiest at \(Format.cpu(busiest.cpu))."
            }
            return MeterItem(
                id: app.id, name: app.name, icon: .image(IconCache.icon(for: app)),
                rgb: color(for: app.id, among: ids, table: &cpuColors),
                amount: app.cpu, number: app.cpu * 100, format: Self.percent, detail: detail
            )
        }
        let busy = s.cpu.total * Double(cores)
        let rest = max(0, busy - top.reduce(0) { $0 + $1.cpu })
        items.append(MeterItem(
            id: "other", name: "Everything else", icon: .swatch, rgb: PX.gray,
            amount: rest, number: rest * 100, format: Self.percent,
            detail: "macOS services and \(max(s.processes.count - top.reduce(0) { $0 + $1.processCount }, 0)) smaller processes."
        ))

        var footer: MeterFooter = .success("Nothing is working hard right now.")
        if let first = top.first, first.cpu >= 1 {
            let whole = Int(first.cpu.rounded())
            let coresText = whole >= 2 ? "about \(whole) cores" : "a full core"
            footer = .suggestion(
                icon: .image(IconCache.icon(for: first)), rgb: PX.blue,
                text: "\(first.name) is using \(Format.cpu(first.cpu)) CPU, \(coresText).",
                action: quitAction(first, control) ?? MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude)
            )
        }

        let pinned = s.cpu.perCore.filter { $0 > 0.8 }.count
        let load = String(format: "%.1f", s.cpu.loadAverage.first ?? 0)
        return MeterModel(
            number: s.cpu.total * 100,
            numberFormat: { "\(Int($0.rounded()))%" },
            caption: "of \(cores) cores busy",
            status: .plain(pinned > 0 ? "\(pinned) \(pinned == 1 ? "core" : "cores") pinned · load \(load)" : "No core pinned · load \(load)"),
            items: items,
            capacity: Double(cores),
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    // MARK: Memory

    func memory(_ s: Snapshot, count: Int = 6, details: (() -> Void)? = nil, control: QuitModel? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        let gib = 1_073_741_824.0
        let m = s.memory
        let top = Array(s.apps.sorted { $0.memory > $1.memory }.prefix(count))
        let ids = top.map(\.id)
        let appBudget = max(0, Double(m.used) - Double(m.wired) - Double(m.compressed))
        let topSum = top.reduce(0.0) { $0 + Double($1.memory) }
        // Footprints can overlap what the kernel counts as app memory; never let the bar exceed what is used.
        let scale = topSum > appBudget && topSum > 0 ? appBudget / topSum : 1

        var items: [MeterItem] = top.map { app in
            var detail = "A single process using \(Format.cpu(app.cpu)) CPU."
            if app.processCount > 1, let largest = app.children.max(by: { $0.memory < $1.memory }) {
                detail = "\(app.processCount) processes. \(largest.name) holds the most at \(Format.bytes(largest.memory))."
            }
            return MeterItem(
                id: app.id, name: app.name, icon: .image(IconCache.icon(for: app)),
                rgb: color(for: app.id, among: ids, table: &memoryColors),
                amount: Double(app.memory) * scale, number: Double(app.memory) / gib, format: Self.gigabytes, detail: detail
            )
        }
        let others = max(0, appBudget - topSum * scale)
        items.append(MeterItem(id: "others", name: "Everything else", icon: .swatch, rgb: PX.gray, amount: others, number: others / gib, format: Self.gigabytes, detail: "Smaller apps, graphics memory and macOS services."))
        items.append(MeterItem(id: "wired", name: "Wired", icon: .symbol("lock.fill"), rgb: PX.orange, amount: Double(m.wired), number: Double(m.wired) / gib, format: Self.gigabytes, detail: "Memory macOS itself needs and cannot move."))
        items.append(MeterItem(id: "compressed", name: "Compressed", icon: .symbol("rectangle.compress.vertical"), rgb: PX.red, amount: Double(m.compressed), number: Double(m.compressed) / gib, format: Self.gigabytes, detail: "Squeezed to make room. A lot of it means memory is tight."))

        let free = m.total > m.used ? m.total - m.used : 0
        var status = "\(Format.bytes(free)) available"
        if m.pressure != .normal { status += " · \(m.pressure.title.lowercased()) pressure" }
        if m.swapUsed > 0 { status += " · \(Format.bytes(m.swapUsed)) swapped" }

        var footer: MeterFooter = .success("No memory pressure. Nothing is being swapped to disk.")
        if m.pressure != .normal || m.swapUsed > 0, let first = top.first {
            footer = .suggestion(
                icon: .image(IconCache.icon(for: first)), rgb: PX.orange,
                text: m.pressure != .normal ? "Memory is tight. \(first.name) is holding \(Format.bytes(first.memory))." : "\(Format.bytes(m.swapUsed)) is swapped to disk. \(first.name) holds \(Format.bytes(first.memory)).",
                action: quitAction(first, control) ?? MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude)
            )
        }

        return MeterModel(
            number: Double(m.used) / gib,
            numberFormat: { String(format: "%.1f GB", $0) },
            caption: "of \(Format.bytes(m.total)) used",
            status: .plain(status),
            items: items,
            capacity: Double(max(m.total, 1)),
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    /// What kind of memory is in use, rather than whose.
    func memoryComposition(_ s: Snapshot) -> MeterModel {
        let gib = 1_073_741_824.0
        let m = s.memory
        let reclaimable = Double(m.cached)
        let free = max(0, Double(m.total) - Double(m.used) - reclaimable)
        func item(_ id: String, _ name: String, _ symbol: String, _ rgb: RGB, _ bytes: Double, _ detail: String, inBar: Bool = true) -> MeterItem {
            MeterItem(id: id, name: name, icon: .symbol(symbol), rgb: rgb, amount: inBar ? bytes : 0, number: bytes / gib, format: Self.gigabytes, detail: detail, inBar: inBar)
        }
        let items = [
            item("app", "App memory", "app.fill", PX.blue, Double(m.app), "What your apps are actively holding."),
            item("wired", "Wired", "lock.fill", PX.orange, Double(m.wired), "Memory macOS itself needs and cannot move or compress."),
            item("compressed", "Compressed", "rectangle.compress.vertical", PX.red, Double(m.compressed), "Squeezed to make room. A lot of it means memory is tight."),
            item("cached", "Cached files", "doc.on.doc.fill", PX.cyan, reclaimable, "Recently used files kept around for speed. Given back the moment an app needs it."),
            item("free", "Free", "circle.dashed", PX.gray, free, "Not in use by anything.", inBar: false),
            item("swap", "Swap used", "arrow.left.arrow.right", m.swapUsed > 0 ? PX.yellow : PX.gray, Double(m.swapUsed), "Memory pushed out to disk. Anything here is slow to come back.", inBar: false),
        ]
        let available = free + reclaimable
        var footer: MeterFooter = .success("macOS reports no memory pressure.")
        if m.pressure == .warning { footer = .suggestion(icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.yellow, text: "Memory pressure is elevated. macOS is compressing to keep up.", action: nil) }
        if m.pressure == .critical { footer = .suggestion(icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.red, text: "Memory pressure is critical. Quit something large.", action: nil) }
        return MeterModel(
            number: available / gib,
            numberFormat: { String(format: "%.1f GB", $0) },
            caption: "available to apps",
            status: .plain("\(m.pressure.title) pressure · \(m.swapUsed > 0 ? Format.bytes(m.swapUsed) + " swapped" : "nothing swapped")"),
            items: items,
            capacity: Double(max(m.total, 1)),
            footer: footer
        )
    }

    // MARK: Thermal

    func thermal(_ s: Snapshot, details: (() -> Void)? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        let t = s.thermal
        let temperature = t.hottest?.celsius
        let low = 30.0
        let zones: [(String, RGB, Double, Double)] = [
            ("cool", PX.blue, 30, 55), ("warm", PX.greenRGB, 55, 75), ("hot", PX.orange, 75, 92), ("critical", PX.red, 92, 108),
        ]
        var items: [MeterItem] = zones.map { id, rgb, start, end in
            let amount = min(max((temperature ?? low) - start, 0), end - start)
            return MeterItem(id: id, name: id, icon: .swatch, rgb: rgb, amount: amount, number: amount, format: { _ in "" }, detail: "", inBar: true, inLegend: false)
        }

        func degrees(_ v: Double) -> String { "\(Int(v.rounded()))°" }
        if let cpu = t.cpuTemperature {
            let count = t.sensors.filter { $0.group == "CPU" }.count
            items.append(MeterItem(id: "cpuTemp", name: "CPU", icon: .symbol("cpu.fill"), rgb: Self.heatColor(cpu), amount: 0, number: cpu, format: degrees, detail: "Hottest of \(count) core sensors.", inBar: false))
        }
        if let gpu = t.gpuTemperature {
            items.append(MeterItem(id: "gpuTemp", name: "GPU", icon: .symbol("rectangle.3.group.fill"), rgb: Self.heatColor(gpu), amount: 0, number: gpu, format: degrees, detail: "Hottest graphics sensor. GPU load is \(Format.percent(s.gpu?.utilization ?? 0)).", inBar: false))
        }
        for fan in t.fans {
            items.append(MeterItem(
                id: "fan\(fan.index)", name: t.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan", icon: .symbol("fan.fill"), rgb: PX.cyan,
                amount: 0, number: fan.rpm, format: { "\(Format.rpm($0)) rpm" },
                detail: "\(Format.percent(fan.percent)) of its range, \(Format.rpm(fan.minRPM)) to \(Format.rpm(fan.maxRPM)) rpm.", inBar: false
            ))
        }
        items.append(MeterItem(id: "state", name: "macOS state", icon: .symbol("gauge.with.dots.needle.33percent"), rgb: Self.stateColor(t.state), amount: 0, number: 0, format: { _ in t.state.title }, detail: "What macOS reports. Above nominal it starts slowing things down.", inBar: false))
        if let limit = t.cpuSpeedLimit {
            items.append(MeterItem(id: "limit", name: "Speed limit", icon: .symbol("speedometer"), rgb: limit < 100 ? PX.red : PX.greenRGB, amount: 0, number: Double(limit), format: { "\(Int($0.rounded()))%" }, detail: "Share of full CPU speed macOS allows right now.", inBar: false))
        } else if let gpu = s.gpu {
            items.append(MeterItem(id: "gpuLoad", name: "GPU load", icon: .symbol("square.stack.3d.up.fill"), rgb: PX.purple, amount: 0, number: gpu.utilization * 100, format: { "\(Int($0.rounded()))%" }, detail: "How busy the graphics cores are.", inBar: false))
        }

        let extras: [(String, String, String, String)] = [
            ("Storage", "SSD", "internaldrive.fill", "Hottest storage sensor."),
            ("Airflow", "Airflow", "wind", "Air moving through the case."),
            ("Power", "Power", "bolt.fill", "Hottest power delivery sensor."),
            ("Memory", "Memory", "memorychip.fill", "Hottest memory sensor."),
        ]
        for (group, name, symbol, detail) in extras where items.filter(\.inLegend).count < 9 {
            let readings = t.sensors.filter { $0.group == group }.map(\.celsius)
            guard let hottest = readings.max() else { continue }
            items.append(MeterItem(id: "group." + group, name: name, icon: .symbol(symbol), rgb: Self.heatColor(hottest), amount: 0, number: hottest, format: degrees, detail: "\(detail) \(readings.count) sensors.", inBar: false))
        }

        let fanText = t.fans.isEmpty ? "No fans" : "Fans at \(Format.rpm(t.averageRPM)) rpm"
        var footer: MeterFooter = .success(t.fans.isEmpty ? "Nothing is running hot." : "Fans are near their minimum. Nothing is running hot.")
        let severity = Severity.from(s)
        if t.isThrottled, let limit = t.cpuSpeedLimit {
            footer = .suggestion(icon: .symbol("flame.fill"), rgb: PX.red, text: "macOS is limiting the CPU to \(limit)% to cool down.", action: MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude))
        } else if severity >= .elevated && (t.averageFanPercent >= 0.3 || (temperature ?? 0) >= 78) {
            let temp = temperature.map { " to hold \(degrees($0))" } ?? ""
            footer = .suggestion(icon: .symbol("flame.fill"), rgb: PX.orange, text: "\(fanText)\(temp).", action: MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude))
        }

        return MeterModel(
            number: temperature ?? 0,
            numberFormat: temperature == nil ? { _ in t.state.title } : degrees,
            caption: temperature == nil ? "thermal state" : (t.hottest?.group == "GPU" ? "GPU, hottest sensor" : "CPU, hottest core"),
            status: .plain("\(fanText) · \(Format.percent(t.averageFanPercent)) of range"),
            items: items,
            capacity: 108 - low,
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    // MARK: Network

    /// Who is using the connection. The bar has no natural whole, so it is drawn against a round figure
    /// just above the busiest moment of the last five minutes, and the status line says what that is.
    func network(_ s: Snapshot, history: [HistoryPoint], count: Int = 8, details: (() -> Void)? = nil, control: QuitModel? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        let n = s.network
        let total = n.total
        let recent = history.filter { s.timestamp.timeIntervalSince($0.time) <= 300 }
        let ceiling = NetScale.ceiling(max(recent.map(\.networkBytesPerSecond).max() ?? 0, total))
        let primary = n.primaryInterface

        var items: [MeterItem] = []
        if n.appsMeasured {
            let top = Array(n.apps.prefix(count))
            let ids = top.map(\.id)
            // Traffic through a tunnel shows up under the app and again under the tunnel's own process;
            // the bar never claims more than the interfaces carried.
            let sum = n.apps.reduce(0) { $0 + $1.rate }
            let scale = sum > total && sum > 0 ? total / sum : 1
            items = top.map { app in
                MeterItem(
                    // A bare process has no icon of its own; its segment color says more than a generic one.
                    id: app.id, name: app.name, icon: app.bundlePath == nil ? .swatch : .image(IconCache.icon(forBundlePath: app.bundlePath)),
                    rgb: color(for: app.id, among: ids, table: &networkColors),
                    amount: app.rate * scale, number: app.rate, format: Format.rate,
                    detail: "↓ \(Format.rate(app.inRate))  ↑ \(Format.rate(app.outRate)). \(Format.data(app.bytes)) over its open connections."
                )
            }
            let rest = max(0, total - top.reduce(0) { $0 + $1.rate } * scale)
            let quieter = max(n.apps.count - top.count, 0)
            items.append(MeterItem(
                id: "other", name: "Everything else", icon: .swatch, rgb: PX.gray,
                amount: rest, number: rest, format: Format.rate,
                detail: quieter > 0 ? "\(quieter) quieter apps and system services." : "System services."
            ))
        } else {
            items = [
                MeterItem(id: "down", name: "Download", icon: .symbol("arrow.down.circle.fill"), rgb: PX.cyan, amount: n.inBytesPerSecond, number: n.inBytesPerSecond, format: Format.rate, detail: "Arriving on \(primary?.title ?? "every port")."),
                MeterItem(id: "up", name: "Upload", icon: .symbol("arrow.up.circle.fill"), rgb: PX.pink, amount: n.outBytesPerSecond, number: n.outBytesPerSecond, format: Format.rate, detail: "Leaving on \(primary?.title ?? "every port")."),
                MeterItem(id: "received", name: "Received", icon: .symbol("tray.and.arrow.down.fill"), rgb: PX.gray, amount: 0, number: Double(n.inBytes), format: { Format.data(UInt64($0)) }, detail: "Since \(App.name) started.", inBar: false),
                MeterItem(id: "sent", name: "Sent", icon: .symbol("tray.and.arrow.up.fill"), rgb: PX.gray, amount: 0, number: Double(n.outBytes), format: { Format.data(UInt64($0)) }, detail: "Since \(App.name) started.", inBar: false),
            ]
        }

        var status = "Not connected"
        if let primary {
            status = ([primary.title] + [primary.address].compactMap { $0 } + ["full bar is \(Format.rate(ceiling))"]).joined(separator: " · ")
        }

        var footer: MeterFooter
        if !n.online {
            footer = .suggestion(
                icon: .symbol("wifi.slash"), rgb: PX.orange, text: "No network port has a route to the internet.",
                action: MeterAction(title: "Network Settings", symbol: "arrow.up.right") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            )
        } else if !n.appsMeasured && n.appsAvailable {
            footer = .searching("Working out which apps are using it")
        } else if let first = n.apps.first, n.appsMeasured, first.rate >= 1e6 {
            let downloading = first.inRate >= first.outRate
            footer = .suggestion(
                icon: first.bundlePath == nil ? .symbol(downloading ? "arrow.down.circle.fill" : "arrow.up.circle.fill") : .image(IconCache.icon(forBundlePath: first.bundlePath)),
                rgb: downloading ? NetScale.down : NetScale.up,
                text: "\(first.name) is \(downloading ? "downloading" : "uploading") at \(Format.rate(downloading ? first.inRate : first.outRate)).",
                action: quitAction(s.apps.first { $0.id == first.id }, control) ?? MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude)
            )
        } else {
            footer = .success("Connected through \(primary?.title ?? "the network"). Nothing is using much of it.")
        }

        return MeterModel(
            number: total,
            numberFormat: n.online ? Format.rate : { _ in "Offline" },
            caption: n.online ? "↓ \(Format.rate(n.inBytesPerSecond))   ↑ \(Format.rate(n.outBytesPerSecond))" : "no connection",
            status: .plain(status),
            items: items,
            capacity: ceiling,
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    // MARK: Graphics

    /// Who is using the graphics cores. Shares come from the GPU time each process has been charged.
    func gpu(_ s: Snapshot, count: Int = 8, details: (() -> Void)? = nil, control: QuitModel? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        let g = s.gpu
        let load = g?.utilization ?? 0
        let users = s.apps.filter { $0.gpu > 0.0005 }.sorted { $0.gpu > $1.gpu }
        let top = Array(users.prefix(count))
        let ids = top.map(\.id)
        // Time charged to processes can overlap what the cores report as busy; the bar never exceeds the load.
        let sum = users.reduce(0) { $0 + $1.gpu }
        let scale = sum > load && sum > 0 ? load / sum : 1
        var items: [MeterItem] = top.map { app in
            MeterItem(
                id: app.id, name: app.name, icon: app.bundlePath == nil ? .swatch : .image(IconCache.icon(for: app)),
                rgb: color(for: app.id, among: ids, table: &gpuColors),
                amount: app.gpu * scale, number: app.gpu * 100, format: Self.percent,
                detail: "Of the graphics cores' time. It is also using \(Format.cpu(app.cpu)) CPU and \(Format.bytes(app.memory))."
            )
        }
        let rest = max(0, load - top.reduce(0) { $0 + $1.gpu } * scale)
        items.append(MeterItem(id: "other", name: "Everything else", icon: .swatch, rgb: PX.gray, amount: rest, number: rest * 100, format: Self.percent, detail: "The window server's own drawing and anything macOS does not attribute."))

        var status: [String] = []
        if let used = g?.memoryInUse { status.append("\(Format.bytes(used)) of graphics memory in use") }
        if let watts = s.power.gpu { status.append(AppTablePanel.watts(watts)) }
        if let temperature = s.thermal.gpuTemperature { status.append(Format.temperature(temperature)) }

        var footer: MeterFooter = .success(g == nil ? "This Mac does not report graphics load." : "The graphics cores are mostly idle.")
        if let first = top.first, load >= 0.5, first.gpu >= 0.2 {
            footer = .suggestion(
                icon: first.bundlePath == nil ? .symbol("square.stack.3d.up.fill") : .image(IconCache.icon(for: first)), rgb: PX.pink,
                text: "\(first.name) is using \(Self.percent(first.gpu * 100)) of the graphics cores.",
                action: quitAction(first, control) ?? MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude)
            )
        } else if load >= 0.25 {
            footer = .success("Working, with room to spare.")
        }
        let cores = g?.cores ?? 0
        return MeterModel(
            number: load * 100,
            numberFormat: { "\(Int($0.rounded()))%" },
            caption: cores > 0 ? "of \(cores) graphics cores busy" : "graphics load",
            status: .plain(status.isEmpty ? (g?.model ?? "Graphics") : status.joined(separator: " · ")),
            items: items,
            capacity: 1,
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    // MARK: Power

    /// The next round figure above a wattage, for bars and charts that have no natural ceiling.
    nonisolated static func wattCeiling(_ watts: Double, floor least: Double = 20) -> Double {
        let value = max(watts * 1.1, least)
        let magnitude = pow(10, floor(log10(value)))
        let leading = value / magnitude
        return (leading <= 1 ? 1 : (leading <= 2 ? 2 : (leading <= 5 ? 5 : 10))) * magnitude
    }

    /// What is drawing power. Apps are charged the energy the kernel bills them; the graphics cores and the
    /// rest of the machine come from the hardware's own counters.
    func power(_ s: Snapshot, history: [HistoryPoint], count: Int = 5, details: (() -> Void)? = nil, control: QuitModel? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        let p = s.power
        let total = p.total ?? 0
        let recent = history.filter { s.timestamp.timeIntervalSince($0.time) <= 300 }
        let ceiling = Self.wattCeiling(max(recent.compactMap(\.power).max() ?? 0, total))
        let users = s.apps.filter { $0.power > 0.01 }.sorted { $0.power > $1.power }
        let top = Array(users.prefix(count))
        let ids = top.map(\.id)
        let parts = (p.gpu ?? 0) + (p.neural ?? 0) + (p.memory ?? 0)
        // What apps are billed is processor energy. Where the processor's own total is known they sit inside
        // it; either way the bar never claims more than the machine drew.
        let budget = max(0, (p.system ?? total) - parts)
        let sum = users.reduce(0) { $0 + $1.power }
        let scale = sum > budget && sum > 0 ? budget / sum : 1

        var items: [MeterItem] = top.map { app in
            MeterItem(
                id: app.id, name: app.name, icon: app.bundlePath == nil ? .swatch : .image(IconCache.icon(for: app)),
                rgb: color(for: app.id, among: ids, table: &powerColors),
                amount: app.power * scale, number: app.power, format: AppTablePanel.watts,
                detail: "Energy the kernel bills to it, mostly processor work. \(Format.cpu(app.cpu)) CPU right now."
            )
        }
        let others = max(0, sum - top.reduce(0) { $0 + $1.power }) * scale
        if others > 0.05 {
            items.append(MeterItem(id: "others", name: "Other apps", icon: .swatch, rgb: PX.gray.mixed(with: PX.blue, 0.35), amount: others, number: others, format: AppTablePanel.watts, detail: "\(max(users.count - top.count, 0)) smaller apps and services."))
        }
        if let gpu = p.gpu {
            items.append(MeterItem(id: "gpu", name: "Graphics cores", icon: .symbol("square.stack.3d.up.fill"), rgb: PX.pink, amount: gpu, number: gpu, format: AppTablePanel.watts, detail: "The GPU's own draw, at \(Format.percent(s.gpu?.utilization ?? 0)) load."))
        }
        if let neural = p.neural, neural > 0.05 {
            items.append(MeterItem(id: "neural", name: "Neural engine", icon: .symbol("brain"), rgb: PX.purple, amount: neural, number: neural, format: AppTablePanel.watts, detail: "On-device machine learning."))
        }
        if let memory = p.memory, memory > 0.05 {
            items.append(MeterItem(id: "memory", name: "Memory", icon: .symbol("memorychip.fill"), rgb: PX.cyan, amount: memory, number: memory, format: AppTablePanel.watts, detail: "Keeping the memory chips powered."))
        }
        if let system = p.system {
            let used = sum * scale + parts
            let rest = max(0, system - used)
            items.append(MeterItem(id: "base", name: "Everything else", icon: .symbol("powerplug.fill"), rgb: PX.gray, amount: rest, number: rest, format: AppTablePanel.watts, detail: "The floor this Mac pays for being on: power supply losses, storage, fans, ports, and macOS itself."))
        }

        var status: [String] = []
        if let battery = p.battery {
            status.append("Battery \(Format.percent(battery.charge))")
            if let minutes = battery.minutesRemaining { status.append("\(Format.duration(Double(minutes) * 60)) \(battery.isCharging ? "to full" : "left")") }
        } else if let peak = recent.compactMap(\.power).max() {
            status.append("peak \(AppTablePanel.watts(peak)) in five minutes")
        }
        status.append("full bar is \(Int(ceiling)) W")

        var footer: MeterFooter = .success(p.total == nil ? "This Mac does not report what it draws." : "Close to the floor this Mac draws when it is on.")
        if let battery = p.battery, !battery.isPluggedIn {
            let left = battery.minutesRemaining.map { "About \(Format.duration(Double($0) * 60)) left at this rate." } ?? "Running on battery."
            footer = .suggestion(icon: .symbol("battery.50percent"), rgb: battery.charge < 0.2 ? PX.red : PX.greenRGB, text: left, action: nil)
        } else if let first = top.first, first.power >= 12 {
            footer = .suggestion(
                icon: first.bundlePath == nil ? .symbol("bolt.fill") : .image(IconCache.icon(for: first)), rgb: PX.yellow,
                text: "\(first.name) is drawing \(AppTablePanel.watts(first.power)).",
                action: quitAction(first, control) ?? MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude)
            )
        } else if total >= ceiling * 0.5, total > 60 {
            footer = .success("Working: \(AppTablePanel.watts(total)) is well above idle.")
        }

        return MeterModel(
            number: total,
            numberFormat: p.total == nil ? { _ in "No reading" } : AppTablePanel.watts,
            caption: p.system != nil ? "drawn by the whole Mac" : (p.total != nil ? "by the parts that report" : "power"),
            status: .plain(status.joined(separator: " · ")),
            items: items,
            capacity: ceiling,
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    // MARK: Battery

    /// The battery as a share of the whole it was built as: what is in it now, what is still to fill, and
    /// what wear has taken away for good.
    func battery(_ s: Snapshot, history: [HistoryPoint], details: (() -> Void)? = nil, control: QuitModel? = nil, askClaude: @escaping () -> Void) -> MeterModel {
        guard let b = s.power.battery else {
            return MeterModel(number: 0, numberFormat: { _ in "No battery" }, caption: "this Mac runs on mains power", status: .plain(""), items: [], capacity: 1, footer: .success("Nothing to show here."))
        }
        let health = b.health ?? 1
        let level = BatteryLook.color(b.charge)
        func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
        var items: [MeterItem] = [
            MeterItem(id: "charge", name: "Charge", icon: .symbol(b.isCharging ? "bolt.fill" : "battery.100percent"), rgb: level, amount: b.charge * health, number: b.charge * 100, format: percent, detail: "What is in the battery now, as macOS shows it."),
            MeterItem(id: "room", name: "Still to fill", icon: .swatch, rgb: RGB(0x5A5E66), amount: (1 - b.charge) * health, number: (1 - b.charge) * 100, format: percent, detail: "Room left before it is full."),
        ]
        if b.health != nil {
            items.append(MeterItem(id: "wear", name: "Lost to wear", icon: .symbol("minus.circle.fill"), rgb: PX.red.mixed(with: PX.gray, 0.45), amount: 1 - health, number: (1 - health) * 100, format: percent, detail: "Capacity that age and use have taken. It does not come back."))
        }
        let time = b.minutesRemaining
        items.append(MeterItem(id: "time", name: b.isCharging ? "Full in" : "Time left", icon: .symbol("clock.fill"), rgb: PX.cyan, amount: 0, number: Double(time ?? 0), format: { _ in b.isPluggedIn && !b.isCharging ? "On mains" : BatteryLook.time(time) }, detail: "The estimate macOS makes from recent use.", inBar: false))
        if let watts = b.watts {
            items.append(MeterItem(id: "rate", name: b.isCharging ? "Charging at" : "Draining at", icon: .symbol(b.isCharging ? "arrow.down.circle.fill" : "arrow.up.circle.fill"), rgb: b.isCharging ? PX.greenRGB : PX.orange, amount: 0, number: abs(watts), format: AppTablePanel.watts, detail: b.isCharging ? "Going into the battery right now." : "Coming out of the battery right now.", inBar: false))
        }
        if let cycles = b.cycles {
            items.append(MeterItem(id: "cycles", name: "Cycles", icon: .symbol("arrow.triangle.2.circlepath"), rgb: PX.gray, amount: 0, number: Double(cycles), format: { "\(Int($0))" }, detail: "Full discharges added up. Apple rates these batteries for a thousand.", inBar: false))
        }
        if let celsius = b.celsius {
            items.append(MeterItem(id: "temperature", name: "Temperature", icon: .symbol("thermometer.medium"), rgb: celsius >= 40 ? PX.orange : PX.blue, amount: 0, number: celsius, format: { String(format: "%.0f°", $0) }, detail: "Of the battery itself. It ages faster when it stays above 35°.", inBar: false))
        }
        if let adapter = s.power.adapter {
            items.append(MeterItem(id: "adapter", name: "Adapter", icon: .symbol("powerplug.fill"), rgb: PX.yellow, amount: 0, number: adapter, format: { "\(Int($0)) W" }, detail: b.adapterName ?? "What the connected adapter can supply.", inBar: false))
        }

        var caption = b.state
        if let time, b.isCharging { caption += " · \(BatteryLook.time(time)) until full" } else if let time, !b.isPluggedIn { caption += " · \(BatteryLook.time(time)) left" }
        var status: [String] = []
        if let watts = b.watts, abs(watts) > 0.05 { status.append("\(b.isCharging ? "taking in" : "giving out") \(AppTablePanel.watts(abs(watts)))") }
        if b.health != nil { status.append("holds \(Format.percent(health)) of what it did new") }
        if let cycles = b.cycles { status.append("\(cycles) cycles") }

        let top = s.apps.max { $0.power < $1.power }
        var footer: MeterFooter
        if !b.isPluggedIn, b.charge < 0.2 {
            footer = .suggestion(icon: .symbol("battery.25percent"), rgb: PX.red, text: time.map { "Low: about \(BatteryLook.time($0)) left at this rate." } ?? "Low. Find a charger soon.", action: quitAction(top.flatMap { $0.power >= 3 ? $0 : nil }, control))
        } else if !b.isPluggedIn, let top, top.power >= 3 {
            footer = .suggestion(
                icon: top.bundlePath == nil ? .symbol("bolt.fill") : .image(IconCache.icon(for: top)), rgb: PX.yellow,
                text: "\(top.name) is the biggest drain at \(AppTablePanel.watts(top.power)).",
                action: quitAction(top, control) ?? MeterAction(title: "Ask \(AIProvider.current.assistant)", symbol: "sparkles", action: askClaude)
            )
        } else if b.isCharging {
            footer = .success(time.map { "Charging. Full in about \(BatteryLook.time($0))." } ?? "Charging.")
        } else if b.isPluggedIn {
            footer = .success(b.isFull || b.charge >= 0.995 ? "Fully charged and on mains power." : "Plugged in and holding at \(Format.percent(b.charge)): macOS is sparing the battery.")
        } else {
            footer = .success("Nothing is draining it unusually fast.")
        }

        return MeterModel(
            number: b.charge * 100,
            numberFormat: percent,
            caption: caption,
            status: .plain(status.joined(separator: " · ")),
            items: items,
            capacity: 1,
            footer: footer,
            trailing: details.map { MeterAction(title: "Details", symbol: "arrow.up.right", action: $0) }
        )
    }

    private static func heatColor(_ celsius: Double) -> RGB {
        celsius >= 92 ? PX.red : (celsius >= 75 ? PX.orange : (celsius >= 55 ? PX.greenRGB : PX.blue))
    }

    private static func stateColor(_ level: ThermalLevel) -> RGB {
        switch level {
        case .nominal: return PX.greenRGB
        case .fair: return PX.yellow
        case .serious: return PX.orange
        case .critical: return PX.red
        }
    }
}
