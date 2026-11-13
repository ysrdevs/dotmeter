import AppKit
import SwiftUI

/// A titled card for everything that is not a meter: charts, tables, lists.
struct PXPanel<Content: View, Trailing: View>: View {
    var title: String
    var caption: String?
    var width: CGFloat
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(PX.font(13, .medium))
                    .tracking(PX.tracking(13))
                    .foregroundStyle(PX.text)
                if let caption {
                    Text(caption)
                        .font(PX.font(12))
                        .tracking(PX.tracking(12))
                        .foregroundStyle(PX.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .frame(height: 20)
            .padding(.top, 18)
            .padding(.horizontal, PX.inset)
            content
        }
        .frame(width: width, alignment: .topLeading)
        .pxCard()
    }
}

extension PXPanel where Trailing == EmptyView {
    init(title: String, caption: String? = nil, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.init(title: title, caption: caption, width: width, trailing: { EmptyView() }, content: content)
    }
}

/// A label on the left, a value on the right, a hairline between rows.
struct PXStatRow: View {
    var label: String
    var value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(PX.font(12))
                .foregroundStyle(PX.label)
            if let detail {
                Text(detail)
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(PX.font(12))
                .monospacedDigit()
                .foregroundStyle(PX.secondary)
                .lineLimit(1)
        }
        .frame(height: 27)
    }
}

/// A stat row whose value is copied by one click anywhere on it. It says so for a moment, then goes back.
struct PXCopyRow: View {
    var label: String
    var value: String
    var detail: String?
    /// What goes to the clipboard. Nil when there is nothing worth copying, and the row is then plain.
    var copy: String?
    /// Shown turning beside the value while it is being found.
    var busy = false

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            guard let copy else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1300))
                copied = false
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(label)
                    .font(PX.font(12))
                    .foregroundStyle(PX.label)
                if let detail {
                    Text(detail)
                        .font(PX.font(11.5))
                        .foregroundStyle(PX.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy { PXSpinner(size: 10.5) }
                Text(copied ? "Copied" : value)
                    .font(PX.font(12))
                    .monospacedDigit()
                    .foregroundStyle(copied ? PX.green : (copy != nil && hovering ? PX.text : PX.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if copy != nil {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(copied ? PX.green : (hovering ? PX.soft : PX.tertiary))
                        .frame(width: 13)
                }
            }
            .frame(height: 27)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && copy != nil ? PX.rowHover : .clear))
            .padding(.horizontal, -7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(copy == nil)
        .onHover { hovering = $0 }
        .help(copy == nil ? "" : "Click to copy")
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: copied)
    }
}

/// The external address as a row: found when the row comes on screen, copied by a click.
struct ExternalAddressRow: View {
    var network: NetworkStats
    var label = "External IP"
    @Environment(PublicAddress.self) private var lookup
    @Environment(AppSettings.self) private var settings
    @Environment(\.pxActivity) private var activity

    var body: some View {
        let online = network.primaryInterface != nil
        let enabled = settings.publicAddressEnabled
        PXCopyRow(label: label, value: value(online: online, enabled: enabled), detail: detail(online: online, enabled: enabled),
                  copy: online && enabled ? lookup.address : nil, busy: online && enabled && lookup.state == .looking)
            // Asked again only when the way out changes, or the panel is opened after the answer has gone stale.
            .task(id: "\(connection)|\(enabled)|\(activity?.active ?? true)") {
                if !enabled { lookup.clear() } else if online, activity?.active ?? true { lookup.lookUp(for: connection) }
            }
    }

    /// What identifies the way out: the interface, this Mac's address on it and the router.
    private var connection: String {
        let primary = network.primaryInterface
        return "\(primary?.name ?? "")|\(primary?.address ?? "")|\(network.router ?? "")"
    }

    private func value(online: Bool, enabled: Bool) -> String {
        if !enabled { return "Off in Settings" }
        if !online { return "None" }
        switch lookup.state {
        case .known(let address): return address
        case .looking, .unknown: return "Looking it up"
        case .failed: return "Could not be read"
        }
    }

    private func detail(online: Bool, enabled: Bool) -> String? {
        guard enabled, online else { return nil }
        if lookup.state == .failed { return "no answer from 1.1.1.1" }
        return lookup.place?.text ?? "as the internet sees you"
    }
}

/// History as a dot-matrix column chart: one column per slice of time, lit from the bottom.
struct MatrixChart: View {
    struct Sample {
        var time: Date
        /// 0...1
        var value: Double
    }

