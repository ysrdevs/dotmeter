import AppKit

enum MenuBarIcon {
    private static var cache: [Severity: NSImage] = [:]

    static func image(severity: Severity) -> NSImage? {
        if let cached = cache[severity] { return cached }
        let image = make(severity: severity)
        if let image { cache[severity] = image }
        return image
    }

    private static func make(severity: Severity) -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "\(App.name)") else { return nil }
        if severity >= .high {
            let palette = NSImage.SymbolConfiguration(paletteColors: [Theme.nsColor(for: severity)])
            if let tinted = symbol.withSymbolConfiguration(base.applying(palette)) {
                tinted.isTemplate = false
                return tinted
            }
        }
        let image = symbol.withSymbolConfiguration(base) ?? symbol
        image.isTemplate = true
        return image
    }

    static func text(style: AppSettings.MenuBarStyle, snapshot: Snapshot?) -> String? {
        guard let s = snapshot else { return nil }
        switch style {
        case .icon: return nil
        case .cpu: return Format.percent(s.cpu.total)
        case .temperature: return s.thermal.hottest.map { Format.temperature($0.celsius) + "C" }
        case .fan: return s.thermal.fans.isEmpty ? nil : Format.rpm(s.thermal.averageRPM)
        }
    }
}

/// Draws one area's menu bar item: a small dot-matrix graph in the app's own language, and its live figure.
///
/// Everything is drawn into a single template image, so macOS colors it for a light or dark menu bar, and
/// its width only ever grows to fit the widest figure seen, so neighbouring items do not shuffle about as
/// digits change.
@MainActor
enum MenuBarRenderer {
    enum Glyph: Equatable {
        /// History, newest last, 0...1. A negative value is a moment before the app was running.
        case columns([Double])
        /// How full something is, 0...1. With pins it is drawn as a chip, which is how memory tells
        /// itself apart from the disk beside it.
        case gauge(Double, pins: Bool)
        /// Download above the middle, upload below, newest last, 0...1 each.
        case duplex(down: [Double], up: [Double])
        /// A battery: a body that fills with the charge, a terminal on its right, and a bolt while charging.
        case battery(charge: Double, charging: Bool)
        /// One column per port, lit by how fast its link is, 0...1; an empty port is a column of dots.
        case ports([Double])
    }

    struct Content {
        var glyph: Glyph
        var lines: [String]
        var symbol: String
        /// Set when the figure deserves attention; the item is then drawn in this color.
        var tint: NSColor?
        var tooltip: String
    }

    static let height: CGFloat = 18
    private static let columns = 10
    private static let rows = 6
    private static let pitch: CGFloat = 2.5
    private static let cell: CGFloat = 1.8
    private static var widest: [String: CGFloat] = [:]

    private static let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    // MARK: What to show

