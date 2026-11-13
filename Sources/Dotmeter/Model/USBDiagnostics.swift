import Foundation

/// A finding about one port, in a sentence someone can act on.
struct USBVerdict: Codable, Equatable, Identifiable {
    enum Tone: String, Codable { case good, plain, caution }

    var id: String
    var tone: Tone
    var title: String
    var detail: String
}

/// One part of a connection and the most it could do, set beside what the connection settled on.
struct LinkPart: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var bitsPerSecond: Double?
    var note: String?
    /// This part is why the connection is no faster.
    var limiting = false

    var text: String { bitsPerSecond.map(Format.linkSpeed) ?? "not stated" }
}

struct PortDiagnosis: Codable, Equatable {
    /// What is limiting the data speed: the Mac's port, the cable or the device.
    var speed: USBVerdict?
    /// The Mac's port, the cable and the device, each with its ceiling.
    var parts: [LinkPart] = []
    var negotiated: Double?
    /// What the negotiated figure is the speed of: "Thunderbolt 4 / USB4", "USB 3".
    var negotiatedName: String?
    /// Whether the cable's own marker and the Mac's controller agree about the cable.
    var crossCheck: USBVerdict?
    var cable: [USBVerdict] = []
    var screens: [USBVerdict] = []
    var power: USBVerdict?
    var health: USBVerdict?

    var all: [USBVerdict] {
        ([speed, crossCheck] + cable.map { Optional($0) } + screens.map { Optional($0) } + [power, health]).compactMap { $0 }
    }

    /// The finding that matters most: a caution if there is one, else the speed verdict.
    var headline: USBVerdict? {
        all.first { $0.tone == .caution } ?? speed ?? all.first
    }
}

/// Works out, for each port, what is holding the connection where it is. Every statement comes from what the
/// three parts report about themselves; where a part says nothing, the verdict says so instead of guessing.
enum USBDiagnostics {
    static func diagnose(_ port: USBPort, charger: ChargerInfo? = nil) -> PortDiagnosis {
        var result = PortDiagnosis()
        guard port.connected else { return result }
        if let link = port.thunderbolt, let negotiated = link.bitsPerSecond {
            thunderbolt(port, link, negotiated, into: &result)
        } else {
            usb(port, into: &result)
        }
        result.cable = cableNotes(port)
        result.screens = port.displays.filter(\.active).compactMap(screen)
        result.power = power(port, charger: charger)
        if let health = port.health, health.troubles > 0 {
            var parts: [String] = []
            if health.linkErrors > 0 { parts.append("\(health.linkErrors) link \(health.linkErrors == 1 ? "error" : "errors")") }
            if health.linkFailures > 0 { parts.append("\(health.linkFailures) failed USB 3 link \(health.linkFailures == 1 ? "attempt" : "attempts")") }
            if health.enumerationFailures + health.addressFailures > 0 { parts.append("\(health.enumerationFailures + health.addressFailures) devices that failed to start") }
            if health.overcurrent > 0 { parts.append("\(health.overcurrent) over-current \(health.overcurrent == 1 ? "trip" : "trips")") }
            result.health = USBVerdict(
                id: "health", tone: .caution, title: "This port has logged errors",
                detail: parts.joined(separator: ", ") + " since the Mac started. A few are normal after plugging and unplugging; a count that keeps climbing points at the cable or the connector."
            )
        }
        return result
    }

    // MARK: Data speed

