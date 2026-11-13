// Draws the install window's background for the DMG, in the app's pixel style.
// Usage: swift Scripts/make-dmg-background.swift <output folder> [--name <app name>] [--version 1.8] [--preview <the .app>]
// Writes background.png and background@2x.png (package.sh joins them into one TIFF).
// With --preview it also writes preview-light.png and preview-dark.png: the background with both icons and
// their labels roughly where Finder puts them, to check that the labels read in either appearance.
//
// What is on it, top to bottom: the name with a strip of menu bar items as the app draws them, the app's own
// meter bar with one segment per area, the tray the two icons sit in with the icon's pulse running from one to
// the other as the arrow, and the areas as a legend.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: make-dmg-background.swift <output folder> [--version <version>] [--preview <app>]")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let version = arguments.firstIndex(of: "--version").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
/// What the app is called. package.sh passes the name from the Info.plist.
let appName = arguments.firstIndex(of: "--name").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "Dotmeter"

// Keep these in step with the Finder layout in package.sh.
let size = CGSize(width: 640, height: 460)
let appCenter = CGPoint(x: 178, y: 264)
let applicationsCenter = CGPoint(x: 462, y: 264)
let iconSize: CGFloat = 112

let pitch: CGFloat = 3.635
let cellSide: CGFloat = pitch - 1.15

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func font(_ points: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: points, weight: weight) }
func digits(_ points: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont.monospacedDigitSystemFont(ofSize: points, weight: weight) }

@discardableResult
func drawText(_ string: String, at point: CGPoint, font: NSFont, color: CGColor, kern: CGFloat = -0.2, centered: Bool = false, trailing: Bool = false, in ctx: CGContext) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white, .kern: kern]
    let text = NSAttributedString(string: string, attributes: attributes)
    let bounds = text.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let x = centered ? point.x - bounds.width / 2 : (trailing ? point.x - bounds.width : point.x)
    text.draw(at: CGPoint(x: x, y: point.y))
    NSGraphicsContext.restoreGraphicsState()
    return bounds.width
}

/// The same hash the app's bars use, so the lit cells gather the way they do there.
func hash(_ x: Int, _ y: Int, _ z: Int) -> Double {
    var h = UInt32(truncatingIfNeeded: x) &* 374_761_393 &+ UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ UInt32(truncatingIfNeeded: z) &* 2_246_822_519
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
}

func noise(_ x: Double, _ y: Double, _ seed: Int) -> Double {
    let xf = floor(x), yf = floor(y)
    let xi = Int(xf), yi = Int(yf)
    var tx = x - xf, ty = y - yf
    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
    func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    return mix(mix(hash(xi, yi, seed), hash(xi + 1, yi, seed), tx), mix(hash(xi, yi + 1, seed), hash(xi + 1, yi + 1, seed), tx), ty)
}

