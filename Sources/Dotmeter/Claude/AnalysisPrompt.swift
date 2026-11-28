import Foundation

enum AnalysisPrompt {
    private static let persona = """
    You are \(App.name), a macOS performance diagnostician that lives in the menu bar. The user pressed Analyze because their Mac feels hot, loud or slow, or they want to know what it is doing. You receive a JSON snapshot taken seconds ago.

    Write for a smart person who is not a sysadmin: direct, specific, friendly, never alarmist. Name apps and processes exactly as they appear in the snapshot and quote their numbers. Never invent anything that is not in the data.

    Interpretation notes: process CPU is a share of one core, so 400% means four cores. Apple silicon performance cores run hot; a few cores pinned near 100% for minutes is what spins the fans. High kernel_task CPU is usually macOS throttling to protect itself. mds_stores and mdworker are Spotlight indexing. backupd is Time Machine. photoanalysisd and mediaanalysisd are Photos indexing in the background. WindowServer high means display or GPU pressure. On macOS, memory pressure matters more than used GB. Games and video exports legitimately use many cores and the GPU. cpu_max_c and gpu_max_c are the die temperatures that matter; 45–65° is idle to light use, 75–90° is sustained load, 100°+ means throttling.
    """

    /// System prompt for the first analysis, which must come back as JSON matching `AnalysisReport.schema`.
    static let system = persona + """

    Reply with a JSON report that the app renders natively. Field guidance:
    - culprits: always list the 3 to 5 biggest consumers right now, biggest first, even when everything is normal, because the user wants to see what is running. Prefer entries from top_apps. For apps with helpers, put the busiest helper names in processes. Use usage for the headline figure and reason for why it is busy and whether that is expected.
    - concern: fix only when the user should act (a runaway or stuck process, swap thrashing, throttling); watch for things worth re-checking later; otherwise none.
    - actions: 1 to 4 concrete steps, most effective first. If nothing is needed, one action titled like "Nothing to do" with a sentence of reassurance. When a step is to quit one app, put that app's exact name from top_apps in quit so the user gets a Quit button; leave quit empty for every other step, and never suggest quitting something the user is plainly using on purpose.
    - verdict: one or two plain sentences with the key numbers, like a sharp friend who knows Macs.
    - thermal: one sentence on fans and heat, including whether the current fan speed is justified; empty string if unremarkable.
    Keep every string short. Emit the keys in this order so the app can render while you stream: status, verdict, culprits, actions, thermal.
    """

    /// System prompt for anything the user types: a first question, or a follow-up to the report.
    static let chatSystem = persona + """

    Answer the user's question about this Mac. The first message in the conversation carries a snapshot (and a storage summary when the disk has been scanned); treat it as your evidence and quote its numbers. If the conversation began with your JSON report, the user is asking about that.

    Plain prose or short "- " bullets, with **bold** for app and process names. No headers, tables or JSON. Stay under 140 words unless the question needs steps. Explain what a process is when asked; you know macOS well. If the snapshot cannot answer the question, say what is missing instead of guessing. You cannot run commands or change anything yourself: say where to click in \(App.name) or macOS, or what to run. If the question has nothing to do with this Mac, answer in a sentence and offer what you can check here.
    """

    /// System prompt for "Explain" on one area.
    static let explainSystem = persona + """

    The user pressed Explain on one area of the app. Explain that area as it is right now: what the figures mean, what is causing them (name the apps or parts responsible and quote their numbers), whether that is normal for this Mac, and the one thing worth doing, if anything is. Stay on that area; mention another only when it is the cause.

    Plain prose with short "- " bullets where they help, and **bold** for app names and the key figures. No headers, tables or JSON. 60 to 130 words. If the data cannot say why, say what is missing instead of guessing. You cannot run commands or change anything yourself: say where to click in \(App.name) or macOS.
    """

