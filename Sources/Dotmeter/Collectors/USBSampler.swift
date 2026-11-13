import CoreGraphics
import Foundation
import IOKit

/// Reads the ports and everything on them from the hardware registry: the port controllers with their Power
/// Delivery answers, the Thunderbolt routers, the USB device tree and the screens.
///
/// Every class is matched by its base class (`IOPort`, `IOThunderboltSwitch`, `IOUSBHostDevice`), so the reader
/// does not depend on which chip a particular Mac uses for its ports. It only reads; nothing is sent to a
/// device, and nothing leaves the Mac.
final class USBSampler {
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_USB_DEMO"]

    func sample() -> USBStats {
        if let demo = Self.demo { return USBDemo.stats(demo) }
        var stats = USBStats()
        var portIndex: [String: Int] = [:]
        readPorts(into: &stats, paths: &portIndex)
        let roots = readControllerPorts(into: &stats, paths: portIndex)
        readDevices(into: &stats, roots: roots)
        readThunderbolt(into: &stats)
        readScreens(into: &stats)
        stats.charger = Self.readCharger()
        stats.ports.sort { ($0.kind.order, $0.number) < ($1.kind.order, $1.number) }
        return stats
    }

    // MARK: Ports

    private func readPorts(into stats: inout USBStats, paths: inout [String: Int]) {
        for entry in Registry.entries("IOPort") {
            defer { IOObjectRelease(entry) }
            let p = Registry.properties(entry)
            let name = Registry.name(entry)
            let described = (p["PortTypeDescription"] as? String) ?? name
            let kind: USBPort.Kind
            if described.contains("USB-C") { kind = .usbC }
            else if described.contains("USB-A") { kind = .usbA }
            else if described.contains("HDMI") || name.contains("HDMI") { kind = .hdmi }
            else if described.contains("SD") || name.contains("SD") { kind = .sdCard }
            else if described.contains("MagSafe") || name.contains("MagSafe") { kind = .magSafe }
            else { kind = .other }

            // The registry names every port of a kind alike; the number is what tells them apart.
            let number = Registry.int(p["PortNumber"]) ?? 0
            var port = USBPort(id: "\(kind.title)@\(number)", kind: kind, number: number)
            port.connected = (p["ConnectionActive"] as? Bool) ?? false
            port.supported = (p["TransportsSupported"] as? [String]) ?? []
            port.provisioned = (p["TransportsProvisioned"] as? [String]) ?? []
            port.active = (p["TransportsActive"] as? [String]) ?? []
            port.orientation = Registry.int(p["PlugOrientation"]).flatMap { $0 == 0 ? nil : $0 }
            port.plugEvents = Registry.int(p["Plug Event Count"])
            port.overcurrentEvents = Registry.int(p["Overcurrent Count"])
            port.activeCable = p["ActiveCable"] as? Bool
            port.opticalCable = p["OpticalCable"] as? Bool
            readTransports(of: entry, into: &port, depth: 0)
            // A slot or socket with something in it counts as connected even when it has no "connection" of its own.
            if port.displays.contains(where: \.active) || port.cardDescription != nil { port.connected = true }
            if let path = Registry.path(entry) { paths[path] = stats.ports.count }
            stats.ports.append(port)
        }
    }

