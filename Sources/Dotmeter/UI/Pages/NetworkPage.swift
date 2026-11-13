import SwiftUI

/// Shared scales and colors for everything that draws traffic.
enum NetScale {
    static let down = PX.cyan
    static let up = PX.pink

    /// The next 1-2-5 step above a rate with a little headroom, and never under 100 KB/s, so a quiet
    /// connection reads as quiet instead of filling the chart with noise.
    static func ceiling(_ bytesPerSecond: Double) -> Double {
        let value = max(bytesPerSecond * 1.1, 100e3)
        let magnitude = pow(10, floor(log10(value)))
        let leading = value / magnitude
        return (leading <= 1 ? 1 : (leading <= 2 ? 2 : (leading <= 5 ? 5 : 10))) * magnitude
    }

    /// 0...1 on a logarithmic scale from 1 KB/s to 100 MB/s, for indicators that only need "how busy".
    static func level(_ bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 500 else { return 0 }
        return min(max(log10(bytesPerSecond / 1e3) / 5, 0.04), 1)
    }

    static func signalColor(_ quality: Double) -> RGB {
        quality >= 0.62 ? PX.greenRGB : (quality >= 0.45 ? PX.yellow : (quality >= 0.3 ? PX.orange : PX.red))
    }
}

struct NetworkPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppRouter.self) private var router
    @Environment(QuitModel.self) private var control
    @State private var meters = AreaMeters()
    @State private var expanded: String?
    @State private var openInterface: String?

    var body: some View {
        PageScaffold(title: "Network", subtitle: subtitle, section: .network) { gridWidth, columns in
            if let s = monitor.snapshot {
                PagePair(columns: columns) {
                    MeterCard(model: meters.network(s, history: monitor.history, control: control, askClaude: askClaude), selected: expanded) { id in
                        expanded = expanded == id ? nil : id
                    }
                } second: {
                    ConnectionPanel(network: s.network, modelName: s.system.modelName)
                }
                PagePair(columns: columns) {
                    ThroughputPanel(history: monitor.history, snapshot: s)
                } second: {
                    if let wifi = s.network.wifi {
                        WiFiPanel(wifi: wifi, history: monitor.history, snapshot: s)
                    } else {
                        LinkPanel(network: s.network)
                    }
                }
                PagePair(columns: columns) {
                    LatencyPanel(network: s.network)
                } second: {
                    SpeedTestPanel()
                }
                InterfacesPanel(network: s.network, width: gridWidth, open: $openInterface)
                NetworkAppsPanel(network: s.network, apps: s.apps, width: gridWidth, expanded: $expanded)
                OpenPortsPanel(network: s.network, width: gridWidth)
            } else {
                LoadingCard(width: gridWidth)
            }
        }
    }

    private var subtitle: String {
        guard let n = monitor.snapshot?.network else { return "Reading sensors" }
        let active = n.interfaces.filter(\.isActive).count
        let state = n.primaryInterface.map { "Online through \($0.title)" } ?? "Offline"
        return "\(state) · \(active) of \(n.interfaces.count) interfaces in use · \(Format.data(n.inBytes)) received and \(Format.data(n.outBytes)) sent \(n.countingLabel)"
    }

    private func askClaude() {
        guard let snapshot = monitor.snapshot else { return }
        if !analysis.isStreaming { analysis.analyze(snapshot: snapshot, history: monitor.history) }
        router.section = .claude
    }
}

// MARK: - Connection

/// Where this Mac sits: the route out drawn as three stops with traffic between them, then the addresses.
struct ConnectionPanel: View {
    var network: NetworkStats
    var modelName: String

