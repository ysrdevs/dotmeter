import Foundation

/// Every reading as a few aligned lines for a terminal, in the words the app's own pages use.
enum ReportText {
    // MARK: Laying out

    /// Rows of columns, each column as wide as its widest cell. Columns named in `right` line up on their right
    /// edge, which is how figures are compared.
    static func table(_ rows: [[String]], right: Set<Int> = [], indent: String = "", gap: String = "  ") -> String {
        let columns = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in rows { for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) } }
        return rows.map { row in
            var line = indent
            for (index, cell) in row.enumerated() {
                let pad = String(repeating: " ", count: widths[index] - cell.count)
                let last = index == row.count - 1
                if right.contains(index) { line += pad + cell } else { line += last ? cell : cell + pad }
                if !last { line += gap }
            }
            // An empty last cell leaves the padding of the one before it hanging.
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    /// A label, its figure, and what the figure needs said about it.
    static func facts(_ rows: [(String, String, String?)]) -> String {
        table(rows.map { [$0.0, $0.1, $0.2 ?? ""] })
    }

    static func watts(_ value: Double) -> String {
        value < 0.995 ? String(format: "%.2f W", value) : (value < 99.5 ? String(format: "%.1f W", value) : "\(Int(value.rounded())) W")
    }

    /// Decimal units, as Finder shows a disk: "994.7 GB", "2 TB".
    static func disk(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 1000 {
            let tb = gb / 1000
            return abs(tb - tb.rounded()) < 0.005 ? "\(Int(tb.rounded())) TB" : String(format: "%.2f TB", tb)
        }
        return String(format: "%.1f GB", gb)
    }

    static func energy(_ wattHours: Double) -> String {
        wattHours >= 1000 ? String(format: "%.2f kWh", wattHours / 1000) : String(format: "%.0f Wh", wattHours)
    }

    private static func traffic(_ down: Double, _ up: Double) -> String {
        "↓ \(Format.rate(down))  ↑ \(Format.rate(up))"
    }

    private static func apps(_ title: String, _ rows: [[String]], right: Set<Int> = [0]) -> String {
        rows.isEmpty ? "" : "\n\n\(title)\n" + table(rows, right: right, indent: "  ")
    }

    private static func processes(_ count: Int) -> String {
        count > 1 ? "\(count) processes" : ""
    }

    // MARK: The whole Mac

    static func status(_ s: Snapshot, volume: VolumeSpace, usb: USBStats?) -> String {
        let system = s.system
        var lines = ["\(system.modelName) · \(system.chip) · \(Format.bytes(system.memoryTotal)) · macOS \(Report.macOS()) · up \(Format.duration(system.uptime))", Severity.from(s).title, ""]

        var rows: [(String, String, String?)] = []
        let load = String(format: "%.1f", s.cpu.loadAverage.first ?? 0)
        rows.append(("Processor", Format.percent(s.cpu.total), [Detail.clusters(s.cpu), "load \(load)"].compactMap { $0 }.joined(separator: " · ")))
        if let gpu = s.gpu {
            rows.append(("Graphics", Format.percent(gpu.utilization), gpu.memoryInUse.map { "\(Format.bytes($0)) in use" }))
        }
        var memory = "\(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total)) · \(s.memory.pressure.title.lowercased()) pressure"
        if s.memory.swapUsed > 0 { memory += " · \(Format.bytes(s.memory.swapUsed)) swapped" }
        rows.append(("Memory", Format.percent(s.memory.usedFraction), memory))
        var heat: [String] = []
        if !s.thermal.fans.isEmpty { heat.append("fans at \(Format.rpm(s.thermal.averageRPM)) rpm") }
        heat.append(s.thermal.isThrottled ? "throttling" : "thermal state \(s.thermal.state.title.lowercased())")
        rows.append(("Thermals", s.thermal.hottest.map { Format.temperature($0.celsius) } ?? s.thermal.state.title, heat.joined(separator: " · ")))
        rows.append(("Network", s.network.online ? (s.network.primaryInterface?.title ?? "Online") : "Offline", traffic(s.network.inBytesPerSecond, s.network.outBytesPerSecond)))
        var power: [String] = []
        if let battery = s.power.battery {
            power.append("battery \(Format.percent(battery.charge)), \(battery.state)")
            if let minutes = battery.minutesRemaining { power.append("\(Format.duration(Double(minutes) * 60)) \(battery.isCharging ? "to full" : "left")") }
        }
        rows.append(("Power", s.power.total.map(watts) ?? "No reading", power.isEmpty ? nil : power.joined(separator: " · ")))
        rows.append(("Storage", Format.percent(volume.usedFraction), "\(disk(volume.free)) free of \(disk(volume.total)) · disk ↓ \(Format.rate(s.disk.readBytesPerSecond))  ↑ \(Format.rate(s.disk.writeBytesPerSecond))"))
        if let usb {
            let overview = USBOverview(usb)
            var detail = Detail.count(overview.deviceCount, overview.deviceCount == 1 ? "device" : "devices")
            if !overview.slow.isEmpty { detail += " · \(overview.slow.map(\.title).joined(separator: ", ")) running slower than \(overview.slow.count == 1 ? "it" : "they") could" }
            rows.append(("Ports", "\(overview.connected.count) of \(overview.ports.count)", detail))
        }
        lines.append(facts(rows))

        let top = Report.top(s, by: .cpu, Report.few)
        return lines.joined(separator: "\n") + apps("Busiest apps", top.map { [Format.cpu($0.cpu), Format.bytes($0.memory), $0.name] }, right: [0, 1])
    }

    // MARK: Areas

    static func processor(_ s: Snapshot) -> String {
        let cpu = s.cpu
        var rows: [(String, String, String?)] = [("Processor", Format.percent(cpu.total), "of \(cpu.perCore.count) cores busy")]
        rows.append(("User", Format.percent(cpu.user), "apps and their helpers"))
        rows.append(("System", Format.percent(cpu.system), "macOS itself"))
        if let clusters = Report.clusters(cpu) {
            rows.append(("Performance", Format.percent(clusters.performance), "\(cpu.performanceCores) cores"))
            rows.append(("Efficiency", Format.percent(clusters.efficiency), "\(cpu.efficiencyCores) cores"))
        }
        rows.append(("Load", String(format: "%.2f", cpu.loadAverage.first ?? 0), cpu.loadAverage.count >= 3 ? String(format: "%.2f over 5 minutes · %.2f over 15", cpu.loadAverage[1], cpu.loadAverage[2]) : nil))
        if let celsius = s.thermal.cpuTemperature { rows.append(("Temperature", Format.temperature(celsius), "hottest core")) }
        if let power = s.power.cpu { rows.append(("Drawing", watts(power), s.power.total.map { "of \(watts($0)) for the whole Mac" })) }
        if let limit = s.thermal.cpuSpeedLimit, limit < 100 { rows.append(("Speed limit", "\(limit)%", "throttling to cool down")) }
        var out = facts(rows)
        if !cpu.perCore.isEmpty {
            // Each core's load in percent, efficiency cores first, twelve to a line.
            let cells = cpu.perCore.map { String(format: "%3d", Int(($0 * 100).rounded())) }
            let lines = stride(from: 0, to: cells.count, by: 12).map { cells[$0..<min($0 + 12, cells.count)].joined(separator: " ") }
            out += "\n\nEach core, %\n" + lines.map { "  " + $0 }.joined(separator: "\n")
        }
        return out + apps("Busiest apps", Report.top(s, by: .cpu, Report.few).map { [Format.cpu($0.cpu), $0.name, processes($0.processCount)] })
    }

    static func graphics(_ s: Snapshot) -> String {
        guard let gpu = s.gpu else { return "This Mac does not report its graphics load." }
        var rows: [(String, String, String?)] = [("Graphics", Format.percent(gpu.utilization), [gpu.model, gpu.cores.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · "))]
        if let renderer = gpu.rendererUtilization { rows.append(("Renderer", Format.percent(renderer), nil)) }
        if let tiler = gpu.tilerUtilization { rows.append(("Tiler", Format.percent(tiler), nil)) }
        if let used = gpu.memoryInUse { rows.append(("Memory in use", Format.bytes(used), gpu.memoryAllocated.map { "\(Format.bytes($0)) set aside, out of main memory" })) }
        if let celsius = s.thermal.gpuTemperature { rows.append(("Temperature", Format.temperature(celsius), "hottest sensor")) }
        if let power = s.power.gpu { rows.append(("Drawing", watts(power), s.power.total.map { "of \(watts($0)) for the whole Mac" })) }
        return facts(rows) + apps("Busiest apps", Report.top(s, by: .gpu, Report.few).map { [String(format: "%.1f%%", $0.gpu * 100), $0.name] })
    }

    static func memory(_ s: Snapshot) -> String {
        let m = s.memory
        let free = m.total > m.used ? m.total - m.used : 0
        var rows: [(String, String, String?)] = [("Memory", Format.bytes(m.used), "of \(Format.bytes(m.total)) used · \(Format.bytes(free)) available")]
        rows.append(("Apps", Format.bytes(m.app), nil))
        rows.append(("Wired", Format.bytes(m.wired), "macOS itself needs it and cannot move it"))
        rows.append(("Compressed", Format.bytes(m.compressed), nil))
        rows.append(("Cached files", Format.bytes(m.cached), "paging \(Detail.paging(m.activity))"))
        rows.append(("Swap", Detail.swap(m), Detail.memoryActivity(m.activity) ?? (m.swapUsed > 0 ? nil : "nothing pushed to disk")))
        rows.append(("Pressure", m.pressure.title, "what macOS itself reports"))
        return facts(rows) + apps("Largest apps", Report.top(s, by: .memory, Report.few).map { [Format.bytes($0.memory), $0.name, processes($0.processCount)] })
    }

    static func thermals(_ s: Snapshot) -> String {
        let t = s.thermal
        var rows: [(String, String, String?)] = []
        if let hottest = t.hottest { rows.append(("Hottest", Format.temperature(hottest.celsius), hottest.group == "GPU" ? "a graphics sensor" : "a processor core")) }
        if let cpu = t.cpuTemperature { rows.append(("Processor", Format.temperature(cpu), nil)) }
        if let gpu = t.gpuTemperature { rows.append(("Graphics", Format.temperature(gpu), nil)) }
        rows.append(("Thermal state", t.state.title, "above nominal, things get slowed down"))
        rows.append(("Speed limit", t.cpuSpeedLimit.map { "\($0)%" } ?? "None", t.isThrottled ? "throttling to cool down" : "running at full speed"))
        if t.fans.isEmpty { rows.append(("Fans", "None", nil)) }
        for fan in t.fans {
            rows.append(("Fan \(fan.index + 1)", "\(Format.rpm(fan.rpm)) rpm", "\(Format.percent(fan.percent)) of its range, \(Format.rpm(fan.minRPM)) to \(Format.rpm(fan.maxRPM))"))
        }
        var out = facts(rows)
        let groups = Report.sensorGroups(t)
        if !groups.isEmpty {
            out += "\n\nSensors\n" + table([["", "Hottest", "Average", ""]] + groups.map { [$0.name, Format.temperature($0.hottest), Format.temperature($0.average), Detail.count($0.count, $0.count == 1 ? "sensor" : "sensors")] }, right: [1, 2], indent: "  ")
        }
        return out
    }

    static func network(_ s: Snapshot, addresses: Bool) -> String {
        let n = s.network
        var rows: [(String, String, String?)] = [("Network", n.online ? "Online" : "Offline", traffic(n.inBytesPerSecond, n.outBytesPerSecond))]
        if let primary = n.primaryInterface {
            rows.append(("Through", primary.title, [primary.name, primary.linkSpeed.map(Format.linkSpeed), n.configMethod].compactMap { $0 }.joined(separator: " · ")))
        }
        if let wifi = n.wifi {
            var facts = ["\(wifi.standard)", "channel \(wifi.channel) \(wifi.band)", wifi.security]
            if wifi.transmitRate > 0 { facts.insert(Format.linkSpeed(wifi.transmitRate * 1e6), at: 0) }
            rows.append(("Wi-Fi", wifi.rssi.map { "\($0) dBm" } ?? "Joined", ([wifi.qualityTitle?.lowercased()].compactMap { $0 } + facts).joined(separator: " · ")))
            if addresses { rows.append(("Wi-Fi name", wifi.ssid ?? "Withheld", wifi.ssid == nil ? "macOS gives it only to apps allowed to use Location" : nil)) }
        }
        if addresses {
            if let router = n.router { rows.append(("Router", router, nil)) }
            // One to a row's middle column, the rest beside it: a long list there would push every row's last column out.
            if let first = n.dns.first { rows.append(("DNS", first, n.dns.count > 1 ? "and \(n.dns.dropFirst().joined(separator: ", "))" : nil)) }
            if let first = n.searchDomains.first { rows.append(("Search", first, n.searchDomains.count > 1 ? "and \(n.searchDomains.dropFirst().joined(separator: ", "))" : nil)) }
        }
        if let firewall = n.firewall { rows.append(("Firewall", firewall ? "On" : "Off", nil)) }
        var out = facts(rows)

        // The interfaces in use. A Mac Studio has fifteen more with nothing plugged in, which are only counted.
        let active = n.interfaces.filter(\.isActive)
        if !active.isEmpty {
            out += "\n\nInterfaces\n" + table(active.map { item in
                var row = [item.name, item.title, item.linkSpeed.map(Format.linkSpeed) ?? "", traffic(item.inRate, item.outRate)]
                if addresses { row.append(([item.address] + [item.mac.map { "mac \($0)" }]).compactMap { $0 }.joined(separator: " · ")) }
                return row
            }, indent: "  ")
        }
        let idle = n.interfaces.count - active.count
        if idle > 0 { out += (active.isEmpty ? "\n\n" : "\n  ") + (active.isEmpty ? "\(idle) interfaces, none connected" : "and \(idle) not connected") }
        if n.appsMeasured {
            let busy = n.apps.filter { $0.rate >= Report.busyRate }.prefix(Report.few)
            out += busy.isEmpty ? "\n\nNo app is sending or receiving much right now." : apps("Busiest apps", busy.map { ["↓ \(Format.rate($0.inRate))", "↑ \(Format.rate($0.outRate))", $0.name] }, right: [0, 1])
        }
        if n.listenersMeasured {
            let open = n.listeners.filter { !$0.exposed.isEmpty }
            let local = n.listeners.count - open.count
            if open.isEmpty {
                out += "\n\nNo app is listening for other devices." + (local > 0 ? " \(local) answer only to this Mac." : "")
            } else {
                out += "\n\nListening for other devices\n" + table(open.map { app in
                    let ports = Array(Set(app.exposed.map(\.port))).sorted()
                    return [app.name, ports.prefix(8).map(String.init).joined(separator: ", ") + (ports.count > 8 ? " and \(ports.count - 8) more" : "")]
                }, indent: "  ")
                if local > 0 { out += "\n  and \(local) more that answer only to this Mac" }
            }
        }
        return out
    }

    static func power(_ s: Snapshot) -> String {
        let p = s.power
        var rows: [(String, String, String?)] = [("Power", p.total.map(watts) ?? "No reading", p.system != nil ? "drawn by the whole Mac" : (p.total != nil ? "by the parts that report" : "this Mac does not report what it draws"))]
        if let cpu = p.cpu { rows.append(("Processor", watts(cpu), nil)) }
        if let gpu = p.gpu { rows.append(("Graphics", watts(gpu), nil)) }
        if let neural = p.neural, neural > 0.05 { rows.append(("Neural engine", watts(neural), nil)) }
        if let memory = p.memory, memory > 0.05 { rows.append(("Memory", watts(memory), nil)) }
        // Where the processor is not reported apart, it is in what is left over.
        if let rest = p.rest { rows.append(("Everything else", watts(rest), p.cpu == nil ? "the processor included: this Mac does not report it apart" : "power supply losses, storage, fans, ports")) }
        if let adapter = p.adapter { rows.append(("Power adapter", "\(Int(adapter)) W", "what it can supply")) }
        if let battery = p.battery {
            var detail = [battery.state]
            if let minutes = battery.minutesRemaining { detail.append("\(Format.duration(Double(minutes) * 60)) \(battery.isCharging ? "to full" : "left")") }
            rows.append(("Battery", Format.percent(battery.charge), detail.joined(separator: " · ")))
            if let rate = battery.watts, abs(rate) > 0.05 { rows.append((battery.isCharging ? "Charging at" : "Draining at", watts(abs(rate)), nil)) }
            if let health = battery.health { rows.append(("Health", Format.percent(health), battery.cycles.map { "\($0) cycles" })) }
            if let celsius = battery.celsius { rows.append(("Battery heat", String(format: "%.1f°", celsius), nil)) }
        }
        return facts(rows) + apps("Drawing the most", Report.top(s, by: .energy, Report.few).filter { $0.power >= 0.01 }.map { [watts($0.power), $0.name] })
    }

    static func storage(_ volume: VolumeSpace) -> String {
        guard volume.total > 0 else { return "The startup disk would not say how big it is." }
        var rows: [(String, String, String?)] = [("Storage", disk(volume.free), "free of \(disk(volume.total))" + (volume.name.isEmpty ? "" : " on \(volume.name)"))]
        rows.append(("Used", disk(volume.used), Format.percent(volume.usedFraction)))
        if volume.reclaimable > 0 { rows.append(("Reclaimable", disk(volume.reclaimable), "macOS clears it when the space is needed")) }
        return facts(rows)
    }

    static func apps(_ s: Snapshot, by order: AppOrder, top count: Int) -> String {
        let list = s.apps.sorted { order.value($0) > order.value($1) }.prefix(count)
        let header = ["CPU", "Memory", "Energy", "Graphics", "Disk", "App"]
        let rows = list.map { app in
            [Format.cpu(app.cpu), Format.bytes(app.memory), watts(app.power), String(format: "%.1f%%", app.gpu * 100), app.disk >= 1e3 ? Format.rate(app.disk) : "", app.name + (app.processCount > 1 ? " (\(app.processCount))" : "")]
        }
        return "\(Detail.count(s.apps.count, "apps")), \(Detail.count(s.processes.count, "processes")) · the top \(list.count) by \(order.title)\n\n" + table([header] + rows, right: [0, 1, 2, 3, 4])
    }

    // MARK: The recorded week

    static func timeline(_ week: RecordedWeek, hours: Int?, now: Date = Date()) -> String {
        guard week.found, !(week.minutes.isEmpty && week.events.isEmpty) else {
            return "Nothing has been recorded yet. \(App.name) records while it is running."
        }
        let s = week.summary(hours: hours, now: now)
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM"
        let stamp = DateFormatter()
        stamp.dateFormat = "EEE d MMM HH:mm"

        let span = s.hours >= RecordedWeek.weekHours ? "the last 7 days" : (s.hours == 1 ? "the last hour" : "the last \(s.hours) hours")
        var out = "Timeline · \(span)" + (week.recordingSince.map { " · recording since \(day.string(from: $0))" } ?? "")
        guard s.minutes > 0 || s.eventsTotal > 0 else { return out + "\n\nNothing was recorded in that time." }

        func recorded(_ minutes: Int) -> String { minutes >= 90 ? "\(Int((Double(minutes) / 60).rounded())) h" : "\(minutes) min" }
        if s.minutes > 0 {
            var rows = [["", "Recorded", "Processor", "Peak", "Hottest", "Fans up to", "Energy"]]
            for item in s.days {
                rows.append([day.string(from: item.start), recorded(item.minutes), Format.percent(item.cpu), Format.percent(item.cpuPeak), item.hottest.map(Format.temperature) ?? "—", "\(Format.rpm(item.fanPeak)) rpm", energy(item.wattHours)])
            }
            if s.days.count > 1 {
                rows.append(["In all", recorded(s.minutes), Format.percent(s.cpu), Format.percent(s.cpuPeak), s.hottest.map(Format.temperature) ?? "—", "\(Format.rpm(s.fanPeak)) rpm", energy(s.wattHours)])
            }
            out += "\n\n" + table(rows, right: [1, 2, 3, 4, 5, 6])
            var notes = ["Network: \(Format.data(UInt64(max(0, s.received)))) received, \(Format.data(UInt64(max(0, s.sent)))) sent"]
            if let average = s.averageWatts { notes.append("average draw \(watts(average))") }
            out += "\n\n" + notes.joined(separator: " · ")
        }

        if s.eventsTotal == 0 {
            out += "\n\nNo events: nothing ran hot, held the processor or dropped."
        } else {
            out += "\n\nEvents (\(s.eventsTotal))\n"
            out += table(s.events.map { item in
                var detail = item.event.summary
                if let peak = item.event.peakCelsius, peak > 0 { detail += " · peak \(Format.temperature(peak))" }
                // A crash is a moment, not a stretch: it has no length worth a figure.
                return [stamp.string(from: item.event.start), item.ongoing ? "now" : (item.duration < 60 ? "" : Format.duration(item.duration)), item.event.kind.title, detail]
            }, right: [1], indent: "  ")
            if s.eventsTotal > s.events.count { out += "\n  and \(s.eventsTotal - s.events.count) earlier" }
        }
        return out
    }
}
