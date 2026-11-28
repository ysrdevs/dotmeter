import Foundation
import IOKit
import IOKit.ps

/// The charge of something connected to the Mac that has a battery of its own: a keyboard, a mouse, a trackpad.
struct AccessoryBattery: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case keyboard, mouse, trackpad, headphones, chargingCase, controller, pencil, other

        var symbol: String {
            switch self {
            case .keyboard: return "keyboard.fill"
            case .mouse: return "magicmouse.fill"
            case .trackpad: return "rectangle.and.hand.point.up.left.fill"
            case .headphones: return "headphones"
            case .chargingCase: return "earbuds.case.fill"
            case .controller: return "gamecontroller.fill"
            case .pencil: return "applepencil"
            case .other: return "dot.radiowaves.left.and.right"
            }
        }

        /// What to call a device that gives no name.
        var noun: String {
            switch self {
            case .keyboard: return "Keyboard"
            case .mouse: return "Mouse"
            case .trackpad: return "Trackpad"
            case .headphones: return "Headphones"
            case .chargingCase: return "Charging case"
            case .controller: return "Controller"
            case .pencil: return "Pencil"
            case .other: return "Accessory"
            }
        }
    }

    /// The same for one device from reading to reading. A digest, so no serial number or address is kept.
    var id: String
    var name: String
    /// 0...100
    var percent: Int
    /// "Bluetooth", "USB". Nil when the device does not say.
    var transport: String?
    /// Nil when the device does not say either way.
    var isCharging: Bool?
    var kind: Kind
    /// Where the level was read. Only a device in the hardware registry is one the Mac is using; the system's
    /// list also holds what is merely nearby, such as earbuds asleep in their case.
    var origin: Origin = .registry
    /// More than the one figure says: "left 80% · right 64%" for a pair whose halves differ.
    var detail: String? = nil

    enum Origin: String, Codable {
        case registry, powerSources
    }

    var fraction: Double { Double(percent) / 100 }
    var isLow: Bool { percent <= AccessoryWatch.low && isCharging != true }
    /// Whether running low is news. A case draining in a drawer is not: only what the registry lists can start
    /// a Timeline event or a notification.
    var announces: Bool { origin == .registry }

    /// "Desk Mouse at 12%"
    var lowSummary: String { "\(name) at \(percent)%" }

    /// One line for an explanation. Nil when nothing reports a level.
    static func summaryLine(_ list: [AccessoryBattery]?) -> String? {
        guard let list, !list.isEmpty else { return nil }
        // By what each one is, not by its name: an accessory's name is often its owner's ("Sam's AirPods").
        return "Accessory batteries: " + list.map { "\($0.kind.noun) \($0.percent)%\($0.isCharging == true ? " (charging)" : "")" }.joined(separator: ", ") + "."
    }
}

// MARK: - Decoding

extension AccessoryBattery {
    /// One registry entry that may be a device with a level, before any are thrown out or merged.
    private struct Candidate {
        var device: AccessoryBattery
        var named: Bool
        var serial: String?
        var address: String?

        /// Whether two entries are the same device: the same serial number or address, or the same name on the
        /// same transport with nothing that tells them apart. Apple's devices appear under more than one driver.
        func same(as other: Candidate) -> Bool {
            if let serial, let theirs = other.serial { return serial == theirs }
            if let address, let theirs = other.address { return address == theirs }
            return device.name.lowercased() == other.device.name.lowercased() && device.transport == other.device.transport
        }
    }

    /// Devices from registry entries that publish `BatteryPercent`. An entry without a believable level is left
    /// out, one without a name is called by what it is, and a device listed twice appears once.
    static func decode(registry entries: [[String: Any]]) -> [AccessoryBattery] {
        var kept: [Candidate] = []
        for entry in entries {
            guard let percent = number(entry["BatteryPercent"]), (0...100).contains(percent) else { continue }
            // The Mac's own battery is the Battery area's, not an accessory.
            if (entry["Built-In"] as? NSNumber)?.boolValue == true { continue }
            let product = text(entry["Product"])
            let transport = transportName(text(entry["Transport"]))
            let kind = guessKind(name: product, usagePage: number(entry["PrimaryUsagePage"]), usage: number(entry["PrimaryUsage"]))
            let serial = text(entry["SerialNumber"]), address = text(entry["DeviceAddress"]).map(normalized)
            let candidate = Candidate(
                device: AccessoryBattery(id: "", name: product ?? kind.noun, percent: percent, transport: transport, isCharging: charging(entry), kind: kind),
                named: product != nil, serial: serial, address: address
            )
            if let index = kept.firstIndex(where: { $0.same(as: candidate) }) {
                // Keep the first, with whatever the second knows that it did not.
                if kept[index].serial == nil { kept[index].serial = serial }
                if kept[index].address == nil { kept[index].address = address }
                if !kept[index].named, candidate.named {
                    kept[index].device.name = candidate.device.name
                    kept[index].device.kind = candidate.device.kind
                    kept[index].named = true
                }
                if kept[index].device.isCharging == nil { kept[index].device.isCharging = candidate.device.isCharging }
                if kept[index].device.transport == nil { kept[index].device.transport = candidate.device.transport }
            } else {
                kept.append(candidate)
            }
        }
        // The id comes last, from the best that is known of each device, so the order the registry lists a
        // device's two entries in does not change it.
        return unique(kept.map { candidate in
            var device = candidate.device
            device.id = digest(candidate.serial ?? candidate.address ?? "\(device.name)|\(device.transport ?? "")")
            return device
        })
    }

