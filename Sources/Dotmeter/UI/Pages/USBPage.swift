import SwiftUI

/// Colours the USB area uses for its three states.
enum USBLook {
    static let live = AppSection.usb.rgb
    static let caution = PX.orange
    static let idle = PX.gray

    static func rgb(_ tone: USBVerdict.Tone?) -> RGB { tone == .caution ? caution : live }

    static func symbol(_ kind: USBPort.Kind) -> String {
        switch kind {
        case .usbC: return "cable.connector.horizontal"
        case .usbA: return "cable.connector"
        case .hdmi: return "tv"
        case .sdCard: return "sdcard"
        case .magSafe: return "powerplug"
        case .other: return "rectangle.connected.to.line.below"
        }
    }

    static func symbol(role: String) -> String {
        switch role {
        case "Hub": return "arrow.triangle.branch"
        case "Storage", "Card reader": return "externaldrive"
        case "Camera": return "web.camera"
        case "Audio": return "hifispeaker"
        case "Network", "Network or serial": return "network"
        case "Keyboard": return "keyboard"
        case "Mouse": return "computermouse"
        case "Wireless receiver", "Wireless adapter": return "dot.radiowaves.left.and.right"
        case "Printer": return "printer"
        case "Input device": return "keyboard"
        default: return "cube"
        }
    }
}