    var body: some View {
        let primary = network.primaryInterface
        let tunnel = network.interfaces.first { $0.kind == .tunnel && $0.isActive }
        PXPanel(title: "Connection", caption: primary.map { "through \($0.title)" } ?? "offline", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                RouteStrip(network: network, modelName: modelName)
                    .padding(.top, 17)
                    .padding(.horizontal, PX.inset - 6)
                Spacer(minLength: 8)
                PXDivider()
                VStack(spacing: 0) {
                    PXCopyRow(label: "Address", value: primary?.ipv4.first ?? "None", detail: addressDetail(primary), copy: primary?.ipv4.first)
                    ExternalAddressRow(network: network)
                    PXStatRow(label: "Router", value: network.router ?? "None", detail: primary.map { "reached over \($0.name)" })
                    PXStatRow(label: "DNS", value: network.dns.isEmpty ? "None" : network.dns.prefix(2).joined(separator: ", "), detail: dnsDetail)
                    PXStatRow(label: "IPv6", value: primary?.ipv6.first ?? (primary?.linkLocal6 != nil ? "Link-local only" : "None"), detail: primary?.ipv6.first == nil ? "no routable address" : nil)
                    PXStatRow(label: "Hardware address", value: primary?.mac ?? (primary?.kind == .wifi ? "Kept private by macOS" : "—"), detail: primary.map { "of \($0.title), MTU \($0.mtu)" })
                    PXStatRow(label: "Tunnel", value: tunnel.map { "\($0.name) · \($0.address ?? "up")" } ?? "None", detail: tunnel == nil ? "no VPN or private relay interface" : "a VPN or relay is up")
                }
                .padding(.horizontal, PX.inset)
                .padding(.vertical, 7)
            }
        }
        .frame(height: 342.75)
    }

    private func addressDetail(_ primary: NetworkInterface?) -> String? {
        guard let primary, primary.ipv4.first != nil else { return "no IPv4 address" }
        var parts: [String] = []
        switch network.configMethod {
        case "DHCP": parts.append("assigned by the router")
        case "Manual": parts.append("set by hand")
        case let method?: parts.append(method)
        case nil: break
        }
        if let mask = primary.netmask { parts.append("mask \(mask)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var dnsDetail: String? {
        if network.dns.count > 2 { return "and \(network.dns.count - 2) more" }
        return network.searchDomains.first.map { "search \($0)" }
    }
}

/// This Mac, the router and the internet, joined by two strips of cells: upload runs left to right on top,
/// download right to left underneath, each lit as far as it is busy.
struct RouteStrip: View {
    var network: NetworkStats
    var modelName: String

    var body: some View {
        let primary = network.primaryInterface
        let online = network.online
        HStack(alignment: .top, spacing: 0) {
            RouteNode(symbol: macSymbol, title: "This Mac", detail: primary?.address ?? "no address", rgb: primary?.address != nil ? PX.blue : PX.gray)
            RouteLink(up: online ? network.outBytesPerSecond : 0, down: online ? network.inBytesPerSecond : 0, label: "↑ " + Format.rate(network.outBytesPerSecond), rgb: NetScale.up, live: online)
            RouteNode(symbol: primary?.kind == .wifi ? "wifi.router.fill" : "rectangle.connected.to.line.below", title: "Router", detail: network.router ?? "none", rgb: network.router != nil ? PX.greenRGB : PX.gray)
            RouteLink(up: online ? network.outBytesPerSecond : 0, down: online ? network.inBytesPerSecond : 0, label: "↓ " + Format.rate(network.inBytesPerSecond), rgb: NetScale.down, live: online)
            RouteNode(symbol: "globe", title: "Internet", detail: online ? "route is up" : "no route", rgb: online ? PX.cyan : PX.gray)
        }
    }

    private var macSymbol: String {
        if modelName.contains("MacBook") { return "laptopcomputer" }
        if modelName.contains("Studio") { return "macstudio.fill" }
        if modelName.contains("mini") { return "macmini.fill" }
        if modelName.contains("Pro") { return "macpro.gen3.fill" }
        return "desktopcomputer"
    }
}

private struct RouteNode: View {
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
                .padding(.top, 7)
            Text(detail)
                .font(PX.mono(10))
                .foregroundStyle(PX.tertiary)
                .lineLimit(1)
                .padding(.top, 2.5)
        }
        .frame(width: 106)
    }
}

private struct RouteLink: View {
    var up: Double
    var down: Double
    var label: String
    var rgb: RGB
    var live: Bool

    private static let rows = 5

    private struct Spec: Hashable {
        var cols: Int
        var upLit: Int
        var downLit: Int
        var live: Bool
    }