    private static func thunderbolt(_ port: USBPort, _ link: ThunderboltLink, _ negotiated: Double, into result: inout PortDiagnosis) {
        result.negotiated = negotiated
        result.negotiatedName = link.familyName
        let device = link.deviceName ?? "The device"
        // Both ends list the lane speeds they support; a link bonds two lanes.
        var mac = LinkPart(id: "mac", name: "This Mac's port", bitsPerSecond: link.hostSpeeds.flatMap(ThunderboltLane.fastest).map { $0 * 2 })
        mac.note = link.hostSpeeds.map { ThunderboltLane.newestFamily($0) + ": " + ThunderboltLane.speeds($0) }
        var far = LinkPart(id: "device", name: device, bitsPerSecond: link.deviceSpeeds.flatMap(ThunderboltLane.fastest).map { $0 * 2 })
        far.note = link.deviceSpeeds.map { ThunderboltLane.newestFamily($0) + ": " + ThunderboltLane.speeds($0) }

        // The Mac's controller tests the cable when the link comes up; that judgement is used when there is one,
        // and the cable's own marker otherwise.
        let marked = port.cable?.linkBitsPerSecond
        var cable = LinkPart(id: "cable", name: "The cable", bitsPerSecond: link.cableBitsPerSecond ?? marked)
        if let rated = link.cableBitsPerSecond, let marked {
            if rated == marked {
                cable.note = "its marker and the Mac's controller agree"
                result.crossCheck = USBVerdict(id: "cross", tone: .good, title: "Marker and controller agree", detail: "The cable's marker says \(Format.linkSpeed(marked)) and the Mac's Thunderbolt controller rates the cable for the same.")
            } else if rated > marked {
                cable.note = "marked \(Format.linkSpeed(marked)), rated higher by the controller"
                let passive = port.cable?.active == false
                result.crossCheck = USBVerdict(
                    id: "cross", tone: .plain, title: "Controller rates the cable above its marker",
                    detail: "The marker says \(Format.linkSpeed(marked)) and the Mac's controller rates the cable for \(Format.linkSpeed(rated))."
                        + (passive && marked == 40e9 ? " That is expected of a short passive cable: the 80 Gb/s mode was designed to run over cables marked for 40." : "")
                )
            } else {
                cable.note = "marked \(Format.linkSpeed(marked)), rated lower by the controller"
                result.crossCheck = USBVerdict(
                    id: "cross", tone: .caution, title: "Controller rates the cable below its marker",
                    detail: "The marker says \(Format.linkSpeed(marked)) but the Mac's controller only rates the cable for \(Format.linkSpeed(rated)). That points at the cable or how it is seated."
                )
            }
        } else if link.cableBitsPerSecond != nil {
            cable.note = port.cable == nil ? "as rated by the Mac's controller; the cable carries no marker" : "as rated by the Mac's controller"
        } else if marked != nil {
            cable.note = "from its marker"
        } else {
            cable.note = "no marker, and the controller gives no rating"
        }
        result.parts = [mac, cable, far]
        result.speed = verdict(negotiated: negotiated, parts: &result.parts, what: link.familyName)
    }

    private static func usb(_ port: USBPort, into result: inout PortDiagnosis) {
        // The device plugged straight into the port sets the port's speed; whatever hangs off a hub has its own.
        guard let device = port.devices.max(by: { $0.bitsPerSecond < $1.bitsPerSecond }) else {
            if port.usb3?.active == true || port.usb2?.active == true {
                result.negotiated = port.usb3?.active == true ? port.usb3?.bitsPerSecond : port.usb2?.bitsPerSecond
                result.negotiatedName = port.usb3?.active == true ? "USB 3" : "USB 2"
            }
            return
        }
        let negotiated = device.bitsPerSecond
        result.negotiated = negotiated
        result.negotiatedName = negotiated >= 5e9 ? "USB 3" : "USB 2"

        // Apple's published figures for the port itself: USB-C ports carry USB 3 at up to 10 Gb/s, USB-A at 5.
        let portCeiling: Double = port.supported.contains("USB3") ? (port.kind == .usbA ? 5e9 : 10e9) : 480e6
        var mac = LinkPart(id: "mac", name: "This Mac's port", bitsPerSecond: portCeiling)
        mac.note = port.kind == .usbA ? "USB-A, up to 5 Gb/s" : "USB 3 at up to 10 Gb/s"
        var cable = LinkPart(id: "cable", name: "The cable", bitsPerSecond: port.cable?.usb3BitsPerSecond)
        cable.note = port.cable.map { "marked \($0.speedName)" } ?? (port.kind == .usbC ? "no marker to read" : "USB-A cables carry no marker")
        var far = LinkPart(id: "device", name: device.name)
        // Below 3.1 the version pins the ceiling. From 3.1 up a device may be a 5, 10 or 20 Gb/s one and does not say.
        if device.usbVersion < 0x0310 {
            far.bitsPerSecond = device.usbVersion == 0x0210 ? nil : device.versionCeiling
            far.note = device.usbVersion == 0x0210 ? "states USB 2.1, as a USB 3 device that fell back does too" : "a \(device.versionText) device"
        } else {
            far.note = "states \(device.versionText), which covers 5, 10 and 20 Gb/s devices alike"
        }
        result.parts = [mac, cable, far]

        if negotiated <= 12e6 {
            result.parts[2].bitsPerSecond = negotiated
            result.parts[2].limiting = true
            result.speed = USBVerdict(
                id: "speed", tone: .good, title: "\(device.name) is a \(Format.linkSpeed(negotiated)) device",
                detail: "Keyboards, mice, receivers and the like run at this speed by design. Nothing is holding it back."
            )
            return
        }
        if negotiated < 5e9, let marker = port.cable, marker.speedCode == 0, port.supported.contains("USB3") {
            result.parts[1].limiting = true
            result.speed = USBVerdict(
                id: "speed", tone: .caution, title: "Cable is limiting data speed",
                detail: "The cable's marker says USB 2.0 only, so this connection cannot run above 480 Mb/s whatever is at the far end. It is a charging cable; one marked for USB 3 or faster would let \(device.name) run at its own speed."
            )
            return
        }
        if negotiated < 5e9, device.usbVersion == 0x0210, port.supported.contains("USB3") {
            result.speed = USBVerdict(
                id: "speed", tone: .plain, title: "Running at USB 2 speed, \(Format.linkSpeed(negotiated))",
                detail: "\(device.name) states USB 2.1. Plain USB 2 devices say that, and so does a USB 3 device that has fallen back to USB 2, so it cannot be told from here which this is. If it should be faster, the cable is the first thing to change."
            )
            return
        }
        result.speed = verdict(negotiated: negotiated, parts: &result.parts, what: result.negotiatedName ?? "USB")
    }

