import CDotmeter
import Foundation
import IOKit
import IOKit.ps

/// What the Mac is drawing. Three sources, none needing privileges: the SMC's power sensor for the whole
/// machine, the energy counters behind `powermetrics` for the processor, graphics, neural engine and memory,
/// and the battery's own figures on a laptop.
final class PowerSampler {
    private var subscription: IOReportSubscriptionRef?
    private var channels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0
    private let smc = SMC()
    private var systemKey: String??
    private var energyWh = 0.0
    private var energyTime: UInt64 = 0
    private let started = Date()
    private var last = PowerStats()
    private var battery: BatteryInfo?
    private var adapter: Double?
    private var batteryRead = Date.distantPast
    private var cpuReports = false
    private var neuralReports = false
    private var memoryReports = false
    /// Debug: what the last reading saw in each channel, in watts.
    private(set) var channelWatts: [(name: String, watts: Double)] = []

    /// Debug: DOTMETER_LOG_POWER=1 keeps the channels whose unit is not an energy, so `--dump` can list them.
    private static let logChannels = ProcessInfo.processInfo.environment["DOTMETER_LOG_POWER"] == "1"

    /// Debug: DOTMETER_POWER_DEMO=laptop reports a made-up MacBook on battery, to review the laptop layout.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_POWER_DEMO"]