    private func spec(_ size: CGSize) -> Spec {
        let cols = max(1, Int((size.width / PX.pitch).rounded(.down)))
        func lit(_ rate: Double) -> Int {
            let level = NetScale.level(rate)
            return level > 0 ? max(1, Int((level * Double(cols)).rounded())) : 0
        }
        return Spec(cols: cols, upLit: lit(up), downLit: lit(down), live: live)
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        let cols = spec.cols
        let gx = (size.width - CGFloat(cols) * p) / 2
        let side = p - 1.15
        var dim: [CGRect] = [], upCells: [CGRect] = [], downCells: [CGRect] = [], heads: [CGRect] = []
        for c in 0..<cols {
            let cx = gx + (CGFloat(c) + 0.5) * p
            for r in 0..<rows where r != 2 {
                let cy = (CGFloat(r) + 0.5) * p
                let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                if r < 2, c < spec.upLit {
                    if c == spec.upLit - 1 { heads.append(rect) } else { upCells.append(rect) }
                } else if r > 2, c >= cols - spec.downLit {
                    if c == cols - spec.downLit { heads.append(rect) } else { downCells.append(rect) }
                } else {
                    dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                }
            }
        }
        pen.fill(dim, .white, spec.live ? 0.13 : 0.07)
        pen.fill(upCells, NetScale.up, 0.85)
        pen.fill(downCells, NetScale.down, 0.85)
        pen.fill(heads, .white, 0.92)
    }

    var body: some View {
        VStack(spacing: 0) {
            BitmapPicture(spec: spec, draw: Self.draw)
                .frame(height: CGFloat(Self.rows) * PX.pitch)
                .padding(.top, (38 - CGFloat(Self.rows) * PX.pitch) / 2)
            Text(label)
                .font(PX.font(10.5))
                .monospacedDigit()
                .foregroundStyle(live ? rgb.color(0.9) : PX.tertiary)
                .lineLimit(1)
                .padding(.top, 17)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -14)
    }
}

// MARK: - Throughput

