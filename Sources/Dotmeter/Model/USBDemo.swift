import Foundation

/// Made-up ports for captures and for what a desktop Mac cannot show: a charger's offers, a cable that limits
/// charging, a cable that limits data, a link that came up slow (DOTMETER_USB_DEMO=laptop, or =slow for the last).
/// Every maker and product here is invented. The cable markers are built as the real 32-bit objects and run
/// through the same decoders as a real cable's.
enum USBDemo {
    /// Identity words for a cable: header, certificate, product, cable object.
    static func cableWords(vendor: UInt32, product: UInt32, xid: UInt32, speed: UInt32, current: UInt32, latency: UInt32 = 1, extended: Bool = false, maxVoltage: UInt32 = 0) -> [UInt32] {
        let header: UInt32 = 3 << 27 | 1 << 26 | 3 << 21 | vendor
        let cable: UInt32 = 1 << 28 | 1 << 24 | 2 << 18 | (extended ? 1 << 17 : 0) | latency << 13 | maxVoltage << 9 | current << 5 | speed
        return [header, xid, product << 16 | 0x0100, cable]
    }

    static func marker(vendor: UInt32, product: UInt32, xid: UInt32, speed: UInt32, current: UInt32, latency: UInt32 = 1, extended: Bool = false, maxVoltage: UInt32 = 0) -> CableMarker? {
        PDIdentity(vdos: cableWords(vendor: vendor, product: product, xid: xid, speed: speed, current: current, latency: latency, extended: extended, maxVoltage: maxVoltage), revision: 3, cable: true).flatMap(CableMarker.init)
    }