    init() {
        guard let wanted = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0) else { return }
        // An Ultra chip lists about 650 channels, nearly all per-core detail. Reading every one costs 7 ms;
        // only the totals are wanted.
        if !Self.logChannels {
            // The new list must hold on to its channels: replacing the old list releases the ones it held.
            var callbacks = kCFTypeArrayCallBacks
            if let kept = CFArrayCreateMutable(kCFAllocatorDefault, 0, &callbacks) {
                for channel in Self.channelList(of: wanted) {
                    if let name = IOReportChannelGetChannelName(channel) as String?, Self.part(for: name) != nil {
                        CFArrayAppendValue(kept, Unmanaged.passUnretained(channel).toOpaque())
                    }
                }
                if CFArrayGetCount(kept) > 0 {
                    let key = "IOReportChannels" as CFString
                    CFDictionarySetValue(wanted, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(kept).toOpaque())
                }
            }
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, wanted, &subscribed, 0, nil)
        channels = subscribed?.takeRetainedValue()
    }

    /// `light` reads only the whole machine's draw from the power sensor, which is one cheap call; the split
    /// into parts costs a few milliseconds and keeps its last values until the next full reading.
    func sample(light: Bool = false) -> PowerStats {
        var stats = last
        let now = DispatchTime.now().uptimeNanoseconds

        if !light, let subscription, let channels, let current = IOReportCreateSamples(subscription, channels, nil) {
            let elapsed = previousTime > 0 ? Double(now &- previousTime) / 1e9 : 0
            if let previous, elapsed >= 0.3, let delta = IOReportCreateSamplesDelta(previous, current, nil) {
                var cpu = 0.0, gpu = 0.0, neural = 0.0, memory = 0.0
                var sawCPU = false, sawGPU = false, sawNeural = false, sawMemory = false
                var seen: [(String, Double)] = []
                // The library writes into each channel as it is read, so the channels must stay the objects
                // it made: bridging them to Swift dictionaries hands it copies it cannot change, and it throws.
                for dictionary in Self.channelList(of: delta) {
                    guard let name = IOReportChannelGetChannelName(dictionary) as String? else { continue }
                    let unit = ((IOReportChannelGetUnitLabel(dictionary) as String?) ?? "").trimmingCharacters(in: .whitespaces)
                    let raw = Double(IOReportSimpleGetIntegerValue(dictionary, nil))
                    let joules: Double
                    switch unit {
                    case "mJ": joules = raw / 1e3
                    case "uJ", "µJ": joules = raw / 1e6
                    case "nJ": joules = raw / 1e9
                    default:
                        if Self.logChannels { seen.append(("\(name) [unit \(unit.isEmpty ? "none" : unit), raw \(Int(raw))]", 0)) }
                        continue
                    }
                    let watts = joules / elapsed
                    seen.append((name, watts))
                    switch Self.part(for: name) {
                    case .cpu: cpu += watts; sawCPU = true
                    case .gpu: gpu += watts; sawGPU = true
                    case .neural: neural += watts; sawNeural = true
                    case .memory: memory += watts; sawMemory = true
                    case nil: break
                    }
                }
                channelWatts = seen
                // Some chips list a channel and never fill it: this M3 Ultra's processor totals stay at zero.
                // A part counts as reported only once it has read above nothing.
                if cpu > 0.001 { cpuReports = true }
                if neural > 0.0005 { neuralReports = true }
                if memory > 0.001 { memoryReports = true }
                stats.cpu = sawCPU && cpuReports ? cpu : nil
                stats.gpu = sawGPU ? gpu : nil
                stats.neural = sawNeural && neuralReports ? neural : nil
                stats.memory = sawMemory && memoryReports ? memory : nil
            }
            if previous == nil || elapsed >= 0.3 {
                previous = current
                previousTime = now
            }
        }

        stats.system = readSystemPower()
        if !light, Date().timeIntervalSince(batteryRead) > 10 {
            batteryRead = Date()
            (battery, adapter) = Self.readBattery()
        }
        stats.battery = battery
        stats.adapter = adapter

        if Self.demo != nil { stats = Self.laptop(from: stats) }

        if let total = stats.total, energyTime > 0 {
            energyWh += total * Double(now &- energyTime) / 1e9 / 3600
        }
        energyTime = now
        stats.energyWh = energyWh
        stats.countingSince = started
        last = stats
        return stats
    }

    private enum Part { case cpu, gpu, neural, memory }

    /// Which part of the machine a channel is the total for. The per-core and per-cluster channels beside
    /// the totals would count the same energy again, so only exact names qualify.
    private static func part(for name: String) -> Part? {
        if name == "CPU Energy" || (name.hasPrefix("DIE_") && name.hasSuffix("_CPU Energy")) { return .cpu }
        if name == "GPU Energy" { return .gpu }
        if name.hasPrefix("ANE") { return .neural }
        if name.hasPrefix("DRAM") { return .memory }
        return nil
    }

    private static func channelList(of samples: CFDictionary) -> [CFDictionary] {
        let key = "IOReportChannels" as CFString
        guard let raw = CFDictionaryGetValue(samples, Unmanaged.passUnretained(key).toOpaque()) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        return (0..<CFArrayGetCount(array)).compactMap { index in
            CFArrayGetValueAtIndex(array, index).map { Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    /// The whole machine's draw. The key is undocumented; it is the one that reads sensibly on Apple silicon.
    private func readSystemPower() -> Double? {
        guard let smc else { return nil }
        if systemKey == nil {
            systemKey = .some(["PSTR", "PDTR", "PPBR"].first { key in
                guard let value = smc.readDouble(key) else { return false }
                return value > 0.5 && value < 2000
            })
        }
        guard let key = systemKey ?? nil, let value = smc.readDouble(key), value > 0, value < 2000 else { return nil }
        return value
    }

    /// The battery as macOS itself describes it: charge, state and time from the power sources list, which
    /// is what the system's own menu bar item shows. nil on a Mac without one.
    static func systemBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (description[kIOPSIsPresentKey] as? Bool) ?? true else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let most = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            var info = BatteryInfo(
                charge: most > 0 ? min(max(current / most, 0), 1) : 0,
                isCharging: (description[kIOPSIsChargingKey] as? Bool) ?? false,
                isPluggedIn: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            )
            info.isFull = (description[kIOPSIsChargedKey] as? Bool) ?? false
            // macOS answers -1 while it is still working the time out.
            let key = info.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if info.isCharging || !info.isPluggedIn, let minutes = (description[key] as? NSNumber)?.intValue, minutes > 0, minutes < 6000 {
                info.minutesRemaining = minutes
            }
            return info
        }
        return nil
    }

    /// The battery, with what only the battery itself knows added from the IO registry: cycles, what it can
    /// still hold, the current in or out, its temperature. The second value is the adapter's wattage.
    private static func readBattery() -> (BatteryInfo?, Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        var properties: [String: Any] = [:]
        if service != 0 {
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                properties = (unmanaged?.takeRetainedValue() as? [String: Any]) ?? [:]
            }
            IOObjectRelease(service)
        }
        func number(_ key: String) -> Double? { (properties[key] as? NSNumber)?.doubleValue }
        let adapterDetails = properties["AdapterDetails"] as? [String: Any]
        let adapter = (adapterDetails?["Watts"] as? NSNumber)?.doubleValue
        guard var info = systemBattery() else { return (nil, adapter) }

        info.cycles = number("CycleCount").map { Int($0) }
        // On Apple silicon the plain capacities are percentages; the raw ones are milliamp-hours.
        let full = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") ?? number("MaxCapacity")
        if let full, full > 200 { info.fullCapacity = Int(full) }
        if let design = number("DesignCapacity"), design > 200 {
            info.designCapacity = Int(design)
            if let full, full > 200 { info.health = min(full / design, 1) }
        }
        if let millivolts = number("Voltage"), millivolts > 0 {
            info.volts = millivolts / 1000
            if let milliamps = number("Amperage") {
                // The current is a signed 64-bit value stored unsigned.
                let signed = milliamps > 9e18 ? milliamps - 18_446_744_073_709_551_616 : milliamps
                info.watts = signed * millivolts / 1e6
            }
        }
        if let centi = number("Temperature"), centi > 0 { info.celsius = centi / 100 }
        info.adapterName = (adapterDetails?["Name"] as? String) ?? (adapterDetails?["Description"] as? String)
        return (info, adapter)
    }

    /// A made-up MacBook. DOTMETER_POWER_DEMO chooses its state: laptop (on battery), charging, low or full.
    private static func laptop(from stats: PowerStats) -> PowerStats {
        var copy = stats
        let wave = 0.5 + 0.5 * sin(Date().timeIntervalSinceReferenceDate / 9)
        let draw = 11.5 + 9 * wave
        copy.system = draw
        copy.cpu = 3.1 + 5.2 * wave
        copy.gpu = 0.9 + 2.4 * wave
        copy.neural = 0.02
        copy.memory = 0.7
        copy.adapter = nil
        var battery = BatteryInfo(charge: 0.62, isCharging: false, isPluggedIn: false, cycles: 214, health: 0.91, minutesRemaining: 312, watts: -draw, celsius: 31.4)
        battery.volts = 12.4
        battery.fullCapacity = 5687
        battery.designCapacity = 6249
        switch demo {
        case "charging":
            battery.charge = 0.34
            battery.isCharging = true
            battery.isPluggedIn = true
            battery.minutesRemaining = 48
            battery.watts = 61.5 - draw
            battery.adapterName = "96W USB-C Power Adapter"
            copy.adapter = 96
        case "low":
            battery.charge = 0.09
            battery.minutesRemaining = 24
        case "full":
            battery.charge = 1
            battery.isPluggedIn = true
            battery.isFull = true
            battery.minutesRemaining = nil
            battery.watts = 0
            battery.adapterName = "96W USB-C Power Adapter"
            copy.adapter = 96
        default:
            break
        }
        copy.battery = battery
        return copy
    }
}