/// Top-left coordinates in points, whatever the pixel scale.
func render(scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx)
    return ctx.makeImage()!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func cell(_ ctx: CGContext, x: CGFloat, y: CGFloat, side: CGFloat = cellSide) {
    ctx.fill(CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
}

/// The eight areas with a menu bar item, in the app's colours, and how much of the bar each takes.
let areas: [(name: String, hex: UInt32, share: CGFloat)] = [
    ("Processor", 0x4C8DF6, 0.19), ("Graphics", 0xE0558D, 0.13), ("Memory", 0x8F6BF2, 0.15), ("Storage", 0xE7813A, 0.12),
    ("Thermals", 0xDE4646, 0.08), ("Network", 0x3FC4D8, 0.14), ("USB", 0xA6D94A, 0.08), ("Power", 0xE9C63F, 0.11),
]

// MARK: The meter bar

/// The app's bar at rest: a rounded track of dim dots, one glowing segment per area, lit cells gathered in
/// checker patches, and a bright hairline along the top of each segment.
func drawMeter(_ ctx: CGContext, in bar: CGRect) {
    let rows = Int((bar.height / pitch).rounded(.down))
    let cols = Int((bar.width / pitch).rounded(.down))
    let gx = bar.minX + (bar.width - CGFloat(cols) * pitch) / 2, gy = bar.minY + (bar.height - CGFloat(rows) * pitch) / 2
    let track = rounded(bar, 9)

    // A soft glow under the bar, in each segment's own colour.
    var left = bar.minX
    for area in areas {
        let width = bar.width * area.share
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 16, color: color(area.hex, 0.55))
        ctx.setFillColor(color(area.hex, 0.30))
        ctx.fill(CGRect(x: left + 6, y: bar.maxY - 6, width: width - 12, height: 4))
        ctx.restoreGState()
        left += width
    }

    ctx.addPath(track)
    ctx.setFillColor(color(0x0E0F10))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(track)
    ctx.clip()
    left = bar.minX
    var column = 0
    for (index, area) in areas.enumerated() {
        let right = index == areas.count - 1 ? bar.maxX - bar.width * 0.0 : left + bar.width * area.share
        // The tint behind a segment's cells.
        ctx.setFillColor(color(area.hex, 0.16))
        ctx.fill(CGRect(x: left, y: bar.minY, width: right - left, height: bar.height))
        while column < cols {
            let cx = gx + (CGFloat(column) + 0.5) * pitch
            if cx > right { break }
            for row in 0..<rows {
                let cy = gy + (CGFloat(row) + 0.5) * pitch
                var lit = false
                if row == 0 { lit = column % 2 == 1 } else if row == rows - 1 { lit = column % 2 == 0 } else if (column + row) % 2 == 0 {
                    let patch = noise(Double(column) / 9 + Double(index) * 3.1, Double(row) / 4.5, 7 + index)
                    lit = hash(column, row, 17) < min(max((patch - 0.30) / 0.30, 0.04), 1)
                }
                if lit {
                    let spark = hash(column, row, 91) > 0.985
                    ctx.setFillColor(spark ? color(0xFFFFFF, 0.92) : color(area.hex, 0.96))
                    cell(ctx, x: cx, y: cy)
                } else {
                    ctx.setFillColor(color(0xFFFFFF, 0.10))
                    cell(ctx, x: cx, y: cy, side: 1)
                }
            }
            column += 1
        }
        // The seam between two segments.
        if index > 0 {
            ctx.setFillColor(color(0x0E0F10, 0.9))
            ctx.fill(CGRect(x: left - 0.75, y: bar.minY, width: 1.5, height: bar.height))
        }
        ctx.setFillColor(color(area.hex, 0.95))
        ctx.fill(CGRect(x: left + (index > 0 ? 0.75 : 0), y: bar.minY, width: right - left - (index > 0 ? 0.75 : 0), height: 1))
        left = right
    }
    ctx.restoreGState()
    ctx.addPath(rounded(bar.insetBy(dx: 0.5, dy: 0.5), 8.5))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(1)
    ctx.strokePath()
}

// MARK: The menu bar strip

enum Glyph {
    case columns([Double])
    case gauge(Double)
    case duplex([Double], [Double])
}

/// One menu bar item as the app draws it: ten columns of small cells and its figure.
@discardableResult
func drawItem(_ ctx: CGContext, glyph: Glyph, lines: [String], at origin: CGPoint, ink: UInt32 = 0xFFFFFF) -> CGFloat {
    let p: CGFloat = 2.5, side: CGFloat = 1.8, rows = 6, cols = 10, height: CGFloat = 18
    let top = origin.y + (height - CGFloat(rows) * p) / 2
    func square(_ column: Int, _ row: Int, on: Bool) {
        // Row 0 is the bottom, as in the app.
        let cx = origin.x + (CGFloat(column) + 0.5) * p, cy = top + (CGFloat(rows - 1 - row) + 0.5) * p
        ctx.setFillColor(color(ink, on ? 0.95 : 0.34))
        cell(ctx, x: cx, y: cy, side: on ? side : 1)
    }
    func lit(_ value: Double, of count: Int) -> Int { value > 0.012 ? max(1, Int((min(value, 1) * Double(count)).rounded())) : 0 }
    switch glyph {
    case .columns(let values):
        for (column, value) in values.prefix(cols).enumerated() {
            let filled = lit(value, of: rows)
            for row in 0..<rows { square(column, row, on: row < filled) }
        }
    case .gauge(let value):
        let filled = lit(value, of: cols)
        for column in 0..<cols {
            for row in 1..<(rows - 1) { square(column, row, on: column < filled) }
            if column % 2 == 1 {
                ctx.setFillColor(color(ink, 0.8))
                let cx = origin.x + (CGFloat(column) + 0.5) * p
                for row in [0, rows - 1] {
                    let cy = top + (CGFloat(rows - 1 - row) + 0.5) * p + (row == 0 ? -0.45 : 0.45)
                    ctx.fill(CGRect(x: cx - 0.6, y: cy - 0.6, width: 1.2, height: 1.2))
                }
            }
        }
    case .duplex(let down, let up):
        let half = rows / 2
        for column in 0..<cols {
            let d = lit(down[column], of: half), u = lit(up[column], of: half)
            for row in 0..<half {
                square(column, half + row, on: row < d)
                square(column, half - 1 - row, on: row < u)
            }
        }
    }
    var width: CGFloat = 0
    let x = origin.x + CGFloat(cols) * p + 5
    if lines.count == 1 {
        width = drawText(lines[0], at: CGPoint(x: x, y: origin.y + 1.6), font: digits(12, .medium), color: color(ink, 0.95), kern: 0, in: ctx)
    } else {
        for (index, line) in lines.enumerated() {
            width = max(width, drawText(line, at: CGPoint(x: x, y: origin.y - 1.4 + CGFloat(index) * 9.6), font: digits(9, .semibold), color: color(ink, 0.95), kern: 0, in: ctx))
        }
    }
    return CGFloat(cols) * p + 5 + width
}

