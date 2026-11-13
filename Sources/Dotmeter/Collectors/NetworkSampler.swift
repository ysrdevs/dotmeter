import CDotmeter
import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Everything about the network that can be read without privileges and without sending a packet:
/// the kernel's interface counters, addresses, what System Settings calls each port, the default route and
/// DNS from the system configuration store, the Wi-Fi link from CoreWLAN, and per-app traffic from `nettop`.
final class NetworkSampler {
    private struct Counters {
        var inBytes: UInt64
        var outBytes: UInt64
    }

    private struct Hardware {
        var title: String
        var kind: NetworkInterface.Kind
        var order: Int
    }

    private struct Addresses {
        var ipv4: [String] = []
        var netmask: String?
        var ipv6: [String] = []
        var linkLocal6: String?
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: UInt64 = 0
    /// Bytes each interface has carried since this sampler first saw it. The kernel's own totals cannot be
    /// shown as they are: some drivers (this Mac's Wi-Fi among them) wrap at 4 GB even in the 64-bit structure.
    private var carried: [String: Counters] = [:]
    private let started = Date()
    private var raw = [dotmeter_interface_t](repeating: dotmeter_interface_t(), count: 160)
    private var hardware: [String: Hardware] = [:]
    private var hardwareRead = Date.distantPast
    private var store: SCDynamicStore?
    private var wifi: WiFiInfo?
    private var wifiRead = Date.distantPast
    private var last = NetworkStats(inBytesPerSecond: 0, outBytesPerSecond: 0)
    private var hasDetail = false
    private let appSampler = NetworkAppSampler()
    private let portSampler = PortSampler()
    private let latencyProbe = LatencyProbe()

    /// Debug: DOTMETER_NET_DEMO=1 replaces the readings with a busy, made-up connection, for design review.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_NET_DEMO"] == "1"