    /// The shared reasoning: the connection can be no faster than its slowest part. If it runs at that, name the
    /// part; if it runs below it, something made it settle lower and that is worth saying.
    private static func verdict(negotiated: Double, parts: inout [LinkPart], what: String) -> USBVerdict {
        let speed = Format.linkSpeed(negotiated)
        let known = parts.filter { $0.bitsPerSecond != nil }
        let unknown = parts.filter { $0.bitsPerSecond == nil }
        let unstated = unknown.isEmpty ? "" : " " + unknown.map { $0.id == "cable" ? "The cable's own rating could not be read." : "\($0.name) does not state its own ceiling." }.joined(separator: " ")
        guard let ceiling = known.compactMap(\.bitsPerSecond).min() else {
            return USBVerdict(id: "speed", tone: .plain, title: "Running at \(speed)", detail: "None of the three parts states what it could do, so there is nothing to compare this with.")
        }
        if negotiated < ceiling * 0.99 {
            let names = list(known.map { $0.name.lowercasedFirst })
            return USBVerdict(
                id: "speed", tone: .caution, title: "Running slower than expected",
                detail: "The link came up at \(speed), and \(names) \(known.count == 1 ? "supports" : "each support") \(Format.linkSpeed(ceiling)) or more. A marginal cable or connector is the usual cause: unplug and replug it, then try another cable or port." + unstated
            )
        }
        for index in parts.indices where (parts[index].bitsPerSecond ?? .infinity) <= negotiated * 1.01 { parts[index].limiting = true }
        let limiting = parts.filter(\.limiting)
        let faster = parts.filter { !$0.limiting && $0.bitsPerSecond != nil }
        if limiting.count == known.count, unknown.isEmpty {
            return USBVerdict(id: "speed", tone: .good, title: "Running at full speed, \(speed)", detail: "\(speed) is the most every part of this connection supports: the Mac's port, the cable and the device.")
        }
        let headroom = faster.isEmpty ? "" : " " + list(faster.map { "\($0.name.lowercasedFirst) (\($0.text))" }).capitalizedFirst + " could do more."
        if limiting.map(\.id) == ["cable"] {
            return USBVerdict(
                id: "speed", tone: .caution, title: "Cable is limiting data speed",
                detail: "The cable is good for \(speed) and the link is running at exactly that." + headroom + " A faster cable would raise it." + unstated
            )
        }
        if limiting.map(\.id) == ["device"] {
            return USBVerdict(
                id: "speed", tone: .good, title: "\(limiting[0].name) runs at \(speed), the fastest it supports",
                detail: "This is not a cable problem." + headroom + unstated
            )
        }
        if limiting.map(\.id) == ["mac"] {
            return USBVerdict(id: "speed", tone: .plain, title: "This Mac's port is the limit, at \(speed)", detail: "The port tops out at \(speed) for \(what)." + headroom + unstated)
        }
        return USBVerdict(
            id: "speed", tone: .good, title: "Running at \(speed)",
            detail: "That is the most \(list(limiting.map { $0.name.lowercasedFirst })) \(limiting.count == 1 ? "supports" : "support")." + headroom + unstated
        )
    }

    // MARK: Cable

    private static func cableNotes(_ port: USBPort) -> [USBVerdict] {
        guard let cable = port.cable else { return [] }
        var notes: [USBVerdict] = []
        if cable.identity.xid != 0 {
            if let holder = USBCertifications.holder(cable.identity.xid) {
                notes.append(USBVerdict(id: "certified", tone: .good, title: "USB-IF certified", detail: "Certificate \(cable.identity.xid), issued to \(holder). The number is read off the cable and matched against the list bundled with the app."))
            } else if USBCertifications.isLoaded {
                notes.append(USBVerdict(id: "certified", tone: .plain, title: "Certified but unlisted", detail: "The cable carries certificate \(cable.identity.xid), which is not in USB-IF's published list. Certification is voluntary and some makers' cables are not listed, so this says something about the number, not about the cable."))
            } else {
                notes.append(USBVerdict(id: "certified", tone: .plain, title: "Carries USB-IF certificate \(cable.identity.xid)", detail: "The number is read off the cable. No list of certificates is bundled with the app yet, so who holds it is not shown."))
            }
        }
        let unusual = cable.unusual
        if !unusual.isEmpty {
            notes.append(USBVerdict(
                id: "trust", tone: .caution, title: unusual.count == 1 ? "One value in the cable's marker looks unusual" : "\(unusual.count) values in the cable's marker look unusual",
                detail: unusual.joined(separator: " ") + " This means the marker looks unusual, not that the cable is fake: it may still do what it says."
            ))
        }
        return notes
    }

