import Foundation

extension USBPort {
    /// What is on the port, in a few words: the dock, the first device, the screen, the charger.
    var attachedName: String {
        guard connected else { return "Empty" }
        if let name = thunderbolt?.deviceName { return name }
        if let device = devices.first { return device.name }
        if let screen = displays.first(where: \.active)?.name { return screen }
        if let charger = powerSource { return charger.name ?? "Charger" }
        if let card = cardDescription { return card }
        return "Attached, no data"
    }

    /// The one figure that says most about the connection: its link speed, else its watts, else its refresh rate.
    var headlineFigure: String? {
        guard connected else { return nil }
        if let link = thunderbolt?.bitsPerSecond { return Format.linkSpeed(link) }
        if let device = devices.map(\.bitsPerSecond).max() { return Format.linkSpeed(device) }
        if let watts = powerSource?.watts { return "\(Int(watts.rounded())) W" }
        if let screen = displays.first(where: \.active), let refresh = screen.refresh { return Format.hertz(refresh) }
        return nil
    }

    /// The fastest data link on the port, in bits per second, if it carries data.
    var fastestLink: Double? {
        guard connected else { return nil }
        return thunderbolt?.bitsPerSecond ?? devices.map(\.bitsPerSecond).max()
    }
}

/// A reading of the ports boiled down to what the menu bar item, its panel and the alerts show: one line per
/// port, and which of them are running slower than they could. Worked out once per reading and kept, because the
/// verdicts cost far more than a look at the menu bar is worth every two seconds.
struct USBOverview: Equatable {
    struct Port: Equatable, Identifiable {
        var id: String
        var title: String
        var kind: USBPort.Kind
        var connected: Bool
        var attached: String
        var figure: String?
        /// 0...1 by link speed, for the menu bar's column: USB 2 is a third, 40 Gb/s and up is full.
        var level: Double
        var headline: USBVerdict?
        /// Set when the data link or the charging is held below what the parts could do.
        var slow: USBVerdict?
        var screens: Int
        var devices: Int
    }

    var ports: [Port] = []
    var deviceCount = 0

    var connected: [Port] { ports.filter(\.connected) }
    var empty: [Port] { ports.filter { !$0.connected } }
    var slow: [Port] { ports.filter { $0.slow != nil } }

    init(_ stats: USBStats) {
        deviceCount = stats.deviceCount
        ports = stats.ports.map { port in
            let diagnosis = port.connected ? USBDiagnostics.diagnose(port, charger: stats.charger) : PortDiagnosis()
            let slow = [diagnosis.speed, diagnosis.power].compactMap { $0 }.first { $0.tone == .caution }
            return Port(
                id: port.id, title: stats.title(port), kind: port.kind, connected: port.connected,
                attached: port.attachedName, figure: port.headlineFigure, level: Self.level(port),
                headline: slow ?? diagnosis.speed ?? diagnosis.headline, slow: slow,
                screens: port.displays.filter(\.active).count, devices: port.allDevices.filter { !$0.isHub }.count
            )
        }
    }

    private static func level(_ port: USBPort) -> Double {
        guard port.connected else { return 0 }
        guard let speed = port.fastestLink else { return 0.5 }
        switch speed {
        case 40e9...: return 1
        case 20e9...: return 0.84
        case 10e9...: return 0.67
        case 5e9...: return 0.5
        default: return 0.34
        }
    }

    // MARK: One per reading

    @MainActor private static var last: (stats: USBStats, overview: USBOverview)?

    /// The overview of this reading, worked out only if the reading differs from the last one asked about.
    @MainActor
    static func of(_ stats: USBStats) -> USBOverview {
        if let last, last.stats == stats { return last.overview }
        let overview = USBOverview(stats)
        last = (stats, overview)
        return overview
    }
}
