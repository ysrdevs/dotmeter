import Foundation

/// Everything the Mac reports about its ports: what is plugged in, through which cable, at what speed, and what
/// each part of the chain could do. Read from the hardware registry; nothing is probed or looked up elsewhere.
struct USBStats: Codable, Equatable {
    var ports: [USBPort] = []
    /// Every Thunderbolt or USB4 router, the Mac's own included, so chains through docks can be drawn.
    var routers: [ThunderboltRouter] = []
    /// The power adapter, on a Mac that charges through a port.
    var charger: ChargerInfo?

    var connectedPorts: [USBPort] { ports.filter(\.connected) }

    /// "USB-C 2", or just "HDMI" where there is only one of its kind.
    func title(_ port: USBPort) -> String {
        ports.filter { $0.kind == port.kind }.count > 1 ? port.title : port.kind.title
    }
    var deviceCount: Int { ports.reduce(0) { $0 + $1.allDevices.filter { !$0.isHub }.count } }
}

struct USBPort: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case usbC, usbA, hdmi, sdCard, magSafe, other

        var title: String {
            switch self {
            case .usbC: return "USB-C"
            case .usbA: return "USB-A"
            case .hdmi: return "HDMI"
            case .sdCard: return "SD card"
            case .magSafe: return "MagSafe"
            case .other: return "Port"
            }
        }
    }

    var id: String
    var kind: Kind
    var number: Int
    var connected = false
    /// What the port can carry, what it has set up for this connection, and what is running: "USB2", "USB3",
    /// "CIO" (Thunderbolt or USB4), "DisplayPort", "PCIe".
    var supported: [String] = []
    var provisioned: [String] = []
    var active: [String] = []
    /// Which way up the plug went in (1 or 2), when the port says.
    var orientation: Int?
    var plugEvents: Int?
    var overcurrentEvents: Int?
    var activeCable: Bool?
    var opticalCable: Bool?
    /// What answered at the far end, and the chip in the cable's plug.
    var partner: PDIdentity?
    var cable: CableMarker?
    var usb2: USBTransport?
    var usb3: USBTransport?
    var thunderbolt: ThunderboltLink?
    var displays: [DisplayLink] = []
    var pcieTunnel: Bool?
    /// Devices plugged straight into the port; each holds what hangs off it.
    var devices: [USBDevice] = []
    /// What the port will give its devices over plain USB, in milliamps.
    var supplyMilliamps: Int?
    var health: PortHealth?
    /// A charger on this port: what it offers and the offer in force.
    var powerSource: PortPowerSource?
    /// The card in an SD slot, as macOS describes it.
    var cardDescription: String?

    var title: String { "\(kind.title) \(number)" }

    /// Every device on the port, hubs included, parents before children.
    var allDevices: [USBDevice] {
        var out: [USBDevice] = []
        func walk(_ device: USBDevice) {
            out.append(device)
            device.children.forEach(walk)
        }
        devices.forEach(walk)
        return out
    }

    /// The transports in everyday words, in the order they are usually thought of.
    var activeNames: [String] {
        var names: [String] = []
        if active.contains("CIO") { names.append(thunderbolt?.familyName ?? "Thunderbolt") }
        if active.contains("USB3") || usb3?.active == true { names.append("USB 3") }
        if active.contains("USB2") || usb2?.active == true { names.append("USB 2") }
        if active.contains("DisplayPort") || displays.contains(where: \.active) { names.append("DisplayPort") }
        if pcieTunnel == true { names.append("PCIe") }
        if powerSource != nil { names.append("Charging") }
        return names
    }
}

/// A plain USB connection on a port: USB 2, or USB 3 either on its own wires or tunnelled through Thunderbolt.
struct USBTransport: Codable, Equatable {
    var active: Bool
    var tunneled: Bool
    /// macOS's own wording for the rate, such as "10 Gbps" or "480 Mbps (High Speed)".
    var rateText: String?
    var bitsPerSecond: Double?
    var product: String?
    var manufacturer: String?
}

