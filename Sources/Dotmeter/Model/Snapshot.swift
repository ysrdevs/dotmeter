import Foundation

/// One complete reading of the machine. Everything the UI shows and everything Claude sees derives from this.
struct Snapshot: Codable {
    var timestamp: Date
    var cpu: CPUStats
    var memory: MemoryStats
    var thermal: ThermalStats
    var gpu: GPUStats?
    var disk: DiskStats
    var network: NetworkStats
    var power: PowerStats
    var apps: [AppUsage]
    var processes: [ProcessUsage]
    var system: SystemInfo
    /// Ports, cables and what is on them. Only read while something shows it or a saved cable is being followed.
    var usb: USBStats? = nil
}

struct CPUStats: Codable {
    /// 0...1 fraction of all cores.
    var total: Double
    var user: Double
    var system: Double
    /// 0...1 per logical core, efficiency cores first.
    var perCore: [Double]
    var performanceCores: Int
    var efficiencyCores: Int
    var loadAverage: [Double]

    static let empty = CPUStats(total: 0, user: 0, system: 0, perCore: [], performanceCores: 0, efficiencyCores: 0, loadAverage: [0, 0, 0])
}

enum MemoryPressure: String, Codable {
    case normal, warning, critical

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct MemoryStats: Codable {
    var total: UInt64
    var used: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure
    /// What the memory system is doing right now, in bytes a second: pages read back from files and written out
    /// to them, moved to and from swap, and squeezed into and out of the compressor. Size alone says how full
    /// memory is; these say whether the Mac is paying for it at this moment.
    var activity = MemoryActivity()

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func empty(total: UInt64) -> MemoryStats {
        MemoryStats(total: total, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
    }
}

enum ThermalLevel: String, Codable, Comparable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

struct FanReading: Codable, Identifiable {
    var index: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var target: Double?
    /// 0...1 between min and max speed.
    var percent: Double

    var id: Int { index }
}

struct TemperatureReading: Codable, Identifiable {
    var key: String
    var label: String
    var celsius: Double
    var group: String

    var id: String { key }
}

struct ThermalStats: Codable {
    var state: ThermalLevel
    var fans: [FanReading]
    var sensors: [TemperatureReading]
    var hottest: TemperatureReading?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    /// Percentage of full speed the system currently allows (100 = no throttling). nil when unknown.
    var cpuSpeedLimit: Int?

    var averageFanPercent: Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map(\.percent).reduce(0, +) / Double(fans.count)
    }

    var averageRPM: Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map(\.rpm).reduce(0, +) / Double(fans.count)
    }

    var isThrottled: Bool { (cpuSpeedLimit ?? 100) < 100 }
}

struct GPUStats: Codable {
    /// 0...1
    var utilization: Double
    var rendererUtilization: Double?
    var tilerUtilization: Double?
    /// Graphics memory in use and set aside, in bytes. On Apple silicon it comes out of main memory.
    var memoryInUse: UInt64?
    var memoryAllocated: UInt64?
    var model: String?
    var cores: Int?
}

/// What the Mac is drawing, in watts. Each part is nil where the hardware does not report it.
struct PowerStats: Codable {
    /// The whole machine, from the power sensor.
    var system: Double?
    var cpu: Double?
    var gpu: Double?
    var neural: Double?
    var memory: Double?
    /// What the power adapter is rated to supply.
    var adapter: Double?
    var battery: BatteryInfo?
    /// Watt-hours counted since Dotmeter started.
    var energyWh = 0.0
    var countingSince: Date?

    /// The headline figure: the sensor's when there is one, otherwise the parts that are known.
    var total: Double? {
        if let system { return system }
        let parts = [cpu, gpu, neural, memory].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// Display, storage, fans, ports and conversion losses: the whole minus the parts that are measured.
    var rest: Double? {
        guard let system else { return nil }
        return max(0, system - [cpu, gpu, neural, memory].compactMap { $0 }.reduce(0, +))
    }

    static let none = PowerStats()
}

struct BatteryInfo: Codable {
    /// 0...1
    var charge: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var cycles: Int?
    /// Full-charge capacity against design capacity, 0...1.
    var health: Double?
    var minutesRemaining: Int?
    /// Positive while charging, negative while draining.
    var watts: Double?
    var celsius: Double?
    /// macOS says it is full.
    var isFull = false
    var volts: Double?
    /// What it holds when full now, and what it held when new, in milliamp-hours.
    var fullCapacity: Int?
    var designCapacity: Int?
    var adapterName: String?