    var samples: [Sample]
    var rgb: RGB
    var rows = 14
    var span: TimeInterval = 300
    /// Optional color by value, for charts where height means heat.
    var tone: ((Double) -> RGB)?
    /// The moment the right-hand edge stands for. Without one it is the newest sample.
    var anchor: Date?

    private struct Spec: Hashable {
        var rows: Int
        var rgb: RGB
        /// Lit cells in each column, counted from the bottom.
        var filled: [Int16]
        /// Each column's own colour, when height means heat.
        var tones: [RGB]?
    }

    var body: some View {
        BitmapPicture(spec: spec, draw: Self.draw)
            .frame(height: CGFloat(rows) * PX.pitch + 6)
    }

    private func spec(_ size: CGSize) -> Spec {
        let cols = max(1, Int((size.width / PX.pitch).rounded(.down)))
        let buckets = Self.buckets(samples, columns: cols, span: span, anchor: anchor)
        return Spec(
            rows: rows, rgb: rgb,
            filled: buckets.map { value in value.map { Int16(max(1, Int((min(max($0, 0), 1) * Double(rows)).rounded()))) } ?? 0 },
            tones: tone.map { tone in buckets.map { $0.map(tone) ?? rgb } }
        )
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        let cols = spec.filled.count, rows = spec.rows
        let gx = (size.width - CGFloat(cols) * p) / 2
        let gy = (size.height - CGFloat(rows) * p) / 2
        let frame = CGRect(origin: .zero, size: size)
        pen.fill(rounded: frame, radius: 8, continuous: true, PX.trackRGB)

        var dim: [CGRect] = [], lit: [CGRect] = [], cap: [CGRect] = []
        var tinted: [([CGRect], RGB)] = []
        let side = p - 1.15
        for c in 0..<cols {
            let cx = gx + (CGFloat(c) + 0.5) * p
            let filled = Int(spec.filled[c])
            var column: [CGRect] = []
            for r in 0..<rows {
                let cy = gy + (CGFloat(r) + 0.5) * p
                let fromBottom = rows - 1 - r
                if fromBottom < filled {
                    let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                    if fromBottom == filled - 1 { cap.append(rect) } else if spec.tones != nil { column.append(rect) } else { lit.append(rect) }
                } else {
                    dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                }
            }
            if let tones = spec.tones, !column.isEmpty { tinted.append((column, tones[c])) }
        }
        pen.clip(rounded: frame, radius: 8, continuous: true)
        pen.fill(dim, .white, 0.085)
        pen.fill(lit, spec.rgb, 0.78)
        for (rects, tone) in tinted { pen.fill(rects, tone, 0.8) }
        pen.fill(cap, (spec.tones == nil ? spec.rgb : RGB.white).mixed(with: .white, 0.55), 0.98)
    }

    /// One value per column. The newest sample sits in the last column; gaps inherit the value before them.
    static func buckets(_ samples: [Sample], columns cols: Int, span: TimeInterval, anchor: Date? = nil) -> [Double?] {
        var buckets = [Double?](repeating: nil, count: cols)
        if let newest = anchor ?? samples.last?.time {
            for sample in samples {
                let age = newest.timeIntervalSince(sample.time)
                guard age >= 0, age <= span else { continue }
                let index = cols - 1 - Int(age / span * Double(cols - 1))
                if index >= 0 && index < cols { buckets[index] = max(buckets[index] ?? 0, sample.value) }
            }
        }
        // With an anchor the chart is a stretch of the clock, and a gap in it means nothing was recorded.
        guard anchor == nil else { return buckets }
        var last: Double?
        var started = false
        for i in 0..<cols {
            if let value = buckets[i] { last = value; started = true } else if started { buckets[i] = last }
        }
        return buckets
    }
}

/// Two histories on one track, mirrored about a seam: one grows up from it, the other down.
/// Used for traffic, where download and upload are each drawn against their own scale.
struct DuplexMatrixChart: View {
    /// Values 0...1.
    var upper: [MatrixChart.Sample]
    var lower: [MatrixChart.Sample]
    var upperRGB: RGB
    var lowerRGB: RGB
    var upperRows = 20
    var lowerRows = 12
    var span: TimeInterval = 300

    private static let seam: CGFloat = 3

    private struct Spec: Hashable {
        /// Lit cells in each column, counted away from the seam.
        var upper: [Int16]
        var lower: [Int16]
        var upperRGB: RGB
        var lowerRGB: RGB
    }