    /// `detail` false only refreshes the counters (the menu bar's needs); `apps` adds per-app traffic,
    /// attributed to the app groups the process sampler found.
    func sample(detail: Bool = true, apps appsEvery: Double? = nil, latency wantLatency: Bool = false, ports wantPorts: Bool = false, groups: [AppUsage] = []) -> NetworkStats {
        let wantApps = appsEvery != nil
        if Self.demo { return NetworkDemo.stats(at: Date(), apps: wantApps, latency: wantLatency, ports: wantPorts) }

        let count = max(0, Int(dotmeter_interfaces(&raw, Int32(raw.count))))
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = previousTime > 0 ? Double(now &- previousTime) / 1e9 : 0
        // Two readings a moment apart turn one burst into a wild rate; keep the last figures instead.
        let tooSoon = dt > 0 && dt < 0.3

        var entries: [String: dotmeter_interface_t] = [:]
        var rates: [String: (in: Double, out: Double)] = [:]
        var next: [String: Counters] = [:]
        var totalIn = 0.0, totalOut = 0.0
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for i in 0..<count {
            let entry = raw[i]
            let name = Self.name(of: entry)
            guard !name.isEmpty else { continue }
            entries[name] = entry
            next[name] = Counters(inBytes: entry.ibytes, outBytes: entry.obytes)
            var rate = (in: 0.0, out: 0.0)
            if let before = previous[name], dt > 0 {
                // The most this link could have carried since the last reading, with room to spare.
                let most = (entry.baudrate > 0 ? Double(entry.baudrate) / 8 * 1.5 : 1.25e9) * max(dt, 1)
                let moved = Counters(inBytes: Self.advance(from: before.inBytes, to: entry.ibytes, atMost: most), outBytes: Self.advance(from: before.outBytes, to: entry.obytes, atMost: most))
                rate = (Double(moved.inBytes) / dt, Double(moved.outBytes) / dt)
                if !tooSoon {
                    var total = carried[name] ?? Counters(inBytes: 0, outBytes: 0)
                    total.inBytes &+= moved.inBytes
                    total.outBytes &+= moved.outBytes
                    carried[name] = total
                }
            }
            rates[name] = rate
            if Self.isCounted(name) {
                totalIn += rate.in
                totalOut += rate.out
                bytesIn &+= carried[name]?.inBytes ?? 0
                bytesOut &+= carried[name]?.outBytes ?? 0
            }
        }
        if !tooSoon {
            previous = next
            previousTime = now
        }

        var stats = last
        if !tooSoon {
            stats.inBytesPerSecond = totalIn
            stats.outBytesPerSecond = totalOut
        }
        stats.inBytes = bytesIn
        stats.outBytes = bytesOut
        stats.countingSince = started

        if !detail, hasDetail {
            for i in stats.interfaces.indices {
                let name = stats.interfaces[i].name
                if !tooSoon, let rate = rates[name] {
                    stats.interfaces[i].inRate = rate.in
                    stats.interfaces[i].outRate = rate.out
                }
                stats.interfaces[i].inBytes = carried[name]?.inBytes ?? 0
                stats.interfaces[i].outBytes = carried[name]?.outBytes ?? 0
            }
            last = stats
            return stats
        }

        refreshHardware()
        let addresses = readAddresses()
        let wifiInfo = readWiFi()

        let ipv4 = storeValue("State:/Network/Global/IPv4")
        let ipv6 = storeValue("State:/Network/Global/IPv6")
        stats.primary = (ipv4?["PrimaryInterface"] as? String) ?? (ipv6?["PrimaryInterface"] as? String)
        stats.router = (ipv4?["Router"] as? String) ?? (ipv6?["Router"] as? String)
        let dns = storeValue("State:/Network/Global/DNS")
        stats.dns = (dns?["ServerAddresses"] as? [String]) ?? []
        stats.searchDomains = (dns?["SearchDomains"] as? [String]) ?? (dns?["DomainName"] as? String).map { [$0] } ?? []
        stats.configMethod = nil
        if let service = ipv4?["PrimaryService"] as? String {
            stats.configMethod = storeValue("Setup:/Network/Service/\(service)/IPv4")?["ConfigMethod"] as? String
        }
        stats.wifi = wifiInfo

        var interfaces: [NetworkInterface] = []
        for (name, entry) in entries {
            let known = hardware[name]
            let address = addresses[name] ?? Addresses()
            let up = entry.flags & UInt32(IFF_UP) != 0 && entry.flags & UInt32(IFF_RUNNING) != 0
            let hasAddress = !address.ipv4.isEmpty || !address.ipv6.isEmpty
            // Ports System Settings lists, and anything else that is up with a routable address (tunnels, mostly).
            guard known != nil || (up && hasAddress && !name.hasPrefix("lo")) else { continue }

            var active: Int32 = 0, duplex: Int32 = 0
            let hasMedia = dotmeter_interface_media(name, &active, &duplex) == 0
            let isActive = hasMedia ? (up && active != 0) : (up && hasAddress)
            let described = known.map { ($0.title, $0.kind) } ?? Self.describe(name)

            var item = NetworkInterface(name: name, title: described.0, kind: described.1, isActive: isActive)
            item.ipv4 = address.ipv4
            item.netmask = address.netmask
            item.ipv6 = address.ipv6
            item.linkLocal6 = address.linkLocal6
            if entry.mac_length == 6 {
                let mac = entry.mac
                let text = [mac.0, mac.1, mac.2, mac.3, mac.4, mac.5].map { String(format: "%02x", $0) }.joined(separator: ":")
                // macOS hands apps a placeholder in place of the Wi-Fi hardware address.
                if text != "02:00:00:00:00:00" && text != "00:00:00:00:00:00" { item.mac = text }
            }
            item.mtu = Int(entry.mtu)
            if isActive {
                if let wifiInfo, wifiInfo.interface == name, wifiInfo.transmitRate > 0 {
                    item.linkSpeed = wifiInfo.transmitRate * 1e6
                } else if entry.baudrate > 0, described.1 != .tunnel {
                    item.linkSpeed = Double(entry.baudrate)
                }
                if hasMedia, described.1 == .ethernet || described.1 == .thunderbolt { item.fullDuplex = duplex != 0 }
            }
            if let rate = rates[name] {
                item.inRate = rate.in
                item.outRate = rate.out
            }
            if tooSoon, let before = last.interfaces.first(where: { $0.name == name }) {
                item.inRate = before.inRate
                item.outRate = before.outRate
            }
            item.inBytes = carried[name]?.inBytes ?? 0
            item.outBytes = carried[name]?.outBytes ?? 0
            item.inPackets = entry.ipackets
            item.outPackets = entry.opackets
            item.inErrors = entry.ierrors
            item.outErrors = entry.oerrors
            interfaces.append(item)
        }
        let primary = stats.primary
        func rank(_ item: NetworkInterface) -> (Int, Int, String) {
            if item.name == primary { return (0, 0, item.name) }
            return (item.isActive ? 1 : 2, hardware[item.name]?.order ?? 900, item.name)
        }
        stats.interfaces = interfaces.sorted { rank($0) < rank($1) }

        latencyProbe.update(active: wantLatency, router: stats.router)
        stats.latency = wantLatency ? latencyProbe.snapshot() : []
        stats.appsAvailable = appSampler.available
        if let appsEvery, let readings = appSampler.sample(every: appsEvery) {
            stats.apps = Self.group(readings, into: groups)
            stats.appsMeasured = true
        } else if !wantApps {
            stats.apps = []
            stats.appsMeasured = false
        }

        // Listeners come and go slowly; every five seconds is plenty while the page is open.
        stats.listenersAvailable = portSampler.available
        if wantPorts, let readings = portSampler.sample(every: 5) {
            stats.listeners = Self.group(readings, into: groups)
            stats.listenersMeasured = true
            stats.firewall = portSampler.firewallOn()
        } else if !wantPorts {
            stats.listeners = []
            stats.listenersMeasured = false
        }

        hasDetail = true
        last = stats
        return stats
    }