    /// What to ask about each area, and the detail only that area has.
    static func explainMessage(section: AppSection, snapshot s: Snapshot, history: [HistoryPoint], storage: String?, timeline: String?, question: String?, extra: String?) -> String {
        var focus = ""
        var detail: [String] = []
        switch section {
        case .cpu:
            focus = "Processor: what is using it, and is any of it a problem?"
            detail.append("Per-core load, percent, efficiency cores first: " + s.cpu.perCore.map { String(Int($0 * 100)) }.joined(separator: " "))
        case .gpu:
            focus = "Graphics: what is using the GPU, and how busy is it for this chip?"
            if let gpu = s.gpu {
                detail.append("GPU: \(gpu.model ?? "unknown"), \(gpu.cores ?? 0) cores, \(Int(gpu.utilization * 100))% busy, memory in use \(gpu.memoryInUse.map(Format.bytes) ?? "unknown") of \(gpu.memoryAllocated.map(Format.bytes) ?? "unknown") set aside, \(s.power.gpu.map { String(format: "%.1f W", $0) } ?? "power unknown").")
            }
            detail.append("Apps by share of GPU time: " + s.apps.sorted { $0.gpu > $1.gpu }.prefix(8).filter { $0.gpu > 0.001 }.map { "\($0.name) \(String(format: "%.1f", $0.gpu * 100))%" }.joined(separator: ", "))
        case .memory:
            focus = "Memory: who is holding it, and is the Mac short of it?"
            detail.append("Cached files \(Format.bytes(s.memory.cached)), swap used \(Format.bytes(s.memory.swapUsed)).")
        case .storage:
            focus = "Storage: what is filling the disk, and what could safely be freed?"
            detail.append("Disk activity now: reading \(Format.rate(s.disk.readBytesPerSecond)), writing \(Format.rate(s.disk.writeBytesPerSecond)). Busiest: " + s.apps.sorted { $0.disk > $1.disk }.prefix(5).filter { $0.disk > 1000 }.map { "\($0.name) read \(Format.rate($0.diskRead)) write \(Format.rate($0.diskWrite))" }.joined(separator: ", "))
        case .thermal:
            focus = "Thermals: why is it this temperature, where is the heat, and are the fans justified?"
            let groups = Dictionary(grouping: s.thermal.sensors, by: \.group)
            detail.append("Hottest sensor per group, °C: " + groups.map { "\($0.key) \(Int(($0.value.map(\.celsius).max() ?? 0).rounded())) (of \($0.value.count))" }.sorted().joined(separator: ", "))
            detail.append("Fans: " + (s.thermal.fans.isEmpty ? "none" : s.thermal.fans.map { "\(Int($0.rpm)) rpm in a range of \(Int($0.minRPM)) to \(Int($0.maxRPM))" }.joined(separator: "; ")))
        case .network:
            focus = "Network: what is using the connection, and is the connection itself healthy?"
            for target in s.network.latency {
                detail.append("\(target.title) round trip: \(target.last.map { String(format: "%.0f ms", $0) } ?? "no answer") now, average \(target.average.map { String(format: "%.0f ms", $0) } ?? "-"), jitter \(target.jitter.map { String(format: "%.1f ms", $0) } ?? "-"), \(Int(target.loss * 100))% lost over \(target.samples.count) echoes.")
            }
            detail.append("Interfaces in use: " + s.network.interfaces.filter(\.isActive).map { "\($0.title) (\($0.kind.rawValue)\($0.linkSpeed.map { ", link " + Format.linkSpeed($0) } ?? ""))" }.joined(separator: ", "))
        case .power:
            focus = "Power: how much is the Mac drawing, what is drawing it, and is that normal?"
            func watts(_ value: Double?) -> String { value.map { String(format: "%.1f W", $0) } ?? "not reported by this Mac" }
            detail.append("Whole machine \(watts(s.power.system)); processor \(watts(s.power.cpu)); graphics \(watts(s.power.gpu)); neural engine \(watts(s.power.neural)); memory \(watts(s.power.memory)). Energy counted since \(App.name) started: \(String(format: "%.1f Wh", s.power.energyWh)).")
            if let battery = s.power.battery {
                detail.append("Battery \(Int(battery.charge * 100))%, \(battery.isCharging ? "charging" : (battery.isPluggedIn ? "plugged in, not charging" : "on battery")), \(battery.cycles.map { "\($0) cycles" } ?? ""), health \(battery.health.map { "\(Int($0 * 100))%" } ?? "unknown"), \(battery.minutesRemaining.map { "\($0) minutes left" } ?? "no estimate").")
            }
            detail.append("Apps by power billed to them: " + s.apps.sorted { $0.power > $1.power }.prefix(8).filter { $0.power > 0.02 }.map { "\($0.name) \(String(format: "%.2f W", $0.power))" }.joined(separator: ", "))
        case .battery:
            focus = "Battery: how is the charge and the battery's health, what is draining it, and how long will it last?"
            if let battery = s.power.battery {
                detail.append("Battery \(Int(battery.charge * 100))%, \(battery.state), \(battery.minutesRemaining.map { "\($0) minutes \(battery.isCharging ? "until full" : "left")" } ?? "no time estimate"), \(battery.watts.map { String(format: "%.1f W %@", abs($0), $0 >= 0 ? "going in" : "coming out") } ?? "rate unknown"). Health \(battery.health.map { "\(Int($0 * 100))%" } ?? "unknown") (\(battery.fullCapacity.map { "\($0) mAh now" } ?? "") \(battery.designCapacity.map { "of \($0) mAh when new" } ?? "")), \(battery.cycles.map { "\($0) cycles" } ?? "cycles unknown"), \(battery.celsius.map { String(format: "%.0f°C", $0) } ?? "temperature unknown"). Adapter: \(s.power.adapter.map { "\(Int($0)) W" } ?? "none connected").")
            } else {
                detail.append("This Mac has no battery.")
            }
            detail.append("Apps by power billed to them: " + s.apps.sorted { $0.power > $1.power }.prefix(8).filter { $0.power > 0.02 }.map { "\($0.name) \(String(format: "%.2f W", $0.power))" }.joined(separator: ", "))
        case .usb:
            focus = "USB and Thunderbolt: what is plugged into each port, is each connection running as fast as its parts allow, and does any cable or device need attention?"
            detail.append(s.usb.map(USBReport.text) ?? "The ports have not been read yet.")
        case .timeline:
            focus = "Timeline: what has this Mac been doing over the recorded period, and when did it work hardest?"
        case .startup:
            focus = "Login items: which of these background items matter, and which could go?"
        case .models:
            focus = "Local AI models: what is loaded, what is it holding in memory and on the graphics chip, and does this Mac have room for it?"
            if let gpu = s.gpu {
                detail.append("Graphics: \(Int(gpu.utilization * 100))% busy, memory in use \(gpu.memoryInUse.map(Format.bytes) ?? "unknown").")
            }
        case .macs:
            focus = "This Mac and the user's other Macs: how do they compare right now?"
        case .dashboard, .claude:
            focus = "The whole Mac: what is it doing right now, and does anything need attention?"
        }
        var parts = [initialMessage(snapshot: s, history: history, storage: section == .storage || section == .dashboard ? storage : "(not relevant to this question)")]
        if !detail.isEmpty { parts.append("Detail for this area:\n" + detail.joined(separator: "\n")) }
        if let timeline, section == .timeline || section == .dashboard || extra != nil { parts.append("What \(App.name) has recorded:\n" + timeline) }
        if let extra { parts.append(extra) }
        parts.append("Explain: " + (question ?? focus))
        return parts.joined(separator: "\n\n")
    }

