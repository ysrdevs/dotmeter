import SwiftUI

// MARK: - Thunderbolt

/// The link lane by lane, and what each end and the cable would allow.
struct USBThunderboltPanel: View {
    var link: ThunderboltLink

    var body: some View {
        PXPanel(title: "Thunderbolt link", caption: link.familyName, width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                if let lane = link.lane {
                    let each = ThunderboltLane.perLane(lane.speedCode) ?? 0
                    VStack(spacing: 9) {
                        ForEach(0..<2, id: \.self) { index in
                            let inUse = index < lane.lanes
                            HStack(spacing: 10) {
                                Text("Lane \(index + 1)")
                                    .font(PX.font(12))
                                    .foregroundStyle(inUse ? PX.label : PX.tertiary)
                                    .frame(width: 52, alignment: .leading)
                                // Forty gigabits a lane is the most any generation runs.
                                MiniMatrixBar(fraction: inUse ? each / 40e9 : 0, rgb: USBLook.live, rows: 3)
                                Text(inUse ? Format.linkSpeed(each) : "not in use")
                                    .font(PX.font(12))
                                    .monospacedDigit()
                                    .foregroundStyle(inUse ? PX.label : PX.tertiary)
                                    .frame(width: 76, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    PXDivider()
                    VStack(spacing: 0) {
                        PXStatRow(label: "Generation", value: lane.generationName, detail: lane.widthName)
                        PXStatRow(label: "This Mac's port", value: link.hostSpeeds.map(ThunderboltLane.newestFamily) ?? "Not stated", detail: link.hostSpeeds.map(ThunderboltLane.speeds))
                        PXStatRow(label: link.deviceName ?? "The device", value: link.deviceSpeeds.map(ThunderboltLane.newestFamily) ?? "Not stated", detail: link.deviceSpeeds.map(ThunderboltLane.speeds))
                        PXStatRow(label: "Cable", value: link.cableBitsPerSecond.map(Format.linkSpeed) ?? "Not rated", detail: "as the Mac's controller rates it")
                        PXStatRow(label: "Uneven lanes", value: link.asymmetricSupported ? "Supported" : "Not supported", detail: "three one way, one back")
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.vertical, 7)
                } else {
                    Text("The link is up, but the Mac's router does not report its lanes.")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .padding(.horizontal, PX.inset)
                        .padding(.top, 14)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 262)
    }
}

/// What is riding the link, and the chain of routers it runs through.
struct USBTunnelsPanel: View {
    var stats: USBStats
    var port: USBPort
    var link: ThunderboltLink

    private struct Hop: Identifiable {
        var id: String
        var depth: Int
        var name: String
        var detail: String
    }

    var body: some View {
        PXPanel(title: "Riding the link", caption: "tunnels and the chain of routers", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(tunnels, id: \.0) { tunnel in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(tunnel.3.color(tunnel.2 ? 1 : 0.3))
                                .frame(width: 7, height: 7)
                            Text(tunnel.0)
                                .font(PX.font(12))
                                .foregroundStyle(tunnel.2 ? PX.label : PX.tertiary)
                            Spacer(minLength: 8)
                            Text(tunnel.1)
                                .font(PX.font(12))
                                .foregroundStyle(PX.secondary)
                                .lineLimit(1)
                        }
                        .frame(height: 27)
                    }
                }
                .padding(.horizontal, PX.inset)
                .padding(.top, 9)
                .padding(.bottom, 6)
                PXDivider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hops) { hop in
                        HStack(spacing: 8) {
                            Image(systemName: hop.depth == 0 ? "macstudio.fill" : "arrow.turn.down.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(hop.depth == 0 ? PX.blue.color() : PX.tertiary)
                                .frame(width: 13)
                                .padding(.leading, CGFloat(max(0, hop.depth - 1)) * 16)
                            Text(hop.name)
                                .font(PX.font(12, hop.depth == 0 ? .regular : .medium))
                                .foregroundStyle(PX.label)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(hop.detail)
                                .font(PX.font(11.5))
                                .foregroundStyle(PX.secondary)
                                .lineLimit(1)
                        }
                        .frame(height: 25)
                    }
                }
                .padding(.horizontal, PX.inset)
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 262)
    }

    /// Name, what it is carrying, whether it is set up, colour.
    private var tunnels: [(String, String, Bool, RGB)] {
        let screens = port.displays.filter(\.active).count
        func on(_ name: String) -> Bool { link.tunnelsProvisioned.contains(name) }
        return [
            ("USB 3", on("USB3") ? (port.usb3?.bitsPerSecond.map { "a \(Format.linkSpeed($0)) hub" } ?? "set up") : (link.tunnelsSupported.contains("USB3") ? "not in use" : "not offered"), on("USB3"), PX.blue),
            ("DisplayPort", screens > 0 ? "\(screens) \(screens == 1 ? "screen" : "screens")" : (on("DisplayPort") ? "set up, no screen" : "not in use"), screens > 0 || on("DisplayPort"), PX.purple),
            ("PCIe", on("PCIe") ? "set up, for storage and other cards" : "not in use", on("PCIe"), PX.orange),
        ]
    }

    /// The Mac's router for this port, then everything plugged in below it, each under what it is plugged into.
    private var hops: [Hop] {
        guard let device = stats.routers.first(where: { $0.uid == link.uid && !$0.isHost }) else { return [] }
        var top = device
        var guardCount = 0
        while let parent = stats.routers.first(where: { $0.uid == top.parentUID }), !parent.isHost, guardCount < 8 {
            top = parent
            guardCount += 1
        }
        var out = [Hop(id: "mac", depth: 0, name: "This Mac", detail: stats.title(port))]
        func walk(_ router: ThunderboltRouter, _ depth: Int) {
            let family = router.linkPorts.first?.supportedSpeeds.map(ThunderboltLane.newestFamily)
            let riding = router.tunnels.map(\.kind.title)
            let carried = Dictionary(grouping: riding, by: { $0 }).map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }.sorted()
            out.append(Hop(id: router.uid, depth: depth, name: router.name, detail: carried.isEmpty ? (family ?? "") : carried.joined(separator: ", ")))
            for child in stats.routers where child.parentUID == router.uid && !child.isHost { walk(child, depth + 1) }
        }
        walk(top, 1)
        return out
    }
}

// MARK: - Screens

/// Each screen with the picture it is really being sent, the link carrying it, and how much of the link that takes.
struct USBDisplaysPanel: View {
    var port: USBPort
    var width: CGFloat
    var columns: Int