    /// The transport states hang below the port: CC with the Power Delivery answers, USB2, USB3, and CIO
    /// (Thunderbolt or USB4) with the transports tunnelled through it.
    private func readTransports(of entry: io_registry_entry_t, into port: inout USBPort, depth: Int) {
        guard depth < 3 else { return }
        for child in Registry.children(entry) {
            defer { IOObjectRelease(child) }
            let cls = Registry.className(child)
            if cls.hasPrefix("IOPortFeaturePowerSource") {
                port.powerSource = Self.powerSource(Registry.properties(child))
                continue
            }
            guard cls.hasPrefix("IOPortTransport") else { continue }
            let p = Registry.properties(child)
            let metadata = (p["Metadata"] as? [String: Any]) ?? [:]
            let active = (p["Active"] as? Bool) ?? false
            let tunneled = (p["Tunneled"] as? Bool) ?? false

            if cls.hasPrefix("IOPortTransportComponent") {
                // SOP is the far end, SOP' the chip in the near plug of the cable, SOP'' the one in the far plug.
                let address = (p["AddressDescription"] as? String) ?? Registry.name(child)
                let words = ((metadata["VDOs"] as? [Data]) ?? []).map(Registry.word)
                let revision = Registry.int(p["Specification Revision"]) ?? 3
                if address == "SOP" {
                    port.partner = PDIdentity(vdos: words, revision: revision, cable: false)
                } else if address == "SOP'", let identity = PDIdentity(vdos: words, revision: revision, cable: true) {
                    port.cable = CableMarker(identity: identity)
                }
                continue
            }

            switch (p["TransportTypeDescription"] as? String) ?? "" {
            case "USB2", "USB3":
                let rate = p["DataRateDescription"] as? String
                let transport = USBTransport(
                    active: active, tunneled: tunneled, rateText: rate == "None" ? nil : rate,
                    bitsPerSecond: rate.flatMap(Self.bitsPerSecond),
                    product: p["Product"] as? String, manufacturer: p["Manufacturer"] as? String
                )
                if (p["TransportTypeDescription"] as? String) == "USB2" { port.usb2 = transport } else { port.usb3 = transport }
            case "CIO":
                guard active else { break }
                var link = ThunderboltLink(uid: Registry.unsigned(p["UID"]).map(String.init) ?? "")
                link.deviceName = p["Device Model Name"] as? String
                link.vendorName = p["Device Vendor Name"] as? String
                link.tunnelsSupported = (p["TunneledTransportsSupported"] as? [String]) ?? []
                link.tunnelsProvisioned = (p["TunneledTransportsProvisioned"] as? [String]) ?? []
                link.legacyAdapter = (p["LegacyAdapter"] as? Bool) ?? false
                link.asymmetricSupported = (p["AsymmetricModeSupported"] as? Bool) ?? false
                link.cableSpeedCode = Registry.int(p["CableSpeed"]).flatMap { $0 == 0 ? nil : $0 }
                port.thunderbolt = link
            case "DisplayPort":
                let rate = p["LinkRateDescription"] as? String
                var screen = DisplayLink(
                    id: (p["TransportDescription"] as? String) ?? "\(port.id)/DisplayPort@\(port.displays.count)",
                    name: p["ProductName"] as? String, maker: p["ManufacturerName"] as? String, productID: Registry.int(p["ProductID"]),
                    active: active, tunneled: tunneled,
                    lanes: Registry.int(p["LaneCount"]) ?? 0, maxLanes: Registry.int(p["MaxLaneCount"]) ?? 0
                )
                screen.laneGigabits = rate.flatMap(Self.gigabits)
                screen.rateName = screen.laneGigabits.flatMap(Self.displayPortRateName)
                screen.branch = p["BranchDeviceID"] as? String
                screen.sink = p["SinkDeviceID"] as? String
                screen.output = metadata["DFP Type Description"] as? String
                screen.year = Registry.int(metadata["Year of Manufacture"])
                // A socket with nothing behind it still has a transport; only screens are listed.
                if active || screen.name != nil { port.displays.append(screen) }
            case "PCIe":
                port.pcieTunnel = active
            case "SD":
                if active {
                    let card = [(p["Card Type Description"] as? String), (p["Speed Class Description"] as? String)]
                        .compactMap { $0 }.filter { $0 != "Unknown" }
                    port.cardDescription = card.isEmpty ? "Card inserted" : card.joined(separator: ", ")
                }
            default:
                break
            }
            readTransports(of: child, into: &port, depth: depth + 1)
        }
    }

