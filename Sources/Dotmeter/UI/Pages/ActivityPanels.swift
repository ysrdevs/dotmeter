import AppKit
import SwiftUI

// MARK: - Disk activity

/// Five minutes of reading and writing, mirrored about one seam like the network's traffic.
struct DiskActivityPanel: View {
    var history: [HistoryPoint]
    var snapshot: Snapshot

    var body: some View {
        let recent = history.filter { snapshot.timestamp.timeIntervalSince($0.time) <= 300 }
        let read = recent.map(\.diskRead), write = recent.map(\.diskWrite)
        let readTop = NetScale.ceiling(read.max() ?? 0), writeTop = NetScale.ceiling(write.max() ?? 0)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let reader = snapshot.apps.max { $0.diskRead < $1.diskRead }
        let writer = snapshot.apps.max { $0.diskWrite < $1.diskWrite }
        return PXPanel(title: "Disk activity", caption: "last five minutes, each direction on its own scale", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ChartHeader(name: "Reading", now: Format.rate(snapshot.disk.readBytesPerSecond), average: Format.rate(avg(read)), peak: Format.rate(read.max() ?? 0), swatch: PX.cyan)
                    .padding(.top, 14)
                DuplexMatrixChart(
                    upper: recent.map { .init(time: $0.time, value: $0.diskRead / readTop) },
                    lower: recent.map { .init(time: $0.time, value: $0.diskWrite / writeTop) },
                    upperRGB: PX.cyan, lowerRGB: PX.orange, upperRows: 18, lowerRows: 14
                )
                .padding(.top, 8)
                ChartHeader(name: "Writing", now: Format.rate(snapshot.disk.writeBytesPerSecond), average: Format.rate(avg(write)), peak: Format.rate(write.max() ?? 0), swatch: PX.orange)
                    .padding(.top, 8)
                HStack {
                    Text("5 min ago · top of chart \(Format.rate(readTop)) read, \(Format.rate(writeTop)) written")
                    Spacer()
                    Text("now")
                }
                .font(PX.font(10.5))
                .monospacedDigit()
                .foregroundStyle(PX.tertiary)
                .padding(.top, 8)
                Spacer(minLength: 8)
                PXDivider().padding(.horizontal, -PX.inset)
                VStack(spacing: 0) {
                    PXStatRow(label: "Reading most", value: reader.map { $0.diskRead > 1000 ? $0.name : "Nothing" } ?? "Nothing", detail: reader.flatMap { $0.diskRead > 1000 ? Format.rate($0.diskRead) : nil })
                    PXStatRow(label: "Writing most", value: writer.map { $0.diskWrite > 1000 ? $0.name : "Nothing" } ?? "Nothing", detail: writer.flatMap { $0.diskWrite > 1000 ? Format.rate($0.diskWrite) : nil })
                }
                .padding(.vertical, 7)
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }
}

extension TopAppsPanel {
    /// The apps touching the disk right now, busiest first.
    static func disk(_ snapshot: Snapshot) -> TopAppsPanel {
        let apps = snapshot.apps.filter { $0.disk > 500 }.sorted { $0.disk > $1.disk }
        let top = max(apps.first?.disk ?? 0, 1)
        return TopAppsPanel(
            title: "Apps using the disk", caption: apps.isEmpty ? "nothing right now" : "\(apps.count) reading or writing",
            rows: apps.prefix(8).map { app in
                Row(id: app.id, name: app.name, bundlePath: app.bundlePath, fraction: max(app.disk / top, 0.02), rgb: app.diskWrite > app.diskRead ? PX.orange : PX.cyan, primary: Format.rate(app.diskRead), secondary: Format.rate(app.diskWrite))
            },
            empty: "No app is reading or writing more than a trickle.", columns: ("Read", "Write")
        )
    }
}

// MARK: - Latency

enum LatencyScale {
    static func color(_ milliseconds: Double) -> RGB {
        milliseconds < 30 ? PX.greenRGB : (milliseconds < 80 ? PX.yellow : (milliseconds < 160 ? PX.orange : PX.red))
    }

