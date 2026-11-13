import Foundation

/// USB Power Delivery "Discover Identity" data, decoded as the specification lays it out (PD 3.x, section 6.4.4.3).
/// macOS hands over the raw 32-bit objects that a port's partner (SOP) or the chip inside a cable's plug
/// (SOP', the e-marker) answered with. Nothing here is guessed: a field the answer does not carry stays empty.
struct PDIdentity: Codable, Equatable {
    enum Kind: String, Codable {
        case hub, peripheral, powerSink, host, powerBrick, passiveCable, activeCable, vconnPoweredDevice, alternateModeAdapter, undefined

        var title: String {
            switch self {
            case .hub: return "Hub or dock"
            case .peripheral: return "Peripheral"
            case .powerSink: return "Power sink"
            case .host: return "Host"
            case .powerBrick: return "Power brick"
            case .passiveCable: return "Passive cable"
            case .activeCable: return "Active cable"
            case .vconnPoweredDevice: return "Cable-powered device"
            case .alternateModeAdapter: return "Alternate mode adapter"
            case .undefined: return "Not stated"
            }
        }
    }

    /// The objects as answered, most significant byte first once read.
    var vdos: [UInt32]
    /// The Power Delivery revision the answer was given in (2 or 3).
    var revision: Int
    var vendorID: Int
    var productID: Int
    /// The product's own version number (bcdDevice).
    var deviceVersion: Int
    /// The certificate number USB-IF issued for the product, 0 when it carries none.
    var xid: UInt32
    var usbHostCapable: Bool
    var usbDeviceCapable: Bool
    var modalOperation: Bool
    /// What it is when it is the device end (or, for a cable plug, what kind of cable).
    var kind: Kind
    /// What it is when it is the host end.
    var hostKind: Kind

    /// `cable` says the answer came from a cable plug, where the same bits name cable types.
    init?(vdos: [UInt32], revision: Int, cable: Bool) {
        guard let header = vdos.first else { return nil }
        self.vdos = vdos
        self.revision = revision
        vendorID = Int(header & 0xFFFF)
        usbHostCapable = header >> 31 & 1 == 1
        usbDeviceCapable = header >> 30 & 1 == 1
        modalOperation = header >> 26 & 1 == 1
        let ufp = Int(header >> 27 & 0x7), dfp = Int(header >> 23 & 0x7)
        if cable {
            switch ufp {
            case 3: kind = .passiveCable
            case 4: kind = .activeCable
            case 6: kind = .vconnPoweredDevice
            default: kind = .undefined
            }
            hostKind = .undefined
        } else {
            switch ufp {
            case 1: kind = .hub
            case 2: kind = .peripheral
            case 3: kind = .powerSink
            case 5: kind = .alternateModeAdapter
            default: kind = .undefined
            }
            switch dfp {
            case 1: hostKind = .hub
            case 2: hostKind = .host
            case 3: hostKind = .powerBrick
            default: hostKind = .undefined
            }
        }
        xid = vdos.count > 1 ? vdos[1] : 0
        let product = vdos.count > 2 ? vdos[2] : 0
        productID = Int(product >> 16)
        deviceVersion = Int(product & 0xFFFF)
    }

    /// The most telling description: a dock says "hub" at both ends, a charger only at the host end.
    var kindTitle: String {
        if kind != .undefined { return kind.title }
        if hostKind != .undefined { return hostKind.title }
        return Kind.undefined.title
    }

    /// Identifies this exact product across connections: maker, product, version and certificate.
    var fingerprint: String {
        String(format: "%04x:%04x:%04x:%x", vendorID, productID, deviceVersion, xid)
    }
}

/// What a cable's e-marker says about the cable: how fast, how much current, how long.
struct CableMarker: Codable, Equatable {
    var identity: PDIdentity
    var active: Bool
    var hardwareVersion: Int
    var firmwareVersion: Int
    /// The four fields below are the raw codes; the readable forms are computed from them.
    var speedCode: Int
    var currentCode: Int
    var latencyCode: Int
    var terminationCode: Int
    var maxVoltageCode: Int
    var plugCode: Int
    /// Rated for the 28 to 48 V range, which is what takes a 5 A cable from 100 W to 240 W.
    var extendedPower: Bool
    /// Only an active cable says these.
    var optical: Bool?
    var retimer: Bool?
    var usb4Supported: Bool?
    var twoLanes: Bool?

    init?(identity: PDIdentity) {
        guard identity.kind == .passiveCable || identity.kind == .activeCable, identity.vdos.count > 3 else { return nil }
        self.identity = identity
        let v = identity.vdos[3]
        active = identity.kind == .activeCable
        hardwareVersion = Int(v >> 28 & 0xF)
        firmwareVersion = Int(v >> 24 & 0xF)
        plugCode = Int(v >> 18 & 0x3)
        extendedPower = v >> 17 & 1 == 1
        latencyCode = Int(v >> 13 & 0xF)
        terminationCode = Int(v >> 11 & 0x3)
        maxVoltageCode = Int(v >> 9 & 0x3)
        currentCode = Int(v >> 5 & 0x3)
        speedCode = Int(v & 0x7)
        if active, identity.vdos.count > 4 {
            let second = identity.vdos[4]
            optical = second >> 10 & 1 == 1
            retimer = second >> 9 & 1 == 1
            // These two are stated in the negative: a clear bit means supported.
            usb4Supported = second >> 8 & 1 == 0
            twoLanes = second >> 3 & 1 == 1
        }
    }