    /// What a charger on this port offers and which offer is in force, as the port's power feature lists them.
    static func powerSource(_ p: [String: Any]) -> PortPowerSource? {
        func option(_ item: [String: Any], _ index: Int) -> PowerOption? {
            guard let volts = Registry.int(item["Voltage (mV)"]), volts > 0 else { return nil }
            var amps = Registry.int(item["Max Current (mA)"]) ?? 0
            if amps == 0, let milliwatts = Registry.int(item["Max Power (mW)"]) { amps = milliwatts * 1000 / volts }
            let fixed = ((item["Class"] as? String) ?? "Fixed").hasSuffix("Fixed")
            return PowerOption(id: index, kind: fixed ? .fixed : .programmable, millivolts: volts, milliamps: amps)
        }
        var source = PortPowerSource(name: p["PowerSourceName"] as? String)
        source.options = ((p["PowerSourceOptions"] as? [[String: Any]]) ?? []).enumerated().compactMap { option($1, $0) }
        if let winning = (p["WinningPowerSourceOption"] as? [String: Any]).flatMap({ option($0, -1) }) {
            source.millivolts = winning.millivolts
            source.milliamps = winning.milliamps
            // The contract may be for less current than the offer it was made on, so fall back to the voltage alone.
            if let index = source.options.firstIndex(where: { $0.millivolts == winning.millivolts && $0.milliamps == winning.milliamps })
                ?? source.options.firstIndex(where: { $0.millivolts == winning.millivolts }) {
                source.options[index].active = true
            }
        }
        return source.options.isEmpty && source.millivolts == nil ? nil : source
    }

    /// "480 Mbps (High Speed)" or "10 Gbps" as bits per second.
    static func bitsPerSecond(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let value = Double(parts[0]) else { return nil }
        switch parts[1] {
        case "Gbps": return value * 1e9
        case "Mbps": return value * 1e6
        case "Kbps": return value * 1e3
        default: return nil
        }
    }

    /// The figure in a DisplayPort rate such as "HBR3 (8.1 Gbps)".
    static func gigabits(_ text: String) -> Double? {
        guard let unit = text.range(of: "Gbps") else { return nil }
        let before = text[..<unit.lowerBound].trimmingCharacters(in: .whitespaces)
        let figure = before.reversed().prefix { $0.isNumber || $0 == "." }
        return Double(String(figure.reversed()))
    }

    // MARK: Controller ports

    /// The USB controller's own ports say which physical port they belong to, how much current that port gives,
    /// and keep the error counts. Returns each one's registry ID with the port it serves.
    private func readControllerPorts(into stats: inout USBStats, paths: [String: Int]) -> [UInt64: Int] {
        var roots: [UInt64: Int] = [:]
        for entry in Registry.entries("AppleUSBHostPort") {
            defer { IOObjectRelease(entry) }
            guard let path = Registry.property(entry, "UsbIOPort") as? String, let index = paths[path] else { continue }
            roots[Registry.id(entry)] = index
            if let limit = Registry.int(Registry.property(entry, "kUSBWakePortCurrentLimit")) {
                stats.ports[index].supplyMilliamps = max(stats.ports[index].supplyMilliamps ?? 0, limit)
            }
            var health = stats.ports[index].health ?? PortHealth()
            health.linkErrors += Registry.int(Registry.property(entry, "link-error-count")) ?? 0
            if let counts = Registry.property(entry, "port-statistics") as? [String: Any] {
                health.linkFailures += Registry.int(counts["kPortStatUSB3LinkFailureCount"]) ?? 0
                health.enumerationFailures += Registry.int(counts["kPortStatEnumerationFailureCount"]) ?? 0
                health.addressFailures += Registry.int(counts["kPortStatAddressFailureCount"]) ?? 0
                health.overcurrent += Registry.int(counts["kPortStatOverCurrentCount"]) ?? 0
                health.connects += Registry.int(counts["kPortStatConnectCount"]) ?? 0
            }
            stats.ports[index].health = health
        }
        return roots
    }