func drawMenuBar(_ ctx: CGContext, trailing: CGFloat, y: CGFloat) {
    let items: [(Glyph, [String])] = [
        (.columns([0.2, 0.3, 0.25, 0.5, 0.85, 0.7, 0.45, 0.6, 0.35, 0.3]), ["12%"]),
        (.gauge(0.42), ["U 146 GB", "F 366 GB"]),
        (.columns([0.5, 0.5, 0.55, 0.6, 0.7, 0.7, 0.65, 0.6, 0.55, 0.55]), ["66°C"]),
        (.duplex([0.4, 0.7, 1, 0.7, 0.4, 0.4, 0.7, 1, 1, 0.7], [0.4, 0.4, 0.4, 0.7, 0.4, 0.34, 0.34, 0.7, 0.4, 0.4]), ["↑ 84 KB/s", "↓ 2.1 MB/s"]),
    ]
    // Measure first, so the strip can be drawn behind its items.
    let scratch = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let widths = items.map { drawItem(scratch, glyph: $0.0, lines: $0.1, at: .zero) }
    let gap: CGFloat = 17, padding: CGFloat = 13
    let total = widths.reduce(0, +) + gap * CGFloat(items.count - 1) + padding * 2
    let strip = CGRect(x: trailing - total, y: y, width: total, height: 28)
    ctx.addPath(rounded(strip, 8))
    ctx.setFillColor(color(0xFFFFFF, 0.065))
    ctx.fillPath()
    ctx.addPath(rounded(strip.insetBy(dx: 0.5, dy: 0.5), 7.5))
    ctx.setStrokeColor(color(0xFFFFFF, 0.09))
    ctx.setLineWidth(1)
    ctx.strokePath()
    var x = strip.minX + padding
    for (index, item) in items.enumerated() {
        drawItem(ctx, glyph: item.0, lines: item.1, at: CGPoint(x: x, y: strip.minY + 5))
        x += widths[index] + gap
    }
}

// MARK: The pulse

/// The app icon's heartbeat, in cells, leaving the app and arriving at Applications as an arrow.
func drawPulse(_ ctx: CGContext, from start: CGFloat, to end: CGFloat, y: CGFloat) {
    // How far each column sits above (negative) or below the line, in cells: flat, a small wave, the spike and
    // its dip, a second small wave, flat again.
    let beat: [Int] = [0, 0, 0, 0, 0, -1, -2, -1, 0, 0, 1, 2, -3, -7, -4, 3, 6, 3, 0, 0, -1, -2, -2, -1, 0, 0, 0, 0, 0, 0]
    let head = 6
    let columns = Int(((end - start) / pitch).rounded(.down))
    let origin = start + ((end - start) - CGFloat(columns) * pitch) / 2
    let lead = max(0, (columns - head - beat.count) / 2)
    func offset(_ column: Int) -> Int {
        let index = column - lead
        return index >= 0 && index < beat.count ? beat[index] : 0
    }
    var cells: [(x: CGFloat, y: CGFloat, strength: CGFloat)] = []
    for column in 0..<(columns - head) {
        let here = offset(column), before = column > 0 ? offset(column - 1) : here
        // Join one column to the next so the trace never breaks.
        let low = min(here, before + (here > before ? 1 : (here < before ? -1 : 0))), high = max(here, before + (here > before ? 1 : (here < before ? -1 : 0)))
        let strength = 0.45 + 0.55 * CGFloat(column) / CGFloat(columns - 1)
        for row in low...high {
            cells.append((origin + (CGFloat(column) + 0.5) * pitch, y + CGFloat(row) * pitch, strength))
        }
    }
    // The arrowhead: a triangle of cells, widest where the trace meets it.
    for step in 0..<head {
        let column = columns - head + step
        let reach = head - 1 - step
        for row in -reach...reach {
            cells.append((origin + (CGFloat(column) + 0.5) * pitch, y + CGFloat(row) * pitch, 1))
        }
    }
    // A cyan glow first, then the bright cells on top of it, as the icon's own line is drawn.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 7, color: color(0x52D6FF, 0.95))
    for item in cells {
        ctx.setFillColor(color(0x8FE6FF, 0.55 * item.strength))
        cell(ctx, x: item.x, y: item.y)
    }
    ctx.restoreGState()
    for item in cells {
        ctx.setFillColor(color(0xFFFFFF, 0.55 + 0.45 * item.strength))
        cell(ctx, x: item.x, y: item.y)
    }
    // The dot the icon's line ends in.
    let last = cells.last!
    ctx.setFillColor(color(0x4FE39A))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 6, color: color(0x4FE39A, 0.9))
    ctx.fillEllipse(in: CGRect(x: last.x + pitch * 0.9, y: last.y - 2.4, width: 4.8, height: 4.8))
    ctx.restoreGState()
}