    static func initialMessage(snapshot: Snapshot, history: [HistoryPoint], storage: String? = nil) -> String {
        let report = report(for: snapshot, history: history)
        return """
        Hardware: \(snapshot.system.modelName) (\(snapshot.system.modelIdentifier)), \(snapshot.system.chip), \(Format.bytes(snapshot.system.memoryTotal)) memory, \(snapshot.system.osVersion). Uptime \(Format.duration(snapshot.system.uptime)).

        Snapshot (JSON):
        \(report)

        Storage:
        \(storage ?? "The disk has not been scanned yet. The user can run a scan from the Storage page.")
        """
    }

    /// A first question typed by the user: the same evidence as a check-up, followed by what they asked.
    static func questionMessage(_ question: String, snapshot: Snapshot, history: [HistoryPoint], storage: String?) -> String {
        """
        \(initialMessage(snapshot: snapshot, history: history, storage: storage))

        Question: \(question)
        """
    }

    static func followUp(_ question: String, snapshot: Snapshot?) -> String {
        guard let s = snapshot else { return question }
        var live = "CPU \(Format.percent(s.cpu.total))"
        if let t = s.thermal.hottest { live += ", hottest sensor \(Format.temperature(t.celsius))" }
        if !s.thermal.fans.isEmpty { live += ", fans \(Format.rpm(s.thermal.averageRPM)) rpm" }
        let top = s.apps.prefix(5).map { "\($0.name) \(Format.cpu($0.cpu))" }.joined(separator: ", ")
        return "\(question)\n\n(Live now: \(live). Top apps: \(top).)"
    }