    // MARK: USB devices

    private func readDevices(into stats: inout USBStats, roots: [UInt64: Int]) {
        struct Found {
            var device: USBDevice
            var parent: UInt64?
            var root: Int?
        }
        var found: [UInt64: Found] = [:]
        var order: [UInt64] = []

        for entry in Registry.entries("IOUSBHostDevice") {
            defer { IOObjectRelease(entry) }
            let p = Registry.properties(entry)
            let vendorID = Registry.int(p["idVendor"]) ?? 0
            let vendor = (p["kUSBVendorString"] as? String) ?? (p["USB Vendor Name"] as? String)
            if let vendor { USBVendors.learn(vendorID, vendor) }
            var device = USBDevice(
                id: String(format: "%08x", Registry.int(p["locationID"]) ?? 0),
                name: ((p["kUSBProductString"] as? String) ?? (p["USB Product Name"] as? String) ?? Registry.name(entry)).trimmingCharacters(in: .whitespaces),
                vendorName: vendor?.trimmingCharacters(in: .whitespaces),
                vendorID: vendorID, productID: Registry.int(p["idProduct"]) ?? 0,
                bitsPerSecond: Double(Registry.int(p["UsbLinkSpeed"]) ?? 0),
                usbVersion: Registry.int(p["bcdUSB"]) ?? 0,
                deviceClass: Registry.int(p["bDeviceClass"]) ?? 0
            )
            device.milliamps = Registry.int(p["UsbPowerSinkAllocation"])
            for child in Registry.children(entry) {
                if let cls = Registry.int(Registry.property(child, "bInterfaceClass")), !device.interfaces.contains(cls) { device.interfaces.append(cls) }
                IOObjectRelease(child)
            }

            // Up through the registry: the first port is the one it is plugged into; the walk ends at the hub it
            // belongs to or at one of the Mac's own ports.
            var item = Found(device: device)
            var current = Registry.parent(entry)
            var steps = 0
            while let ancestor = current, steps < 10 {
                steps += 1
                if IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0 {
                    item.parent = Registry.id(ancestor)
                    IOObjectRelease(ancestor)
                    break
                }
                if IOObjectConformsTo(ancestor, "AppleUSBHostPort") != 0 {
                    if item.device.hubPort == nil { item.device.hubPort = Registry.int(Registry.property(ancestor, "port")) }
                    if let root = roots[Registry.id(ancestor)] {
                        item.root = root
                        IOObjectRelease(ancestor)
                        break
                    }
                }
                current = Registry.parent(ancestor)
                IOObjectRelease(ancestor)
            }
            let id = Registry.id(entry)
            found[id] = item
            order.append(id)
        }

        // Children into their parents, deepest first, then the top of each chain onto its port.
        func assembled(_ id: UInt64) -> USBDevice {
            var device = found[id]!.device
            device.children = order.filter { found[$0]!.parent == id }.map(assembled).sorted { ($0.hubPort ?? 0) < ($1.hubPort ?? 0) }
            return device
        }
        for id in order where found[id]!.parent == nil {
            guard let root = found[id]!.root else { continue }
            var device = assembled(id)
            let tunnel = stats.ports[root].usb3?.tunneled == true
            if tunnel { Self.markTunneled(&device) }
            stats.ports[root].devices.append(device)
        }
        for index in stats.ports.indices {
            // USB 3 before USB 2: the faster half of a dock first.
            stats.ports[index].devices.sort { $0.bitsPerSecond > $1.bitsPerSecond }
        }
    }

    /// Only the SuperSpeed half of a dock rides the tunnel; its USB 2 half has wires of its own in the cable.
    private static func markTunneled(_ device: inout USBDevice) {
        guard device.isSuperSpeed else { return }
        device.tunneled = true
        for index in device.children.indices { markTunneled(&device.children[index]) }
    }

    // MARK: Thunderbolt

