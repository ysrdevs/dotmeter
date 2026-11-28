import Foundation

/// Takes readings for the command and the AI server with the collectors the app itself uses.
///
/// Processor load, traffic and each app's share are differences between two readings, so a reading that means
/// anything needs one before it. A single command takes two, a moment apart. The server keeps its collectors, so a
/// burst of questions is answered from one reading to the next, and only a question after a pause waits again.
final class MeterReader {
    /// The least time between the starts of two readings for the difference to mean something. The process
    /// sampler sets it: under three quarters of a second it calls one burst of work a wild percentage and keeps
    /// its last figures, which for a first reading are all zero.
    static let window = 0.8
    /// The least time from the end of one reading to the start of the next. The traffic and power counters are
    /// read late in a pass and refuse a difference over less than three tenths of a second, and a first pass
    /// is slow: it opens every sensor.
    private static let settle = 0.35
    /// A reading older than this says nothing about now, so the next one starts over.
    private static let stale = 5.0
    /// Questions that arrive together are answered from the same reading.
    private static let together = 0.3
    /// Traffic by app is a difference of its own, between two runs of a helper at least nine tenths of a second
    /// apart and no more than a few seconds.
    private static let networkWindow = 0.95
    private static let networkStale = 10.0

    /// Made when the first reading is asked for: opening every sensor takes a fifth of a second, and the words
    /// that read no sensor (storage, usb, timeline) should not wait for it.
    private lazy var collectors: Collectors = timed("collectors opened") { Collectors() }
    private var last: Snapshot?
    /// When the last reading was started, which is about when its first counters were read.
    private var lastAt: UInt64 = 0
    private var lastHadNetwork = false
    private var lastNetworkAt: UInt64 = 0

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ value: Double) -> UInt64 { UInt64(value * 1e9) }

    /// `network` adds what only the network area asks for: traffic by app and the apps that are listening, each
    /// of which costs a helper process. `meanwhile` runs inside the wait between two readings, for work that
    /// would otherwise make the wait longer.
    func read(network: Bool = false, meanwhile: (() -> Void)? = nil) -> Snapshot {
        var options = CollectOptions()
        if network {
            options.networkApps = 0.5
            options.networkPorts = true
        }
        func since(_ moment: UInt64) -> Double { moment == 0 ? .infinity : Double(Self.now() &- moment) / 1e9 }
        var meanwhile = meanwhile
        func wait(until deadline: UInt64) {
            meanwhile?()
            meanwhile = nil
            let now = Self.now()
            if deadline > now { Thread.sleep(forTimeInterval: Double(deadline - now) / 1e9) }
        }

        let gap = since(lastAt)
        if let last, gap < Self.together, lastHadNetwork || !network {
            meanwhile?()
            return last
        }
        // Opened before any clock is started: the time it takes is no part of the wait between two readings.
        let collectors = collectors
        // With nothing recent to compare against, a reading is taken only to be compared against.
        let primeNetwork = network && !NetworkSampler.demo && since(lastNetworkAt) > Self.networkStale
        if gap > Self.stale || primeNetwork {
            let started = Self.now()
            _ = timed("first reading") { collectors.collect(options) }
            let ended = Self.now()
            wait(until: max(started + Self.seconds(Self.window), ended + Self.seconds(primeNetwork ? Self.networkWindow : Self.settle)))
        } else if gap < Self.window {
            wait(until: lastAt + Self.seconds(Self.window))
        }
        meanwhile?()
        var started = Self.now()
        var snapshot = timed("reading") { collectors.collect(options) }
        // Every process at rest is not a Mac that is running: the process sampler found the wait too short and
        // gave back the nothing it had. Wait it out in full and read again, whatever order a pass reads in.
        if !AppsDemo.on, !snapshot.processes.isEmpty, snapshot.processes.allSatisfy({ $0.cpu == 0 }) {
            wait(until: Self.now() + Self.seconds(Self.window))
            started = Self.now()
            snapshot = timed("reading again, for the apps") { collectors.collect(options) }
        }
        if network, !snapshot.network.appsMeasured, snapshot.network.appsAvailable, !NetworkSampler.demo {
            wait(until: Self.now() + Self.seconds(Self.networkWindow))
            started = Self.now()
            snapshot = timed("reading again, for traffic by app") { collectors.collect(options) }
        }
        snapshot = Self.withoutThisProcess(snapshot)
        last = snapshot
        lastAt = started
        lastHadNetwork = network
        if network { lastNetworkAt = started }
        return snapshot
    }

    /// Debug: DOTMETER_LOG_COMMAND=1 says on standard error how long each part of a reading took.
    private static let logs = ProcessInfo.processInfo.environment["DOTMETER_LOG_COMMAND"] == "1"

    private func timed<T>(_ label: String, _ work: () -> T) -> T {
        guard Self.logs else { return work() }
        let started = Self.now()
        let result = work()
        Command.say(String(format: "%@ in %.0f ms", label, Double(Self.now() &- started) / 1e6))
        return result
    }

    /// Taking a reading is work, and over so short a wait the program that takes it would show up among the
    /// busiest apps under the app's own name. The question was about the Mac, so the asker is left out.
    private static func withoutThisProcess(_ snapshot: Snapshot) -> Snapshot {
        let me = getpid()
        guard !AppsDemo.on, let own = snapshot.processes.first(where: { $0.pid == me }) else { return snapshot }
        var s = snapshot
        s.processes.removeAll { $0.pid == me }
        guard let at = s.apps.firstIndex(where: { app in app.children.contains { $0.pid == me } }) else { return s }
        if s.apps[at].processCount <= 1 {
            s.apps.remove(at: at)
        } else {
            s.apps[at].children.removeAll { $0.pid == me }
            s.apps[at].processCount -= 1
            s.apps[at].cpu = max(0, s.apps[at].cpu - own.cpu)
            s.apps[at].memory = s.apps[at].memory > own.memory ? s.apps[at].memory - own.memory : 0
            s.apps[at].power = max(0, s.apps[at].power - own.power)
            s.apps[at].gpu = max(0, s.apps[at].gpu - own.gpu)
            s.apps[at].diskRead = max(0, s.apps[at].diskRead - own.diskRead)
            s.apps[at].diskWrite = max(0, s.apps[at].diskWrite - own.diskWrite)
            if let first = s.apps[at].children.map(\.pid).min() { s.apps[at].pid = first }
        }
        return s
    }

    private func pause(_ seconds: Double, _ meanwhile: (() -> Void)?) {
        let started = DispatchTime.now().uptimeNanoseconds
        meanwhile?()
        let left = seconds - Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9
        if left > 0 { Thread.sleep(forTimeInterval: left) }
    }
}