    /// In a few words: "on battery", "charging", "fully charged", "plugged in, not charging".
    var state: String {
        if isCharging { return "charging" }
        if !isPluggedIn { return "on battery" }
        return isFull || charge >= 0.995 ? "fully charged" : "plugged in, not charging"
    }

    /// Watt-hours in a full charge today, when the voltage and capacity are known.
    var fullWattHours: Double? {
        guard let fullCapacity, let volts else { return nil }
        return Double(fullCapacity) * volts / 1000
    }
}

/// What the machine is, where a screen needs to know before any reading exists.
enum Hardware {
    /// Whether this Mac has a battery. It does not change while the app runs.
    static let hasBattery = PowerSampler.demo != nil || PowerSampler.systemBattery() != nil
}

/// Round trips to one place, measured by echo.
struct LatencyTarget: Codable, Identifiable {
    struct Sample: Codable {
        var time: Date
        /// nil when nothing came back.
        var milliseconds: Double?
    }

    var id: String
    var title: String
    var host: String
    var samples: [Sample] = []
    /// Set when macOS refused to send: the Local Network permission, usually.
    var blocked = false

    var last: Double? { samples.last?.milliseconds }
    var answered: [Double] { samples.compactMap(\.milliseconds) }
    var average: Double? { answered.isEmpty ? nil : answered.reduce(0, +) / Double(answered.count) }
    var best: Double? { answered.min() }
    var worst: Double? { answered.max() }
    /// Share of echoes that went unanswered, 0...1.
    var loss: Double { samples.isEmpty ? 0 : Double(samples.count - answered.count) / Double(samples.count) }
    /// How much one round trip differs from the next, on average.
    var jitter: Double? {
        let values = answered
        guard values.count > 1 else { return nil }
        return zip(values, values.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(values.count - 1)
    }
}

struct DiskStats: Codable {
    var total: UInt64
    var free: UInt64
    var readBytesPerSecond: Double
    var writeBytesPerSecond: Double
    /// Requests a second, over every drive.
    var readOps = 0.0
    var writeOps = 0.0
    /// How long a request took on average since the last reading, in seconds. Nil when there were none.
    var readLatency: Double?
    var writeLatency: Double?
    /// Since the Mac started.
    var bytesRead: UInt64 = 0
    var bytesWritten: UInt64 = 0
    /// Requests the drives failed or had to repeat since the Mac started.
    var errors: UInt64 = 0
    var retries: UInt64 = 0
}

struct MemoryActivity: Codable, Equatable {
    var pageIn = 0.0
    var pageOut = 0.0
    var swapIn = 0.0
    var swapOut = 0.0
    var compress = 0.0
    var decompress = 0.0

    /// Anything moving to or from swap or the compressor: the work that makes a Mac feel slow when memory is short.
    var underStrain: Bool { swapIn + swapOut + compress + decompress > 64 * 1024 }
}

struct NetworkStats: Codable {
    /// Over the physical interfaces only, so traffic through a tunnel is not counted twice.
    var inBytesPerSecond: Double
    var outBytesPerSecond: Double
    /// Carried since Dotmeter started counting, same interfaces.
    var inBytes: UInt64 = 0
    var outBytes: UInt64 = 0
    var countingSince: Date?
    /// What System Settings calls network ports, plus any tunnel that has an address. Primary first.
    var interfaces: [NetworkInterface] = []
    /// BSD name of the interface the default route uses.
    var primary: String?
    var router: String?
    var dns: [String] = []
    var searchDomains: [String] = []
    /// "DHCP", "Manual", …
    var configMethod: String?
    var wifi: WiFiInfo?
    /// Per-app traffic, busiest first. Only sampled while something on screen shows it.
    var apps: [NetworkAppUsage] = []
    /// Router first, then the internet. Empty unless the Network area is on screen.
    var latency: [LatencyTarget] = []
    var appsMeasured = false
    /// False once the tool that reports per-app traffic has failed repeatedly.
    var appsAvailable = true
    /// Apps waiting for connections, those reachable from other devices first. Only read while the Network
    /// area is on screen.
    var listeners: [ListeningApp] = []
    var listenersMeasured = false
    var listenersAvailable = true
    /// Whether the macOS firewall is on. Nil when it would not say.
    var firewall: Bool?

    var total: Double { inBytesPerSecond + outBytesPerSecond }
    var online: Bool { primary != nil }

    /// "since Dotmeter started 3h 14m ago"
    var countingLabel: String {
        guard let since = countingSince else { return "since \(App.name) started" }
        let elapsed = Date().timeIntervalSince(since)
        return elapsed < 90 ? "since \(App.name) started just now" : "since \(App.name) started \(Format.duration(elapsed)) ago"
    }
    var primaryInterface: NetworkInterface? { interfaces.first { $0.name == primary } }
}

struct NetworkInterface: Codable, Identifiable {
    enum Kind: String, Codable {
        case wifi, ethernet, thunderbolt, bridge, tunnel, cellular, other