    private func readThunderbolt(into stats: inout USBStats) {
        for entry in Registry.entries("IOThunderboltSwitch") {
            defer { IOObjectRelease(entry) }
            let p = Registry.properties(entry)
            var router = ThunderboltRouter(
                uid: Registry.unsigned(p["UID"]).map(String.init) ?? String(Registry.id(entry)),
                name: (p["Device Model Name"] as? String) ?? "Thunderbolt device",
                vendor: p["Device Vendor Name"] as? String,
                depth: Registry.int(p["Depth"]) ?? 0,
                version: Registry.int(p["Thunderbolt Version"])
            )

            for child in Registry.children(entry) {
                defer { IOObjectRelease(child) }
                guard IOObjectConformsTo(child, "IOThunderboltPort") != 0 else { continue }
                var port = Self.thunderboltPort(Registry.properties(child))
                if port.lane != nil, port.isPrimaryLane, let socket = Registry.property(child, "Socket ID") as? String { router.socket = Int(socket) }
                if port.kind == .display {
                    // The adapter's driver hangs below it and says what DisplayPort link it brought up.
                    for driver in Registry.children(child) {
                        if let rate = Registry.int(Registry.property(driver, "Established DP Link Rate")) {
                            port.displayRateCode = rate
                            port.displayLaneCode = Registry.int(Registry.property(driver, "Established DP Lane Count"))
                        }
                        IOObjectRelease(driver)
                    }
                }
                router.ports.append(port)
            }
            router.ports.sort { $0.number < $1.number }

            // Up to the router it is plugged into. Its own upstream port sits between the two in the registry, so
            // the last port passed on the way is the parent's.
            var current = Registry.parent(entry)
            var steps = 0
            var passed: [ThunderboltPort] = []
            while let ancestor = current, steps < 8 {
                steps += 1
                if IOObjectConformsTo(ancestor, "IOThunderboltSwitch") != 0 {
                    router.parentUID = Registry.unsigned(Registry.property(ancestor, "UID")).map(String.init)
                    IOObjectRelease(ancestor)
                    break
                }
                if IOObjectConformsTo(ancestor, "IOThunderboltPort") != 0 { passed.append(Self.thunderboltPort(Registry.properties(ancestor))) }
                current = Registry.parent(ancestor)
                IOObjectRelease(ancestor)
            }
            if router.parentUID != nil {
                router.parentPort = passed.last?.number
                // Its upstream port is listed with the parent, not among its own ports: keep it with the router.
                if passed.count > 1, var upstream = passed.first, !router.ports.contains(where: { $0.number == upstream.number }) {
                    upstream.isPrimaryLane = true
                    router.ports.insert(upstream, at: 0)
                }
            }
            stats.routers.append(router)
        }
        stats.routers.sort { ($0.depth, $0.socket ?? 99, $0.name) < ($1.depth, $1.socket ?? 99, $1.name) }

        // Each port's link: the Mac's own router gives the speed and width, both ends say what they could do.
        for index in stats.ports.indices {
            guard var link = stats.ports[index].thunderbolt else { continue }
            let device = stats.routers.first { $0.uid == link.uid && !$0.isHost }
            var host = device
            var hops = 0
            while let router = host, !router.isHost, hops < 8 {
                host = stats.routers.first { $0.uid == router.parentUID }
                hops += 1
            }
            if host == nil || host?.isHost != true { host = stats.routers.first { $0.isHost && $0.socket == stats.ports[index].number } }
            if let host, let port = host.linkPorts.first {
                link.lane = port.lane
                link.hostSpeeds = port.supportedSpeeds
            }
            if let device { link.deviceSpeeds = device.linkPorts.first?.supportedSpeeds }
            stats.ports[index].thunderbolt = link
        }
    }