    static func content(for section: AppSection, snapshot s: Snapshot, history: [HistoryPoint], storage: StorageModel) -> Content {
        let recent = Array(history.suffix(columns))
        func padded(_ values: [Double]) -> [Double] { Array(repeating: -1, count: max(0, columns - values.count)) + values }
        switch section {
        case .cpu:
            return Content(
                glyph: .columns(padded(recent.map(\.cpu))), lines: [Format.percent(s.cpu.total)], symbol: section.symbol, tint: nil,
                tooltip: "Processor · \(Format.percent(s.cpu.total)) of \(s.cpu.perCore.count) cores busy"
            )
        case .memory:
            // Used over free, two rows, the way the network item stacks its two rates.
            func size(_ bytes: UInt64) -> String {
                let gib = Double(bytes) / 1_073_741_824
                return gib >= 10 ? "\(Int(gib.rounded())) GB" : String(format: "%.1f GB", gib)
            }
            let available = s.memory.total > s.memory.used ? s.memory.total - s.memory.used : 0
            let tint: NSColor? = s.memory.pressure == .critical ? .systemRed : (s.memory.pressure == .warning ? .systemOrange : nil)
            return Content(
                glyph: .gauge(s.memory.usedFraction, pins: true), lines: ["U " + size(s.memory.used), "F " + size(available)], symbol: section.symbol, tint: tint,
                tooltip: "Memory · \(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total)) used · \(s.memory.pressure.title.lowercased()) pressure"
            )
        case .storage:
            let capacity = max(storage.capacity, 1)
            let free = max(0, capacity - storage.usedBytes)
            func size(_ bytes: Double) -> String { bytes >= 999.5e9 ? String(format: "%.2f TB", bytes / 1e12) : "\(Int((bytes / 1e9).rounded())) GB" }
            return Content(
                glyph: .gauge(min(storage.usedBytes / capacity, 1), pins: false), lines: ["U " + size(storage.usedBytes), "F " + size(free)], symbol: section.symbol, tint: free / capacity < 0.05 ? .systemOrange : nil,
                tooltip: "Storage · \(StorageModel.gb(free)) free of \(StorageModel.gb(capacity))"
            )
        case .thermal:
            let severity = Severity.from(s)
            // "66°C": in the menu bar a bare degree sign does not say which scale.
            let text = s.thermal.hottest.map { Format.temperature($0.celsius) + "C" } ?? s.thermal.state.title
            var tooltip = "Thermals · " + (s.thermal.hottest.map { "hottest sensor \(Format.temperature($0.celsius))" } ?? s.thermal.state.title)
            if !s.thermal.fans.isEmpty { tooltip += " · fans \(Format.rpm(s.thermal.averageRPM)) rpm" }
            return Content(
                glyph: .columns(padded(recent.map { $0.temperature.map { min(max(($0 - 30) / 78, 0.02), 1) } ?? -1 })), lines: [text], symbol: section.symbol,
                tint: severity >= .high ? Theme.nsColor(for: severity) : nil, tooltip: tooltip
            )
        case .network:
            let top = NetScale.ceiling(max(history.suffix(40).map { max($0.networkIn, $0.networkOut) }.max() ?? 0, 1))
            // Square root, so a trickle still lights a cell beside a big transfer.
            func level(_ rate: Double) -> Double { rate > 500 ? max(sqrt(rate / top), 0.34) : 0 }
            let name = s.network.primaryInterface?.title ?? "offline"
            return Content(
                glyph: .duplex(down: padded(recent.map { level($0.networkIn) }), up: padded(recent.map { level($0.networkOut) })),
                lines: ["↑ " + Format.shortRate(s.network.outBytesPerSecond), "↓ " + Format.shortRate(s.network.inBytesPerSecond)],
                symbol: section.symbol, tint: s.network.online ? nil : .systemOrange,
                tooltip: "Network · \(name) · ↓ \(Format.rate(s.network.inBytesPerSecond))  ↑ \(Format.rate(s.network.outBytesPerSecond))"
            )
        case .gpu:
            let load = s.gpu?.utilization ?? 0
            return Content(
                glyph: .columns(padded(recent.map(\.gpu))), lines: [Format.percent(load)], symbol: section.symbol, tint: nil,
                tooltip: "Graphics · \(Format.percent(load)) of the graphics cores busy" + (s.gpu?.memoryInUse.map { " · \(Format.bytes($0)) of memory in use" } ?? "")
            )
        case .power:
            let top = AreaMeters.wattCeiling(history.suffix(40).compactMap(\.power).max() ?? 0)
            let text = s.power.total.map { "\(Int($0.rounded())) W" } ?? "—"
            var tooltip = "Power · " + (s.power.total.map { AppTablePanel.watts($0) + " drawn" } ?? "not reported by this Mac")
            if let battery = s.power.battery { tooltip += " · battery \(Format.percent(battery.charge))" }
            return Content(
                glyph: .columns(padded(recent.map { $0.power.map { min(max($0 / top, 0.02), 1) } ?? -1 })), lines: [text], symbol: section.symbol,
                tint: nil, tooltip: tooltip
            )
        case .battery:
            guard let battery = s.power.battery else {
                return Content(glyph: .battery(charge: 0, charging: false), lines: ["—"], symbol: "battery.0percent", tint: nil, tooltip: "Battery · this Mac has none")
            }
            var tooltip = "Battery · \(Format.percent(battery.charge)) · \(battery.state)"
            if let minutes = battery.minutesRemaining { tooltip += " · \(BatteryLook.time(minutes)) \(battery.isCharging ? "until full" : "left")" }
            if let watts = battery.watts, abs(watts) > 0.05 { tooltip += " · \(AppTablePanel.watts(abs(watts)))" }
            // Low on battery is the one state worth color: orange under a fifth, red under a tenth.
            let low: NSColor? = battery.isPluggedIn ? nil : (battery.charge <= 0.10 ? .systemRed : (battery.charge <= 0.20 ? .systemOrange : nil))
            return Content(glyph: .battery(charge: battery.charge, charging: battery.isCharging), lines: [Format.percent(battery.charge)], symbol: BatteryLook.symbol(battery), tint: low, tooltip: tooltip)
        case .usb:
            guard let usb = s.usb else {
                return Content(glyph: .ports(Array(repeating: 0, count: 4)), lines: ["—"], symbol: section.symbol, tint: nil, tooltip: "USB · reading the ports")
            }
            let overview = USBOverview.of(usb)
            let used = overview.connected.count
            var tooltip = "USB · \(used) of \(overview.ports.count) ports in use"
            if overview.deviceCount > 0 { tooltip += " · \(overview.deviceCount) \(overview.deviceCount == 1 ? "device" : "devices")" }
            if let slow = overview.slow.first, let verdict = slow.slow { tooltip += " · \(slow.title): \(verdict.title.lowercasedFirst)" }
            return Content(
                glyph: .ports(overview.ports.prefix(columns).map(\.level)), lines: ["\(used)/\(overview.ports.count)"], symbol: section.symbol,
                tint: overview.slow.isEmpty ? nil : .systemOrange, tooltip: tooltip
            )
        case .dashboard, .claude, .timeline, .startup, .models, .macs:
            return Content(glyph: .gauge(0, pins: false), lines: [], symbol: "waveform.path.ecg", tint: nil, tooltip: "\(App.name)")
        }
    }