    /// The next round figure above the slowest round trip.
    static func ceiling(_ milliseconds: Double) -> Double {
        [10, 20, 50, 100, 200, 500, 1000, 2000].first { $0 >= milliseconds * 1.15 } ?? 2000
    }

    static func text(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        return milliseconds < 10 ? String(format: "%.1f ms", milliseconds) : "\(Int(milliseconds.rounded())) ms"
    }
}

/// Round trips to the router and to the internet. A lost echo shows as a full red column.
struct LatencyPanel: View {
    var network: NetworkStats
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let targets = network.latency
        PXPanel(title: "Latency", caption: settings.latencyEnabled ? "an echo every two seconds while this is open" : "switched off", width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                if !settings.latencyEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(App.name) can time a small echo to your router and to the internet (\(LatencyProbe.internetHost)) every two seconds while this page is open, to show delay, jitter and loss.")
                            .font(PX.font(12.5))
                            .foregroundStyle(PX.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        PXButton(title: "Turn on", symbol: "dot.radiowaves.left.and.right") { settings.latencyEnabled = true }
                    }
                    .padding(.top, 18)
                    Spacer(minLength: 0)
                } else if targets.isEmpty {
                    HStack(spacing: 8) {
                        PXSpinner(size: 13)
                        Text(network.online ? "Waiting for the first echoes" : "Offline: nothing to ask").font(PX.font(12)).foregroundStyle(PX.secondary)
                    }
                    .padding(.top, 20)
                    Spacer(minLength: 0)
                } else {
                    ForEach(targets) { target in
                        block(target)
                            .padding(.top, target.id == targets.first?.id ? 14 : 15)
                    }
                    ChartAxis(span: "5 min ago")
                        .padding(.top, 7)
                    Spacer(minLength: 8)
                    PXDivider().padding(.horizontal, -PX.inset)
                    VStack(spacing: 0) {
                        PXStatRow(label: "Jitter", value: targets.map { "\($0.title.lowercased()) \(LatencyScale.text($0.jitter))" }.joined(separator: " · "), detail: "echo to echo · best \(targets.map { LatencyScale.text($0.best) }.joined(separator: " and "))")
                        PXStatRow(label: "Lost", value: targets.map { "\($0.title.lowercased()) \($0.samples.count - $0.answered.count) of \($0.samples.count)" }.joined(separator: " · "), detail: "echoes that never came back")
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    @ViewBuilder
    private func block(_ target: LatencyTarget) -> some View {
        if target.blocked && target.answered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(PX.orange.color())
                    Text("\(target.title): macOS has not let \(App.name) reach the local network.")
                        .font(PX.font(12))
                        .foregroundStyle(PX.label)
                }
                PXButton(title: "Open Privacy settings", symbol: "arrow.up.right", height: 26) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
                }
            }
        } else {
            let top = LatencyScale.ceiling(target.worst ?? 10)
            VStack(alignment: .leading, spacing: 8) {
                ChartHeader(
                    name: "\(target.title)  \(target.host)", now: target.last.map { LatencyScale.text($0) } ?? "lost", average: LatencyScale.text(target.average), peak: LatencyScale.text(target.worst),
                    swatch: target.last.map { LatencyScale.color($0) } ?? PX.red
                )
                MatrixChart(
                    samples: target.samples.map { .init(time: $0.time, value: $0.milliseconds.map { min($0 / top, 0.97) } ?? 1) },
                    rgb: PX.greenRGB, rows: 13, tone: { $0 >= 0.985 ? PX.red : LatencyScale.color($0 * top) }
                )
            }
        }
    }
}

// MARK: - Speed test

