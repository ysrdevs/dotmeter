import Accelerate
import CoreGraphics
import Foundation

/// One colour ready to be written into a picture: three bytes in the screen's own colour space.
struct DotInk: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    /// `strength` dims the colour toward black, as an LED driven at part power.
    @MainActor
    init(_ rgb: RGB, _ strength: Double = 1) {
        let ink = ScreenInk.convert(RGB(r: rgb.r * strength, g: rgb.g * strength, b: rgb.b * strength))
        r = UInt8((ink.r * 255).rounded())
        g = UInt8((ink.g * 255).rounded())
        b = UInt8((ink.b * 255).rounded())
    }
}

/// The wall as one small picture: a pixel for every dot of the lattice. The graphics card scales it up to the
/// screen, so a new reading costs a few hundred thousand bytes here however large the screen is.
struct DotCanvas {
    let cols: Int
    let rows: Int
    /// Four bytes a dot: its colour and 255 where it is lit, zeros where it is not.
    private(set) var lit: [UInt8]
    /// One where an unlit dot belongs to a chart, which shows a little brighter than the rest of the lattice.
    private(set) var track: [UInt8]
    /// Dots that were asked for outside the lattice. A layout that fits never has any.
    private(set) var clipped = 0

    init(cols: Int, rows: Int) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        lit = [UInt8](repeating: 0, count: self.cols * self.rows * 4)
        track = [UInt8](repeating: 0, count: self.cols * self.rows)
    }

    mutating func set(_ x: Int, _ y: Int, _ ink: DotInk) {
        guard x >= 0, y >= 0, x < cols, y < rows else { clipped += 1; return }
        let i = (y * cols + x) * 4
        lit[i] = ink.r
        lit[i + 1] = ink.g
        lit[i + 2] = ink.b
        lit[i + 3] = 255
    }

    mutating func fill(_ rect: DotRect, _ ink: DotInk) {
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX { set(x, y, ink) }
        }
    }

    mutating func markTrack(_ rect: DotRect) {
        for y in max(rect.y, 0)..<min(rect.maxY, rows) {
            for x in max(rect.x, 0)..<min(rect.maxX, cols) { track[y * cols + x] = 1 }
        }
    }

    /// Writes `text` in the dot font with its top left corner at `x`, `y`; every dot of the font becomes a square
    /// of `scale` lattice dots. Returns the width it took.
    @discardableResult
    mutating func text(_ text: String, x: Int, y: Int, scale: Int, ink: DotInk) -> Int {
        var cursor = x
        for character in text {
            let span = DotText.span(character)
            let glyph = DotFont.rows(character)
            for (row, bits) in glyph.enumerated() where bits != 0 {
                for column in 0..<span.count where bits & (0b10000 >> UInt8(span.first + column)) != 0 {
                    fill(DotRect(x: cursor + column * scale, y: y + row * scale, width: scale, height: scale), ink)
                }
            }
            cursor += (span.count + 1) * scale
        }
        return max(cursor - scale - x, 0)
    }

    /// The smallest rectangle holding every lit dot.
    var litBounds: DotRect? {
        var minX = cols, minY = rows, maxX = -1, maxY = -1
        for y in 0..<rows {
            for x in 0..<cols where lit[(y * cols + x) * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : DotRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func isLit(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < cols && y < rows && lit[(y * cols + x) * 4 + 3] != 0
    }

    // MARK: Pictures

    /// How the light spreads. The values were chosen by eye from captures at 4K, 1440p and 1080p.
    enum Look {
        /// An unlit dot of the lattice, and one inside a chart, as shares of white.
        static let unlit = 0.040
        static let trackUnlit = 0.105
        /// The glow reaches three dots from its source.
        static let reach = 3
        /// The glow between two lit dots, as a share of their colour: enough to soften the grid, not to close it.
        static let glow = 0.42
        /// What an unlit dot picks up from lit ones nearby.
        static let spill = 0.20
        /// Thin strokes throw less light than solid shapes; this curve gives them back some of their halo.
        static let curve = 0.62
    }

    /// The two pictures the wall is made of, a pixel a dot: the dots themselves, lit or not, and the glow that
    /// lies over the gaps between them.
    @MainActor
    func pictures() -> (dots: CGImage, glow: CGImage)? {
        let count = cols * rows
        var soft = [UInt8](repeating: 0, count: count * 4)
        let kernel = UInt32(Look.reach * 2 + 1)
        let blurred: Bool = lit.withUnsafeBufferPointer { source in
            soft.withUnsafeMutableBufferPointer { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: vImagePixelCount(rows), width: vImagePixelCount(cols), rowBytes: cols * 4)
                var to = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(cols), rowBytes: cols * 4)
                let black: [UInt8] = [0, 0, 0, 0]
                return vImageTentConvolve_ARGB8888(&from, &to, nil, 0, 0, kernel, kernel, black, vImage_Flags(kvImageBackgroundColorFill)) == kvImageNoError
            }
        }
        guard blurred else { return nil }

        var glowCurve = [UInt8](repeating: 0, count: 256), spillCurve = [UInt8](repeating: 0, count: 256)
        for level in 0..<256 {
            let lifted = pow(Double(level) / 255, Look.curve)
            glowCurve[level] = UInt8((lifted * Look.glow * 255).rounded())
            spillCurve[level] = UInt8((lifted * Look.spill * 255).rounded())
        }
        let unlit = DotInk(.white, Look.unlit), trackUnlit = DotInk(.white, Look.trackUnlit)
        var dots = [UInt8](repeating: 255, count: count * 4)
        var glow = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            let p = i * 4
            let r = soft[p], g = soft[p + 1], b = soft[p + 2]
            if lit[p + 3] != 0 {
                dots[p] = lit[p]
                dots[p + 1] = lit[p + 1]
                dots[p + 2] = lit[p + 2]
            } else {
                let base = track[i] != 0 ? trackUnlit : unlit
                dots[p] = UInt8(min(Int(base.r) + Int(spillCurve[Int(r)]), 255))
                dots[p + 1] = UInt8(min(Int(base.g) + Int(spillCurve[Int(g)]), 255))
                dots[p + 2] = UInt8(min(Int(base.b) + Int(spillCurve[Int(b)]), 255))
            }
            guard r | g | b != 0 else { continue }
            // Colour already multiplied by its cover, as a layer wants it: the glow hides what is under it only
            // as far as it is bright itself.
            let gr = glowCurve[Int(r)], gg = glowCurve[Int(g)], gb = glowCurve[Int(b)]
            glow[p] = gr
            glow[p + 1] = gg
            glow[p + 2] = gb
            glow[p + 3] = max(gr, gg, gb)
        }
        guard let dotsImage = Self.image(dots, cols: cols, rows: rows, alpha: .noneSkipLast),
              let glowImage = Self.image(glow, cols: cols, rows: rows, alpha: .premultipliedLast)
        else { return nil }
        return (dotsImage, glowImage)
    }

    @MainActor
    static func image(_ bytes: [UInt8], cols: Int, rows: Int, alpha: CGImageAlphaInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
            space: ScreenInk.space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Draws a reading onto the lattice.
@MainActor
enum WallPicture {
    /// The neutral inks, which follow the theme like every other colour: nearly white where each area has its
    /// own colour, a lighter and a darker shade of the one colour where there is only one.
    static var bright: RGB {
        DotTheme.current.base.map { $0.mixed(with: .white, 0.55) } ?? RGB(0xEEEFF1)
    }

    static var quiet: RGB { PX.gray }

    static func draw(_ reading: WallReading, layout: WallLayout) -> DotCanvas {
        var canvas = DotCanvas(cols: layout.cols, rows: layout.rows)
        let small = layout.labelScale
        let brightInk = DotInk(bright), quietInk = DotInk(quiet, 0.88), faintInk = DotInk(quiet, 0.58)

        // The header: the clock on the left with the date beside it, the busiest app on the right.
        let header = layout.header
        var x = header.x + canvas.text(reading.clock, x: header.x, y: header.y, scale: layout.clockScale, ink: brightInk) + layout.clockScale * 2
        if !reading.clockSuffix.isEmpty {
            let scale = max(1, layout.clockScale / 2)
            x += canvas.text(reading.clockSuffix, x: x, y: header.maxY - 7 * scale, scale: scale, ink: quietInk) + layout.clockScale * 2
        }
        // The date stands clear of the clock, as a column of its own.
        x += layout.clockScale * 3
        var dateEnd = x + canvas.text(reading.date, x: x, y: header.y, scale: small, ink: quietInk)
        dateEnd = max(dateEnd, x + canvas.text(reading.note, x: x, y: header.maxY - 7 * small, scale: small, ink: faintInk))

        if let name = reading.busiest, let figure = reading.busiestFigure {
            let figureWidth = DotText.columns(figure) * layout.clockScale
            let figureX = header.maxX - figureWidth
            // The name gives way before it reaches the date.
            let room = figureX - layout.clockScale * 2 - dateEnd - 8 * small
            let title = "BUSIEST APP"
            if room >= DotText.columns(title) * small {
                canvas.text(figure, x: figureX, y: header.y, scale: layout.clockScale, ink: DotInk(WallTile.cpu.rgb.mixed(with: .white, 0.12)))
                let right = figureX - layout.clockScale * 2
                canvas.text(title, x: right - DotText.columns(title) * small, y: header.y, scale: small, ink: faintInk)
                let fitted = DotText.fitted(name, columns: room, scale: small)
                canvas.text(fitted, x: right - DotText.columns(fitted) * small, y: header.maxY - 7 * small, scale: small, ink: brightInk)
            }
        }
        // A dotted rule under it.
        let ruleInk = DotInk(quiet, 0.30)
        for column in stride(from: layout.content.x, to: layout.content.maxX, by: 2) { canvas.set(column, layout.rule, ruleInk) }

        for (tile, rect) in zip(reading.tiles, layout.tiles) {
            let parts = layout.parts(rect)
            let labelWidth = canvas.text(tile.kind.label, x: rect.x, y: parts.labelY, scale: small, ink: quietInk)
            let detail = DotText.drawable(tile.detail)
            let detailWidth = DotText.columns(detail) * small
            if !detail.isEmpty, detailWidth + labelWidth + 6 * small <= rect.width {
                canvas.text(detail, x: rect.maxX - detailWidth, y: parts.labelY, scale: small, ink: faintInk)
            }

            let scale = layout.figureScale, unitScale = layout.unitScale
            let numberWidth = canvas.text(tile.number, x: rect.x, y: parts.figureY, scale: scale, ink: DotInk(tile.rgb.mixed(with: .white, 0.14)))
            if !tile.unit.isEmpty {
                // A degree sign hangs from the top of the figure; every other unit stands on its baseline.
                let unitY = tile.unit == "°" ? parts.figureY : parts.figureY + 7 * (scale - unitScale)
                canvas.text(tile.unit, x: rect.x + numberWidth + WallLayout.unitGap(scale: scale, unitScale: unitScale), y: unitY, scale: unitScale, ink: DotInk(tile.rgb, 0.66))
            }
            chart(tile, in: parts.chart, on: &canvas)
        }
        return canvas
    }

    /// The last five minutes as columns of dots, the newest at the right, each topped by a brighter dot.
    private static func chart(_ tile: WallReading.Tile, in rect: DotRect, on canvas: inout DotCanvas) {
        guard rect.width > 0, rect.height > 0 else { return }
        canvas.markTrack(rect)
        let columns = buckets(times: tile.times, values: tile.values, columns: rect.width, span: WallReading.span)
        let body = DotInk(tile.rgb, 0.60), cap = DotInk(tile.rgb.mixed(with: .white, 0.5))
        var heatInks: [RGB: DotInk] = [:]
        for (column, value) in columns.enumerated() {
            guard let value else { continue }
            let filled = min(max(1, Int((Double(value) * Double(rect.height)).rounded())), rect.height)
            var ink = body
            if let heat = tile.heat {
                let rgb = heatColor(heat.lowerBound + Double(value) * (heat.upperBound - heat.lowerBound))
                ink = heatInks[rgb] ?? DotInk(rgb, 0.60)
                heatInks[rgb] = ink
            }
            let x = rect.x + column
            for row in 0..<(filled - 1) { canvas.set(x, rect.maxY - 1 - row, ink) }
            canvas.set(x, rect.maxY - filled, tile.heat == nil ? cap : DotInk(bright))
        }
    }

    /// One value a column. The newest reading sits in the last column; a column no reading fell in takes the
    /// value before it, so a slow refresh still draws an unbroken chart.
    static func buckets(times: [Double], values: [Float], columns: Int, span: TimeInterval) -> [Float?] {
        var buckets = [Float?](repeating: nil, count: max(columns, 0))
        guard columns > 0, let newest = times.last, times.count == values.count else { return buckets }
        for (time, value) in zip(times, values) {
            let age = newest - time
            guard age >= 0, age <= span else { continue }
            let index = columns - 1 - Int(age / span * Double(columns - 1))
            if index >= 0, index < columns { buckets[index] = max(buckets[index] ?? 0, value) }
        }
        var last: Float?
        for index in 0..<columns {
            if let value = buckets[index] { last = value } else if last != nil { buckets[index] = last }
        }
        return buckets
    }
}
