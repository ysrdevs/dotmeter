import SwiftUI

/// Which apps are waiting for connections, split by who can reach them: other devices on the network, or only
/// this Mac. Read from the kernel's own table; nothing is probed.
struct OpenPortsPanel: View {
    var network: NetworkStats
    var width: CGFloat
    @State private var showAll = false

    private static let shown = 8

    var body: some View {
        let reachable = network.listeners.filter { !$0.exposed.isEmpty }
        let local = network.listeners.filter { $0.exposed.isEmpty }
        let reachablePorts = reachable.reduce(0) { $0 + $1.exposed.count }
        PXPanel(title: "Open ports", caption: caption(reachable: reachablePorts, apps: reachable.count), width: width) {
            if network.listenersMeasured {
                VStack(alignment: .leading, spacing: 0) {
                    group("Reachable from other devices", count: reachable.count, rgb: PX.orange, apps: reachable, exposed: true,
                          empty: "Nothing on this Mac is answering to the network.")
                    PXDivider()
                    group("This Mac only", count: local.count, rgb: PX.gray, apps: showAll ? local : Array(local.prefix(Self.shown)), exposed: false,
                          empty: "Nothing is listening for this Mac's own apps.")
                    if local.count > Self.shown {
                        PXButton(title: showAll ? "Show fewer" : "Show all \(local.count)", style: .ghost, height: 24) { showAll.toggle() }
                            .padding(.horizontal, PX.inset - 8)
                            .padding(.bottom, 10)
                    }
                    PXDivider()
                    HStack(spacing: 8) {
                        Image(systemName: network.firewall == true ? "lock.shield.fill" : "shield.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(network.firewall == true ? PX.green : PX.tertiary)
                        Text(firewallText)
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PX.inset)
                    .padding(.vertical, 12)
                }
            } else {
                HStack(spacing: 8.5) {
                    if network.listenersAvailable {
                        PXSpinner(size: 13)
                        Text("Reading which apps are listening")
                    } else {
                        MeterIconView(icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.orange, size: 13)
                        Text("Open ports are not available: macOS's nettop tool did not answer.")
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

    private func caption(reachable: Int, apps: Int) -> String? {
        guard network.listenersMeasured else { return nil }
        if reachable == 0 { return "apps waiting for connections · none reachable from the network" }
        return "apps waiting for connections · \(reachable) \(reachable == 1 ? "port" : "ports") in \(apps) \(apps == 1 ? "app" : "apps") reachable from the network"
    }

    private var firewallText: String {
        switch network.firewall {
        case true?: return "The macOS firewall is on. A reachable port answers only if its app is allowed incoming connections."
        case false?: return "The macOS firewall is off, so every reachable port above answers to any device on your network."
        default: return "The macOS firewall did not say whether it is on."
        }
    }

    private func group(_ title: String, count: Int, rgb: RGB, apps: [ListeningApp], exposed: Bool, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(rgb.color()).frame(width: 7, height: 7)
                Text(title)
                    .font(PX.font(12, .medium))
                    .foregroundStyle(PX.text)
                Text("\(count) \(count == 1 ? "app" : "apps")")
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.secondary)
            }
            .padding(.horizontal, PX.inset)
            .padding(.top, 13)
            .padding(.bottom, 6)
            if apps.isEmpty {
                Text(empty)
                    .font(PX.font(12))
                    .foregroundStyle(PX.secondary)
                    .padding(.horizontal, PX.inset)
                    .padding(.bottom, 12)
            } else {
                VStack(spacing: 1) {
                    ForEach(apps) { app in
                        OpenPortsRow(app: app, exposed: exposed, rgb: rgb)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
            }
        }
    }
}

private struct OpenPortsRow: View {
    var app: ListeningApp
    var exposed: Bool
    var rgb: RGB
    @State private var hovering = false

    var body: some View {
        let ports = exposed ? app.exposed : app.local
        let also = exposed ? app.local.count : 0
        HStack(alignment: .center, spacing: 0) {
            Image(nsImage: IconCache.icon(forBundlePath: app.bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(app.name)
                .font(PX.font(12, .medium))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .padding(.leading, 9)
                .frame(width: 210, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(ports.prefix(6)) { port in
                    chip(port)
                }
                if ports.count > 6 {
                    Text("and \(ports.count - 6) more")
                        .font(PX.font(11.5))
                        .foregroundStyle(PX.tertiary)
                }
            }
            Spacer(minLength: 8)
            if also > 0 {
                Text("+ \(also) for this Mac only")
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(hovering ? PX.rowHover : .clear))
        .onHover { hovering = $0 }
        .help(ports.map { "\($0.port)\(KnownPorts.name($0.port).map { " (\($0))" } ?? "") · \($0.process), process \($0.pid)" }.joined(separator: "\n"))
    }

    private func chip(_ port: ListeningPort) -> some View {
        HStack(spacing: 4) {
            Text(String(port.port))
                .font(PX.mono(10.5))
                .foregroundStyle(exposed ? rgb.color() : PX.soft)
            if let name = KnownPorts.name(port.port) {
                Text(name)
                    .font(PX.font(10.5))
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(exposed ? rgb.color(0.13) : PX.button))
    }
}