/// Round trips to the router and to the internet, by ICMP echo every two seconds while the Network area is
/// on screen. Each echo runs on its own queue so a lost one cannot hold up a reading.
final class LatencyProbe: @unchecked Sendable {
    /// Cloudflare's resolver: anycast, close to everywhere, and it answers echoes.
    static let internetHost = "1.1.1.1"
    private static let keep = 150

    private let lock = NSLock()
    private var targets: [String: LatencyTarget] = [:]
    private var router: String?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt16 = 0
    private let queue = DispatchQueue(label: "dotmeter.latency", qos: .utility, attributes: .concurrent)

    /// Starts or stops the echoes. Only an IPv4 router can be asked.
    func update(active: Bool, router: String?) {
        lock.lock()
        self.router = router.flatMap { $0.contains(":") ? nil : $0 }
        let running = timer != nil
        lock.unlock()
        if active, !running {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.fire() }
            lock.lock(); self.timer = timer; lock.unlock()
            timer.resume()
        } else if !active, running {
            lock.lock()
            timer?.cancel()
            timer = nil
            lock.unlock()
        }
    }

    func snapshot() -> [LatencyTarget] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-300)
        return ["router", "internet"].compactMap { id in
            guard var target = targets[id] else { return nil }
            target.samples.removeAll { $0.time < cutoff }
            return target.samples.isEmpty && !target.blocked ? nil : target
        }
    }

    private func fire() {
        lock.lock()
        sequence &+= 1
        let number = sequence
        let router = self.router
        lock.unlock()
        if let router { queue.async { self.echo(id: "router", title: "Router", host: router, sequence: number) } }
        queue.async { self.echo(id: "internet", title: "Internet", host: Self.internetHost, sequence: number &+ 20_000) }
    }

    private func echo(id: String, title: String, host: String, sequence: UInt16) {
        var milliseconds = 0.0
        let result = dotmeter_ping(host, 1500, sequence, &milliseconds)
        let code = errno
        lock.lock()
        var target = targets[id] ?? LatencyTarget(id: id, title: title, host: host)
        if target.host != host { target = LatencyTarget(id: id, title: title, host: host) }
        // Refused before it left: no route, or macOS has not been allowed to reach the local network.
        target.blocked = result < 0 && (code == EHOSTUNREACH || code == EPERM || code == EACCES || code == ENETUNREACH)
        target.samples.append(.init(time: Date(), milliseconds: result == 0 ? milliseconds : nil))
        if target.samples.count > Self.keep { target.samples.removeFirst(target.samples.count - Self.keep) }
        targets[id] = target
        lock.unlock()
    }
}