/// Which figure the apps are ranked by.
enum AppOrder: String, CaseIterable {
    case cpu, memory, energy, gpu

    func value(_ app: AppUsage) -> Double {
        switch self {
        case .cpu: return app.cpu
        case .memory: return Double(app.memory)
        case .energy: return app.power
        case .gpu: return app.gpu
        }
    }

    var title: String {
        switch self {
        case .cpu: return "processor"
        case .memory: return "memory"
        case .energy: return "energy"
        case .gpu: return "graphics"
        }
    }
}

/// The startup disk: how big it is and how much of it is free. Asked of the volume; nothing is scanned.
struct VolumeSpace {
    var name: String
    var total: UInt64
    var free: UInt64
    /// What macOS would clear on demand on top of the free space: local snapshots and purgeable caches.
    var reclaimable: UInt64

    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read() -> VolumeSpace {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)
        let total = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let free = UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return VolumeSpace(name: values?.volumeName ?? "", total: total, free: free, reclaimable: important > free ? important - free : 0)
    }
}

/// Every reading as JSON: plain keys, base units (bytes, watts, degrees Celsius, shares from 0 to 1), and a key
/// left out where the Mac does not report the figure. `--json` prints these and the AI server's tools return them,
/// so the two never differ.
enum Report {
    /// How many apps the area readings name.
    static let few = 5
    /// Bytes a second under which an app's traffic is not worth a line: it would read as zero.
    static let busyRate = 1000.0