/// Five minutes of download and upload on one track, mirrored about a seam.
struct ThroughputPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot
    /// The dashboard has less to say under the chart than the Network area does.
    var compact = false

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let down = recent.map(\.networkIn), up = recent.map(\.networkOut)
        let downTop = NetScale.ceiling(down.max() ?? 0), upTop = NetScale.ceiling(up.max() ?? 0)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let n = snapshot.network
        return PXPanel(title: "Throughput", caption: "last five minutes, each direction on its own scale", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Download", now: Format.rate(n.inBytesPerSecond), average: Format.rate(avg(down)), peak: Format.rate(down.max() ?? 0), swatch: NetScale.down)
                    .padding(.top, 14)
                DuplexMatrixChart(
                    upper: recent.map { .init(time: $0.time, value: $0.networkIn / downTop) },
                    lower: recent.map { .init(time: $0.time, value: $0.networkOut / upTop) },
                    upperRGB: NetScale.down, lowerRGB: NetScale.up,
                    upperRows: compact ? 32 : 20, lowerRows: compact ? 18 : 12
                )
                .padding(.top, 8)
                ChartHeader(name: "Upload", now: Format.rate(n.outBytesPerSecond), average: Format.rate(avg(up)), peak: Format.rate(up.max() ?? 0), swatch: NetScale.up)
                    .padding(.top, 8)
                HStack {
                    Text("5 min ago · top of chart \(Format.rate(downTop)) down, \(Format.rate(upTop)) up")
                    Spacer()
                    Text("now")
                }
                .font(PX.font(10.5))
                .monospacedDigit()
                .foregroundStyle(PX.tertiary)
                .padding(.top, 8)
                Spacer(minLength: 8)
                if !compact {
                    PXDivider().padding(.horizontal, -PX.inset)
                    VStack(spacing: 0) {
                        PXStatRow(label: "Received", value: Format.data(n.inBytes), detail: n.countingLabel)
                        PXStatRow(label: "Sent", value: Format.data(n.outBytes), detail: "tunnels are not counted twice")
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

// MARK: - Wi-Fi and wired links

struct WiFiPanel: View {
    var wifi: WiFiInfo
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let rates = recent.compactMap(\.wifiRate)
        let signals = recent.compactMap(\.wifiRSSI)
        let top = max(rates.max() ?? 0, wifi.transmitRate, 1)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func mbps(_ v: Double) -> String { Format.linkSpeed(v * 1e6) }
        func dbm(_ v: Double) -> String { "\(Int(v.rounded())) dBm" }
        func quality(_ rssi: Double) -> Double { min(max((rssi + 95) / 60, 0), 1) }
        let hasSignal = wifi.rssi != nil
        return PXPanel(title: "Wi-Fi", caption: wifi.ssid ?? "macOS keeps the network name from apps without Location access", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Link rate", now: mbps(wifi.transmitRate), average: mbps(avg(rates)), peak: mbps(rates.max() ?? wifi.transmitRate), swatch: PX.greenRGB)
                    .padding(.top, 14)
                MatrixChart(samples: recent.compactMap { p in p.wifiRate.map { .init(time: p.time, value: $0 / top) } }, rgb: PX.greenRGB, rows: hasSignal ? 11 : 26)
                    .padding(.top, 8)
                if hasSignal, let rssi = wifi.rssi {
                    ChartHeader(name: "Signal", now: dbm(Double(rssi)), average: signals.isEmpty ? "—" : dbm(avg(signals)), peak: signals.max().map(dbm) ?? "—", swatch: NetScale.signalColor(wifi.quality ?? 0))
                        .padding(.top, 13)
                    MatrixChart(samples: recent.compactMap { p in p.wifiRSSI.map { .init(time: p.time, value: quality($0)) } }, rgb: PX.greenRGB, rows: 8, tone: { NetScale.signalColor($0) })
                        .padding(.top, 8)
                }
                ChartAxis(span: "5 min ago")
                    .padding(.top, 7)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Channel", value: ([String(wifi.channel), wifi.band] + [wifi.width].compactMap { $0 }).joined(separator: " · "), detail: wifi.country.map { "regulatory domain \($0)" })
                    PXStatRow(label: "Standard", value: wifi.standard, detail: wifi.security)
                    if let rssi = wifi.rssi {
                        PXStatRow(label: "Signal", value: "\(rssi) dBm", detail: "\((wifi.qualityTitle ?? "").lowercased()), \(wifi.snr ?? 0) dB above the noise at \(wifi.noise) dBm")
                    } else {
                        PXStatRow(label: "Signal", value: "Not reported", detail: "macOS gives no strength reading here")
                        PXStatRow(label: "Noise floor", value: "\(wifi.noise) dBm", detail: "lower is quieter")
                    }
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

/// The physical link when it is a cable, or what is missing when there is no connection at all.
struct LinkPanel: View {
    var network: NetworkStats

    var body: some View {
        let primary = network.primaryInterface
        PXPanel(title: "Link", caption: primary?.title ?? "nothing is connected", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                if let primary {
                    let speed = primary.linkSpeed
                    let used = speed.map { min(1, (primary.inRate + primary.outRate) * 8 / max($0, 1)) } ?? 0
                    HStack(alignment: .firstTextBaseline, spacing: 6.5) {
                        Text(speed.map { Format.linkSpeed($0) } ?? "Unknown speed")
                            .font(PX.font(22.5, .medium))
                            .tracking(PX.tracking(22.5))
                            .foregroundStyle(PX.text)
                        Text(primary.fullDuplex.map { $0 ? "full duplex" : "half duplex" } ?? "negotiated link speed")
                            .font(PX.font(12.5))
                            .foregroundStyle(PX.secondary)
                    }
                    .padding(.top, 16)
                    MiniMatrixBar(fraction: max(used, 0.004), rgb: used >= 0.8 ? PX.orange : NetScale.down, rows: 6)
                        .padding(.top, 14)
                    HStack {
                        Text(speed == nil ? "the port does not report a speed" : "\(Self.share(used)) of the link in use")
                        Spacer()
                        if let speed { Text(Format.rate(speed / 8) + " at most") }
                    }
                    .font(PX.font(10.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.tertiary)
                    .padding(.top, 7)
                    Spacer(minLength: 8)
                    PXDivider().padding(.horizontal, -PX.inset)
                    VStack(spacing: 0) {
                        PXStatRow(label: "Port", value: "\(primary.title) (\(primary.name))", detail: primary.kind == .tunnel ? "a tunnel, not a physical port" : nil)
                        PXStatRow(label: "MTU", value: "\(primary.mtu) bytes", detail: "largest packet sent whole")
                        PXStatRow(label: "Hardware address", value: primary.mac ?? "—")
                        PXStatRow(label: "Packets", value: "\(Format.count(primary.inPackets)) in", detail: "\(Format.count(primary.outPackets)) out")
                        PXStatRow(label: "Errors", value: primary.inErrors + primary.outErrors == 0 ? "None" : "\(Format.count(primary.inErrors)) in, \(Format.count(primary.outErrors)) out", detail: "damaged or dropped at the port")
                    }
                    .padding(.vertical, 7)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        MeterIconView(icon: .symbol("wifi.slash"), rgb: PX.orange, size: 20)
                        Text("No port has a cable with a link or a Wi-Fi network joined.")
                            .font(PX.font(12.5))
                            .foregroundStyle(PX.label)
                        Text("Every port this Mac has is listed under Interfaces below.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                    }
                    .padding(.top, 22)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private static func share(_ fraction: Double) -> String {
        fraction < 0.01 ? "Under 1%" : Format.percent(fraction)
    }
}

// MARK: - Interfaces

/// Every port and tunnel. The ones carrying something get a row that opens; the idle ones are listed as chips.
struct InterfacesPanel: View {
    var network: NetworkStats
    var width: CGFloat
    @Binding var open: String?

    var body: some View {
        let active = network.interfaces.filter(\.isActive)
        let idle = network.interfaces.filter { !$0.isActive }
        let wide = width > 700
        let top = max(active.map { $0.inRate + $0.outRate }.max() ?? 0, 1)
        PXPanel(title: "Interfaces", caption: "\(active.count) in use, \(idle.count) idle · click one for its details", width: width) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Interface").frame(maxWidth: .infinity, alignment: .leading)
                    // One card wide there is no room for the address; it is in the row's details.
                    if wide { Text("Address").frame(width: 138, alignment: .leading) }
                    Text("Link").frame(width: 78, alignment: .trailing)
                    if wide { Color.clear.frame(width: 212) }
                    Text("Down").frame(width: 88, alignment: .trailing)
                    Text("Up").frame(width: 88, alignment: .trailing)
                    if wide {
                        Text("Received").frame(width: 84, alignment: .trailing)
                        Text("Sent").frame(width: 84, alignment: .trailing)
                    }
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
                    if active.isEmpty {
                        Text("Nothing is connected.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                    }
                    ForEach(active) { item in
                        row(item, wide: wide, top: top)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, idle.isEmpty ? 8 : 4)
                if !idle.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        Text("Idle")
                            .font(PX.font(10.5, .medium))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(PX.tertiary)
                            .frame(height: 22)
                            .padding(.trailing, 4)
                        ForEach(idle) { item in
                            HStack(spacing: 5) {
                                Image(systemName: item.kind.symbol)
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(PX.tertiary)
                                Text(item.title)
                                    .font(PX.font(11))
                                    .foregroundStyle(PX.secondary)
                                Text(item.name)
                                    .font(PX.mono(9.5))
                                    .foregroundStyle(PX.tertiary)
                            }
                            .padding(.horizontal, 7.5)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.045)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PX.inset)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: open)
    }

    private func row(_ item: NetworkInterface, wide: Bool, top: Double) -> some View {
        let isOpen = open == item.id
        let isPrimary = item.name == network.primary
        let rate = item.inRate + item.outRate
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    MeterIconView(icon: .symbol(item.kind.symbol), rgb: isPrimary ? PX.greenRGB : PX.cyan, size: 13)
                    Text(item.title)
                        .font(PX.font(12, .medium))
                        .foregroundStyle(PX.label)
                        .lineLimit(1)
                    Text(item.name)
                        .font(PX.mono(10))
                        .foregroundStyle(PX.tertiary)
                    if isPrimary {
                        Text("default route")
                            .font(PX.font(10))
                            .foregroundStyle(PX.greenRGB.color(0.95))
                            .padding(.horizontal, 5.5)
                            .frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(PX.greenRGB.color(0.14)))
                            .fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(PX.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    Text(item.address ?? "—")
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 138, alignment: .leading)
                }
                Text(item.linkSpeed.map { Format.linkSpeed($0) } ?? "—")
                    .foregroundStyle(PX.secondary)
                    .frame(width: 78, alignment: .trailing)
                if wide {
                    MiniMatrixBar(fraction: rate > 500 ? max(rate / top, 0.02) : 0, rgb: NetScale.down)
                        .frame(width: 190)
                        .padding(.leading, 16)
                        .padding(.trailing, 6)
                }
                Text(Format.rate(item.inRate))
                    .foregroundStyle(PX.label)
                    .frame(width: 88, alignment: .trailing)
                Text(Format.rate(item.outRate))
                    .foregroundStyle(PX.label)
                    .frame(width: 88, alignment: .trailing)
                if wide {
                    Text(Format.data(item.inBytes)).foregroundStyle(PX.secondary).frame(width: 84, alignment: .trailing)
                    Text(Format.data(item.outBytes)).foregroundStyle(PX.secondary).frame(width: 84, alignment: .trailing)
                }
            }
            .font(PX.font(12))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(isOpen ? PX.rowHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { open = isOpen ? nil : item.id }

            if isOpen {
                let facts = Self.facts(for: item)
                let perRow = wide ? 3 : 2
                let lines = stride(from: 0, to: facts.count, by: perRow).map { Array(facts[$0..<min($0 + perRow, facts.count)]) }
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 18) {
                            ForEach(line, id: \.0) { fact in
                                HStack(spacing: 7) {
                                    Text(fact.0).foregroundStyle(PX.tertiary)
                                    Text(fact.1)
                                        .foregroundStyle(PX.soft)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if line.count < perRow {
                                ForEach(0..<(perRow - line.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                        .font(PX.font(11.5))
                        .monospacedDigit()
                        .frame(height: 22)
                    }
                }
                .padding(.leading, 31)
                .padding(.trailing, 10)
                .padding(.top, 2)
                .padding(.bottom, 7)
                .transition(.opacity)
            }
        }
    }

    private static func facts(for item: NetworkInterface) -> [(String, String)] {
        var facts: [(String, String)] = []
        for address in item.ipv4 { facts.append(("IPv4", address + (item.netmask.map { "  mask \($0)" } ?? ""))) }
        for address in item.ipv6.prefix(2) { facts.append(("IPv6", address)) }
        if let local = item.linkLocal6 { facts.append(("Link-local", local)) }
        if let mac = item.mac { facts.append(("Hardware address", mac)) }
        facts.append(("MTU", "\(item.mtu) bytes"))
        if let duplex = item.fullDuplex { facts.append(("Duplex", duplex ? "full" : "half")) }
        facts.append(("Packets", "\(Format.count(item.inPackets)) in, \(Format.count(item.outPackets)) out"))
        facts.append(("Errors", item.inErrors + item.outErrors == 0 ? "none" : "\(Format.count(item.inErrors)) in, \(Format.count(item.outErrors)) out"))
        facts.append(("Since \(App.name) started", "\(Format.data(item.inBytes)) in, \(Format.data(item.outBytes)) out"))
        return facts
    }
}

/// Lays children out left to right and wraps onto further lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}

// MARK: - Apps

/// Every app with an open connection, busiest first, with its processes one click away.
struct NetworkAppsPanel: View {
    var network: NetworkStats
    /// The same apps as the processor sees them, so one can be quit from here.
    var apps: [AppUsage] = []
    var width: CGFloat
    @Binding var expanded: String?

    var body: some View {
        let listed = Array(network.apps.prefix(18))
        let top = max(listed.first?.rate ?? 0, 1)
        let wide = width > 700
        PXPanel(title: "Apps using the network", caption: network.appsMeasured ? "\(network.apps.count) with open connections · click one to see its processes" : nil, width: width) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("App").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Down").frame(width: 92, alignment: .trailing)
                    Text("Up").frame(width: 92, alignment: .trailing)
                    Text("Carried").frame(width: 86, alignment: .trailing)
                    if wide { Text("Processes").frame(width: 78, alignment: .trailing) }
                }
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .padding(.horizontal, PX.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                PXDivider()
                QuitNoticeLine()
                if network.appsMeasured {
                    VStack(spacing: 1) {
                        ForEach(listed) { app in
                            row(app, fraction: app.rate / top)
                        }
                        if listed.isEmpty {
                            Text("Nothing has a connection open.")
                                .font(PX.font(12))
                                .foregroundStyle(PX.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    HStack(spacing: 8.5) {
                        if network.appsAvailable {
                            PXSpinner(size: 13)
                            Text("Working out which apps are using the network")
                        } else {
                            MeterIconView(icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.orange, size: 13)
                            Text("Per-app traffic is not available: macOS's nettop tool did not answer.")
                        }
                        Spacer()
                    }
                    .font(PX.font(12))
                    .foregroundStyle(PX.secondary)
                    .padding(.horizontal, PX.inset)
                    .frame(height: 56)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    private func row(_ app: NetworkAppUsage, fraction: Double) -> some View {
        let isOpen = expanded == app.id
        let wide = width > 700
        let barWidth: CGFloat = wide ? 300 : 58
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(nsImage: IconCache.icon(forBundlePath: app.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text(app.name)
                    .font(PX.font(12, .medium))
                    .foregroundStyle(PX.label)
                    .lineLimit(1)
                    .padding(.leading, 9)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(PX.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .padding(.leading, 6)
                Spacer(minLength: 12)
                MiniMatrixBar(fraction: app.rate > 500 ? max(fraction, 0.02) : 0, rgb: app.inRate >= app.outRate ? NetScale.down : NetScale.up)
                    .frame(width: barWidth)
                    .padding(.trailing, 6)
                Text(Format.rate(app.inRate))
                    .foregroundStyle(app.inRate >= 1e3 ? PX.label : PX.tertiary)
                    .frame(width: 92, alignment: .trailing)
                Text(Format.rate(app.outRate))
                    .foregroundStyle(app.outRate >= 1e3 ? PX.label : PX.tertiary)
                    .frame(width: 92, alignment: .trailing)
                Text(Format.data(app.bytes))
                    .foregroundStyle(PX.secondary)
                    .frame(width: 86, alignment: .trailing)
                if wide {
                    Text("\(app.processes.count)")
                        .foregroundStyle(PX.tertiary)
                        .frame(width: 78, alignment: .trailing)
                }
            }
            .font(PX.font(12))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(isOpen ? PX.rowHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { expanded = isOpen ? nil : app.id }

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(app.processes.prefix(8)) { process in
                        HStack(spacing: 0) {
                            Text(process.name)
                                .font(PX.mono(10.5))
                                .foregroundStyle(PX.secondary)
                                .lineLimit(1)
                            Text(verbatim: "pid \(process.pid)")
                                .font(PX.mono(10))
                                .foregroundStyle(PX.tertiary)
                                .padding(.leading, 8)
                            Spacer(minLength: 8)
                            Text(Format.rate(process.inRate)).frame(width: 92, alignment: .trailing)
                            Text(Format.rate(process.outRate)).frame(width: 92, alignment: .trailing)
                            Text(Format.data(process.inBytes &+ process.outBytes)).frame(width: 86, alignment: .trailing)
                            if wide { Color.clear.frame(width: 78) }
                        }
                        .font(PX.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.secondary)
                        .frame(height: 22)
                    }
                    Text(app.processes.count > 8 ? "and \(app.processes.count - 8) more · carried is what its open connections have moved so far" : "Carried is what its open connections have moved so far: \(Format.data(app.inBytes)) in, \(Format.data(app.outBytes)) out.")
                        .font(PX.font(11))
                        .foregroundStyle(PX.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 20)
                    if let target = apps.first(where: { $0.id == app.id }) {
                        AppActionRow(app: target).padding(.top, 2)
                    }
                }
                .padding(.leading, 35)
                .padding(.trailing, 10)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }
}