    /// Folds listening sockets into the same app groups the rest of the app uses. What launchd holds open on
    /// behalf of a sharing service is named for the system, and reachable apps come first.
    static func group(_ readings: [PortSampler.Reading], into groups: [AppUsage]) -> [ListeningApp] {
        var owners: [Int32: (id: String, name: String, bundlePath: String?)] = [:]
        for group in groups {
            for child in group.children { owners[child.pid] = (group.id, group.name, group.bundlePath) }
        }
        var apps: [String: ListeningApp] = [:]
        for reading in readings {
            let owner: (id: String, name: String, bundlePath: String?)
            if reading.pid == 1 {
                owner = ("proc:launchd", "macOS sharing services", nil)
            } else {
                owner = owners[reading.pid] ?? ("proc:" + reading.process, reading.process, nil)
            }
            let port = ListeningPort(port: reading.port, pid: reading.pid, process: reading.process, exposed: reading.exposed)
            if apps[owner.id] != nil {
                // One app's helpers can each hold the same port number on different addresses; show it once.
                if let index = apps[owner.id]?.ports.firstIndex(where: { $0.port == port.port }) {
                    if port.exposed { apps[owner.id]?.ports[index].exposed = true }
                } else {
                    apps[owner.id]?.ports.append(port)
                }
            } else {
                apps[owner.id] = ListeningApp(id: owner.id, name: owner.name, bundlePath: owner.bundlePath, ports: [port])
            }
        }
        return apps.values
            .map { app in
                var sorted = app
                sorted.ports.sort { $0.port < $1.port }
                return sorted
            }
            .sorted { a, b in
                if a.exposed.isEmpty != b.exposed.isEmpty { return !a.exposed.isEmpty }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    // MARK: Pieces

    private static func name(of entry: dotmeter_interface_t) -> String {
        withUnsafeBytes(of: entry.name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// How far a byte counter moved between two readings. A counter that fell back from just under the
    /// 32-bit limit, by no more than the link could have carried, has wrapped. Anything else going backwards
    /// means the interface was reset, and counts as nothing.
    static func advance(from old: UInt64, to new: UInt64, atMost most: Double) -> UInt64 {
        if new >= old { return new - old }
        let limit: UInt64 = 1 << 32
        guard old < limit else { return 0 }
        let wrapped = new &+ limit &- old
        return Double(wrapped) <= most ? wrapped : 0
    }

    /// Physical links only. A tunnel's traffic also crosses the link under it, and a bridge repeats its members.
    private static func isCounted(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("pdp_ip")
    }

    /// Interfaces that are not hardware ports.
    private static func describe(_ name: String) -> (String, NetworkInterface.Kind) {
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun") || name.hasPrefix("tap") { return ("Tunnel", .tunnel) }
        if name.hasPrefix("pdp_ip") { return ("Cellular", .cellular) }
        if name.hasPrefix("bridge") { return ("Virtual bridge", .bridge) }
        if name.hasPrefix("vmenet") || name.hasPrefix("vmnet") { return ("Virtual machine", .other) }
        if name.hasPrefix("ap") { return ("Hotspot", .wifi) }
        return (name, .other)
    }

    /// Port names as System Settings shows them. They only change when hardware does, so once a minute is plenty.
    private func refreshHardware() {
        guard Date().timeIntervalSince(hardwareRead) > 60 else { return }
        hardwareRead = Date()
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        var found: [String: Hardware] = [:]
        for (index, interface) in all.enumerated() {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let title = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? name
            let type = (SCNetworkInterfaceGetInterfaceType(interface) as String?) ?? ""
            var kind = NetworkInterface.Kind.other
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = .wifi }
            else if type == "Bridge" { kind = .bridge }
            else if type == (kSCNetworkInterfaceTypeEthernet as String) { kind = title.hasPrefix("Thunderbolt") ? .thunderbolt : .ethernet }
            else if type == (kSCNetworkInterfaceTypeWWAN as String) { kind = .cellular }
            else if type == (kSCNetworkInterfaceTypePPP as String) || type == (kSCNetworkInterfaceTypeIPSec as String) || type == "VPN" { kind = .tunnel }
            found[name] = Hardware(title: title, kind: kind, order: index)
        }
        hardware = found
    }

    private func readAddresses() -> [String: Addresses] {
        var result: [String: Addresses] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next
            guard let address = ifa.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            var text = String(cString: host)
            if family == AF_INET {
                result[name, default: Addresses()].ipv4.append(text)
                if result[name]?.netmask == nil, let mask = ifa.ifa_netmask {
                    var inner = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &inner, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        result[name]?.netmask = String(cString: buffer)
                    }
                }
            } else {
                // Link-local addresses come back with the interface appended ("fe80::1%en0").
                if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                if text.lowercased().hasPrefix("fe80") {
                    result[name, default: Addresses()].linkLocal6 = text
                } else {
                    result[name, default: Addresses()].ipv6.append(text)
                }
            }
        }
        return result
    }

    private func storeValue(_ key: String) -> [String: Any]? {
        if store == nil { store = SCDynamicStoreCreate(nil, "\(App.name)" as CFString, nil, nil) }
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// The Wi-Fi link, when a network is joined. CoreWLAN asks a system service, so it is read every few seconds.
    private func readWiFi() -> WiFiInfo? {
        guard Date().timeIntervalSince(wifiRead) > 3.5 else { return wifi }
        wifiRead = Date()
        wifi = nil
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let channel = interface.wlanChannel(), let name = interface.interfaceName else { return nil }
        // Not joined: no rate. Joined but with the signal withheld, the strength reads as exactly zero.
        let rate = interface.transmitRate()
        let strength = interface.rssiValue()
        guard rate > 0 || strength != 0 else { return nil }
        let rssi: Int? = strength != 0 ? strength : nil

        let band: String
        switch channel.channelBand.rawValue {
        case 1: band = "2.4 GHz"
        case 2: band = "5 GHz"
        case 3: band = "6 GHz"
        default: band = channel.channelNumber <= 14 ? "2.4 GHz" : "5 GHz"
        }
        let width: String?
        switch channel.channelWidth.rawValue {
        case 1: width = "20 MHz"
        case 2: width = "40 MHz"
        case 3: width = "80 MHz"
        case 4: width = "160 MHz"
        case 5: width = "320 MHz"
        default: width = nil
        }
        let standard: String
        switch interface.activePHYMode().rawValue {
        case 1: standard = "802.11a"
        case 2: standard = "802.11b"
        case 3: standard = "802.11g"
        case 4: standard = "Wi-Fi 4 (802.11n)"
        case 5: standard = "Wi-Fi 5 (802.11ac)"
        case 6: standard = band == "6 GHz" ? "Wi-Fi 6E (802.11ax)" : "Wi-Fi 6 (802.11ax)"
        case 7: standard = "Wi-Fi 7 (802.11be)"
        default: standard = "Unknown"
        }
        let security: String
        switch interface.security().rawValue {
        case 0: security = "Open"
        case 1, 6: security = "WEP"
        case 2, 3: security = "WPA Personal"
        case 4, 5: security = "WPA2 Personal"
        case 7, 8: security = "WPA Enterprise"
        case 9, 10: security = "WPA2 Enterprise"
        case 11: security = "WPA3 Personal"
        case 12: security = "WPA3 Enterprise"
        case 13: security = "WPA2/WPA3 Personal"
        case 14, 15: security = "Enhanced Open"
        default: security = "Unknown"
        }
        wifi = WiFiInfo(
            interface: name, ssid: interface.ssid(), rssi: rssi, noise: interface.noiseMeasurement(),
            transmitRate: rate, channel: channel.channelNumber, band: band, width: width,
            standard: standard, security: security, country: interface.countryCode()
        )
        return wifi
    }

    /// Folds per-process readings into the same app groups the processor and memory areas use.
    private static func group(_ readings: [Int32: NetworkAppSampler.Reading], into groups: [AppUsage]) -> [NetworkAppUsage] {
        struct Owner {
            var id: String
            var name: String
            var bundlePath: String?
            var process: String
        }
        var owners: [Int32: Owner] = [:]
        for group in groups {
            for child in group.children {
                owners[child.pid] = Owner(id: group.id, name: group.name, bundlePath: group.bundlePath, process: child.name)
            }
        }
        var apps: [String: NetworkAppUsage] = [:]
        for (pid, reading) in readings where reading.inBytes > 0 || reading.outBytes > 0 || reading.inRate > 0 || reading.outRate > 0 {
            // Processes owned by root are invisible to libproc; they keep the (shortened) name nettop gives them.
            let owner = owners[pid] ?? Owner(id: "proc:" + reading.name, name: reading.name, bundlePath: nil, process: reading.name)
            let process = NetworkProcessUsage(pid: pid, name: owner.process, inRate: reading.inRate, outRate: reading.outRate, inBytes: reading.inBytes, outBytes: reading.outBytes)
            if var app = apps[owner.id] {
                app.inRate += reading.inRate
                app.outRate += reading.outRate
                app.inBytes &+= reading.inBytes
                app.outBytes &+= reading.outBytes
                app.processes.append(process)
                apps[owner.id] = app
            } else {
                apps[owner.id] = NetworkAppUsage(id: owner.id, name: owner.name, bundlePath: owner.bundlePath, inRate: reading.inRate, outRate: reading.outRate, inBytes: reading.inBytes, outBytes: reading.outBytes, processes: [process])
            }
        }
        func before(_ a: (Double, UInt64, String), _ b: (Double, UInt64, String)) -> Bool {
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.2 < b.2
        }
        return apps.values.map { app in
            var sorted = app
            sorted.processes.sort { before(($0.rate, $0.inBytes &+ $0.outBytes, $0.name), ($1.rate, $1.inBytes &+ $1.outBytes, $1.name)) }
            return sorted
        }
        .sorted { before(($0.rate, $0.bytes, $0.name), ($1.rate, $1.bytes, $1.name)) }
    }
}

/// Per-process traffic from `nettop`, the tool behind Activity Monitor's Network tab.
///
/// One reading costs about 40 ms of CPU, so it is only taken while something on screen shows it, and at most
/// every couple of seconds. Left running in its logging mode the tool spins a full core, so each reading is a
/// fresh one-shot. A reading is the bytes carried by each process's open connections; the rate is the change
/// since the reading before. When a process closes connections its total drops, and for that one reading the
/// rate is carried over at half strength rather than shown as zero.
final class NetworkAppSampler {
    struct Reading {
        var name: String
        var inBytes: UInt64
        var outBytes: UInt64
        var inRate = 0.0
        var outRate = 0.0
    }

    private static let tool = "/usr/bin/nettop"

    private var readings: [Int32: Reading] = [:]
    private var sampledAt: UInt64 = 0
    private var measured = false
    private var failures = 0

    var available: Bool { failures < 3 }

    /// nil until two readings exist to compare, or when the tool is missing. `every` is the least time between
    /// readings; until there is a rate to show, the second reading is taken as soon as a second has passed.
    func sample(every: Double) -> [Int32: Reading]? {
        let now = DispatchTime.now().uptimeNanoseconds
        let gap = sampledAt > 0 ? Double(now &- sampledAt) / 1e9 : .infinity
        if gap < (measured ? every : 0.9) { return measured ? readings : nil }
        guard failures < 3 else { return nil }
        guard let output = run() else {
            failures += 1
            return nil
        }
        failures = 0
        // A reading from before a long pause says nothing about the rate now.
        let comparable = gap < 15
        var next: [Int32: Reading] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, let inBytes = UInt64(fields[fields.count - 3]), let outBytes = UInt64(fields[fields.count - 2]) else { continue }
            let label = fields[0..<(fields.count - 3)].joined(separator: ",")
            guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { continue }
            var reading = Reading(name: String(label[..<dot]), inBytes: inBytes, outBytes: outBytes)
            if comparable, let before = readings[pid] {
                reading.inRate = inBytes >= before.inBytes ? Double(inBytes - before.inBytes) / gap : before.inRate * 0.5
                reading.outRate = outBytes >= before.outBytes ? Double(outBytes - before.outBytes) / gap : before.outRate * 0.5
            }
            next[pid] = reading
        }
        measured = comparable && !readings.isEmpty
        readings = next
        sampledAt = now
        return measured ? readings : nil
    }

    private func run() -> String? {
        guard FileManager.default.isExecutableFile(atPath: Self.tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tool)
        // One sample, per process, as CSV, numeric, without loopback traffic.
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-t", "external", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // The tool answers in about 40 ms. If it ever hangs, it must not take the whole sampler with it.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A made-up, busy connection (`DOTMETER_NET_DEMO=1`): a large download, a video call and a backup upload on
/// Wi-Fi 6E, with a tunnel up. Addresses come from the ranges reserved for documentation.
enum NetworkDemo {
    private static let start = Date()

    private static func wave(_ t: Double, _ period: Double, _ phase: Double) -> Double {
        0.5 + 0.5 * sin(t / period * 2 * .pi + phase)
    }

    /// Download and upload in bytes per second at a moment in time.
    static func totals(at time: Date) -> (down: Double, up: Double) {
        let t = time.timeIntervalSinceReferenceDate
        let burst = wave(t, 173, 0.4) > 0.3 ? 1.0 : 0.12
        let down = (30e6 * burst * (0.62 + 0.38 * wave(t, 23, 1.1)) + 1.4e6 * wave(t, 9, 0.2) + 0.4e6) * (0.92 + 0.08 * wave(t, 3.1, 2))
        let up = 4.6e6 * (0.55 + 0.45 * wave(t, 41, 2.6)) * (wave(t, 211, 1.9) > 0.25 ? 1 : 0.08) + 0.9e6 * wave(t, 7, 0.9) + 0.12e6
        return (down, up)
    }

    static func stats(at time: Date, apps wantApps: Bool, latency wantLatency: Bool = false, ports wantPorts: Bool = false) -> NetworkStats {
        let (down, up) = totals(at: time)
        // History is filled in backwards from launch, so the moment asked about can be before it.
        let elapsed = max(0, time.timeIntervalSince(start))
        var stats = NetworkStats(inBytesPerSecond: down, outBytesPerSecond: up)
        stats.inBytes = 48_300_000_000 + UInt64(elapsed * 21e6)
        stats.outBytes = 6_120_000_000 + UInt64(elapsed * 3.1e6)
        stats.countingSince = start.addingTimeInterval(-11_640)
        stats.primary = "en1"
        stats.router = "192.0.2.1"
        stats.dns = ["192.0.2.1", "2001:db8::1"]
        stats.searchDomains = ["home.example"]
        stats.configMethod = "DHCP"
        let t = time.timeIntervalSinceReferenceDate
        let rssi: Int? = -51 - Int((6 * wave(t, 67, 0.3)).rounded())
        stats.wifi = WiFiInfo(interface: "en1", ssid: "Parkside 6E", rssi: rssi, noise: -93, transmitRate: 2161, channel: 37, band: "6 GHz", width: "160 MHz", standard: "Wi-Fi 6E (802.11ax)", security: "WPA3 Personal", country: "CA")

        var wifi = NetworkInterface(name: "en1", title: "Wi-Fi", kind: .wifi, isActive: true)
        wifi.ipv4 = ["192.0.2.24"]
        wifi.netmask = "255.255.255.0"
        wifi.ipv6 = ["2001:db8:4c2:1:18f2:9a3c:71d0:5be4"]
        wifi.linkLocal6 = "fe80::1c4f:9aff:fe21:7e03"
        wifi.mac = "1e:4f:9a:21:7e:03"
        wifi.mtu = 1500
        wifi.linkSpeed = 2161e6
        wifi.inRate = down
        wifi.outRate = up
        wifi.inBytes = stats.inBytes
        wifi.outBytes = stats.outBytes
        wifi.inPackets = 41_882_113
        wifi.outPackets = 12_540_871
        var tunnel = NetworkInterface(name: "utun4", title: "Tunnel", kind: .tunnel, isActive: true)
        tunnel.ipv4 = ["198.51.100.7"]
        tunnel.netmask = "255.255.255.255"
        tunnel.mtu = 1280
        tunnel.inRate = 0.21e6 * wave(t, 13, 0.5)
        tunnel.outRate = 0.06e6 * wave(t, 11, 1.5)
        tunnel.inBytes = 1_840_000_000
        tunnel.outBytes = 392_000_000
        tunnel.inPackets = 2_113_402
        tunnel.outPackets = 1_204_377
        var ethernet = NetworkInterface(name: "en0", title: "Ethernet", kind: .ethernet, isActive: false)
        ethernet.mac = "a4:fc:14:0d:52:9b"
        ethernet.mtu = 1500
        var bridge = NetworkInterface(name: "bridge0", title: "Thunderbolt Bridge", kind: .bridge, isActive: false)
        bridge.mtu = 1500
        let ports = (1...3).map { NetworkInterface(name: "en\($0 + 1)", title: "Thunderbolt \($0)", kind: .thunderbolt, isActive: false) }
        stats.interfaces = [wifi, tunnel, ethernet, bridge] + ports

        if wantLatency {
            // Five minutes of echoes: a steady router, an internet path with the odd spike and one lost echo.
            func series(_ base: Double, _ spread: Double, lossAt: Int?) -> [LatencyTarget.Sample] {
                (0..<150).map { index in
                    let moment = time.addingTimeInterval(-Double(149 - index) * 2)
                    let s = moment.timeIntervalSinceReferenceDate
                    let spike = wave(s, 61, 0.7) > 0.93 ? base * 2.4 : 0
                    let value = base + spread * wave(s, 3.7, 1.3) + spread * 0.6 * wave(s, 11, 0.2) + spike
                    return .init(time: moment, milliseconds: index == lossAt ? nil : value)
                }
            }
            stats.latency = [
                LatencyTarget(id: "router", title: "Router", host: "192.0.2.1", samples: series(2.1, 1.4, lossAt: nil)),
                LatencyTarget(id: "internet", title: "Internet", host: LatencyProbe.internetHost, samples: series(13.5, 6, lossAt: 97)),
            ]
        }
        if wantPorts {
            // A few sharing services open to the network, and some developer tools that answer only here.
            func app(_ name: String, _ path: String?, _ ports: [(Int, Bool)], pid: Int32) -> ListeningApp {
                ListeningApp(id: path ?? "proc:" + name, name: name, bundlePath: path, ports: ports.map { ListeningPort(port: $0.0, pid: pid, process: name, exposed: $0.1) })
            }
            stats.listeners = [
                app("macOS sharing services", nil, [(22, true), (445, true), (5900, true)], pid: 1),
                app("Control Center", "/System/Library/CoreServices/ControlCenter.app", [(5000, true), (7000, true)], pid: 788),
                app("node", nil, [(3000, true), (3001, true), (8789, false)], pid: 674),
                app("Penrose Studio", "/Applications/Penrose Studio.app", [(49152, true)], pid: 1670),
                app("Atlas", "/Applications/Atlas.app", [(7265, false)], pid: 919),
                app("ollama", nil, [(11434, false)], pid: 882),
                app("postgres", nil, [(5432, false)], pid: 472),
                app("Northwind Mail", "/Applications/Northwind Mail.app", [(25, false), (587, false)], pid: 377),
            ]
            stats.listenersMeasured = true
            stats.firewall = false
        }
        guard wantApps else { return stats }
        // Shares of the totals, so the apps always add up to a little less than the interface counters.
        let rows: [(String, String?, Double, Double, UInt64, UInt64, [(String, Double)])] = [
            ("App Store", "/System/Applications/App Store.app", 0.71, 0.02, 9_420_000_000, 31_000_000, [("appstoreagent", 0.82), ("App Store", 0.18)]),
            ("FaceTime", "/System/Applications/FaceTime.app", 0.045, 0.19, 612_000_000, 540_000_000, [("avconferenced", 1)]),
            ("Safari", "/Applications/Safari.app", 0.12, 0.03, 2_310_000_000, 148_000_000, [("com.apple.WebKit.Networking", 0.93), ("Safari", 0.07)]),
            ("Time Machine", nil, 0.004, 0.62, 44_000_000, 3_870_000_000, [("backupd", 1)]),
            ("Music", "/System/Applications/Music.app", 0.031, 0.004, 388_000_000, 9_000_000, [("Music", 1)]),
            ("Mail", "/System/Applications/Mail.app", 0.012, 0.022, 96_000_000, 41_000_000, [("Mail", 1)]),
            ("Messages", "/System/Applications/Messages.app", 0.006, 0.011, 31_000_000, 18_000_000, [("imagent", 1)]),
            ("cloudd", nil, 0.021, 0.064, 512_000_000, 730_000_000, [("cloudd", 1)]),
            ("mDNSResponder", nil, 0.002, 0.003, 104_000_000, 22_000_000, [("mDNSResponder", 1)]),
            ("Calendar", "/System/Applications/Calendar.app", 0.001, 0.001, 4_000_000, 2_000_000, [("Calendar", 1)]),
        ]
        stats.apps = rows.enumerated().map { index, row in
            let wobble = 0.8 + 0.2 * wave(t, 5 + Double(index) * 1.7, Double(index))
            let inRate = down * row.2 * wobble, outRate = up * row.3 * wobble
            let processes = row.6.enumerated().map { offset, part in
                NetworkProcessUsage(pid: Int32(1200 + index * 37 + offset), name: part.0, inRate: inRate * part.1, outRate: outRate * part.1, inBytes: UInt64(Double(row.4) * part.1), outBytes: UInt64(Double(row.5) * part.1))
            }
            return NetworkAppUsage(id: row.1 ?? "proc:" + row.0, name: row.0, bundlePath: row.1, inRate: inRate, outRate: outRate, inBytes: row.4, outBytes: row.5, processes: processes)
        }
        .sorted { $0.rate > $1.rate }
        stats.appsMeasured = true
        return stats
    }
}