    var body: some View {
        let screens = port.displays.filter(\.active)
        PXPanel(title: "Screens", caption: "the signal on the wire, not the scaled size", width: width) {
            let perRow = columns >= 2 && screens.count > 1 ? 2 : 1
            let rows = stride(from: 0, to: screens.count, by: perRow).map { Array(screens[$0..<min($0 + perRow, screens.count)]) }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 30) {
                        ForEach(rows[index]) { screen in
                            USBScreenBlock(screen: screen).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if rows[index].count < perRow { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                    }
                }
            }
            .padding(.horizontal, PX.inset)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
    }
}

private struct USBScreenBlock: View {
    var screen: DisplayLink

    var body: some View {
        let needs = screen.pixelClock.map(DisplayLink.bits)
        let compressed = needs.flatMap { n in screen.payload.map { n > $0 } } ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "display")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PX.purple.color())
                Text(screen.name ?? "Screen")
                    .font(PX.font(13, .medium))
                    .foregroundStyle(PX.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(screen.signalText ?? "mode not reported")
                    .font(PX.font(12.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.soft)
            }
            if let payload = screen.payload, let needs {
                MiniMatrixBar(fraction: min(1, needs / payload), rgb: compressed ? USBLook.caution : PX.purple, rows: 3)
                    .padding(.top, 11)
                HStack(spacing: 0) {
                    Text(compressed ? "needs \(Format.linkSpeed(needs)) uncompressed, so it is sent compressed" : "uses \(Format.linkSpeed(needs)) of the link's \(Format.linkSpeed(payload))")
                    Spacer(minLength: 8)
                    Text("\(Int((min(needs / payload, 9.99) * 100).rounded()))%")
                }
                .font(PX.font(11.5))
                .monospacedDigit()
                .foregroundStyle(PX.secondary)
                .padding(.top, 6)
            }
            VStack(spacing: 0) {
                PXStatRow(label: "Link", value: screen.linkText ?? "Not reported", detail: screen.rateFromAdapter ? "from the dock's adapter" : nil)
                PXStatRow(label: "Top refresh here", value: screen.topRefresh.map(Format.hertz) ?? "Not reported", detail: screen.topRefresh.flatMap { top in screen.refresh.map { top > $0 + 1.5 ? "running below it" : "running at it" } })
                PXStatRow(label: "Path", value: path, detail: screen.tunneled ? "through the Thunderbolt tunnel" : nil)
                if let drawn = screen.drawnWidth, let height = screen.drawnHeight, drawn != screen.signalWidth {
                    PXStatRow(label: "Drawn at", value: "\(drawn) × \(height)", detail: "then scaled to the signal")
                }
            }
            .padding(.top, 8)
        }
    }

    private var path: String {
        var parts: [String] = []
        if let branch = screen.branch { parts.append("via \(branch)") }
        if let output = screen.output { parts.append("\(output == "DP" ? "DisplayPort" : output) to the screen") }
        return parts.isEmpty ? "Direct" : parts.joined(separator: ", ")
    }
}