struct ThunderboltLink: Codable, Equatable {
    /// Identifies the device at the far end; the same number names its router in `USBStats.routers`.
    var uid: String
    var deviceName: String?
    var vendorName: String?
    var tunnelsSupported: [String] = []
    var tunnelsProvisioned: [String] = []
    var legacyAdapter = false
    var asymmetricSupported = false
    /// How fast the Mac's controller judges the cable good for: 2 is 20 Gbps, 3 is 40, 4 is 80. This can be more
    /// than the cable's marker says, because a short passive cable marked for 40 also carries 80.
    var cableSpeedCode: Int?
    /// The link as the Mac's own router reports it.
    var lane: ThunderboltLane?
    /// What the two ends could do, as masks of generations (see `ThunderboltLane.speeds`).
    var hostSpeeds: Int?
    var deviceSpeeds: Int?

    var bitsPerSecond: Double? { lane?.bitsPerSecond }

    var cableBitsPerSecond: Double? {
        switch cableSpeedCode {
        case 2: return 20e9
        case 3: return 40e9
        case 4: return 80e9
        default: return nil
        }
    }

    /// Named for the speed the link trained at, since that is what the names stand for in practice.
    var familyName: String {
        guard let lane else { return "Thunderbolt" }
        return ThunderboltLane.family(lane.speedCode)
    }
}

/// One direction-pair of a Thunderbolt or USB4 link: how fast each lane runs and how many are bonded.
struct ThunderboltLane: Codable, Equatable {
    /// The registers hold a generation flag: 8 is Gen 2 (10 Gb/s a lane), 4 Gen 3 (20), 2 Gen 4 (40).
    var speedCode: Int
    /// 1 is a single lane, 2 two bonded lanes; 4 and 8 are the uneven three-and-one splits of USB4 version 2.
    var widthCode: Int
    /// What the port itself reports for the whole link, in bits per second.
    var reported: Double?

    static func perLane(_ code: Int) -> Double? {
        switch code {
        case 8: return 10e9
        case 4: return 20e9
        case 2: return 40e9
        default: return nil
        }
    }

    /// The fastest generation in a mask of supported ones.
    static func fastest(_ mask: Int) -> Double? {
        for code in [2, 4, 8] where mask & code != 0 { return perLane(code) }
        return nil
    }

    /// The family a lane speed belongs to. Thunderbolt 3 ran 10 or 20 Gb/s lanes; the names split cleanly from 4 on.
    static func family(_ code: Int) -> String {
        switch code {
        case 2: return "Thunderbolt 5"
        case 4: return "Thunderbolt 4 / USB4"
        case 8: return "Thunderbolt 3"
        default: return "Thunderbolt"
        }
    }

    /// The newest family in a mask of supported generations.
    static func newestFamily(_ mask: Int) -> String {
        for code in [2, 4, 8] where mask & code != 0 { return family(code) }
        return "Thunderbolt"
    }

    static func speeds(_ mask: Int) -> String {
        var names: [String] = []
        if mask & 8 != 0 { names.append("10") }
        if mask & 4 != 0 { names.append("20") }
        if mask & 2 != 0 { names.append("40") }
        return names.isEmpty ? "none stated" : names.joined(separator: ", ") + " Gb/s a lane"
    }

    var lanes: Int { widthCode == 1 ? 1 : 2 }

    var bitsPerSecond: Double? {
        if let reported, reported > 0 { return reported }
        guard let lane = Self.perLane(speedCode) else { return nil }
        return lane * Double(lanes)
    }

    var generationName: String {
        switch speedCode {
        case 8: return "Gen 2"
        case 4: return "Gen 3"
        case 2: return "Gen 4"
        default: return "generation not stated"
        }
    }

    var widthName: String {
        switch widthCode {
        case 1: return "one lane"
        case 2: return "two lanes"
        case 4: return "three lanes out, one in"
        case 8: return "one lane out, three in"
        default: return "width not stated"
        }
    }
}

struct ThunderboltRouter: Codable, Equatable, Identifiable {
    var id: String { uid }
    var uid: String
    var name: String
    var vendor: String?
    /// 0 for one of the Mac's own routers, 1 for what is plugged into it, 2 for what is plugged into that.
    var depth: Int
    var version: Int?
    /// The Mac's port this router sits behind.
    var socket: Int?
    var parentUID: String?
    /// The port on the parent it is plugged into.
    var parentPort: Int?
    var ports: [ThunderboltPort] = []