    // MARK: Screens

    private static func screen(_ screen: DisplayLink) -> USBVerdict? {
        guard let signal = screen.signalText, let refresh = screen.refresh else { return nil }
        let name = screen.name ?? "The screen"
        var detail = "\(name) is being sent \(signal)."
        if let drawn = screen.drawnWidth, let height = screen.drawnHeight, drawn != screen.signalWidth {
            detail += " The picture is drawn at \(drawn) × \(height) and scaled to fit."
        }
        let link = screen.linkText.map { $0 + (screen.rateFromAdapter ? ", as the dock's display adapter reports it" : "") }
        let needs = screen.pixelClock.map(DisplayLink.bits)

        if let top = screen.topRefresh, top > refresh + 1.5 {
            if let payload = screen.payload, let link, let wanted = screen.topPixelClock.map(DisplayLink.bits) {
                detail += wanted > payload
                    ? " It offers \(Format.hertz(top)) at this size, which needs \(Format.linkSpeed(wanted)) uncompressed. The link to it is \(link), \(Format.linkSpeed(payload)) of picture, so the connection may be what holds it at \(Format.hertz(refresh))."
                    : " It offers \(Format.hertz(top)) at this size, and the link has room for it: \(link), \(Format.linkSpeed(payload)) of picture against the \(Format.linkSpeed(wanted)) it would need. This is a setting, under Displays in System Settings."
            } else {
                detail += " It offers \(Format.hertz(top)) at this size."
            }
            return USBVerdict(id: "screen:\(screen.id)", tone: .plain, title: "\(name) is below its top refresh rate", detail: detail)
        }
        if let payload = screen.payload, let link, let needs {
            detail += needs > payload
                ? " The link is \(link), \(Format.linkSpeed(payload)) of picture, and this mode needs \(Format.linkSpeed(needs)) uncompressed, so it is being sent compressed (DSC), which is designed to be visually lossless."
                : " The link is \(link), \(Format.linkSpeed(payload)) of picture; this mode needs \(Format.linkSpeed(needs)) of it at eight bits a colour."
        }
        return USBVerdict(id: "screen:\(screen.id)", tone: .good, title: "\(name) is at its top refresh rate for this size", detail: detail)
    }

    // MARK: Power

    private static func power(_ port: USBPort, charger: ChargerInfo?) -> USBVerdict? {
        guard let source = port.powerSource, let watts = source.watts else { return nil }
        let offered = source.options.map(\.watts).max() ?? watts
        let contract = String(format: "%g V at up to %.2g A (%.0f W)", Double(source.millivolts ?? 0) / 1000, Double(source.milliamps ?? 0) / 1000, watts)
        if let cable = port.cable, let limit = cable.watts, Double(limit) + 1 < offered, watts <= Double(limit) + 1 {
            return USBVerdict(
                id: "power", tone: .caution, title: "Cable limits charging to \(limit) W",
                detail: "The charger offers up to \(Int(offered.rounded())) W, and this cable is marked for \(cable.amps.map { String(format: "%g A", $0) } ?? "less"). The contract in force is \(contract). A cable marked for 5 A would let the charger give its full output."
            )
        }
        return USBVerdict(id: "power", tone: .good, title: "Charging contract: \(contract)", detail: offered > watts + 1 ? "The charger offers up to \(Int(offered.rounded())) W; the Mac asked for this much." : "This is the most the charger offers.")
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// Who holds a USB-IF certificate, from a list bundled with the app when there is one: a tab-separated file,
/// certificate number then holder. Nothing is looked up over the network.
enum USBCertifications {
    private static let holders: [UInt32: String] = {
        guard let url = Bundle.main.url(forResource: "usb-certifications", withExtension: "tsv"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [UInt32: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            if fields.count == 2, let xid = UInt32(fields[0]) { out[xid] = String(fields[1]) }
        }
        return out
    }()

    static var isLoaded: Bool { !holders.isEmpty }
    static func holder(_ xid: UInt32) -> String? { holders[xid] }
}

extension String {
    var lowercasedFirst: String {
        // "This Mac's port" reads as "this Mac's port" mid-sentence; a product name keeps its capital.
        hasPrefix("This ") || hasPrefix("The ") ? prefix(1).lowercased() + dropFirst() : self
    }

    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