        var symbol: String {
            switch self {
            case .wifi: return "wifi"
            case .ethernet: return "cable.connector"
            case .thunderbolt: return "bolt.horizontal.fill"
            case .bridge: return "point.3.connected.trianglepath.dotted"
            case .tunnel: return "lock.shield.fill"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .other: return "network"
            }
        }
    }

    /// BSD name, such as en0.
    var name: String
    /// The name System Settings shows, such as "Wi-Fi" or "Thunderbolt Bridge".
    var title: String
    var kind: Kind
    /// A cable is plugged in and negotiated, a Wi-Fi network is joined, or a tunnel is up with an address.
    var isActive: Bool
    var ipv4: [String] = []
    var netmask: String?
    /// Routable IPv6 addresses; the link-local one is kept apart.
    var ipv6: [String] = []
    var linkLocal6: String?
    var mac: String?
    var mtu: Int = 0
    /// Bits per second, when the interface reports one.
    var linkSpeed: Double?
    var fullDuplex: Bool?
    var inRate = 0.0
    var outRate = 0.0
    /// Carried since Dotmeter started counting.
    var inBytes: UInt64 = 0
    var outBytes: UInt64 = 0
    var inPackets: UInt64 = 0
    var outPackets: UInt64 = 0
    var inErrors: UInt64 = 0
    var outErrors: UInt64 = 0

    var id: String { name }
    var address: String? { ipv4.first ?? ipv6.first }
}

struct WiFiInfo: Codable {
    var interface: String
    /// macOS only hands the network name to apps allowed to use Location.
    var ssid: String?
    /// Received signal strength in dBm. Some Macs and macOS versions report none.
    var rssi: Int?
    /// Noise floor in dBm.
    var noise: Int
    /// Megabits per second.
    var transmitRate: Double
    var channel: Int
    var band: String
    var width: String?
    var standard: String
    var security: String
    var country: String?

    var snr: Int? { rssi.map { $0 - noise } }

    /// 0...1 across the range that matters: −95 dBm is unusable, −35 dBm is next to the router.
    var quality: Double? { rssi.map { min(max((Double($0) + 95) / 60, 0), 1) } }

    var qualityTitle: String? {
        guard let rssi else { return nil }
        switch rssi {
        case (-55)...: return "Excellent"
        case (-67)...: return "Good"
        case (-75)...: return "Fair"
        case (-85)...: return "Weak"
        default: return "Very weak"
        }
    }
}

struct NetworkProcessUsage: Codable, Identifiable {
    var pid: Int32
    var name: String
    var inRate: Double
    var outRate: Double
    /// Carried by the connections it has open right now.
    var inBytes: UInt64
    var outBytes: UInt64

    var id: Int32 { pid }
    var rate: Double { inRate + outRate }
}

/// A TCP port something is waiting for connections on.
struct ListeningPort: Codable, Equatable, Identifiable {
    var port: Int
    var pid: Int32
    /// The process's own name, as the kernel has it.
    var process: String
    /// Other devices can reach it; false when it only answers to this Mac.
    var exposed: Bool

    var id: String { "\(pid):\(port)" }
}

/// One app and every port it is listening on.
struct ListeningApp: Codable, Equatable, Identifiable {
    /// Same ids as `AppUsage`: bundle path for apps, "proc:<name>" for bare executables.
    var id: String
    var name: String
    var bundlePath: String?
    var ports: [ListeningPort]

    var exposed: [ListeningPort] { ports.filter(\.exposed) }
    var local: [ListeningPort] { ports.filter { !$0.exposed } }
}

struct NetworkAppUsage: Codable, Identifiable {
    /// Same ids as `AppUsage`: bundle path for apps, "proc:<name>" for bare executables.
    var id: String
    var name: String
    var bundlePath: String?
    var inRate: Double
    var outRate: Double
    var inBytes: UInt64
    var outBytes: UInt64
    var processes: [NetworkProcessUsage]

    var rate: Double { inRate + outRate }
    var bytes: UInt64 { inBytes &+ outBytes }
}

struct ProcessUsage: Codable, Identifiable {
    var pid: Int32
    var ppid: Int32
    /// The process's own executable name (for example "Google Chrome Helper (Renderer)").
    var name: String
    var path: String?
    /// 0...N where 1.0 == one fully busy core (so 4.0 is 400% in Activity Monitor terms).
    var cpu: Double
    /// Physical footprint in bytes (what Activity Monitor calls Memory).
    var memory: UInt64
    var parentName: String?
    /// Bytes per second read from and written to disk.
    var diskRead = 0.0
    var diskWrite = 0.0
    /// Watts billed to this process by the kernel.
    var power = 0.0
    /// Share of the graphics cores' time, 0...1.
    var gpu = 0.0