/// Apple's networkQuality on request: live traffic while it runs, then the figures and how they compare with earlier runs.
struct SpeedTestPanel: View {
    @Environment(SpeedTestModel.self) private var speed

    var body: some View {
        PXPanel(title: "Speed test", caption: "against Apple's servers", width: PX.cardWidth) {
            if speed.isRunning {
                PXButton(title: "Stop", symbol: "stop.fill", style: .ghost, height: 28, action: speed.stop)
                    .offset(x: 6.5)
            } else {
                PXButton(title: speed.latest == nil ? "Run test" : "Run again", symbol: "arrow.triangle.2.circlepath", style: .ghost, height: 28, symbolRotation: 90, action: speed.run)
                    .offset(x: 6.5)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if speed.isRunning {
                    running
                } else if let result = speed.latest {
                    finished(result)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Measures what this connection really carries by downloading and uploading for about fifteen seconds. On a fast line that moves a few hundred megabytes, so it only runs when you ask.")
                            .font(PX.font(12.5))
                            .foregroundStyle(PX.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .failed(let message) = speed.state { failure(message) }
                        PXButton(title: "Run speed test", symbol: "speedometer", action: speed.run)
                    }
                    .padding(.top, 18)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, PX.inset)
        }
        .frame(height: 342.75)
    }

    private func failure(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(PX.orange.color())
            Text(message).font(PX.font(12)).foregroundStyle(PX.soft)
        }
    }