    var body: some View {
        BitmapPicture(spec: spec, draw: draw)
            .frame(height: CGFloat(upperRows + lowerRows) * PX.pitch + 6 + Self.seam)
    }

    private func spec(_ size: CGSize) -> Spec {
        let cols = max(1, Int((size.width / PX.pitch).rounded(.down)))
        func filled(_ samples: [MatrixChart.Sample], rows: Int) -> [Int16] {
            MatrixChart.buckets(samples, columns: cols, span: span).map { value in
                value.map { $0 <= 0 ? 0 : Int16(max(1, Int((min($0, 1) * Double(rows)).rounded()))) } ?? 0
            }
        }
        return Spec(upper: filled(upper, rows: upperRows), lower: filled(lower, rows: lowerRows), upperRGB: upperRGB, lowerRGB: lowerRGB)
    }

    private func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        let cols = spec.upper.count
        let gx = (size.width - CGFloat(cols) * p) / 2
        let top: CGFloat = 3
        let seamY = top + CGFloat(upperRows) * p
        let frame = CGRect(origin: .zero, size: size)
        pen.fill(rounded: frame, radius: 8, continuous: true, PX.trackRGB)
        pen.clip(rounded: frame, radius: 8, continuous: true)

        let side = p - 1.15
        var dim: [CGRect] = []
        func half(_ filled: [Int16], rows: Int, rgb: RGB, upward: Bool) {
            var lit: [CGRect] = [], cap: [CGRect] = []
            for c in 0..<cols {
                let cx = gx + (CGFloat(c) + 0.5) * p
                let count = Int(filled[c])
                for r in 0..<rows {
                    // r counts away from the seam.
                    let cy = upward ? seamY - (CGFloat(r) + 0.5) * p : seamY + Self.seam + (CGFloat(r) + 0.5) * p
                    if r < count {
                        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                        if r == count - 1 { cap.append(rect) } else { lit.append(rect) }
                    } else {
                        dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                    }
                }
            }
            pen.fill(lit, rgb, 0.78)
            pen.fill(cap, rgb.mixed(with: .white, 0.55), 0.98)
        }
        half(spec.upper, rows: upperRows, rgb: spec.upperRGB, upward: true)
        half(spec.lower, rows: lowerRows, rgb: spec.lowerRGB, upward: false)
        pen.fill(dim, .white, 0.085)
        pen.fill(CGRect(x: 0, y: seamY + Self.seam / 2 - 0.25, width: size.width, height: 0.5), .white, 0.10)
    }
}

/// A thin strip of cells: the bar's little sibling, for table rows.
struct MiniMatrixBar: View {
    var fraction: Double
    var rgb: RGB
    var rows = 2

    private struct Spec: Hashable {
        var cols: Int
        var filled: Int
        var rows: Int
        var rgb: RGB
    }

    var body: some View {
        BitmapPicture(spec: spec, draw: Self.draw, shared: true)
            .frame(height: CGFloat(rows) * PX.pitch)
    }

    private func spec(_ size: CGSize) -> Spec {
        let cols = max(1, Int((size.width / PX.pitch).rounded(.down)))
        return Spec(cols: cols, filled: fraction > 0 ? max(1, Int((min(fraction, 1) * Double(cols)).rounded())) : 0, rows: rows, rgb: rgb)
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        var lit: [CGRect] = [], dim: [CGRect] = []
        let side = p - 1.15
        for c in 0..<spec.cols {
            for r in 0..<spec.rows {
                let cx = (CGFloat(c) + 0.5) * p, cy = (CGFloat(r) + 0.5) * p
                if c < spec.filled {
                    lit.append(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
                } else {
                    dim.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                }
            }
        }
        pen.fill(dim, .white, 0.11)
        pen.fill(lit, spec.rgb, 0.92)
    }
}

/// `MiniMatrixBar` while its item is being removed: the lit squares drain from the right behind a white-hot edge
/// that sheds sparks, the way the big bar clears. `progress` nil means there is nothing to measure (a move to the
/// Trash), so a highlight runs along the squares instead.
/// The strip is one layer. Its picture is filled by hand into a small bitmap nine times a second, which costs
/// next to nothing; as a SwiftUI Canvas on a timeline it had the same cost as the old spinner.
struct DrainingMatrixBar: View {
    var fraction: Double
    var progress: Double?
    var rgb: RGB
    var rows = 2
    @Environment(\.pxActivity) private var activity