    private static func thunderboltPort(_ p: [String: Any]) -> ThunderboltPort {
        let described = (p["Description"] as? String) ?? ""
        let kind: ThunderboltPort.Kind
        if described == "Thunderbolt Port" { kind = .link }
        else if described.contains("PCIe") { kind = .pcie }
        else if described.contains("USB") { kind = .usb }
        else if described.contains("DP") || described.contains("HDMI") { kind = .display }
        else if described.contains("Host Interface") { kind = .host }
        else if described.contains("inactive") { kind = .inactive }
        else { kind = .other }
        var port = ThunderboltPort(number: Registry.int(p["Port Number"]) ?? 0, kind: kind)
        if kind == .link, let speed = Registry.int(p["Current Link Speed"]) {
            let bandwidth = Registry.int(p["Link Bandwidth"]) ?? 0
            port.lane = ThunderboltLane(speedCode: speed, widthCode: Registry.int(p["Current Link Width"]) ?? 0, reported: bandwidth > 0 ? Double(bandwidth) * 1e8 : nil)
            port.isPrimaryLane = (Registry.int(p["Lane"]) ?? 1) == 1
            port.supportedSpeeds = Registry.int(p["Supported Link Speed"])
        }
        port.allocated = Registry.int(p["Maximum Bandwidth Allocated"])
        return port
    }

    // MARK: Screens

    /// One timing a screen offers: the picture, the full raster with its blanking, and how often it repeats.
    private struct Timing {
        var width: Int
        var height: Int
        var totalWidth: Int
        var totalHeight: Int
        var refresh: Double

        /// Pixels a second on the wire, blanking included.
        var pixelClock: Double { Double(totalWidth) * Double(totalHeight) * refresh }
    }

    /// Every timing of each external screen, by the framebuffer's registry ID. The list is half a megabyte of
    /// properties per screen and never changes while the screen stays plugged in, so it is read once.
    private var timings: [UInt64: [Int: Timing]] = [:]

    /// The signal each screen is really being sent, from the framebuffer that drives it: its timing list and which
    /// entry is in use. The public display services are asked too, for the size the picture is drawn at, which on
    /// a scaled screen is larger than what goes down the cable.
    private func readScreens(into stats: inout USBStats) {
        struct Signal {
            var productID: Int
            var maker: String
            var current: Timing?
            var topRefresh: Double?
            var topClock: Double?
        }
        var signals: [Signal] = []
        var seen = Set<UInt64>()
        for cls in ["IOMobileFramebufferShim", "AppleCLCD2"] {
            for entry in Registry.entries(cls) {
                defer { IOObjectRelease(entry) }
                guard let width = Registry.int(Registry.property(entry, "DisplayWidth")), width > 0, let height = Registry.int(Registry.property(entry, "DisplayHeight")),
                      let attributes = Registry.property(entry, "DisplayAttributes") as? [String: Any],
                      let product = attributes["ProductAttributes"] as? [String: Any], let productID = Registry.int(product["ProductID"]) else { continue }
                let id = Registry.id(entry)
                seen.insert(id)
                if timings[id] == nil { timings[id] = Self.timings(Registry.property(entry, "TimingElements") as? [[String: Any]] ?? []) }
                var signal = Signal(productID: productID, maker: (product["ManufacturerID"] as? String) ?? "")
                let table = timings[id] ?? [:]
                signal.current = Registry.int(Registry.property(entry, "DPTimingModeId")).flatMap { table[$0] }
                    ?? Timing(width: width, height: height, totalWidth: 0, totalHeight: 0, refresh: 0)
                // The fastest the screen offers at the size it is showing.
                if let best = table.values.filter({ $0.width == width && $0.height == height }).max(by: { $0.refresh < $1.refresh }) {
                    signal.topRefresh = best.refresh
                    signal.topClock = best.pixelClock
                }
                signals.append(signal)
            }
            if !signals.isEmpty { break }
        }
        timings = timings.filter { seen.contains($0.key) }

        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetOnlineDisplayList(16, &displays, &count) != .success { count = 0 }
        var taken = Set<CGDirectDisplayID>()

        for portIndex in stats.ports.indices {
            // A tunnelled screen's own transport reads "No Link"; the dock's display adapters hold the link instead.
            let uid = stats.ports[portIndex].thunderbolt?.uid
            let adapters = stats.routers.first { $0.uid == uid && !$0.isHost }?.ports.filter { $0.kind == .display && $0.displayRateCode != nil } ?? []
            for screenIndex in stats.ports[portIndex].displays.indices {
                var screen = stats.ports[portIndex].displays[screenIndex]
                if screen.laneGigabits == nil, adapters.count == stats.ports[portIndex].displays.filter(\.active).count, screenIndex < adapters.count,
                   let code = adapters[screenIndex].displayRateCode, let rate = Self.displayPortRate(code) {
                    screen.laneGigabits = rate.gigabits
                    screen.rateName = rate.name
                    screen.rateFromAdapter = true
                }
                if let at = signals.firstIndex(where: { $0.productID == screen.productID && $0.maker == screen.maker }) {
                    let signal = signals.remove(at: at)
                    if let timing = signal.current {
                        screen.signalWidth = timing.width
                        screen.signalHeight = timing.height
                        if timing.refresh > 0 {
                            screen.refresh = timing.refresh
                            screen.pixelClock = timing.pixelClock
                        }
                    }
                    screen.topRefresh = signal.topRefresh
                    screen.topPixelClock = signal.topClock
                }
                if let id = displays.prefix(Int(count)).first(where: { display in
                    !taken.contains(display) && CGDisplayIsBuiltin(display) == 0
                        && Int(CGDisplayModelNumber(display)) == screen.productID && Self.makerCode(CGDisplayVendorNumber(display)) == screen.maker
                }), let mode = CGDisplayCopyDisplayMode(id) {
                    taken.insert(id)
                    screen.drawnWidth = mode.pixelWidth
                    screen.drawnHeight = mode.pixelHeight
                    if screen.refresh == nil, mode.refreshRate > 0 { screen.refresh = mode.refreshRate }
                }
                stats.ports[portIndex].displays[screenIndex] = screen
            }
        }
    }