    var isHost: Bool { depth == 0 }

    /// The link ports, one per connector: a connector's two lanes are listed as a pair and the first carries the figures.
    var linkPorts: [ThunderboltPort] { ports.filter { $0.lane != nil && $0.isPrimaryLane } }
    /// What rides the link from this router: PCIe, USB and display adapters with something allocated.
    var tunnels: [ThunderboltPort] { ports.filter { $0.lane == nil && $0.kind != .host && $0.kind != .inactive && ($0.allocated ?? 0) > 0 } }
}

struct ThunderboltPort: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case link, pcie, usb, display, host, inactive, other

        var title: String {
            switch self {
            case .link: return "Link"
            case .pcie: return "PCIe"
            case .usb: return "USB 3"
            case .display: return "DisplayPort"
            case .host: return "Host interface"
            case .inactive: return "Inactive"
            case .other: return "Adapter"
            }
        }
    }

    var id: Int { number }
    var number: Int
    var kind: Kind
    var lane: ThunderboltLane?
    var isPrimaryLane = false
    var supportedSpeeds: Int?
    /// macOS's "Maximum Bandwidth Allocated", in the same hundreds of megabits a second it reports link bandwidth in.
    var allocated: Int?
    /// For a display adapter: the DisplayPort link it has established, as the two register codes.
    var displayRateCode: Int?
    var displayLaneCode: Int?
}

/// A screen on a port, with the link carrying it.
struct DisplayLink: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    /// The maker's three-letter code from the screen's own description.
    var maker: String?
    var productID: Int?
    var active: Bool
    var tunneled: Bool
    var lanes: Int
    var maxLanes: Int
    /// "HBR2", "HBR3": the DisplayPort rate each lane runs at, and what that is in gigabits a second.
    var rateName: String?
    var laneGigabits: Double?
    /// The rate was read from a dock's display adapter, because a tunnelled screen's own entry does not carry it.
    var rateFromAdapter = false
    /// Whatever sits between the port and the screen and names itself: a dock's display chip, an adapter.
    var branch: String?
    var sink: String?
    /// "DP" or "HDMI": what the last hop to the screen speaks.
    var output: String?
    var year: Int?
    /// The picture actually being sent, from the framebuffer's own timing.
    var signalWidth: Int?
    var signalHeight: Int?
    var refresh: Double?
    /// Pixels a second on the wire, blanking included: what the link has to carry, times the bits in a pixel.
    var pixelClock: Double?
    /// The fastest refresh the screen offers at the size it is showing, and what that would need.
    var topRefresh: Double?
    var topPixelClock: Double?
    /// The size the picture is drawn at before scaling, when the display services report one.
    var drawnWidth: Int?
    var drawnHeight: Int?

    /// What the link can carry after its 8b/10b line coding, in bits per second.
    var payload: Double? {
        guard let laneGigabits, lanes > 0 else { return nil }
        return laneGigabits * 1e9 * Double(lanes) * 0.8
    }

    var linkText: String? {
        guard lanes > 0 else { return nil }
        guard let laneGigabits else { return "\(lanes) \(lanes == 1 ? "lane" : "lanes")" }
        return "\(lanes) \(lanes == 1 ? "lane" : "lanes") of \(rateName ?? "DisplayPort") (\(String(format: "%g", laneGigabits)) Gb/s each)"
    }

    var signalText: String? {
        guard let signalWidth, let signalHeight else { return nil }
        return "\(signalWidth) × \(signalHeight)" + (refresh.map { " at \(Format.hertz($0))" } ?? "")
    }

    /// Uncompressed, at eight bits for each of the three colours.
    static func bits(_ pixelClock: Double) -> Double { pixelClock * 24 }
}