    var id: Int32 { pid }
}

struct AppUsage: Codable, Identifiable {
    /// Bundle path for apps, "proc:<name>" for bare executables.
    var id: String
    var name: String
    var bundlePath: String?
    var pid: Int32
    var cpu: Double
    var memory: UInt64
    var processCount: Int
    var children: [ProcessUsage]
    var diskRead = 0.0
    var diskWrite = 0.0
    var power = 0.0
    var gpu = 0.0

    var disk: Double { diskRead + diskWrite }
}

struct SystemInfo: Codable {
    var modelName: String
    var modelIdentifier: String
    var chip: String
    var osVersion: String
    var uptime: TimeInterval
    var memoryTotal: UInt64
}

struct HistoryPoint: Identifiable {
    var id: Date { time }
    var time: Date
    var cpu: Double
    var gpu: Double
    var memory: Double
    var swap: Double
    /// Hottest die sensor.
    var temperature: Double?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var fan: Double
    var fanRPM: Double
    var diskBytesPerSecond: Double
    var diskRead: Double
    var diskWrite: Double
    var power: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    var gpuMemory: Double?
    var latencyRouter: Double?
    var latencyInternet: Double?
    /// 0...1, and watts in or out, on a Mac with a battery.
    var batteryCharge: Double?
    var batteryWatts: Double?
    var networkBytesPerSecond: Double
    var networkIn: Double
    var networkOut: Double
    /// Wi-Fi signal in dBm and link rate in megabits per second, while a network is joined.
    var wifiRSSI: Double?
    var wifiRate: Double?

    init(snapshot: Snapshot) {
        time = snapshot.timestamp
        cpu = snapshot.cpu.total
        gpu = snapshot.gpu?.utilization ?? 0
        memory = snapshot.memory.usedFraction
        swap = Double(snapshot.memory.swapUsed)
        temperature = snapshot.thermal.hottest?.celsius
        cpuTemperature = snapshot.thermal.cpuTemperature
        gpuTemperature = snapshot.thermal.gpuTemperature
        fan = snapshot.thermal.averageFanPercent
        fanRPM = snapshot.thermal.averageRPM
        diskBytesPerSecond = snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond
        diskRead = snapshot.disk.readBytesPerSecond
        diskWrite = snapshot.disk.writeBytesPerSecond
        power = snapshot.power.total
        cpuPower = snapshot.power.cpu
        gpuPower = snapshot.power.gpu
        gpuMemory = snapshot.gpu?.memoryInUse.map { Double($0) }
        latencyRouter = snapshot.network.latency.first { $0.id == "router" }?.last
        latencyInternet = snapshot.network.latency.first { $0.id == "internet" }?.last
        batteryCharge = snapshot.power.battery?.charge
        batteryWatts = snapshot.power.battery?.watts
        networkBytesPerSecond = snapshot.network.inBytesPerSecond + snapshot.network.outBytesPerSecond
        networkIn = snapshot.network.inBytesPerSecond
        networkOut = snapshot.network.outBytesPerSecond
        wifiRSSI = snapshot.network.wifi?.rssi.map { Double($0) }
        wifiRate = snapshot.network.wifi?.transmitRate
    }
}

/// The one-word answer to "how is my Mac doing?" that drives the header, icon tint and alerts.
enum Severity: Int, Comparable, Codable {
    case nominal, elevated, high, critical

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    static func from(_ s: Snapshot) -> Severity {
        let fan = s.thermal.fans.map(\.percent).max() ?? 0
        let temp = s.thermal.hottest?.celsius ?? 0
        if s.thermal.state == .critical || s.thermal.isThrottled { return .critical }
        if s.thermal.state == .serious || temp >= 98 || fan >= 0.9 { return .high }
        let gpu = s.gpu?.utilization ?? 0
        if s.thermal.state == .fair || temp >= 75 || fan >= 0.4 || s.cpu.total >= 0.6 || gpu >= 0.6 || s.memory.pressure != .normal { return .elevated }
        return .nominal
    }

    var title: String {
        switch self {
        case .nominal: return "Running cool"
        case .elevated: return "Working hard"
        case .high: return "Running hot"
        case .critical: return "Throttling"
        }
    }
}