/// Every port and what is on it: the cable, the link, the devices, the screens, and what limits each.
struct USBPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(CableStore.self) private var cables
    /// Debug: DOTMETER_USB_PORT=USB-C@3 opens on that port, DOTMETER_USB_HUBS=1 with hubs shown, and
    /// DOTMETER_USB_FOLLOW=<name> follows that port's cable once it has been read (into the test file only).
    @State private var selected: String? = ProcessInfo.processInfo.environment["DOTMETER_USB_PORT"]
    @State private var hubsShown = ProcessInfo.processInfo.environment["DOTMETER_USB_HUBS"] == "1"

    var body: some View {
        PageScaffold(title: "USB", subtitle: subtitle, section: .usb) { gridWidth, columns in
            if let snapshot = monitor.snapshot, let usb = snapshot.usb {
                let port = usb.ports.first { $0.id == selected } ?? usb.ports.first(where: \.connected) ?? usb.ports.first
                if usb.ports.isEmpty {
                    Text("This Mac does not publish its ports the way this page reads them. That takes Apple silicon and a recent macOS.")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                        .padding(PX.inset)
                        .frame(width: gridWidth, alignment: .leading)
                        .pxCard()
                } else {
                    USBPortsPanel(stats: usb, width: gridWidth, selected: port?.id) { selected = $0 }
                }
                if let port {
                    let diagnosis = USBDiagnostics.diagnose(port, charger: usb.charger)
                    if port.connected {
                        PagePair(columns: columns) {
                            USBConnectionPanel(stats: usb, port: port, diagnosis: diagnosis, modelName: snapshot.system.modelName)
                        } second: {
                            USBCablePanel(stats: usb, port: port)
                        }
                        if !diagnosis.all.isEmpty { USBFindingsPanel(diagnosis: diagnosis, width: gridWidth) }
                        if let link = port.thunderbolt {
                            PagePair(columns: columns) {
                                USBThunderboltPanel(link: link)
                            } second: {
                                USBTunnelsPanel(stats: usb, port: port, link: link)
                            }
                        }
                        if port.displays.contains(where: \.active) { USBDisplaysPanel(port: port, width: gridWidth, columns: columns) }
                        if !port.devices.isEmpty { USBDevicesPanel(port: port, width: gridWidth, hubsShown: $hubsShown) }
                        PagePair(columns: columns) {
                            USBPowerPanel(stats: usb, port: port, history: monitor.history)
                        } second: {
                            USBHealthPanel(port: port)
                        }
                    } else {
                        USBEmptyPortPanel(stats: usb, port: port, width: gridWidth)
                    }
                }
                // A charger that no port lays claim to still has its offers listed by the battery.
                if let charger = usb.charger, !usb.ports.contains(where: { $0.powerSource != nil }) {
                    USBChargerCard(name: charger.name, options: charger.options, millivolts: charger.millivolts, milliamps: charger.milliamps, live: charger, history: monitor.history, width: gridWidth)
                }
                USBSavedCablesPanel(width: gridWidth)
                    .onAppear {
                        guard let name = ProcessInfo.processInfo.environment["DOTMETER_USB_FOLLOW"], let marker = port?.cable, cables.saved(marker) == nil else { return }
                        cables.add(marker, name: name)
                        cables.record(usb)
                    }
            } else {
                HStack(spacing: 8) {
                    PXSpinner(size: 13)
                    Text("Reading the ports").font(PX.font(12)).foregroundStyle(PX.secondary)
                }
                .frame(width: gridWidth, height: 120)
                .pxCard()
            }
        }
    }

    private var subtitle: String {
        guard let usb = monitor.snapshot?.usb else { return "Reading the ports" }
        let screens = usb.ports.reduce(0) { $0 + $1.displays.filter(\.active).count }
        var parts = ["\(usb.connectedPorts.count) of \(usb.ports.count) ports in use", "\(usb.deviceCount) \(usb.deviceCount == 1 ? "device" : "devices")"]
        if screens > 0 { parts.append("\(screens) \(screens == 1 ? "screen" : "screens")") }
        if let charger = usb.charger, let watts = charger.watts { parts.append("charging at \(watts) W") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Ports

/// One tile per port. The selected one is what the rest of the page is about.
struct USBPortsPanel: View {
    var stats: USBStats
    var width: CGFloat
    var selected: String?
    var select: (String) -> Void

    var body: some View {
        // Ten tiles at most, laid out by hand: a lazy grid builds its cells late, which is no use for so few.
        let perRow = max(1, Int((width - 2 * (PX.inset - 6) + 10) / 270))
        let rows = stride(from: 0, to: stats.ports.count, by: perRow).map { Array(stats.ports[$0..<min($0 + perRow, stats.ports.count)]) }
        PXPanel(title: "Ports", caption: "choose one to see its cable, link and devices", width: width) {
            VStack(spacing: 10) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        ForEach(rows[index]) { port in
                            USBPortTile(stats: stats, port: port, selected: port.id == selected) { select(port.id) }
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(0..<(perRow - rows[index].count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, PX.inset - 6)
            .padding(.top, 13)
            .padding(.bottom, 16)
        }
    }
}

private struct USBPortTile: View {
    var stats: USBStats
    var port: USBPort
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let diagnosis = USBDiagnostics.diagnose(port, charger: stats.charger)
        let caution = diagnosis.all.contains { $0.tone == .caution }
        let rgb = !port.connected ? USBLook.idle : (caution ? USBLook.caution : USBLook.live)
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(rgb.color(port.connected ? 0.15 : 0.07))
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(rgb.color(port.connected ? 0.24 : 0.10), lineWidth: 0.5)
                    Image(systemName: USBLook.symbol(port.kind))
                        .font(.system(size: 13.5, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(rgb.color(port.connected ? 1 : 0.6))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(stats.title(port))
                        .font(PX.font(12.5, .medium))
                        .foregroundStyle(port.connected ? PX.text : PX.secondary)
                    Text(detail)
                        .font(PX.font(11.5))
                        .foregroundStyle(port.connected ? PX.secondary : PX.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let figure {
                    VStack(alignment: .trailing, spacing: 2.5) {
                        Text(figure)
                            .font(PX.font(12, .medium))
                            .monospacedDigit()
                            .foregroundStyle(rgb.color())
                        if caution {
                            Text("needs a look").font(PX.font(10.5)).foregroundStyle(USBLook.caution.color(0.85))
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? rgb.color(0.10) : (hovering ? PX.rowHover : PX.trackFill)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? rgb.color(0.55) : Color.white.opacity(0.05), lineWidth: selected ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PXPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var detail: String { port.attachedName }
    private var figure: String? { port.headlineFigure }
}

struct USBEmptyPortPanel: View {
    var stats: USBStats
    var port: USBPort
    var width: CGFloat

    var body: some View {
        PXPanel(title: stats.title(port), caption: "nothing connected", width: width) {
            VStack(alignment: .leading, spacing: 0) {
                Text(carries)
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.soft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                if let events = port.plugEvents, events > 0 {
                    Text("Something has been plugged in here \(events) \(events == 1 ? "time" : "times") since the Mac started.")
                        .font(PX.font(12))
                        .foregroundStyle(PX.secondary)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, PX.inset)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var carries: String {
        var names: [String] = []
        if port.supported.contains("CIO") { names.append("Thunderbolt and USB4") }
        if port.supported.contains("USB3") { names.append("USB 3") }
        if port.supported.contains("USB2") { names.append("USB 2") }
        if port.supported.contains("DisplayPort") || port.kind == .hdmi { names.append("screens") }
        if port.kind == .sdCard { return "The card slot is empty." }
        if port.kind == .magSafe { return "No charger is attached." }
        return names.isEmpty ? "This port is empty." : "This port can carry " + names.joined(separator: ", ") + "."
    }
}

// MARK: - Connection

/// The link as it stands: its speed, the chain from the Mac through the cable to what is at the far end, and what
/// each of the three could do, with whatever is holding the speed where it is marked.
struct USBConnectionPanel: View {
    var stats: USBStats
    var port: USBPort
    var diagnosis: PortDiagnosis
    var modelName: String

    var body: some View {
        let tone = diagnosis.speed?.tone
        let rgb = USBLook.rgb(tone)
        let ceiling = max(diagnosis.parts.compactMap(\.bitsPerSecond).max() ?? 0, diagnosis.negotiated ?? 0)
        PXPanel(title: "Connection", caption: stats.title(port) + (port.activeNames.isEmpty ? "" : " · " + port.activeNames.joined(separator: ", ")), width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6.5) {
                    Text(diagnosis.negotiated.map(Format.linkSpeed) ?? headlineFallback)
                        .font(PX.font(22.5, .medium))
                        .tracking(PX.tracking(22.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.text)
                    Text(diagnosis.negotiatedName ?? "")
                        .font(PX.font(12.5))
                        .foregroundStyle(PX.secondary)
                }
                .padding(.top, 13)
                .padding(.horizontal, PX.inset)
                Text(underline)
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
                    .padding(.top, 5)
                    .padding(.horizontal, PX.inset)

                HStack(alignment: .top, spacing: 0) {
                    USBNode(symbol: macSymbol, title: "This Mac", detail: stats.title(port), rgb: PX.blue)
                    VStack(spacing: 0) {
                        MiniMatrixBar(fraction: fraction(diagnosis.negotiated, of: ceiling), rgb: rgb, rows: 4)
                            .padding(.top, (38 - 4 * PX.pitch) / 2)
                        Text(cableLabel)
                            .font(PX.font(10.5))
                            .foregroundStyle(port.cable == nil ? PX.tertiary : rgb.color(0.9))
                            .lineLimit(1)
                            .padding(.top, 17)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, -8)
                    USBNode(symbol: farSymbol, title: farTitle, detail: farDetail, rgb: rgb)
                }
                .padding(.top, 15)
                .padding(.horizontal, PX.inset - 6)

                Spacer(minLength: 8)
                PXDivider()
                VStack(spacing: 0) {
                    if diagnosis.parts.isEmpty {
                        Text(port.powerSource != nil ? "This port is charging the Mac; no data is running over it." : "Nothing on this port is exchanging data.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 38)
                    }
                    ForEach(diagnosis.parts) { part in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.name)
                                    .font(PX.font(12))
                                    .foregroundStyle(PX.label)
                                    .lineLimit(1)
                                Text(part.note ?? "")
                                    .font(PX.font(10.5))
                                    .foregroundStyle(PX.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 10)
                            if part.limiting {
                                Text("limit")
                                    .font(PX.font(10, .medium))
                                    .foregroundStyle(rgb.color())
                                    .padding(.horizontal, 5.5)
                                    .frame(height: 16)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(rgb.color(0.16)))
                                    .padding(.trailing, 8)
                            }
                            MiniMatrixBar(fraction: fraction(part.bitsPerSecond, of: ceiling), rgb: part.limiting ? rgb : PX.gray)
                                .frame(width: 96)
                                .padding(.trailing, 8)
                            Text(part.text)
                                .font(PX.font(12))
                                .monospacedDigit()
                                .foregroundStyle(part.bitsPerSecond == nil ? PX.tertiary : PX.label)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: 38)
                    }
                }
                .padding(.horizontal, PX.inset)
                .padding(.vertical, 6)
            }
        }
        .frame(height: 342.75)
    }

    private func fraction(_ value: Double?, of ceiling: Double) -> Double {
        guard let value, ceiling > 0 else { return 0 }
        // Speeds span four orders of magnitude; a log scale keeps 480 Mb/s visible beside 80 Gb/s.
        return min(1, max(0.06, log10(value / 1e6) / log10(ceiling / 1e6)))
    }

    private var headlineFallback: String {
        if let watts = port.powerSource?.watts { return "\(Int(watts.rounded())) W" }
        if let screen = port.displays.first(where: \.active)?.signalText { return screen }
        return "No data"
    }

    private var underline: String {
        if let lane = port.thunderbolt?.lane, let each = ThunderboltLane.perLane(lane.speedCode) {
            return "\(lane.widthName.capitalizedSentence) of \(Format.linkSpeed(each)), \(lane.generationName)"
        }
        if let device = port.devices.max(by: { $0.bitsPerSecond < $1.bitsPerSecond }) {
            return "\(device.name) · \(device.versionText)" + (port.usb3?.active == true ? " · SuperSpeed" : "")
        }
        if let source = port.powerSource, let volts = source.millivolts, let amps = source.milliamps { return "Charging contract: \(Format.volts(volts)) at up to \(Format.amps(amps))" }
        if port.displays.contains(where: \.active) { return "A screen, and nothing else" }
        return "Something is attached, but nothing is exchanging data"
    }

    private var cableLabel: String {
        if let cable = port.cable { return "\(cable.speedText.components(separatedBy: ",").first ?? cable.speedText) cable" + (cable.amps.map { String(format: " · %g A", $0) } ?? "") }
        return port.kind == .usbC ? "cable with no marker" : "cable"
    }

    private var farTitle: String {
        port.thunderbolt?.deviceName ?? port.devices.max(by: { $0.bitsPerSecond < $1.bitsPerSecond })?.name ?? port.powerSource?.name ?? port.displays.first(where: \.active)?.name ?? "Far end"
    }

    private var farDetail: String {
        let devices = port.allDevices.filter { !$0.isHub }.count
        if port.thunderbolt != nil { return devices > 0 ? "\(devices) \(devices == 1 ? "device" : "devices") behind it" : (port.partner?.kindTitle ?? "Thunderbolt") }
        if let device = port.devices.first { return devices > 1 ? "and \(devices - 1) more" : device.role }
        if port.powerSource != nil { return "charger" }
        return port.partner?.kindTitle ?? ""
    }

    private var farSymbol: String {
        if port.powerSource != nil, port.devices.isEmpty { return "powerplug" }
        if port.partner?.kind == .hub || port.allDevices.contains(where: \.isHub) { return "arrow.triangle.branch" }
        if let device = port.devices.first { return USBLook.symbol(role: device.role) }
        if port.displays.contains(where: \.active) { return "display" }
        return "externaldrive"
    }

    private var macSymbol: String {
        if modelName.contains("MacBook") { return "laptopcomputer" }
        if modelName.contains("Studio") { return "macstudio.fill" }
        if modelName.contains("mini") { return "macmini.fill" }
        return "desktopcomputer"
    }
}

struct USBNode: View {
    var symbol: String
    var title: String
    var detail: String
    var rgb: RGB

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(rgb.color(0.14))
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(rgb.color(0.22), lineWidth: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(rgb.color())
            }
            .frame(width: 38, height: 38)
            Text(title)
                .font(PX.font(11.5, .medium))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .padding(.top, 7)
            Text(detail)
                .font(PX.font(10.5))
                .foregroundStyle(PX.tertiary)
                .lineLimit(1)
                .padding(.top, 2.5)
        }
        .frame(width: 150)
    }
}

// MARK: - Cable

/// What the chip in the cable's plug says about the cable, and the control for following it over time.
struct USBCablePanel: View {
    var stats: USBStats
    var port: USBPort
    @Environment(CableStore.self) private var store
    @State private var name = ""
    @FocusState private var naming: Bool

    var body: some View {
        PXPanel(title: "Cable", caption: port.cable.map { $0.constructionText.lowercased() } ?? "no marker answered", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                if let cable = port.cable {
                    VStack(spacing: 0) {
                        PXStatRow(label: "Data", value: cable.speedText, detail: "marked \(cable.speedName)")
                        PXStatRow(label: "Power", value: power(cable), detail: cable.maxVolts.map { cable.watts == 240 ? "extended range, up to 48 V" : "up to \($0) V" })
                        PXStatRow(label: "Length", value: cable.lengthText ?? "Not stated", detail: "from the signal's travel time")
                        PXStatRow(label: "Ends", value: cable.plugText ?? "Not stated", detail: nil)
                        PXStatRow(label: "Marker chip", value: USBVendors.label(cable.identity.vendorID), detail: String(format: "product 0x%04X, hardware %d, firmware %d", cable.identity.productID, cable.hardwareVersion, cable.firmwareVersion))
                        PXStatRow(label: "Certificate", value: cable.identity.xid == 0 ? "None carried" : "\(cable.identity.xid)", detail: certificate(cable))
                        if let rated = port.thunderbolt?.cableBitsPerSecond {
                            PXStatRow(label: "Rated by the Mac", value: Format.linkSpeed(rated), detail: "its Thunderbolt controller's own test")
                        }
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.top, 9)
                    Spacer(minLength: 6)
                    PXDivider()
                    follow(cable)
                        .padding(.horizontal, PX.inset)
                        .frame(height: 62)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(port.kind == .usbC ? "No chip in this cable answered." : "\(port.kind.title) cables carry no marker.")
                            .font(PX.font(13, .medium))
                            .foregroundStyle(PX.label)
                        Text(port.kind == .usbC
                            ? "A marker is only required in cables that carry more than USB 2 speed or more than 3 A. A plain charging cable has none, nor does a cable fixed to its device or an adapter to USB-A. So nothing about this cable's own limits can be read."
                            : "The marker chip is part of USB-C. What a cable on this port can do can only be judged from how the connection came up.")
                            .font(PX.font(12.5))
                            .foregroundStyle(PX.secondary)
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                        if let rated = port.thunderbolt?.cableBitsPerSecond {
                            Text("The Mac's Thunderbolt controller tested it and rates it for \(Format.linkSpeed(rated)).")
                                .font(PX.font(12.5))
                                .foregroundStyle(PX.soft)
                        }
                        if port.activeCable == true || port.opticalCable == true {
                            Text("The port reports it as \(port.opticalCable == true ? "an optical" : "an active") cable.")
                                .font(PX.font(12.5))
                                .foregroundStyle(PX.soft)
                        }
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.top, 16)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 342.75)
    }

    private func power(_ cable: CableMarker) -> String {
        guard let amps = cable.amps, let watts = cable.watts else { return "Not stated" }
        return String(format: "%g A · up to %d W", amps, watts)
    }

    private func certificate(_ cable: CableMarker) -> String? {
        guard cable.identity.xid != 0 else { return "certification is voluntary" }
        if let holder = USBCertifications.holder(cable.identity.xid) { return "USB-IF certified, \(holder)" }
        return USBCertifications.isLoaded ? "certified but unlisted" : "USB-IF certificate number"
    }

    @ViewBuilder
    private func follow(_ cable: CableMarker) -> some View {
        if let saved = store.saved(cable) {
            let verdict = saved.verdict
            HStack(spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(USBLook.live.color())
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(saved.name)
                        .font(PX.font(12.5, .medium))
                        .foregroundStyle(PX.label)
                        .lineLimit(1)
                    Text(verdict.title + ". " + saved.record)
                        .font(PX.font(11.5))
                        .foregroundStyle(verdict.caution ? USBLook.caution.color(0.9) : PX.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                TextField("", text: $name, prompt: Text("Name this cable to follow it").foregroundStyle(PX.tertiary))
                    .textFieldStyle(.plain)
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.label)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PX.button))
                    .focused($naming)
                    .onSubmit { add(cable) }
                    // A window gives its first text field the keyboard when it opens; this one should wait to be clicked.
                    .onAppear { DispatchQueue.main.async { naming = false } }
                PXButton(title: "Follow", symbol: "bookmark", height: 28) { add(cable) }
            }
        }
    }

    private func add(_ cable: CableMarker) {
        store.add(cable, name: name)
        store.record(stats)
        name = ""
    }
}

// MARK: - Findings

/// Every finding about the port in plain words. Anything that needs a look sits on an orange card.
struct USBFindingsPanel: View {
    var diagnosis: PortDiagnosis
    var width: CGFloat

    var body: some View {
        let cautions = diagnosis.all.filter { $0.tone == .caution }
        PXPanel(title: "What this port says", caption: cautions.isEmpty ? "nothing needs attention" : "\(cautions.count) \(cautions.count == 1 ? "thing" : "things") to look at", width: width) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(diagnosis.all) { verdict in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            switch verdict.tone {
                            case .good: Image(systemName: "checkmark").foregroundStyle(PX.green)
                            case .plain: Image(systemName: "info").foregroundStyle(PX.secondary)
                            case .caution: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(USBLook.caution.color())
                            }
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 14)
                        VStack(alignment: .leading, spacing: 3.5) {
                            Text(verdict.title)
                                .font(PX.font(12.5, .medium))
                                .foregroundStyle(PX.label)
                            Text(verdict.detail)
                                .font(PX.font(12.5))
                                .foregroundStyle(PX.secondary)
                                .lineSpacing(2.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, verdict.tone == .caution ? 10 : 3)
                    .background {
                        if verdict.tone == .caution {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(USBLook.caution.color(0.09))
                            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(USBLook.caution.color(0.22), lineWidth: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, PX.inset - 12)
            .padding(.top, 11)
            .padding(.bottom, 16)
        }
    }
}

extension String {
    /// "two lanes" as "Two lanes".
    var capitalizedSentence: String { prefix(1).uppercased() + dropFirst() }
}