    var body: some View {
        DrainingStripHost(fraction: fraction, progress: progress, rgb: rgb, rows: rows, active: activity?.active != false)
            .frame(height: CGFloat(rows) * PX.pitch)
            .allowsHitTesting(false)
    }
}

private struct DrainingStripHost: NSViewRepresentable {
    var fraction: Double
    var progress: Double?
    var rgb: RGB
    var rows: Int
    var active: Bool

    func makeNSView(context: Context) -> DrainingStripView {
        let view = DrainingStripView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DrainingStripView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DrainingStripView) {
        view.fraction = fraction
        view.progress = progress
        view.rgb = rgb
        view.rows = rows
        view.active = active
        view.render()
    }
}

final class DrainingStripView: NSView {
    static let stepTime = 0.09

    var fraction = 0.0
    var progress: Double?
    var rgb = RGB.white
    var rows = 2
    var active = true {
        didSet { if active != oldValue { reschedule() } }
    }

    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.actions = ["contents": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard active, window != nil else { return }
        let timer = Timer(timeInterval: Self.stepTime, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        render()
    }

    /// Cheap repeatable noise in 0..<1 for a cell at a given tick.
    private static func noise(_ c: Int, _ r: Int, _ step: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: c &* 73_856_093 ^ r &* 19_349_663 ^ step &* 83_492_791)
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Double(h % 10_000) / 10_000
    }

    func render() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        var canvas = PixelCanvas(width: Int((Double(bounds.width) * scale).rounded(.up)), height: Int((Double(bounds.height) * scale).rounded(.up)))
        let step = Int(Date().timeIntervalSinceReferenceDate / Self.stepTime)
        let p = Double(PX.pitch)
        let cols = max(1, Int((Double(bounds.width) / p).rounded(.down)))
        let full = fraction > 0 ? max(1.0, (min(fraction, 1) * Double(cols)).rounded()) : 0
        let edge = full * (1 - min(max(progress ?? 0, 0), 1))
        let side = p - 1.15
        let hot = RGB(r: 1, g: 0.95, b: 0.86)

        // Points from the top left, as the strip was first drawn; the bitmap's first row is its top.
        func square(_ cx: Double, _ cy: Double, _ size: Double, _ tone: RGB, _ alpha: Double) {
            canvas.fill(x: (cx - size / 2) * scale, y: (cy - size / 2) * scale, width: size * scale, height: size * scale, rgb: tone, alpha: alpha)
        }

        for c in 0..<cols {
            let x = Double(c)
            for r in 0..<rows {
                let cx = (Double(c) + 0.5) * p, cy = (Double(r) + 0.5) * p
                if x < edge {
                    // How much of this column is still there, and how close it is to the edge.
                    let cover = min(1, edge - x)
                    var tone = rgb
                    var alpha = 0.92
                    if progress != nil {
                        let near = max(0, 1 - (edge - x - 1) / 3.2)
                        tone = rgb.mixed(with: hot, near * near * 0.85)
                        // A slow ripple runs through what is left, towards the edge.
                        alpha = 0.80 + 0.12 * sin((x - Double(step) * 1.1) * 0.55)
                    } else {
                        // Nothing to measure: a band of light travels along the squares.
                        let head = Double(step % 22) / 21 * (full + 8) - 4
                        let near = max(0, 1 - abs(x - head) / 3.5)
                        tone = rgb.mixed(with: hot, near * 0.75)
                        alpha = 0.62 + 0.33 * near
                    }
                    square(cx, cy, side, tone, alpha * cover)
                } else {
                    // Sparks: squares that have just gone, flickering out over the next few columns.
                    let distance = x - edge
                    if progress != nil, edge > 0.01, distance < 7, x < full {
                        let chance = 0.62 * (1 - distance / 7)
                        if Self.noise(c, r, step) < chance {
                            square(cx, cy, side * (0.36 + 0.3 * (1 - distance / 7)), rgb.mixed(with: hot, 0.35), 0.28 + 0.5 * (1 - distance / 7))
                        }
                    }
                    square(cx, cy, 1, .white, 0.11)
                }
            }
        }
        layer?.contentsScale = CGFloat(scale)
        layer?.contents = canvas.image()
    }
}

/// Small filter pill used above lists.
struct PXPill: View {
    var title: String
    var symbol: String?
    var rgb: RGB
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5.5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(rgb.color(selected ? 1 : 0.75))
                }
                Text(title)
                    .font(PX.font(11.5, selected ? .medium : .regular))
                    .foregroundStyle(selected ? PX.text : (hovering ? PX.soft : PX.secondary))
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? PX.button : (hovering ? PX.ghostHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