struct USBDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var vendorName: String?
    var vendorID: Int
    var productID: Int
    /// The speed this device's own connection came up at.
    var bitsPerSecond: Double
    /// The USB version the device says it implements, as 0x0320 for 3.2.
    var usbVersion: Int
    var deviceClass: Int
    /// Interface classes, which say what a composite device does: 3 keyboard or mouse, 8 storage, and so on.
    var interfaces: [Int] = []
    /// What it asked for and was given, in milliamps.
    var milliamps: Int?
    /// The port of its hub (or of the Mac) it is plugged into.
    var hubPort: Int?
    var controller: String?
    /// It reaches the Mac through a Thunderbolt tunnel.
    var tunneled = false
    var children: [USBDevice] = []

    var isHub: Bool { deviceClass == 9 }
    var isSuperSpeed: Bool { bitsPerSecond >= 5e9 }

    /// What the device is for. Its interfaces say most; a composite device hands some of them straight to a
    /// driver where they cannot be seen, so a plain word in its own name is believed first.
    var role: String {
        if deviceClass == 9 { return "Hub" }
        let lower = name.lowercased()
        for (word, role) in [("audio", "Audio"), ("lan", "Network"), ("ethernet", "Network"), ("camera", "Camera"), ("webcam", "Camera"), ("keyboard", "Keyboard"), ("mouse", "Mouse"), ("receiver", "Wireless receiver"), ("billboard", "Alternate mode notice")] where lower.contains(word) {
            return role
        }
        let classes = [deviceClass] + interfaces
        if classes.contains(8) { return "Storage" }
        if classes.contains(14) { return "Camera" }
        if classes.contains(1) { return "Audio" }
        if classes.contains(2) || classes.contains(10) { return "Network or serial" }
        if classes.contains(7) { return "Printer" }
        if classes.contains(224) { return "Wireless adapter" }
        if classes.contains(11) { return "Card reader" }
        if classes.contains(3) { return "Input device" }
        if classes.contains(17) { return "Alternate mode notice" }
        if classes.contains(255) { return "Vendor-specific" }
        return "Device"
    }

    var versionText: String {
        let major = usbVersion >> 8, minor = usbVersion >> 4 & 0xF
        return "USB \(major).\(minor)"
    }

    /// The fastest a device of the version it states can run. A device that says 3.1 or later may still be a
    /// 5 Gbps one, so above 3.0 this is a ceiling, not a promise.
    var versionCeiling: Double {
        switch usbVersion {
        case 0x0320...: return 20e9
        case 0x0310..<0x0320: return 10e9
        case 0x0300..<0x0310: return 5e9
        case 0x0200..<0x0300: return 480e6
        default: return 12e6
        }
    }
}

/// A charger as one port sees it.
struct PortPowerSource: Codable, Equatable {
    var name: String?
    var options: [PowerOption] = []
    var millivolts: Int?
    var milliamps: Int?

    var watts: Double? {
        guard let millivolts, let milliamps else { return nil }
        return Double(millivolts) * Double(milliamps) / 1e6
    }
}

/// Error counts the USB controller keeps for a port since the Mac started.
struct PortHealth: Codable, Equatable {
    var linkErrors = 0
    var linkFailures = 0
    var enumerationFailures = 0
    var addressFailures = 0
    var overcurrent = 0
    var connects = 0

    var troubles: Int { linkErrors + linkFailures + enumerationFailures + addressFailures + overcurrent }
}

/// The power adapter on a Mac that charges through a port: what it offers and what is in force.
struct ChargerInfo: Codable, Equatable {
    var name: String?
    var manufacturer: String?
    var watts: Int?
    var options: [PowerOption] = []
    /// The contract in force.
    var millivolts: Int?
    var milliamps: Int?
    var wireless = false
    /// Measured at the Mac's input: what is actually arriving.
    var inputWatts: Double?
    var inputMillivolts: Int?
    var inputMilliamps: Int?

    var activeOption: PowerOption? { options.first(where: \.active) }

    /// Resistance between the charger and the Mac, from how far the arriving voltage sags below the agreed one at
    /// the current being drawn. It takes in the cable and both plugs, and a charger that lets its output droop
    /// reads as resistance too, so this is an estimate and only made when enough current flows to measure.
    var pathMilliohms: Double? {
        guard let agreed = millivolts, let arriving = inputMillivolts, let current = inputMilliamps, current >= 1000, agreed > arriving else { return nil }
        return Double(agreed - arriving) / Double(current) * 1000
    }
}