    /// The framebuffer lists each timing with its active and total size and its rates as 16.16 fixed-point numbers.
    private static func timings(_ elements: [[String: Any]]) -> [Int: Timing] {
        var out: [Int: Timing] = [:]
        for element in elements {
            guard let id = Registry.int(element["ID"]), let horizontal = element["HorizontalAttributes"] as? [String: Any], let vertical = element["VerticalAttributes"] as? [String: Any],
                  let width = Registry.int(horizontal["Active"]), let height = Registry.int(vertical["Active"]) else { continue }
            let precise = Registry.int(vertical["PreciseSyncRate"]) ?? 0, nominal = Registry.int(vertical["SyncRate"]) ?? 0
            out[id] = Timing(
                width: width, height: height,
                totalWidth: Registry.int(horizontal["Total"]) ?? width, totalHeight: Registry.int(vertical["Total"]) ?? height,
                refresh: Double(precise > 0 ? precise : nominal) / 65536
            )
        }
        return out
    }

    /// What DisplayPort calls each lane rate.
    static func displayPortRateName(_ gigabits: Double) -> String? {
        switch gigabits {
        case 1.62: return "RBR"
        case 2.7: return "HBR"
        case 5.4: return "HBR2"
        case 8.1: return "HBR3"
        case 10: return "UHBR10"
        case 13.5: return "UHBR13.5"
        case 20: return "UHBR20"
        default: return nil
        }
    }

    /// The link rate codes a Thunderbolt display adapter keeps in its register: 0 is the original 1.62 Gb/s a lane.
    static func displayPortRate(_ code: Int) -> (name: String, gigabits: Double)? {
        switch code {
        case 0: return ("RBR", 1.62)
        case 1: return ("HBR", 2.7)
        case 2: return ("HBR2", 5.4)
        case 3: return ("HBR3", 8.1)
        default: return nil
        }
    }