    /// Devices from the system's list of accessory power sources: the levels macOS itself keeps for
    /// headphones and their cases, which the hardware registry does not carry. A pair of earbuds is one source
    /// with one figure and its two halves inside it; the case is a source of its own.
    static func decode(sources: [[String: Any]]) -> [AccessoryBattery] {
        var kept: [AccessoryBattery] = []
        for source in sources {
            // The list asked for holds accessories only; an entry that says it is something else is left out.
            if let type = text(source[kIOPSTypeKey]), type != "Accessory Source" { continue }
            guard (source[kIOPSIsPresentKey] as? NSNumber)?.boolValue ?? true, let percent = level(source) else { continue }
            let category = text(source["Accessory Category"])?.lowercased() ?? ""
            let part = text(source["Part Identifier"])?.lowercased() ?? ""
            let given = text(source[kIOPSNameKey])
            var kind = guessKind(name: given, usagePage: nil, usage: nil)
            if category.contains("case") || part == "case" { kind = .chargingCase } else if category.contains("head") || category.contains("audio") { kind = .headphones }
            var name = given ?? kind.noun
            // Halves listed on their own would otherwise be two rows with one name.
            if part == "left" || part == "right" { name += " (\(part))" }
            var device = AccessoryBattery(id: digest((text(source["Accessory Identifier"]) ?? given ?? kind.noun) + "|" + part), name: name, percent: percent,
                                          transport: transportName(text(source[kIOPSTransportTypeKey])), isCharging: (source[kIOPSIsChargingKey] as? NSNumber)?.boolValue, kind: kind)
            device.origin = .powerSources
            // The halves of a pair, when they have drifted apart: the one figure hides which is nearly out.
            if let halves = source["Combined Parts"] as? [[String: Any]] {
                let levels = halves.compactMap { half in level(half).flatMap { percent in text(half["Part Identifier"]).map { ($0.lowercased(), percent) } } }
                if levels.count > 1, Set(levels.map(\.1)).count > 1 {
                    device.detail = levels.sorted { $0.0 < $1.0 }.map { "\($0.0) \($0.1)%" }.joined(separator: " · ")
                }
            }
            kept.append(device)
        }
        return unique(kept)
    }

    /// A power source's charge as a percentage. Nil without a believable one.
    private static func level(_ source: [String: Any]) -> Int? {
        guard let current = number(source[kIOPSCurrentCapacityKey]) else { return nil }
        let most = number(source[kIOPSMaxCapacityKey]) ?? 100
        guard most > 0, current >= 0, current <= most else { return nil }
        return Int((Double(current) / Double(most) * 100).rounded())
    }

    /// Both lists as one. A device both of them know is the registry's, which is read from the device's driver.
    static func merged(registry: [AccessoryBattery], sources: [AccessoryBattery]) -> [AccessoryBattery] {
        let known = Set(registry.map { $0.name.lowercased() })
        return unique(registry + sources.filter { !known.contains($0.name.lowercased()) })
    }

    /// In name order, each id once.
    private static func unique(_ list: [AccessoryBattery]) -> [AccessoryBattery] {
        var seen = Set<String>()
        var out: [AccessoryBattery] = []
        for (index, device) in list.enumerated() {
            var device = device
            // Two devices nothing tells apart (the same name, no serial numbers) still each get a row.
            if !seen.insert(device.id).inserted { device.id += "#\(index)"; seen.insert(device.id) }
            out.append(device)
        }
        return out.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    private static func number(_ value: Any?) -> Int? {
        // A level arrives as a number. A boolean is one too, as far as Foundation can tell, and is not a level.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    private static func normalized(_ address: String) -> String {
        address.lowercased().filter { $0.isHexDigit }
    }

    /// Charging, where the device says. Apple's input devices publish `BatteryStatusFlags`; its two low bits are
    /// set while the device is on external power and charging.
    private static func charging(_ entry: [String: Any]) -> Bool? {
        for key in ["IsCharging", "BatteryIsCharging"] {
            if let flag = entry[key] as? NSNumber { return flag.boolValue }
        }
        guard let flags = number(entry["BatteryStatusFlags"]) else { return nil }
        return flags & 0x3 != 0
    }

    private static func transportName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let plain = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if plain.hasPrefix("bluetooth") { return "Bluetooth" }
        if plain == "usb" { return "USB" }
        return raw
    }