    private func figure(_ name: String, _ value: String, _ rgb: RGB) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(rgb.color()).frame(width: 7, height: 7)
                Text(name).font(PX.font(12)).foregroundStyle(PX.label)
            }
            Text(value)
                .font(PX.font(22.5, .medium))
                .tracking(PX.tracking(22.5))
                .monospacedDigit()
                .foregroundStyle(PX.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var running: some View {
        let trace = speed.trace
        let downTop = max(trace.map(\.down).max() ?? 0, 1), upTop = max(trace.map(\.up).max() ?? 0, 1)
        let now = Date()
        HStack(spacing: 0) {
            figure("Download, live", Format.linkSpeed(speed.liveDown * 8), NetScale.down)
            figure("Upload, live", Format.linkSpeed(speed.liveUp * 8), NetScale.up)
        }
        .padding(.top, 15)
        DuplexMatrixChart(
            upper: trace.enumerated().map { .init(time: now.addingTimeInterval(-Double(trace.count - 1 - $0.offset) * 0.25), value: $0.element.down / downTop) },
            lower: trace.enumerated().map { .init(time: now.addingTimeInterval(-Double(trace.count - 1 - $0.offset) * 0.25), value: $0.element.up / upTop) },
            upperRGB: NetScale.down, lowerRGB: NetScale.up, upperRows: 20, lowerRows: 12, span: 16
        )
        .padding(.top, 13)
        MiniMatrixBar(fraction: max(speed.progress, 0.012), rgb: PX.orange, rows: 2)
            .padding(.top, 12)
        HStack(spacing: 8) {
            PXSpinner(size: 11.5)
            Text("Testing: about \(max(1, Int((1 - speed.progress) * 15.5))) seconds left. This is real traffic on your line.")
                .font(PX.font(11.5))
                .foregroundStyle(PX.secondary)
        }
        .padding(.top, 9)
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private func finished(_ result: SpeedResult) -> some View {
        HStack(spacing: 0) {
            figure("Download", Format.linkSpeed(result.down), NetScale.down)
            figure("Upload", Format.linkSpeed(result.up), NetScale.up)
        }
        .padding(.top, 15)
        SpeedHistoryStrip(results: Array(speed.results.suffix(24)))
            .padding(.top, 14)
        HStack {
            Text(speed.results.count > 1 ? "\(speed.results.count) runs, oldest on the left" : "one run so far")
            Spacer()
            Text("latest")
        }
        .font(PX.font(10.5))
        .foregroundStyle(PX.tertiary)
        .padding(.top, 6)
        if case .failed(let message) = speed.state { failure(message).padding(.top, 8) }
        Spacer(minLength: 8)
        PXDivider().padding(.horizontal, -PX.inset)
        VStack(spacing: 0) {
            PXStatRow(label: "Responsiveness", value: result.responsiveness.map { "\(result.responsivenessTitle ?? "") · \(Format.rpm($0)) RPM" } ?? "—", detail: "round trips a minute while busy")
            PXStatRow(label: "Idle latency", value: LatencyScale.text(result.baseRTT), detail: "to Apple's test server")
            PXStatRow(label: "Measured", value: Self.ago(result.date), detail: result.interface.map { "over \($0)" })
        }
        .padding(.vertical, 7)
    }

    private static func ago(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 90 { return "just now" }
        if elapsed < 86_400 { return "\(Format.duration(elapsed)) ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

/// Earlier runs as pairs of bars: download above the seam, upload below, each against the best of its kind.
struct SpeedHistoryStrip: View {
    var results: [SpeedResult]
    private static let upRows = 12
    private static let downRows = 7

    private struct Spec: Hashable {
        struct Run: Hashable {
            var down: Int
            var up: Int
        }

        var cols: Int
        /// Lit cells for each run, oldest first.
        var runs: [Run]
    }

    var body: some View {
        BitmapPicture(spec: spec, draw: Self.draw)
            .frame(height: CGFloat(Self.upRows + Self.downRows) * PX.pitch + 9)
    }

    private func spec(_ size: CGSize) -> Spec {
        let bestDown = max(results.map(\.down).max() ?? 1, 1), bestUp = max(results.map(\.up).max() ?? 1, 1)
        return Spec(
            cols: max(1, Int((size.width / PX.pitch).rounded(.down))),
            runs: results.map {
                Spec.Run(
                    down: max(1, Int(($0.down / bestDown * Double(Self.upRows)).rounded())),
                    up: max(1, Int(($0.up / bestUp * Double(Self.downRows)).rounded()))
                )
            }
        )
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        let cols = spec.cols
        let gx = (size.width - CGFloat(cols) * p) / 2
        let frame = CGRect(origin: .zero, size: size)
        pen.fill(rounded: frame, radius: 8, continuous: true, PX.trackRGB)
        pen.clip(rounded: frame, radius: 8, continuous: true)
        let side = p - 1.15
        let seam = 3 + CGFloat(upRows) * p
        // Each run is three columns wide with one between, packed against the right-hand edge.
        let width = 4
        let first = cols - spec.runs.count * width
        var dim: [CGRect] = [], down: [CGRect] = [], up: [CGRect] = [], caps: [CGRect] = []
        for c in 0..<cols {
            let cx = gx + (CGFloat(c) + 0.5) * p
            let slot = c - first
            let index = slot >= 0 ? slot / width : -1
            let inBar = slot >= 0 && slot % width != width - 1 && index < spec.runs.count
            let downFilled = inBar ? spec.runs[index].down : 0
            let upFilled = inBar ? spec.runs[index].up : 0
            for r in 0..<upRows {
                let cy = seam - (CGFloat(r) + 0.5) * p
                let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                if r < downFilled { if r == downFilled - 1 { caps.append(rect) } else { down.append(rect) } } else { dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1)) }
            }
            for r in 0..<downRows {
                let cy = seam + 3 + (CGFloat(r) + 0.5) * p
                let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                if r < upFilled { up.append(rect) } else { dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1)) }
            }
        }
        pen.fill(dim, .white, 0.085)
        pen.fill(down, NetScale.down, 0.78)
        pen.fill(caps, NetScale.down.mixed(with: .white, 0.55), 0.98)
        pen.fill(up, NetScale.up, 0.8)
        pen.fill(CGRect(x: 0, y: seam + 1.25, width: size.width, height: 0.5), .white, 0.10)
    }
}