    /// The three letters a screen's maker is registered under, packed five bits each.
    static func makerCode(_ vendor: UInt32) -> String {
        let letters = [vendor >> 10 & 31, vendor >> 5 & 31, vendor & 31].map { Character(UnicodeScalar(UInt8(64 + min($0, 26)))) }
        return String(letters)
    }

    // MARK: Charger

    /// On a Mac that charges through a port, the battery's own entry holds what the adapter offers (its voltage
    /// menu, with the one in force) and what is measured arriving.
    static func readCharger() -> ChargerInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return charger(from: Registry.properties(service))
    }

    static func charger(from properties: [String: Any]) -> ChargerInfo? {
        guard let adapter = properties["AdapterDetails"] as? [String: Any], !adapter.isEmpty,
              (properties["ExternalConnected"] as? Bool) ?? true else { return nil }
        var charger = ChargerInfo()
        charger.name = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        charger.manufacturer = adapter["Manufacturer"] as? String
        charger.watts = Registry.int(adapter["Watts"])
        charger.millivolts = Registry.int(adapter["AdapterVoltage"])
        charger.milliamps = Registry.int(adapter["Current"])
        charger.wireless = (adapter["IsWireless"] as? Bool) ?? false
        let chosen = Registry.int(adapter["UsbHvcHvcIndex"])
        for (position, item) in ((adapter["UsbHvcMenu"] as? [[String: Any]]) ?? []).enumerated() {
            guard let volts = Registry.int(item["MaxVoltage"]), let amps = Registry.int(item["MaxCurrent"]), volts > 0 else { continue }
            let index = Registry.int(item["Index"]) ?? position
            charger.options.append(PowerOption(id: index, millivolts: volts, milliamps: amps, active: index == chosen))
        }
        if let telemetry = properties["PowerTelemetryData"] as? [String: Any] {
            charger.inputWatts = Registry.int(telemetry["SystemPowerIn"]).map { Double($0) / 1000 }
            charger.inputMillivolts = Registry.int(telemetry["SystemVoltageIn"])
            charger.inputMilliamps = Registry.int(telemetry["SystemCurrentIn"])
        }
        guard charger.watts != nil || !charger.options.isEmpty || charger.millivolts != nil else { return nil }
        return charger
    }
}

private extension USBPort.Kind {
    var order: Int {
        switch self {
        case .usbC: return 0
        case .magSafe: return 1
        case .usbA: return 2
        case .hdmi: return 3
        case .sdCard: return 4
        case .other: return 5
        }
    }
}

/// The few registry calls the reader needs, with their memory handling in one place.
enum Registry {
    /// Every entry of a class or of one that inherits from it. The caller releases each.
    static func entries(_ className: String) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_registry_entry_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 { out.append(entry) }
        return out
    }

    /// Direct children in the service plane. The caller releases each.
    static func children(_ entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_registry_entry_t] = []
        while case let child = IOIteratorNext(iterator), child != 0 { out.append(child) }
        return out
    }

    /// The caller releases it.
    static func parent(_ entry: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        return IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS && parent != 0 ? parent : nil
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dictionary
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func name(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    static func className(_ entry: io_registry_entry_t) -> String {
        (IOObjectCopyClass(entry)?.takeRetainedValue() as String?) ?? ""
    }

    static func id(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func path(_ entry: io_registry_entry_t) -> String? {
        IORegistryEntryCopyPath(entry, kIOServicePlane)?.takeRetainedValue() as String?
    }

    /// For identifiers that use all 64 bits, which would not fit a signed number.
    static func unsigned(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    /// A number, whether the registry holds it as one or as little-endian bytes.
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data, !data.isEmpty, data.count <= 8 {
            return data.reversed().reduce(0) { $0 << 8 | Int($1) }
        }
        return nil
    }

    /// A 32-bit object stored as four little-endian bytes.
    static func word(_ data: Data) -> UInt32 {
        data.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