    /// The fastest signalling the cable is marked for, as the specification names it.
    var speedName: String {
        switch speedCode {
        case 0: return "USB 2.0"
        case 1: return "USB 3.2 Gen 1"
        case 2: return "USB 3.2 Gen 2"
        case 3: return "USB4 Gen 3"
        case 4: return "USB4 Gen 4"
        default: return "Reserved value \(speedCode)"
        }
    }

    /// What that comes to on a USB4 or Thunderbolt link, which uses both pairs of wires.
    var linkBitsPerSecond: Double? {
        switch speedCode {
        case 0: return 480e6
        case 1: return 5e9
        case 2: return 20e9
        case 3: return 40e9
        case 4: return 80e9
        default: return nil
        }
    }

    /// What it comes to for plain USB 3, which a Mac runs over one pair: 10 Gbps at most.
    var usb3BitsPerSecond: Double? {
        switch speedCode {
        case 0: return 480e6
        case 1: return 5e9
        case 2, 3, 4: return 10e9
        default: return nil
        }
    }

    var speedText: String {
        switch speedCode {
        case 0: return "480 Mb/s"
        case 1: return "5 Gb/s"
        case 2: return "10 Gb/s, 20 Gb/s as USB4"
        case 3: return "40 Gb/s"
        case 4: return "80 Gb/s"
        default: return "not stated"
        }
    }

    var amps: Double? {
        switch currentCode {
        case 1: return 3
        case 2: return 5
        default: return nil
        }
    }

    var maxVolts: Int? {
        switch maxVoltageCode {
        case 0: return 20
        case 1: return 30
        case 2: return 40
        case 3: return 50
        default: return nil
        }
    }

    /// 60 W for a 3 A cable, 100 W for 5 A, 240 W for 5 A marked for extended power.
    var watts: Int? {
        guard let amps else { return nil }
        if amps == 5, extendedPower, maxVoltageCode == 3 { return 240 }
        return Int(amps * 20)
    }

    /// The signal's travel time through the cable, which is how an e-marker states its length.
    var lengthText: String? {
        switch latencyCode {
        case 1: return "about 1 m or less"
        case 2: return "about 2 m"
        case 3: return "about 3 m"
        case 4: return "about 4 m"
        case 5: return "about 5 m"
        case 6: return "about 6 m"
        case 7: return "about 7 m"
        case 8: return "over 7 m"
        case 9 where active: return "about 100 m, optical"
        case 10 where active: return "about 200 m, optical"
        default: return nil
        }
    }

    var plugText: String? {
        switch plugCode {
        case 2: return "USB-C at both ends"
        case 3: return "attached to its device"
        case 0 where identity.revision < 3: return "USB-A at the far end"
        case 1 where identity.revision < 3: return "USB-B at the far end"
        default: return nil
        }
    }

    var constructionText: String {
        if !active { return terminationCode == 1 ? "Passive, plug chip powered by the port" : "Passive" }
        var parts = ["Active"]
        if let optical, optical { parts.append("optical") }
        if let retimer { parts.append(retimer ? "with retimers" : "with redrivers") }
        if terminationCode == 3 { parts.append("both ends powered") } else if terminationCode == 2 { parts.append("one end powered") }
        return parts.joined(separator: ", ")
    }

    /// Values that look unusual against the specification. A flag means "this looks unusual", never
    /// "this cable is fake": some honest cables carry sloppy markers, and plenty of bad ones carry tidy ones.
    var unusual: [String] {
        var notes: [String] = []
        if identity.vendorID == 0 { notes.append("The marker gives vendor ID 0. Every maker of USB products is assigned one, and a marker normally carries it.") }
        if speedCode > 4 { notes.append("The speed field holds \(speedCode), a value the specification reserves.") }
        if currentCode == 3 { notes.append("The current field holds a reserved value, so its rating cannot be read.") }
        if latencyCode == 0 || (!active && latencyCode > 8) || latencyCode > 10 { notes.append("The length field holds \(latencyCode), a value the specification reserves.") }
        if !active, terminationCode > 1 { notes.append("A passive cable's termination field holds a value that only active cables use.") }
        if active, terminationCode < 2 { notes.append("An active cable's termination field holds a value that only passive cables use.") }
        if identity.revision >= 3, plugCode < 2 { notes.append("The plug field holds a value the specification reserves.") }
        if maxVoltageCode == 1 || maxVoltageCode == 2 { notes.append("The voltage field uses a marking the specification has since withdrawn (\(maxVolts ?? 0) V).") }
        if !active, extendedPower, maxVoltageCode != 3 { notes.append("The marker claims the extended power range but a top voltage of \(maxVolts ?? 0) V, and the two do not go together.") }
        return notes
    }
}