    private static func report(for s: Snapshot, history: [HistoryPoint]) -> String {
        func pct(_ v: Double) -> Int { Int((v * 100).rounded()) }
        func gb(_ b: UInt64) -> Double { (Double(b) / 1_073_741_824 * 10).rounded() / 10 }
        func mb(_ b: UInt64) -> Int { Int(Double(b) / 1_048_576) }

        var report: [String: Any] = [:]
        report["cpu"] = [
            "total_percent": pct(s.cpu.total),
            "user_percent": pct(s.cpu.user),
            "system_percent": pct(s.cpu.system),
            "cores": s.cpu.perCore.count,
            "performance_cores": s.cpu.performanceCores,
            "efficiency_cores": s.cpu.efficiencyCores,
            "cores_above_80_percent": s.cpu.perCore.filter { $0 > 0.8 }.count,
            "load_average": s.cpu.loadAverage.map { ($0 * 10).rounded() / 10 },
        ]
        var memory: [String: Any] = [
            "total_gb": gb(s.memory.total),
            "used_gb": gb(s.memory.used),
            "app_gb": gb(s.memory.app),
            "wired_gb": gb(s.memory.wired),
            "compressed_gb": gb(s.memory.compressed),
            "pressure": s.memory.pressure.rawValue,
        ]
        if s.memory.swapUsed > 0 { memory["swap_used_gb"] = gb(s.memory.swapUsed) }
        report["memory"] = memory

        var thermal: [String: Any] = ["apple_thermal_state": s.thermal.state.rawValue]
        if let limit = s.thermal.cpuSpeedLimit { thermal["cpu_speed_limit_percent"] = limit }
        if !s.thermal.fans.isEmpty {
            thermal["fans"] = s.thermal.fans.map { ["rpm": Int($0.rpm), "min_rpm": Int($0.minRPM), "max_rpm": Int($0.maxRPM), "percent_of_range": pct($0.percent)] }
        }
        if let cpu = s.thermal.cpuTemperature { thermal["cpu_max_c"] = Int(cpu.rounded()) }
        if let gpu = s.thermal.gpuTemperature { thermal["gpu_max_c"] = Int(gpu.rounded()) }
        report["thermal"] = thermal

        if let gpu = s.gpu {
            var graphics: [String: Any] = ["utilization_percent": pct(gpu.utilization)]
            if let used = gpu.memoryInUse { graphics["memory_in_use_gb"] = gb(used) }
            let users = s.apps.sorted { $0.gpu > $1.gpu }.prefix(4).filter { $0.gpu >= 0.01 }.map { ["name": $0.name, "share_percent": pct($0.gpu)] as [String: Any] }
            if !users.isEmpty { graphics["top_apps"] = users }
            report["gpu"] = graphics
        }
        var power: [String: Any] = [:]
        if let system = s.power.system { power["system_watts"] = (system * 10).rounded() / 10 }
        if let gpuWatts = s.power.gpu { power["gpu_watts"] = (gpuWatts * 10).rounded() / 10 }
        if let cpuWatts = s.power.cpu { power["cpu_watts"] = (cpuWatts * 10).rounded() / 10 }
        if let battery = s.power.battery { power["battery_percent"] = pct(battery.charge); power["on_battery"] = !battery.isPluggedIn }
        if !power.isEmpty { report["power"] = power }
        report["disk"] = ["free_gb": gb(s.disk.free), "read_mb_s": Int(s.disk.readBytesPerSecond / 1e6), "write_mb_s": Int(s.disk.writeBytesPerSecond / 1e6)]
        // Rates, the kind of link and the busiest apps. Addresses, network names and hardware ids stay on the Mac.
        var network: [String: Any] = [
            "down_mb_s": (s.network.inBytesPerSecond / 1e6 * 10).rounded() / 10,
            "up_mb_s": (s.network.outBytesPerSecond / 1e6 * 10).rounded() / 10,
            "online": s.network.online,
        ]
        if let primary = s.network.primaryInterface {
            network["connection"] = primary.kind.rawValue
            if let speed = primary.linkSpeed { network["link_mbit_s"] = Int(speed / 1e6) }
        }
        if let wifi = s.network.wifi {
            var link: [String: Any] = ["standard": wifi.standard, "band": wifi.band, "channel": wifi.channel]
            if let rssi = wifi.rssi { link["signal_dbm"] = rssi; link["noise_dbm"] = wifi.noise }
            network["wifi"] = link
        }
        if s.network.interfaces.contains(where: { $0.kind == .tunnel && $0.isActive }) { network["vpn_or_tunnel_up"] = true }
        if s.network.appsMeasured {
            network["top_apps"] = s.network.apps.prefix(6).filter { $0.rate >= 1e3 }.map { app -> [String: Any] in
                ["name": app.name, "down_kb_s": Int(app.inRate / 1e3), "up_kb_s": Int(app.outRate / 1e3)]
            }
        }
        report["network"] = network

        report["top_apps"] = s.apps.prefix(12).map { app -> [String: Any] in
            var entry: [String: Any] = ["name": app.name, "cpu_percent": pct(app.cpu), "memory_mb": mb(app.memory), "processes": app.processCount]
            if app.processCount > 1 {
                entry["busiest_processes"] = app.children.prefix(3).map { ["name": $0.name, "cpu_percent": pct($0.cpu)] }
            }
            return entry
        }
        report["top_processes"] = s.processes.sorted { $0.cpu > $1.cpu }.prefix(15).map { p -> [String: Any] in
            var entry: [String: Any] = ["pid": Int(p.pid), "name": p.name, "cpu_percent": pct(p.cpu), "memory_mb": mb(p.memory)]
            if let parent = p.parentName { entry["parent"] = parent }
            return entry
        }
        report["top_memory"] = s.apps.sorted { $0.memory > $1.memory }.prefix(6).map { ["name": $0.name, "memory_mb": mb($0.memory)] }

        if history.count >= 3 {
            let cpu = history.map(\.cpu)
            var trend: [String: Any] = [
                "samples": history.count,
                "window_seconds": Int(history.last!.time.timeIntervalSince(history.first!.time)),
                "cpu_avg_percent": pct(cpu.reduce(0, +) / Double(cpu.count)),
                "cpu_peak_percent": pct(cpu.max() ?? 0),
            ]
            let temps = history.compactMap(\.temperature)
            if !temps.isEmpty { trend["hottest_avg_c"] = Int((temps.reduce(0, +) / Double(temps.count)).rounded()) }
            report["recent_trend"] = trend
        }

        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