    static func macOS() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)" : "\(version.majorVersion).\(version.minorVersion)"
    }

    /// The average load of the performance cores and of the efficiency cores, where the Mac has both.
    static func clusters(_ cpu: CPUStats) -> (performance: Double, efficiency: Double)? {
        guard cpu.efficiencyCores > 0, cpu.perCore.count > cpu.efficiencyCores else { return nil }
        let efficiency = cpu.perCore.prefix(cpu.efficiencyCores), performance = cpu.perCore.dropFirst(cpu.efficiencyCores)
        func average(_ values: ArraySlice<Double>) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        return (average(performance), average(efficiency))
    }

    static func top(_ s: Snapshot, by order: AppOrder, _ count: Int) -> [AppUsage] {
        Array(s.apps.sorted { order.value($0) > order.value($1) }.prefix(count)).filter { order.value($0) > 0 }
    }

    // MARK: The whole Mac

    static func status(_ s: Snapshot, volume: VolumeSpace, usb: USBStats?) -> JSON {
        let clusters = clusters(s.cpu)
        var ports: JSON?
        if let usb {
            let overview = USBOverview(usb)
            ports = .record([
                "connected": .int(Int64(overview.connected.count)),
                "total": .int(Int64(overview.ports.count)),
                "devices": .int(Int64(overview.deviceCount)),
                "running_slow": .array(overview.slow.map { .string($0.title) }),
            ])
        }
        return .record([
            "time": JSON.time(s.timestamp),
            "mac": .record([
                "model": .string(s.system.modelName),
                "identifier": .string(s.system.modelIdentifier),
                "chip": .string(s.system.chip),
                "memory_bytes": JSON.bytes(s.system.memoryTotal),
                "macos": .string(macOS()),
                "uptime_seconds": JSON.rounded(s.system.uptime),
            ]),
            "state": .string(Severity.from(s).title),
            "processor": .record([
                "load": JSON.fraction(s.cpu.total),
                "performance_load": JSON.fraction(clusters?.performance),
                "efficiency_load": JSON.fraction(clusters?.efficiency),
                "cores": .int(Int64(s.cpu.perCore.count)),
                "load_average": JSON.figure(s.cpu.loadAverage.first),
            ]),
            "graphics": s.gpu.map { gpu in
                .record(["load": JSON.fraction(gpu.utilization), "memory_used_bytes": JSON.bytes(gpu.memoryInUse)])
            },
            "memory": .record([
                "used_fraction": JSON.fraction(s.memory.usedFraction),
                "used_bytes": JSON.bytes(s.memory.used),
                "total_bytes": JSON.bytes(s.memory.total),
                "pressure": .string(s.memory.pressure.rawValue),
                "swap_used_bytes": JSON.bytes(s.memory.swapUsed),
            ]),
            "thermals": .record([
                "state": .string(s.thermal.state.rawValue),
                "throttled": .bool(s.thermal.isThrottled),
                "hottest_celsius": JSON.celsius(s.thermal.hottest?.celsius),
                "fan_rpm": s.thermal.fans.isEmpty ? nil : JSON.rounded(s.thermal.averageRPM),
                "fan_speed": s.thermal.fans.isEmpty ? nil : JSON.fraction(s.thermal.averageFanPercent),
            ]),
            "network": .record([
                "online": .bool(s.network.online),
                "interface": JSON.text(s.network.primaryInterface?.title),
                "download_bytes_per_second": JSON.rounded(s.network.inBytesPerSecond),
                "upload_bytes_per_second": JSON.rounded(s.network.outBytesPerSecond),
            ]),
            "disk": .record([
                "read_bytes_per_second": JSON.rounded(s.disk.readBytesPerSecond),
                "write_bytes_per_second": JSON.rounded(s.disk.writeBytesPerSecond),
            ]),
            "power": .record([
                "watts": JSON.watts(s.power.total),
                "battery": s.power.battery.map { battery in
                    .record([
                        "charge": JSON.fraction(battery.charge),
                        "state": .string(battery.state),
                        "minutes_remaining": JSON.whole(battery.minutesRemaining),
                    ])
                },
            ]),
            "storage": .record([
                "total_bytes": JSON.bytes(volume.total),
                "free_bytes": JSON.bytes(volume.free),
                "used_fraction": JSON.fraction(volume.usedFraction),
            ]),
            "ports": ports,
            "top_apps": .array(top(s, by: .cpu, few).map { app in
                .record(["name": .string(app.name), "cpu_cores": JSON.figure(app.cpu, places: 3), "memory_bytes": JSON.bytes(app.memory)])
            }),
        ])
    }

    // MARK: Areas

    static func processor(_ s: Snapshot) -> JSON {
        let clusters = clusters(s.cpu)
        return .record([
            "time": JSON.time(s.timestamp),
            "load": JSON.fraction(s.cpu.total),
            "user": JSON.fraction(s.cpu.user),
            "system": JSON.fraction(s.cpu.system),
            "cores": .int(Int64(s.cpu.perCore.count)),
            "performance_cores": .int(Int64(s.cpu.performanceCores)),
            "efficiency_cores": .int(Int64(s.cpu.efficiencyCores)),
            "performance_load": JSON.fraction(clusters?.performance),
            "efficiency_load": JSON.fraction(clusters?.efficiency),
            // Efficiency cores first, as the Mac numbers them.
            "per_core": .array(s.cpu.perCore.map { .number($0, places: 3) }),
            "load_average": .array(s.cpu.loadAverage.map { .number($0, places: 2) }),
            "celsius": JSON.celsius(s.thermal.cpuTemperature),
            "watts": JSON.watts(s.power.cpu),
            "speed_limit": JSON.fraction(s.thermal.cpuSpeedLimit.map { Double($0) / 100 }),
            "top_apps": .array(top(s, by: .cpu, few).map { app in
                .record(["name": .string(app.name), "cpu_cores": JSON.figure(app.cpu, places: 3), "processes": .int(Int64(app.processCount))])
            }),
        ])
    }

    static func graphics(_ s: Snapshot) -> JSON {
        guard let gpu = s.gpu else { return .record(["time": JSON.time(s.timestamp), "available": .bool(false)]) }
        return .record([
            "time": JSON.time(s.timestamp),
            "available": .bool(true),
            "model": JSON.text(gpu.model),
            "cores": JSON.whole(gpu.cores),
            "load": JSON.fraction(gpu.utilization),
            "renderer_load": JSON.fraction(gpu.rendererUtilization),
            "tiler_load": JSON.fraction(gpu.tilerUtilization),
            "memory_used_bytes": JSON.bytes(gpu.memoryInUse),
            "memory_allocated_bytes": JSON.bytes(gpu.memoryAllocated),
            "celsius": JSON.celsius(s.thermal.gpuTemperature),
            "watts": JSON.watts(s.power.gpu),
            "top_apps": .array(top(s, by: .gpu, few).map { app in
                .record(["name": .string(app.name), "gpu": JSON.fraction(app.gpu)])
            }),
        ])
    }

    static func memory(_ s: Snapshot) -> JSON {
        let m = s.memory
        return .record([
            "time": JSON.time(s.timestamp),
            "total_bytes": JSON.bytes(m.total),
            "used_bytes": JSON.bytes(m.used),
            "used_fraction": JSON.fraction(m.usedFraction),
            "available_bytes": JSON.bytes(m.total > m.used ? m.total - m.used : 0),
            "app_bytes": JSON.bytes(m.app),
            "wired_bytes": JSON.bytes(m.wired),
            "compressed_bytes": JSON.bytes(m.compressed),
            "cached_bytes": JSON.bytes(m.cached),
            "swap_used_bytes": JSON.bytes(m.swapUsed),
            "swap_total_bytes": JSON.bytes(m.swapTotal),
            "pressure": .string(m.pressure.rawValue),
            "activity": .record([
                "page_in_bytes_per_second": JSON.rounded(m.activity.pageIn),
                "page_out_bytes_per_second": JSON.rounded(m.activity.pageOut),
                "swap_in_bytes_per_second": JSON.rounded(m.activity.swapIn),
                "swap_out_bytes_per_second": JSON.rounded(m.activity.swapOut),
                "compress_bytes_per_second": JSON.rounded(m.activity.compress),
                "decompress_bytes_per_second": JSON.rounded(m.activity.decompress),
            ]),
            "top_apps": .array(top(s, by: .memory, few).map { app in
                .record(["name": .string(app.name), "memory_bytes": JSON.bytes(app.memory), "processes": .int(Int64(app.processCount))])
            }),
        ])
    }

    /// One line for each kind of sensor: a Mac Studio has several hundred sensors, and nobody wants them one by one.
    struct SensorGroup {
        var name: String
        var count: Int
        var hottest: Double
        var average: Double
    }

    static func sensorGroups(_ thermal: ThermalStats) -> [SensorGroup] {
        let order = ["CPU", "GPU", "SoC", "Memory", "Storage", "Power", "Battery", "Airflow", "Enclosure", "Wireless"]
        let groups = Dictionary(grouping: thermal.sensors, by: \.group)
        let names = order.filter { groups[$0] != nil } + groups.keys.filter { !order.contains($0) }.sorted()
        return names.compactMap { name in
            guard let readings = groups[name]?.map(\.celsius), let hottest = readings.max() else { return nil }
            return SensorGroup(name: name, count: readings.count, hottest: hottest, average: readings.reduce(0, +) / Double(readings.count))
        }
    }

    static func thermals(_ s: Snapshot) -> JSON {
        let t = s.thermal
        return .record([
            "time": JSON.time(s.timestamp),
            "state": .string(t.state.rawValue),
            "throttled": .bool(t.isThrottled),
            "speed_limit": JSON.fraction(t.cpuSpeedLimit.map { Double($0) / 100 }),
            "hottest_celsius": JSON.celsius(t.hottest?.celsius),
            "hottest_sensor": JSON.text(t.hottest?.group),
            "processor_celsius": JSON.celsius(t.cpuTemperature),
            "graphics_celsius": JSON.celsius(t.gpuTemperature),
            "fans": .array(t.fans.map { fan in
                .record([
                    "fan": .int(Int64(fan.index + 1)),
                    "rpm": JSON.rounded(fan.rpm),
                    "min_rpm": JSON.rounded(fan.minRPM),
                    "max_rpm": JSON.rounded(fan.maxRPM),
                    "speed": JSON.fraction(fan.percent),
                ])
            }),
            "sensors": .array(sensorGroups(t).map { group in
                .record([
                    "group": .string(group.name),
                    "count": .int(Int64(group.count)),
                    "hottest_celsius": JSON.celsius(group.hottest),
                    "average_celsius": JSON.celsius(group.average),
                ])
            }),
        ])
    }

    /// Addresses, the Wi-Fi network's name and the names of the search domains are left out unless asked for: a
    /// reading pasted into a chat or handed to a model should not say where this Mac is or what it is called on its
    /// network.
    static func network(_ s: Snapshot, addresses: Bool) -> JSON {
        let n = s.network
        return .record([
            "time": JSON.time(s.timestamp),
            "online": .bool(n.online),
            "download_bytes_per_second": JSON.rounded(n.inBytesPerSecond),
            "upload_bytes_per_second": JSON.rounded(n.outBytesPerSecond),
            "primary_interface": JSON.text(n.primary),
            "configured_by": JSON.text(n.configMethod),
            "router": addresses ? JSON.text(n.router) : nil,
            "dns": addresses ? .array(n.dns.map { .string($0) }) : nil,
            "search_domains": addresses ? .array(n.searchDomains.map { .string($0) }) : nil,
            "firewall_on": JSON.flag(n.firewall),
            "wifi": n.wifi.map { wifi in
                .record([
                    "name": addresses ? JSON.text(wifi.ssid) : nil,
                    "signal_dbm": JSON.whole(wifi.rssi),
                    "noise_dbm": .int(Int64(wifi.noise)),
                    "quality": JSON.fraction(wifi.quality),
                    "link_bits_per_second": JSON.rounded(wifi.transmitRate * 1e6),
                    "channel": .int(Int64(wifi.channel)),
                    "band": .string(wifi.band),
                    "width": JSON.text(wifi.width),
                    "standard": .string(wifi.standard),
                    "security": .string(wifi.security),
                ])
            },
            "interfaces": .array(n.interfaces.map { item in
                .record([
                    "name": .string(item.name),
                    "title": .string(item.title),
                    "kind": .string(item.kind.rawValue),
                    "active": .bool(item.isActive),
                    "link_bits_per_second": JSON.rounded(item.linkSpeed),
                    "download_bytes_per_second": JSON.rounded(item.inRate),
                    "upload_bytes_per_second": JSON.rounded(item.outRate),
                    "ipv4": addresses ? .array(item.ipv4.map { .string($0) }) : nil,
                    "ipv6": addresses ? .array((item.ipv6 + [item.linkLocal6].compactMap { $0 }).map { .string($0) }) : nil,
                    "mac": addresses ? JSON.text(item.mac) : nil,
                ])
            }),
            "apps": n.appsMeasured ? .array(n.apps.filter { $0.rate >= busyRate }.prefix(few).map { app in
                .record([
                    "name": .string(app.name),
                    "download_bytes_per_second": JSON.rounded(app.inRate),
                    "upload_bytes_per_second": JSON.rounded(app.outRate),
                ])
            }) : nil,
            // Ports other devices can reach, by app. What only answers to this Mac itself is counted, not listed.
            "listening": n.listenersMeasured ? .array(n.listeners.filter { !$0.exposed.isEmpty }.map { app in
                .record(["name": .string(app.name), "ports": .array(Array(Set(app.exposed.map(\.port))).sorted().map { .int(Int64($0)) })])
            }) : nil,
            "listening_local_only": n.listenersMeasured ? .int(Int64(n.listeners.filter { $0.exposed.isEmpty }.count)) : nil,
        ])
    }

    static func power(_ s: Snapshot) -> JSON {
        let p = s.power
        return .record([
            "time": JSON.time(s.timestamp),
            "watts": JSON.watts(p.total),
            // Whether the figure is the whole Mac's, from its power sensor, or only the parts that report.
            "whole_mac": .bool(p.system != nil),
            "processor_watts": JSON.watts(p.cpu),
            "graphics_watts": JSON.watts(p.gpu),
            "neural_watts": JSON.watts(p.neural),
            "memory_watts": JSON.watts(p.memory),
            "rest_watts": JSON.watts(p.rest),
            "adapter_watts": JSON.watts(p.adapter),
            "battery": p.battery.map { battery in
                .record([
                    "charge": JSON.fraction(battery.charge),
                    "state": .string(battery.state),
                    "plugged_in": .bool(battery.isPluggedIn),
                    "charging": .bool(battery.isCharging),
                    "minutes_remaining": JSON.whole(battery.minutesRemaining),
                    // Positive while charging, negative while draining.
                    "watts": JSON.watts(battery.watts),
                    "health": JSON.fraction(battery.health),
                    "cycles": JSON.whole(battery.cycles),
                    "celsius": JSON.celsius(battery.celsius),
                ])
            },
            "top_apps": .array(top(s, by: .energy, few).map { app in
                .record(["name": .string(app.name), "watts": JSON.watts(app.power)])
            }),
        ])
    }

    static func storage(_ volume: VolumeSpace) -> JSON {
        .record([
            "time": JSON.time(Date()),
            "volume": .string(volume.name),
            "total_bytes": JSON.bytes(volume.total),
            "used_bytes": JSON.bytes(volume.used),
            "free_bytes": JSON.bytes(volume.free),
            "reclaimable_bytes": JSON.bytes(volume.reclaimable),
            "used_fraction": JSON.fraction(volume.usedFraction),
        ])
    }

    static func apps(_ s: Snapshot, by order: AppOrder, top count: Int) -> JSON {
        .record([
            "time": JSON.time(s.timestamp),
            "by": .string(order.rawValue),
            "apps_running": .int(Int64(s.apps.count)),
            "processes_running": .int(Int64(s.processes.count)),
            "apps": .array(s.apps.sorted { order.value($0) > order.value($1) }.prefix(count).map { app in
                .record([
                    "name": .string(app.name),
                    // 1 is one core fully busy, so an app on several cores reads above 1.
                    "cpu_cores": JSON.figure(app.cpu, places: 3),
                    "memory_bytes": JSON.bytes(app.memory),
                    "watts": JSON.watts(app.power),
                    "gpu": JSON.fraction(app.gpu),
                    "disk_read_bytes_per_second": JSON.rounded(app.diskRead),
                    "disk_write_bytes_per_second": JSON.rounded(app.diskWrite),
                    "processes": .int(Int64(app.processCount)),
                ])
            }),
        ])
    }

    static func usb(_ stats: USBStats) -> JSON {
        .record([
            "time": JSON.time(Date()),
            "devices": .int(Int64(stats.deviceCount)),
            "ports": .array(stats.ports.map { port in
                guard port.connected else {
                    return .record(["name": .string(stats.title(port)), "kind": .string(port.kind.rawValue), "connected": .bool(false)])
                }
                let diagnosis = USBDiagnostics.diagnose(port, charger: stats.charger)
                var cable: JSON?
                if let marker = port.cable {
                    cable = .record([
                        "speed_bits_per_second": JSON.rounded(marker.linkBitsPerSecond),
                        "watts": JSON.whole(marker.watts),
                        "active": .bool(marker.active),
                    ])
                }
                return .record([
                    "name": .string(stats.title(port)),
                    "kind": .string(port.kind.rawValue),
                    "connected": .bool(true),
                    "attached": .string(port.attachedName),
                    "carrying": .array(port.activeNames.map { .string($0) }),
                    "speed_bits_per_second": JSON.rounded(diagnosis.negotiated ?? port.fastestLink),
                    "charger_watts": JSON.watts(port.powerSource?.watts),
                    "cable": cable,
                    "devices": .array(port.allDevices.filter { !$0.isHub }.map { device in
                        .record(["name": .string(device.name), "speed_bits_per_second": JSON.rounded(device.bitsPerSecond)])
                    }),
                    "screens": .array(port.displays.filter(\.active).map { .string($0.name ?? "Screen") }),
                    // What the app makes of the connection: tone is good, plain or caution.
                    "findings": .array(diagnosis.all.map { verdict in
                        .record(["tone": .string(verdict.tone.rawValue), "title": .string(verdict.title), "detail": .string(verdict.detail)])
                    }),
                ])
            }),
            "charger": stats.charger.map { charger in
                .record(["name": JSON.text(charger.name), "watts": JSON.whole(charger.watts), "arriving_watts": JSON.watts(charger.inputWatts)])
            },
        ])
    }
}