    static func stats(_ name: String) -> USBStats {
        let slow = name.contains("slow")
        var stats = USBStats()

        // Port 1: a dock on a good cable, two screens and a tree of devices behind it.
        var dock = USBPort(id: "USB-C@1", kind: .usbC, number: 1)
        dock.connected = true
        dock.supported = ["CC", "USB2", "USB3", "CIO", "DisplayPort"]
        dock.provisioned = ["CC", "USB2", "CIO"]
        dock.active = ["CC", "USB2", "CIO"]
        dock.orientation = 1
        dock.plugEvents = 14
        dock.overcurrentEvents = 0
        dock.partner = PDIdentity(vdos: [1 << 30 | 1 << 27 | 1 << 26 | 1 << 23 | 2 << 21 | 0x1234, 0, 0x4410 << 16 | 0x0102], revision: 3, cable: false)
        dock.cable = marker(vendor: 0x1234, product: 0x0B70, xid: 5120, speed: 3, current: 2)
        dock.usb2 = USBTransport(active: true, tunneled: false, rateText: "480 Mbps (High Speed)", bitsPerSecond: 480e6, product: "Harbor Dock Hub", manufacturer: "Northline")
        dock.usb3 = USBTransport(active: true, tunneled: true, rateText: "10 Gbps", bitsPerSecond: 10e9, product: "Harbor Dock Hub", manufacturer: "Northline")
        var link = ThunderboltLink(uid: "1001", deviceName: "Harbor Dock 11", vendorName: "Northline")
        link.tunnelsSupported = ["USB3", "DisplayPort", "PCIe"]
        link.tunnelsProvisioned = ["USB3", "DisplayPort", "PCIe"]
        link.cableSpeedCode = 3
        link.lane = slow ? ThunderboltLane(speedCode: 8, widthCode: 1, reported: 10e9) : ThunderboltLane(speedCode: 4, widthCode: 2, reported: 40e9)
        link.hostSpeeds = 12
        link.deviceSpeeds = 12
        dock.thunderbolt = link
        dock.pcieTunnel = true
        // A 6K picture is more than four HBR3 lanes carry uncompressed, so this one arrives compressed.
        var studio = DisplayLink(id: "USB-C@1/CIO/DisplayPort@0", name: "Meridian 32 6K", maker: "MRD", productID: 1, active: true, tunneled: true, lanes: 4, maxLanes: 4)
        studio.rateName = "HBR3"; studio.laneGigabits = 8.1; studio.rateFromAdapter = true; studio.output = "DP"; studio.branch = "HARBR"
        studio.signalWidth = 6016; studio.signalHeight = 3384; studio.refresh = 60; studio.pixelClock = 6176 * 3466 * 60; studio.topRefresh = 60; studio.topPixelClock = studio.pixelClock
        studio.drawnWidth = 6016; studio.drawnHeight = 3384
        var side = DisplayLink(id: "USB-C@1/CIO/DisplayPort@1", name: "Meridian 27 QHD", maker: "MRD", productID: 2, active: true, tunneled: true, lanes: 4, maxLanes: 4)
        side.rateName = "HBR2"; side.laneGigabits = 5.4; side.rateFromAdapter = true; side.output = "HDMI"
        side.signalWidth = 2560; side.signalHeight = 1440; side.refresh = 60; side.pixelClock = 2720 * 1481 * 60; side.topRefresh = 144; side.topPixelClock = 2720 * 1490 * 144
        dock.displays = [studio, side]
        func device(_ id: String, _ name: String, _ vendor: String, speed: Double, version: Int, cls: Int = 0, interfaces: [Int] = [], milliamps: Int? = nil, port: Int, tunneled: Bool = false, children: [USBDevice] = []) -> USBDevice {
            var d = USBDevice(id: id, name: name, vendorName: vendor, vendorID: 0x1234, productID: 1, bitsPerSecond: speed, usbVersion: version, deviceClass: cls)
            d.interfaces = interfaces; d.milliamps = milliamps; d.hubPort = port; d.tunneled = tunneled; d.children = children
            return d
        }
        dock.devices = [
            device("a1", "Harbor Dock Hub", "Northline", speed: 10e9, version: 0x0320, cls: 9, port: 1, tunneled: true, children: [
                device("a2", "Kestrel X2 SSD", "Kestrel", speed: 10e9, version: 0x0320, interfaces: [8], milliamps: 896, port: 1, tunneled: true),
                device("a3", "Harbor Hub", "Northline", speed: 5e9, version: 0x0310, cls: 9, port: 3, tunneled: true, children: [
                    device("a4", "Card Reader", "Northline", speed: 5e9, version: 0x0300, interfaces: [8], milliamps: 400, port: 2, tunneled: true),
                    device("a5", "USB 10/100/1000 LAN", "Northline", speed: 5e9, version: 0x0300, interfaces: [255], milliamps: 288, port: 4, tunneled: true),
                ]),
            ]),
            device("b1", "Harbor Dock Hub", "Northline", speed: 480e6, version: 0x0210, cls: 9, port: 1, children: [
                device("b2", "Tactile Keyboard", "Ostrander", speed: 12e6, version: 0x0200, interfaces: [3], milliamps: 500, port: 1),
                device("b3", "Studio Webcam", "Ostrander", speed: 480e6, version: 0x0200, interfaces: [14, 1], milliamps: 500, port: 2),
                device("b4", "Harbor Hub", "Northline", speed: 480e6, version: 0x0210, cls: 9, port: 3, children: [
                    device("b5", "Wireless Receiver", "Ostrander", speed: 12e6, version: 0x0200, interfaces: [3], milliamps: 98, port: 1),
                    device("b6", "USB Audio", "Northline", speed: 480e6, version: 0x0200, interfaces: [1, 3], milliamps: 100, port: 2),
                ]),
            ]),
        ]
        dock.supplyMilliamps = 3000
        dock.health = PortHealth(linkErrors: 0, linkFailures: 0, enumerationFailures: 0, addressFailures: 0, overcurrent: 0, connects: 3)
        stats.ports.append(dock)

        // Port 2: a 96 W charger on a cable marked for 3 A, so the contract stops at 60 W.
        var charging = USBPort(id: "USB-C@2", kind: .usbC, number: 2)
        charging.connected = true
        charging.supported = dock.supported
        charging.provisioned = ["CC"]
        charging.active = ["CC"]
        charging.plugEvents = 31
        charging.partner = PDIdentity(vdos: [3 << 23 | 2 << 21 | 0x1235, 0, 0x7019 << 16 | 0x0100], revision: 3, cable: false)
        charging.cable = marker(vendor: 0x1236, product: 0x0102, xid: 0, speed: 0, current: 1, latency: 2)
        var source = PortPowerSource(name: "Northline 96W Charger")
        source.options = [
            PowerOption(id: 0, millivolts: 5000, milliamps: 3000), PowerOption(id: 1, millivolts: 9000, milliamps: 3000),
            PowerOption(id: 2, millivolts: 15000, milliamps: 3000), PowerOption(id: 3, millivolts: 20000, milliamps: 4800),
        ]
        source.options[3].active = true
        source.millivolts = 20000
        source.milliamps = 3000
        charging.powerSource = source
        charging.health = PortHealth(connects: 0)
        stats.ports.append(charging)

        // Port 3: a fast drive on a charging cable, with a marker that leaves its maker blank.
        var drive = USBPort(id: "USB-C@3", kind: .usbC, number: 3)
        drive.connected = true
        drive.supported = dock.supported
        drive.provisioned = ["CC", "USB2", "USB3"]
        drive.active = ["CC", "USB2"]
        drive.plugEvents = 6
        drive.cable = marker(vendor: 0, product: 0, xid: 0, speed: 0, current: 1, latency: 2)
        drive.usb2 = USBTransport(active: true, tunneled: false, rateText: "480 Mbps (High Speed)", bitsPerSecond: 480e6, product: "Kestrel X1 SSD", manufacturer: "Kestrel")
        drive.usb3 = USBTransport(active: false, tunneled: false)
        drive.devices = [device("c1", "Kestrel X1 SSD", "Kestrel", speed: 480e6, version: 0x0210, interfaces: [8], milliamps: 500, port: 1)]
        drive.supplyMilliamps = 3000
        drive.health = PortHealth(linkErrors: 2, linkFailures: 3, enumerationFailures: 0, addressFailures: 0, overcurrent: 0, connects: 6)
        stats.ports.append(drive)

        var magsafe = USBPort(id: "MagSafe@1", kind: .magSafe, number: 1)
        magsafe.supported = ["CC"]
        stats.ports.append(magsafe)
        var hdmi = USBPort(id: "HDMI@1", kind: .hdmi, number: 1)
        hdmi.connected = true
        hdmi.supported = ["DisplayPort"]
        hdmi.active = ["DisplayPort"]
        var tv = DisplayLink(id: "HDMI@1/DisplayPort", name: "Lumen 55 TV", maker: "LMN", productID: 3, active: true, tunneled: false, lanes: 4, maxLanes: 4)
        tv.rateName = "HBR3"; tv.laneGigabits = 8.1; tv.output = "HDMI"
        tv.signalWidth = 3840; tv.signalHeight = 2160; tv.refresh = 60; tv.pixelClock = 4400 * 2250 * 60; tv.topRefresh = 60; tv.topPixelClock = tv.pixelClock
        hdmi.displays = [tv]
        stats.ports.append(hdmi)
        stats.ports.append(USBPort(id: "SD Card@1", kind: .sdCard, number: 1))

        stats.routers = [
            ThunderboltRouter(uid: "1", name: "This Mac", vendor: "Apple Inc.", depth: 0, version: 0x20, socket: 1, ports: [
                ThunderboltPort(number: 1, kind: .link, lane: link.lane, isPrimaryLane: true, supportedSpeeds: 12),
                ThunderboltPort(number: 3, kind: .pcie, allocated: 200), ThunderboltPort(number: 4, kind: .usb, allocated: 200),
                ThunderboltPort(number: 5, kind: .display, allocated: 261), ThunderboltPort(number: 6, kind: .display, allocated: 161),
            ]),
            ThunderboltRouter(uid: "1001", name: "Harbor Dock 11", vendor: "Northline", depth: 1, version: 0x20, parentUID: "1", parentPort: 1, ports: [
                ThunderboltPort(number: 1, kind: .link, lane: link.lane, isPrimaryLane: true, supportedSpeeds: 12),
                ThunderboltPort(number: 9, kind: .pcie, allocated: 200), ThunderboltPort(number: 13, kind: .display, allocated: 1, displayRateCode: 3, displayLaneCode: 2),
                ThunderboltPort(number: 14, kind: .display, allocated: 1, displayRateCode: 2, displayLaneCode: 2), ThunderboltPort(number: 16, kind: .usb, allocated: 200),
            ]),
        ]

        var charger = ChargerInfo(name: "Northline 96W Charger", manufacturer: "Northline", watts: 60)
        charger.options = source.options
        charger.millivolts = 20000
        charger.milliamps = 3000
        charger.inputWatts = 52.4
        charger.inputMillivolts = 19620
        charger.inputMilliamps = 2670
        stats.charger = charger
        return stats
    }