// MARK: The whole picture

func drawBackground(_ ctx: CGContext) {
    // The window's colour, with the faint dot grid every bar in the app sits on, and a wash of the first and
    // last area colours in the corners.
    ctx.setFillColor(color(0x141517))
    ctx.fill(CGRect(origin: .zero, size: size))
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    for (hex, center) in [(UInt32(0x4C8DF6), CGPoint(x: 40, y: 10)), (UInt32(0x8F6BF2), CGPoint(x: size.width - 60, y: -10)), (UInt32(0x3FC4D8), CGPoint(x: size.width / 2, y: size.height + 40))] {
        if let gradient = CGGradient(colorsSpace: space, colors: [color(hex, 0.20), color(hex, 0)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 300, options: [])
        }
    }
    ctx.setFillColor(color(0xFFFFFF, 0.055))
    var y = pitch
    while y < size.height {
        var x = pitch
        while x < size.width {
            ctx.fill(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
            x += pitch * 2
        }
        y += pitch * 2
    }

    let margin: CGFloat = 30

    // The name, the version beside it, and what the app is.
    let nameWidth = drawText(appName, at: CGPoint(x: margin, y: 22), font: font(25, .semibold), color: color(0xF2F3F5), kern: -0.6, in: ctx)
    if let version {
        let label = NSAttributedString(string: version, attributes: [.font: digits(11, .semibold)])
        let pill = CGRect(x: margin + nameWidth + 10, y: 31, width: label.size().width + 14, height: 18)
        ctx.addPath(rounded(pill, 9))
        ctx.setFillColor(color(0x4C8DF6, 0.20))
        ctx.fillPath()
        ctx.addPath(rounded(pill.insetBy(dx: 0.5, dy: 0.5), 8.5))
        ctx.setStrokeColor(color(0x4C8DF6, 0.45))
        ctx.setLineWidth(1)
        ctx.strokePath()
        drawText(version, at: CGPoint(x: pill.midX, y: pill.minY + 2.2), font: digits(11, .semibold), color: color(0x9CC2FF), kern: 0, centered: true, in: ctx)
    }
    drawText("A check-up for your Mac, live in the menu bar.", at: CGPoint(x: margin + 1, y: 57), font: font(12.5, .regular), color: color(0x9A9CA1), in: ctx)
    drawMenuBar(ctx, trailing: size.width - margin, y: 30)

    // The app's bar, one segment per area.
    drawMeter(ctx, in: CGRect(x: margin, y: 92, width: size.width - margin * 2, height: pitch * 8 + 2))

    // The tray. Finder draws icon labels black in Light appearance and white in Dark, whatever is behind them,
    // so the icons sit on a mid grey that both can be read on. Everything decorative stays clear of the labels.
    let tray = CGRect(x: margin - 2, y: 140, width: size.width - (margin - 2) * 2, height: 252)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: color(0x000000, 0.45))
    ctx.addPath(rounded(tray, 16))
    ctx.setFillColor(color(0x6C6E73))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rounded(tray, 16))
    ctx.clip()
    // Light from above along the top edge, and the app's dots.
    if let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tray.minY), end: CGPoint(x: 0, y: tray.minY + 70), options: [])
    }
    ctx.setFillColor(color(0x000000, 0.11))
    y = tray.minY + pitch
    while y < tray.maxY {
        var x = tray.minX + pitch
        while x < tray.maxX {
            ctx.fill(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
            x += pitch * 2
        }
        y += pitch * 2
    }
    ctx.restoreGState()
    ctx.addPath(rounded(tray.insetBy(dx: 0.5, dy: 0.5), 15.5))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(1)
    ctx.strokePath()

    // A well under each icon and its name: a plain one for the app, and one outlined in cells for where it
    // goes. The fill is kept light, because Finder's label sits on it in black or in white.
    let wellSide = iconSize + 36
    for (center, target) in [(appCenter, false), (applicationsCenter, true)] {
        let well = CGRect(x: center.x - wellSide / 2, y: center.y - iconSize / 2 - 16, width: wellSide, height: iconSize + 16 + 38)
        ctx.addPath(rounded(well, 30))
        ctx.setFillColor(color(0x000000, target ? 0.085 : 0.06))
        ctx.fillPath()
        if target {
            // Dashes the size of a cell, walking round the rounded square.
            let path = rounded(well.insetBy(dx: 1.5, dy: 1.5), 28.5)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(color(0xFFFFFF, 0.46))
            ctx.setLineWidth(cellSide)
            ctx.setLineDash(phase: 0, lengths: [cellSide, pitch - cellSide + 1.2])
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            ctx.addPath(rounded(well.insetBy(dx: 0.5, dy: 0.5), 29.5))
            ctx.setStrokeColor(color(0xFFFFFF, 0.10))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    drawText("DRAG TO INSTALL", at: CGPoint(x: tray.midX, y: tray.minY + 15), font: font(9.5, .semibold), color: color(0x17181A, 0.62), kern: 1.4, centered: true, in: ctx)
    drawPulse(ctx, from: appCenter.x + wellSide / 2 + 4, to: applicationsCenter.x - wellSide / 2 - 9, y: appCenter.y)

    // The areas, as the legend under one of the app's cards.
    let legendY: CGFloat = 413
    let widths = areas.map { NSAttributedString(string: $0.name, attributes: [.font: font(11, .medium), .kern: -0.1]).size().width + 13 }
    let gap = (size.width - margin * 2 - widths.reduce(0, +)) / CGFloat(areas.count - 1)
    var x = margin
    for (index, area) in areas.enumerated() {
        ctx.addPath(rounded(CGRect(x: x, y: legendY + 3.5, width: 7, height: 7), 2))
        ctx.setFillColor(color(area.hex))
        ctx.fillPath()
        drawText(area.name, at: CGPoint(x: x + 13, y: legendY), font: font(11, .medium), color: color(0xB4B6BB), kern: -0.1, in: ctx)
        x += widths[index] + gap
    }
    drawText("Timeline · Login Items · Ask Claude or GPT · Uninstall any app", at: CGPoint(x: margin, y: legendY + 19), font: font(10.5, .regular), color: color(0x74767B), kern: 0, in: ctx)
    drawText("Apple silicon and Intel · macOS 14 or later", at: CGPoint(x: size.width - margin, y: legendY + 19), font: font(10.5, .regular), color: color(0x74767B), kern: 0, trailing: true, in: ctx)
}

func write(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
}

write(render(scale: 1, drawBackground), "background.png")
write(render(scale: 2, drawBackground), "background@2x.png")
print("wrote background.png and background@2x.png to \(output.path)")

if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
    let app = NSWorkspace.shared.icon(forFile: arguments[index + 1])
    let folder = NSWorkspace.shared.icon(forFile: "/Applications")
    for (name, label) in [("preview-light.png", NSColor.black), ("preview-dark.png", NSColor.white)] {
        let image = render(scale: 2) { ctx in
            drawBackground(ctx)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            for (icon, center) in [(app, appCenter), (folder, applicationsCenter)] {
                icon.draw(in: CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            drawText(appName, at: CGPoint(x: appCenter.x, y: appCenter.y + iconSize / 2 + 6), font: font(13, .regular), color: label.cgColor, centered: true, in: ctx)
            drawText("Applications", at: CGPoint(x: applicationsCenter.x, y: applicationsCenter.y + iconSize / 2 + 6), font: font(13, .regular), color: label.cgColor, centered: true, in: ctx)
        }
        write(image, name)
    }
    print("wrote preview-light.png and preview-dark.png")
}