    /// Changes exactly when the picture would.
    static func key(_ content: Content, style: AppSettings.MenuBarItemStyle) -> String {
        func cells(_ values: [Double], _ count: Int) -> String { values.map { $0 < 0 ? "x" : String(lit($0, of: count)) }.joined() }
        let glyph: String
        switch content.glyph {
        case .columns(let values): glyph = "c" + cells(values, rows)
        case .gauge(let value, let pins): glyph = "g\(lit(value, of: columns))\(pins ? "p" : "")"
        case .duplex(let down, let up): glyph = "d" + cells(down, rows / 2) + "/" + cells(up, rows / 2)
        case .battery(let charge, let charging): glyph = "b\(lit(charge, of: columns - 1))\(charging ? "c" : "")"
        case .ports(let levels): glyph = "p" + cells(levels, rows)
        }
        return [style.rawValue, glyph, content.lines.joined(separator: "|"), content.tint?.description ?? ""].joined(separator: ";")
    }

    private static func lit(_ value: Double, of count: Int) -> Int {
        value > 0.012 ? max(1, Int((min(value, 1) * Double(count)).rounded())) : 0
    }

    // MARK: Drawing

    static func plan(_ content: Content, style: AppSettings.MenuBarItemStyle, id: String, color: NSColor? = nil) -> Plan {
        let font = content.lines.count > 1 ? stackedFont : singleFont
        let showsText = style != .compact && !content.lines.isEmpty
        // A charging battery carries a small bolt after it.
        var bolt: CGFloat = 0
        if case .battery(_, true) = content.glyph, style != .icon { bolt = 7.5 }
        // Ports are drawn two columns each while they fit, so a Mac with three of them is not a sliver.
        var glyphColumns = columns
        if case .ports(let levels) = content.glyph { glyphColumns = min(columns, max(levels.count, 1) * portWidth(levels.count)) }
        let leading: CGFloat = style == .icon ? (content.symbol.hasPrefix("battery") ? 23 : 16) : CGFloat(glyphColumns) * pitch + bolt
        var textWidth: CGFloat = 0
        if showsText {
            // Measure with every digit at its widest, and never shrink: the item must not twitch.
            for line in content.lines {
                let widestLine = String(line.map { $0.isNumber ? "8" : $0 })
                textWidth = max(textWidth, ceil(NSAttributedString(string: widestLine, attributes: [.font: font]).size().width))
            }
            let slot = id + style.rawValue
            textWidth = max(textWidth, widest[slot] ?? 0)
            widest[slot] = textWidth
        }
        let gap: CGFloat = showsText ? 5 : 0
        let size = NSSize(width: ceil(leading + gap + textWidth) + 1, height: height)
        let ink = color ?? content.tint ?? .black

        let paint: () -> Bool = {
            if style == .icon {
                let configuration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
                if let symbol = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    let fitted = symbol.size
                    symbol.draw(in: NSRect(x: (leading - fitted.width) / 2, y: (height - fitted.height) / 2, width: fitted.width, height: fitted.height))
                }
            } else {
                draw(content.glyph, at: NSPoint(x: 0, y: (height - CGFloat(rows) * pitch) / 2), ink: ink)
                if bolt > 0 {
                    // Drawn by hand: at this size a font's bolt turns to mush.
                    let x = CGFloat(columns) * pitch + 1.5, y = (height - 10) / 2
                    let shape = NSBezierPath()
                    shape.move(to: NSPoint(x: x + 3.6, y: y + 10))
                    shape.line(to: NSPoint(x: x, y: y + 4.3))
                    shape.line(to: NSPoint(x: x + 2.5, y: y + 4.3))
                    shape.line(to: NSPoint(x: x + 1.6, y: y))
                    shape.line(to: NSPoint(x: x + 5.6, y: y + 5.9))
                    shape.line(to: NSPoint(x: x + 3.0, y: y + 5.9))
                    shape.close()
                    ink.setFill()
                    shape.fill()
                }
            }
            guard showsText else { return true }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let lineHeight = ceil(font.ascender - font.descender)
            for (index, line) in content.lines.enumerated() {
                let text = NSAttributedString(string: line, attributes: attributes)
                let width = text.size().width
                let y: CGFloat = content.lines.count > 1
                    ? (index == 0 ? height / 2 - 0.8 : height / 2 - lineHeight + 1.2)
                    : (height - lineHeight) / 2 + 0.25
                text.draw(at: NSPoint(x: leading + gap + textWidth - width, y: y))
            }
            return true
        }
        return Plan(size: size, template: color == nil && content.tint == nil, paint: paint)
    }

    /// A picture worked out but not yet drawn: how big it is, whether macOS colors it, and how to draw it.
    struct Plan {
        var size: NSSize
        var template: Bool
        var paint: () -> Bool
    }

    /// `color` draws in that color instead of as a template, for previews outside the menu bar.
    static func image(_ content: Content, style: AppSettings.MenuBarItemStyle, id: String, color: NSColor? = nil) -> NSImage {
        let plan = plan(content, style: style, id: id, color: color)
        let image = NSImage(size: plan.size, flipped: false) { _ in plan.paint() }
        image.isTemplate = plan.template
        return image
    }

    /// The same picture drawn once, now, into pixels: showing it again costs a copy, not a drawing.
    static func pixels(_ plan: Plan, scale: CGFloat) -> CGImage? {
        let width = Int((plan.size.width * scale).rounded(.up)), height = Int((plan.size.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ScreenInk.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // A bare bitmap thickens its text for a screen of coloured stripes; a view's own drawing has not done that
        // for years, and the figures must look as they do when the button draws them.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        _ = plan.paint()
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// How many columns each port gets: two while all of them still fit in the glyph, else one.
    private static func portWidth(_ count: Int) -> Int { count * 2 <= columns ? 2 : 1 }

    private static func draw(_ glyph: Glyph, at origin: NSPoint, ink: NSColor) {
        let lit = NSBezierPath(), dim = NSBezierPath(), legs = NSBezierPath()
        func square(_ column: Int, _ row: Int, on: Bool) {
            let cx = origin.x + (CGFloat(column) + 0.5) * pitch, cy = origin.y + (CGFloat(row) + 0.5) * pitch
            let side: CGFloat = on ? cell : 1
            (on ? lit : dim).appendRect(NSRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
        }
        switch glyph {
        case .columns(let values):
            for (column, value) in values.prefix(columns).enumerated() {
                let filled = value < 0 ? 0 : Self.lit(value, of: rows)
                for row in 0..<rows { square(column, row, on: row < filled) }
            }
        case .gauge(let value, let pins):
            let filled = Self.lit(value, of: columns)
            for column in 0..<columns {
                for row in 1..<(rows - 1) { square(column, row, on: column < filled) }
                // The legs of a chip, above and below every other column.
                if pins, column % 2 == 1 {
                    let cx = origin.x + (CGFloat(column) + 0.5) * pitch
                    for row in [0, rows - 1] {
                        let cy = origin.y + (CGFloat(row) + 0.5) * pitch + (row == 0 ? 0.45 : -0.45)
                        legs.appendRect(NSRect(x: cx - 0.6, y: cy - 0.6, width: 1.2, height: 1.2))
                    }
                }
            }
        case .battery(let charge, _):
            // Nine columns of body and one of terminal. Even an almost empty battery keeps one column lit.
            let body = columns - 1
            let filled = charge > 0.005 ? max(1, Int((min(charge, 1) * Double(body)).rounded())) : 0
            for column in 0..<body {
                for row in 1..<(rows - 1) { square(column, row, on: column < filled) }
            }
            for row in [2, 3] {
                let cx = origin.x + (CGFloat(body) + 0.5) * pitch - 0.35, cy = origin.y + (CGFloat(row) + 0.5) * pitch
                legs.appendRect(NSRect(x: cx - 0.75, y: cy - 0.9, width: 1.5, height: 1.8))
            }
        case .ports(let levels):
            let width = portWidth(levels.count)
            for (index, level) in levels.prefix(columns).enumerated() {
                let filled = Self.lit(level, of: rows)
                for part in 0..<width {
                    for row in 0..<rows { square(index * width + part, row, on: row < filled) }
                }
            }
        case .duplex(let down, let up):
            let half = rows / 2
            for column in 0..<columns {
                let downFilled = column < down.count && down[column] >= 0 ? Self.lit(down[column], of: half) : 0
                let upFilled = column < up.count && up[column] >= 0 ? Self.lit(up[column], of: half) : 0
                for row in 0..<half {
                    square(column, half + row, on: row < downFilled)
                    square(column, half - 1 - row, on: row < upFilled)
                }
            }
        }
        ink.withAlphaComponent(0.42).setFill()
        dim.fill()
        ink.withAlphaComponent(0.8).setFill()
        legs.fill()
        ink.setFill()
        lit.fill()
    }

    /// Debug: every area in every style, on a dark and a light strip, written as a PNG.
    static func writeSheet(to path: String, snapshot: Snapshot, history: [HistoryPoint], storage: StorageModel) {
        let sections = AppSettings.menuBarSections.filter { $0 != .dashboard }
        let styles = AppSettings.MenuBarItemStyle.allCases
        let rowHeight: CGFloat = 30, width: CGFloat = Hardware.hasBattery ? 900 : 800
        let size = NSSize(width: width, height: rowHeight * CGFloat(styles.count * 2))
        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (band, dark) in [true, false].enumerated() {
            for (index, style) in styles.enumerated() {
                let y = size.height - rowHeight * CGFloat(band * styles.count + index + 1)
                (dark ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
                var x: CGFloat = 14
                for section in sections {
                    let content = content(for: section, snapshot: snapshot, history: history, storage: storage)
                    let picture = image(content, style: style, id: "sheet." + section.rawValue, color: content.tint ?? (dark ? .white : .black))
                    picture.draw(in: NSRect(x: x, y: y + (rowHeight - height) / 2, width: picture.size.width, height: height))
                    x += picture.size.width + 22
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("CAPTURE \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
}