    private static func guessKind(name: String?, usagePage: Int?, usage: Int?) -> Kind {
        let lower = (name ?? "").lowercased()
        let words: [(String, Kind)] = [("keyboard", .keyboard), ("trackpad", .trackpad), ("mouse", .mouse), ("case", .chargingCase), ("airpods", .headphones),
                                       ("headphone", .headphones), ("headset", .headphones), ("buds", .headphones), ("beats", .headphones),
                                       ("controller", .controller), ("gamepad", .controller), ("pencil", .pencil)]
        if let match = words.first(where: { lower.contains($0.0) }) { return match.1 }
        // What the device says it is for, in the HID tables: generic desktop page, then the kind of control.
        if usagePage == 1 {
            switch usage {
            case 6, 7: return .keyboard
            case 2: return .mouse
            case 4, 5: return .controller
            default: break
            }
        }
        if usagePage == 0x0D { return .trackpad }
        return .other
    }

    /// FNV-1a, as hex: enough to tell a handful of devices apart without keeping what identified them.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}

// MARK: - Reading

extension AccessoryBattery {
    /// The system's accessory power sources are read as well as the registry: that list is where headphones
    /// and their cases are. Debug: DOTMETER_ACCESSORY_SOURCES=0 leaves it out for one run.
    static let usesPowerSources = ProcessInfo.processInfo.environment["DOTMETER_ACCESSORY_SOURCES"] != "0"

    /// Everything that reports a level right now.
    static func read() -> [AccessoryBattery] {
        let registry = decode(registry: registryEntries(publishing: "BatteryPercent"))
        guard usesPowerSources, let sources = powerSources() else { return registry }
        return merged(registry: registry, sources: decode(sources: sources))
    }

    /// The properties of every registry entry that has `key`, whatever its class: Apple's keyboards, mice and
    /// trackpads publish the level under their own driver, and other makers' under theirs.
    static func registryEntries(publishing key: String) -> [[String: Any]] {
        guard let matching = IOServiceMatching("IOService") as NSMutableDictionary? else { return [] }
        matching["IOPropertyExistsMatch"] = key
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var entries: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { continue }
            entries.append(properties)
        }
        return entries
    }

    /// The accessory power sources, as the system's power daemon lists them (what `pmset -g accps` prints).
    /// The call has no public header, so it is looked up when needed: nil where this macOS does not have it,
    /// and the registry's devices are then all there is. No Bluetooth framework is involved and nothing is
    /// asked of the user: the daemon already holds the levels.
    static func powerSources() -> [[String: Any]]? {
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else { return nil }
        let byType = unsafeBitCast(symbol, to: ByType.self)
        // 4 asks for accessories only.
        guard let blob = byType(4)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}

// MARK: - Running low

/// Decides when an accessory's battery is news: once when it falls to 15% or under, and not again until it has
/// been above 20%. A device that goes away while low takes its event with it and stays told. Devices known
/// only from the system's power sources are never news (see `AccessoryBattery.announces`).
struct AccessoryWatch {
    static let low = 15
    static let rearm = 20

    enum Change: Equatable {
        /// This device has just run low.
        case low(AccessoryBattery)
        /// The device with this id is back above 20%, or gone: its event is over.
        case over(String)
    }

    /// Devices that have had their event and have not been above 20% since.
    private var told: Set<String> = []
    /// Devices whose event is still running.
    private var running: Set<String> = []

    mutating func step(_ all: [AccessoryBattery]) -> [Change] {
        let list = all.filter(\.announces)
        var changes: [Change] = []
        for device in list {
            if device.percent > Self.rearm {
                told.remove(device.id)
                if running.remove(device.id) != nil { changes.append(.over(device.id)) }
            } else if device.isLow, told.insert(device.id).inserted {
                running.insert(device.id)
                changes.append(.low(device))
            }
        }
        let present = Set(list.map(\.id))
        for id in running.subtracting(present).sorted() {
            running.remove(id)
            changes.append(.over(id))
        }
        return changes
    }
}