/// One supply a charger offers, or the one in force.
struct PowerOption: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case fixed, variable, battery, programmable, adjustable }

    var id: Int
    var kind: Kind
    /// Millivolts. For a range this is the top of it and `minMillivolts` the bottom.
    var millivolts: Int
    var minMillivolts: Int?
    var milliamps: Int
    var active = false

    var watts: Double { Double(millivolts) * Double(milliamps) / 1e6 }

    /// Decodes a source Power Data Object (PD 3.x, section 6.4.1).
    init?(pdo: UInt32, index: Int) {
        id = index
        switch pdo >> 30 {
        case 0:
            kind = .fixed
            millivolts = Int(pdo >> 10 & 0x3FF) * 50
            milliamps = Int(pdo & 0x3FF) * 10
        case 1:
            kind = .battery
            millivolts = Int(pdo >> 20 & 0x3FF) * 50
            minMillivolts = Int(pdo >> 10 & 0x3FF) * 50
            // A battery supply states power, in quarter watts; the current follows from it.
            let milliwatts = Int(pdo & 0x3FF) * 250
            milliamps = millivolts > 0 ? milliwatts * 1000 / millivolts : 0
        case 2:
            kind = .variable
            millivolts = Int(pdo >> 20 & 0x3FF) * 50
            minMillivolts = Int(pdo >> 10 & 0x3FF) * 50
            milliamps = Int(pdo & 0x3FF) * 10
        default:
            switch pdo >> 28 & 0x3 {
            case 0:
                kind = .programmable
                millivolts = Int(pdo >> 17 & 0xFF) * 100
                minMillivolts = Int(pdo >> 8 & 0xFF) * 100
                milliamps = Int(pdo & 0x7F) * 50
            case 1:
                kind = .adjustable
                millivolts = Int(pdo >> 17 & 0x1FF) * 100
                minMillivolts = Int(pdo >> 8 & 0xFF) * 100
                // An adjustable supply states its power in watts.
                let watts = Int(pdo & 0xFF)
                milliamps = millivolts > 0 ? watts * 1_000_000 / millivolts : 0
            default:
                return nil
            }
        }
        guard millivolts > 0 else { return nil }
    }

    init(id: Int, kind: Kind = .fixed, millivolts: Int, minMillivolts: Int? = nil, milliamps: Int, active: Bool = false) {
        self.id = id
        self.kind = kind
        self.millivolts = millivolts
        self.minMillivolts = minMillivolts
        self.milliamps = milliamps
        self.active = active
    }
}

/// Names for the vendor IDs USB-IF assigns. This is a short list of makers that could be checked, not USB-IF's
/// whole register, so an ID missing from it says nothing about the ID. Names read from attached devices are
/// added as they are seen, since a device states its own maker.
enum USBVendors {
    private static let known: [Int: String] = [
        0x05AC: "Apple", 0x291A: "Anker", 0x8087: "Intel", 0x8086: "Intel", 0x1D5C: "Fresco Logic", 0x2109: "VIA Labs",
        0x1532: "Razer", 0x0BDA: "Realtek", 0x046D: "Logitech", 0x174C: "ASMedia", 0x1B1C: "Corsair", 0x05E3: "Genesys Logic",
        0x04B4: "Cypress Semiconductor", 0x0451: "Texas Instruments", 0x04E8: "Samsung", 0x18D1: "Google", 0x045E: "Microsoft",
        0x413C: "Dell", 0x03F0: "HP", 0x17EF: "Lenovo", 0x054C: "Sony", 0x0781: "SanDisk", 0x1058: "Western Digital",
        0x0BC2: "Seagate", 0x0951: "Kingston", 0x043E: "LG Electronics", 0x050D: "Belkin", 0x0B05: "ASUS", 0x0424: "Microchip",
        0x0483: "STMicroelectronics", 0x1A40: "Terminus Technology", 0x152D: "JMicron", 0x12D1: "Huawei", 0x2717: "Xiaomi",
    ]

    nonisolated(unsafe) private static var learned: [Int: String] = [:]
    private static let lock = NSLock()

    static func name(_ id: Int) -> String? {
        if let name = known[id] { return name }
        lock.lock(); defer { lock.unlock() }
        return learned[id]
    }

    /// A device named its own maker.
    static func learn(_ id: Int, _ name: String) {
        let tidy = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard id != 0, known[id] == nil, tidy.count > 1, tidy.lowercased() != "generic" else { return }
        lock.lock(); defer { lock.unlock() }
        learned[id] = tidy
    }

    static func label(_ id: Int) -> String {
        if let name = name(id) { return name }
        return String(format: "vendor 0x%04X", id)
    }
}