// MARK: - Devices

/// Each device inside the thing it is plugged into. Hubs are plumbing and about half of any list, so they are
/// left out unless asked for; a device behind hidden hubs says how many.
struct USBDevicesPanel: View {
    var port: USBPort
    var width: CGFloat
    @Binding var hubsShown: Bool

    private struct Row: Identifiable {
        var id: String
        var device: USBDevice?
        var heading: String?
        var depth: Int
        var hiddenHubs: Int
    }

    var body: some View {
        let hubs = port.allDevices.filter(\.isHub).count
        let devices = port.allDevices.count - hubs
        PXPanel(title: "Devices", caption: "\(devices) \(devices == 1 ? "device" : "devices")" + (hubs > 0 && !hubsShown ? ", \(hubs) \(hubs == 1 ? "hub" : "hubs") hidden" : ""), width: width, trailing: {
            if hubs > 0 {
                PXButton(title: hubsShown ? "Hide hubs" : "Show \(hubs) \(hubs == 1 ? "hub" : "hubs")", symbol: "arrow.triangle.branch", style: .ghost, height: 24) { hubsShown.toggle() }
            }
        }) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Device").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Kind").frame(width: 150, alignment: .leading)
                    Text("Speed").frame(width: 190, alignment: .trailing)
                    Text("Power").frame(width: 80, alignment: .trailing)
                }
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .padding(.horizontal, PX.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                PXDivider()
                VStack(spacing: 1) {
                    ForEach(rows) { row in
                        if let heading = row.heading {
                            Text(heading)
                                .font(PX.font(11, .medium))
                                .foregroundStyle(PX.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                        } else if let device = row.device {
                            deviceRow(device, row)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func deviceRow(_ device: USBDevice, _ row: Row) -> some View {
        HStack(spacing: 0) {
            Image(systemName: USBLook.symbol(role: device.role))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(device.isHub ? PX.tertiary : USBLook.live.color(0.9))
                .frame(width: 18)
                .padding(.leading, CGFloat(row.depth) * 18)
            Text(label(device))
                .font(PX.font(12, device.isHub ? .regular : .medium))
                .foregroundStyle(device.isHub ? PX.secondary : PX.label)
                .lineLimit(1)
                .padding(.leading, 7)
            if row.hiddenHubs > 0 {
                Text("via \(row.hiddenHubs) \(row.hiddenHubs == 1 ? "hub" : "hubs")")
                    .font(PX.font(11))
                    .foregroundStyle(PX.tertiary)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 10)
            Text(device.role + (device.tunneled && !device.isHub ? " · tunnelled" : ""))
                .font(PX.font(12))
                .foregroundStyle(PX.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            MiniMatrixBar(fraction: speedFraction(device.bitsPerSecond), rgb: device.isHub ? PX.gray : USBLook.live)
                .frame(width: 96)
                .padding(.trailing, 8)
            Text(Format.linkSpeed(device.bitsPerSecond))
                .font(PX.font(12))
                .monospacedDigit()
                .foregroundStyle(PX.label)
                .frame(width: 86, alignment: .trailing)
            Text(device.milliamps.map { "\($0) mA" } ?? "—")
                .font(PX.font(12))
                .monospacedDigit()
                .foregroundStyle(device.milliamps == nil ? PX.tertiary : PX.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .help("\(device.name) · \(device.versionText) · \(String(format: "%04X:%04X", device.vendorID, device.productID))")
    }

    /// The maker's name is added where the product name alone would not tell two devices apart, or says nothing.
    private func label(_ device: USBDevice) -> String {
        let generic = ["usb storage", "usb audio", "usb receiver", "usb2.0 hub", "usb3.0 hub", "usb3.1 hub", "usb hub", "usb device"].contains(device.name.lowercased())
        let twins = port.allDevices.filter { $0.name == device.name }.count > 1
        guard generic || twins, let vendor = device.vendorName, !vendor.isEmpty, vendor.lowercased() != "generic", !device.name.lowercased().contains(vendor.lowercased()) else { return device.name }
        return "\(device.name), \(vendor.trimmingCharacters(in: CharacterSet(charactersIn: ".,")))"
    }

    /// 12 Mb/s to 10 Gb/s on a log scale, so a keyboard still shows a cell or two.
    private func speedFraction(_ bitsPerSecond: Double) -> Double {
        guard bitsPerSecond > 0 else { return 0 }
        return min(1, max(0.05, log10(bitsPerSecond / 1.5e6) / log10(20e9 / 1.5e6)))
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ device: USBDevice, depth: Int, hidden: Int) {
            if device.isHub, !hubsShown {
                device.children.forEach { walk($0, depth: depth, hidden: hidden + 1) }
                return
            }
            out.append(Row(id: device.id, device: device, depth: depth, hiddenHubs: hubsShown ? 0 : hidden))
            device.children.forEach { walk($0, depth: depth + 1, hidden: 0) }
        }
        for root in port.devices {
            // A dock shows up twice, once on each set of wires: say which is which.
            if port.devices.count > 1 {
                out.append(Row(id: "heading:" + root.id, heading: root.isSuperSpeed ? "USB 3 side" + (root.tunneled ? ", through the Thunderbolt tunnel" : "") : "USB 2 side, on its own wires in the cable", depth: 0, hiddenHubs: 0))
            }
            walk(root, depth: 0, hidden: 0)
        }
        return out
    }
}

// MARK: - Power

/// A charger's offers with the one in force, or on a port that feeds devices, what they have asked for.
struct USBPowerPanel: View {
    var stats: USBStats
    var port: USBPort
    var history: [HistoryPoint]

    static let height: CGFloat = 318

    var body: some View {
        if let source = port.powerSource {
            USBChargerCard(name: source.name ?? stats.charger?.name, options: source.options, millivolts: source.millivolts, milliamps: source.milliamps, live: stats.charger, history: history, width: PX.cardWidth)
                .frame(height: Self.height)
        } else {
            supply
        }
    }

    private var supply: some View {
        let drawing = port.allDevices.compactMap { device in device.milliamps.map { (device, $0) } }.sorted { $0.1 > $1.1 }
        // What the port itself gives is asked of it by whatever is plugged straight in; devices behind a hub draw from the hub.
        let direct = port.devices.compactMap(\.milliamps).reduce(0, +)
        let limit = port.supplyMilliamps ?? 0
        return PXPanel(title: "Power to devices", caption: limit > 0 ? "this port gives up to \(Format.amps(limit)) over USB" : "what each device has asked for", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                if limit > 0 {
                    MiniMatrixBar(fraction: Double(direct) / Double(limit), rgb: PX.yellow, rows: 3)
                        .padding(.top, 15)
                        .padding(.horizontal, PX.inset)
                    HStack {
                        Text(direct > 0 ? "\(direct) mA asked of the port directly" : "nothing plugged straight in has asked for power")
                        Spacer(minLength: 8)
                        Text("of \(limit) mA")
                    }
                    .font(PX.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, PX.inset)
                    .padding(.bottom, 10)
                    PXDivider()
                }
                VStack(spacing: 0) {
                    if drawing.isEmpty {
                        Text("No device on this port reports a power request. A dock or hub with its own supply feeds what is behind it.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }
                    ForEach(drawing.prefix(5), id: \.0.id) { item in
                        PXStatRow(label: item.0.name, value: "\(item.1) mA", detail: String(format: "%.1f W at 5 V", Double(item.1) * 5 / 1000))
                    }
                }
                .padding(.horizontal, PX.inset)
                .padding(.vertical, 7)
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.height)
    }
}

/// Every supply a charger offers, with the one in force lit, what is measured arriving, and the Mac's draw over
/// the last five minutes.
struct USBChargerCard: View {
    var name: String?
    var options: [PowerOption]
    var millivolts: Int?
    var milliamps: Int?
    var live: ChargerInfo?
    var history: [HistoryPoint]
    var width: CGFloat

    var body: some View {
        let offered = options.map(\.watts).max() ?? 0
        let ceiling = max(offered, history.compactMap(\.power).max() ?? 0, 10)
        PXPanel(title: "Charger", caption: name ?? "offers and the contract in force", width: width) {
            VStack(alignment: .leading, spacing: 0) {
                if !options.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(options) { option in
                            VStack(spacing: 3) {
                                Text(option.minMillivolts.map { "\(Format.volts($0)) to \(Format.volts(option.millivolts))" } ?? Format.volts(option.millivolts))
                                    .font(PX.font(13, .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(option.active ? PX.text : PX.soft)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(Format.amps(option.milliamps))
                                    .font(PX.font(11))
                                    .monospacedDigit()
                                    .foregroundStyle(PX.secondary)
                                Text("\(Int(option.watts.rounded())) W")
                                    .font(PX.font(11))
                                    .monospacedDigit()
                                    .foregroundStyle(option.active ? PX.yellow.color() : PX.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(option.active ? PX.yellow.color(0.13) : PX.trackFill))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(option.active ? PX.yellow.color(0.6) : Color.white.opacity(0.05), lineWidth: option.active ? 1 : 0.5))
                        }
                    }
                    .padding(.horizontal, PX.inset - 4)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    PXDivider()
                }
                VStack(spacing: 0) {
                    PXStatRow(label: "In force", value: contract, detail: options.isEmpty ? nil : "lit above")
                    PXStatRow(label: "Arriving now", value: live?.inputWatts.map { String(format: "%.1f W", $0) } ?? "Not measured", detail: arriving)
                    PXStatRow(label: "Charger to Mac", value: live?.pathMilliohms.map { "about \(Int($0.rounded())) mΩ" } ?? "Not enough current to tell", detail: "cable and plugs, from the voltage sag")
                }
                .padding(.horizontal, PX.inset)
                .padding(.top, 7)
                if history.contains(where: { $0.power != nil }) {
                    MatrixChart(samples: history.compactMap { point in point.power.map { MatrixChart.Sample(time: point.time, value: $0 / ceiling) } }, rgb: PX.yellow, rows: 9)
                        .padding(.horizontal, PX.inset)
                        .padding(.top, 8)
                    HStack {
                        Text("the Mac's draw, last five minutes")
                        Spacer(minLength: 8)
                        Text("top of chart \(Int(ceiling.rounded())) W")
                    }
                    .font(PX.font(10.5))
                    .foregroundStyle(PX.tertiary)
                    .padding(.horizontal, PX.inset)
                    .padding(.top, 5)
                }
                Spacer(minLength: 12)
            }
        }
    }

    private var contract: String {
        guard let millivolts, let milliamps else { return "None" }
        return "\(Format.volts(millivolts)) · up to \(Format.amps(milliamps)) · \(Int((Double(millivolts) * Double(milliamps) / 1e6).rounded())) W"
    }

    private var arriving: String? {
        guard let volts = live?.inputMillivolts, let amps = live?.inputMilliamps else { return nil }
        return String(format: "%.2f V at %.2f A", Double(volts) / 1000, Double(amps) / 1000)
    }
}

/// The error counts the port's controller keeps.
struct USBHealthPanel: View {
    var port: USBPort

    var body: some View {
        let health = port.health
        PXPanel(title: "Port counters", caption: "since the Mac started", width: PX.cardWidth) {
            VStack(spacing: 0) {
                PXStatRow(label: "Plugged in", value: port.plugEvents.map { "\($0) \($0 == 1 ? "time" : "times")" } ?? "Not counted", detail: port.orientation.map { "now with side \($0 == 1 ? "A" : "B") up" })
                PXStatRow(label: "Link errors", value: count(health?.linkErrors), detail: "USB 3 signal faults")
                PXStatRow(label: "Failed USB 3 links", value: count(health?.linkFailures), detail: "came up, then fell back")
                PXStatRow(label: "Devices that failed to start", value: count(health.map { $0.enumerationFailures + $0.addressFailures }), detail: nil)
                PXStatRow(label: "Over-current trips", value: count(max(health?.overcurrent ?? 0, port.overcurrentEvents ?? 0)), detail: "a device drew too much")
                PXStatRow(label: "Verdict", value: (health?.troubles ?? 0) == 0 ? "Clean" : "Errors logged", detail: (health?.troubles ?? 0) == 0 ? nil : "see what this port says")
            }
            .padding(.horizontal, PX.inset)
            .padding(.vertical, 9)
            Spacer(minLength: 0)
        }
        .frame(height: USBPowerPanel.height)
    }

    private func count(_ value: Int?) -> String {
        guard let value else { return "Not counted" }
        return value == 0 ? "None" : "\(value)"
    }
}

// MARK: - Followed cables

/// Cables the user chose to follow, each with its record over time.
struct USBSavedCablesPanel: View {
    var width: CGFloat
    @Environment(CableStore.self) private var store
    @State private var open: String?
    @State private var armed: String?

    var body: some View {
        PXPanel(title: "Followed cables", caption: store.cables.isEmpty ? "none yet" : "\(store.cables.count) followed", width: width) {
            VStack(alignment: .leading, spacing: 0) {
                if store.cables.isEmpty {
                    Text("Name a cable in its port's Cable card and \(App.name) keeps a record of it: when it was last used, what speed each connection came up at, and whether it has misbehaved. A cable is recognised by its marker, so two of the same make and model share one record, and a cable with no marker cannot be followed.")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, PX.inset)
                        .padding(.top, 12)
                        .padding(.bottom, 18)
                } else {
                    VStack(spacing: 1) {
                        ForEach(store.cables) { cable in
                            cableRow(cable)
                            if open == cable.id { timeline(cable) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func cableRow(_ cable: SavedCable) -> some View {
        let verdict = cable.verdict
        return HStack(spacing: 0) {
            Image(systemName: open == cable.id ? "chevron.down" : "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(PX.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(cable.name)
                        .font(PX.font(12.5, .medium))
                        .foregroundStyle(PX.label)
                        .lineLimit(1)
                    Text(marker(cable.marker))
                        .font(PX.font(11.5))
                        .foregroundStyle(PX.tertiary)
                        .lineLimit(1)
                }
                Text(cable.record + (cable.lastUsed.map { " Last seen \(Self.ago($0))." } ?? ""))
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            Spacer(minLength: 12)
            Text(verdict.title)
                .font(PX.font(11.5, .medium))
                .foregroundStyle(verdict.caution ? USBLook.caution.color() : PX.green)
                .lineLimit(1)
                .padding(.trailing, 12)
            PXConfirmButton(title: "Stop following", armedTitle: "Confirm", symbol: "xmark", armed: armed == cable.id) {
                if armed == cable.id {
                    store.remove(cable.id)
                    armed = nil
                } else {
                    armed = cable.id
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .contentShape(Rectangle())
        .onTapGesture {
            open = open == cable.id ? nil : cable.id
            armed = nil
        }
    }

    private func timeline(_ cable: SavedCable) -> some View {
        VStack(spacing: 0) {
            if cable.sessions.isEmpty {
                Text("Nothing recorded yet. It is noted each time the ports are read while it is plugged in.")
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
            }
            ForEach(cable.sessions.suffix(8).reversed()) { session in
                HStack(spacing: 0) {
                    Text(Self.day(session.start))
                        .frame(width: 150, alignment: .leading)
                    Text(session.port + (session.partner.map { " to \($0)" } ?? ""))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(session.verdict ?? "")
                        .foregroundStyle(session.trouble ? USBLook.caution.color(0.9) : PX.secondary)
                        .lineLimit(1)
                        .frame(width: 250, alignment: .leading)
                    Text(session.bitsPerSecond.map(Format.linkSpeed) ?? session.watts.map { "\(Int($0.rounded())) W" } ?? "—")
                        .foregroundStyle(PX.label)
                        .frame(width: 80, alignment: .trailing)
                    Text(Format.duration(max(60, session.end.timeIntervalSince(session.start))))
                        .frame(width: 80, alignment: .trailing)
                }
                .font(PX.font(11.5))
                .monospacedDigit()
                .foregroundStyle(PX.secondary)
                .frame(height: 24)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    private func marker(_ marker: CableMarker) -> String {
        var parts = [marker.speedText.components(separatedBy: ",").first ?? marker.speedText]
        if let amps = marker.amps { parts.append(String(format: "%g A", amps)) }
        parts.append(marker.active ? "active" : "passive")
        if let length = marker.lengthText { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    private static func ago(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 300 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }
}