    static func savedCables() -> [SavedCable] {
        guard let good = marker(vendor: 0x1234, product: 0x0B70, xid: 5120, speed: 3, current: 2),
              let weak = marker(vendor: 0, product: 0, xid: 0, speed: 0, current: 1, latency: 2) else { return [] }
        let now = Date()
        func session(_ daysAgo: Double, hours: Double, port: String, partner: String, speed: Double, family: String, verdict: String, trouble: Bool = false) -> CableSession {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            return CableSession(start: start, end: start.addingTimeInterval(hours * 3600), port: port, partner: partner, bitsPerSecond: speed, family: family, watts: nil, verdict: verdict, trouble: trouble)
        }
        return [
            SavedCable(id: CableStore.fingerprint(good), name: "Desk dock cable", added: now.addingTimeInterval(-41 * 86_400), marker: good, sessions: [
                session(40, hours: 9, port: "USB-C 1", partner: "Harbor Dock 11", speed: 40e9, family: "Thunderbolt 4 / USB4", verdict: "Running at full speed, 40 Gb/s"),
                session(21, hours: 11, port: "USB-C 1", partner: "Harbor Dock 11", speed: 40e9, family: "Thunderbolt 4 / USB4", verdict: "Running at full speed, 40 Gb/s"),
                session(9, hours: 8, port: "USB-C 3", partner: "Harbor Dock 11", speed: 40e9, family: "Thunderbolt 4 / USB4", verdict: "Running at full speed, 40 Gb/s"),
                session(0.2, hours: 4.5, port: "USB-C 1", partner: "Harbor Dock 11", speed: 40e9, family: "Thunderbolt 4 / USB4", verdict: "Running at full speed, 40 Gb/s"),
            ]),
            SavedCable(id: CableStore.fingerprint(weak), name: "White cable from the drawer", added: now.addingTimeInterval(-12 * 86_400), marker: weak, sessions: [
                session(12, hours: 0.4, port: "USB-C 3", partner: "Kestrel X1 SSD", speed: 480e6, family: "USB 2", verdict: "Cable is limiting data speed", trouble: true),
                session(5, hours: 1.2, port: "USB-C 2", partner: "Kestrel X1 SSD", speed: 480e6, family: "USB 2", verdict: "Cable is limiting data speed", trouble: true),
                session(0.1, hours: 2, port: "USB-C 3", partner: "Kestrel X1 SSD", speed: 480e6, family: "USB 2", verdict: "Cable is limiting data speed", trouble: true),
            ]),
        ]
    }
}
