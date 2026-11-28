import Foundation

/// A rectangle of dots on the wall's lattice, counted from the top left.
struct DotRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func contains(_ other: DotRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}

/// Text in the dot font, set a little tighter than a fixed grid would: a full stop or a colon takes only the
/// columns it lights, so "1.2" and "14:32" read as one figure.
enum DotText {
    /// The first lit column of a character and how many columns it takes.
    static func span(_ character: Character) -> (first: Int, count: Int) {
        switch character {
        case " ": return (0, 3)
        case ".", ":", ",", "'", "!", "·":
            let lit = DotFont.rows(character).reduce(UInt8(0), |)
            guard lit != 0 else { return (0, DotFont.width) }
            let first = (0..<DotFont.width).first { lit & (0b10000 >> UInt8($0)) != 0 } ?? 0
            let last = (0..<DotFont.width).last { lit & (0b10000 >> UInt8($0)) != 0 } ?? DotFont.width - 1
            return (first, last - first + 1)
        default: return (0, DotFont.width)
        }
    }

    /// How many dots wide `text` is at scale one, with one empty column between characters.
    static func columns(_ text: String) -> Int {
        max(text.reduce(0) { $0 + span($1).count + 1 } - 1, 0)
    }

    /// Whether the font can draw the character at all.
    static func knows(_ character: Character) -> Bool {
        character == " " || DotFont.rows(character).contains { $0 != 0 }
    }

    /// `text` with anything the font cannot draw left out, so a name never shows as a row of gaps.
    static func drawable(_ text: String) -> String {
        String(text.filter(knows)).trimmingCharacters(in: .whitespaces)
    }

    /// `text` cut to fit `columns` dots at `scale`.
    static func fitted(_ text: String, columns limit: Int, scale: Int) -> String {
        var result = text
        while !result.isEmpty, columns(result) * scale > limit { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Where everything on the wall goes, for a screen of a given size in pixels.
///
/// The whole picture sits on one lattice of dots whose pitch is a whole number of pixels, so every dot is as
/// sharp as its neighbour. The lattice is a little larger than the screen: the picture drifts by up to one pitch
/// to spare the panel, and its edge must never come into view. Everything lit stays inside `safe`, the dots
/// that are wholly on screen wherever the picture has drifted to.
struct WallLayout: Equatable {
    /// The screen, in pixels.
    let width: Int
    let height: Int
    /// Pixels from one dot to the next, the lit part of that, and the dark pixels before it.
    let pitch: Int
    let dot: Int
    let lead: Int
    /// The lattice.
    let cols: Int
    let rows: Int
    /// Where the lattice's top left corner sits at rest, in pixels from the screen's. Never positive.
    let originX: Int
    let originY: Int
    /// How far the picture may drift from rest, in pixels, in each direction.
    let drift: Int
    let safe: DotRect
    let content: DotRect
    let header: DotRect
    /// The row of the dotted rule under the header.
    let rule: Int
    /// One rectangle per reading, in `WallTile.allCases` order.
    let tiles: [DotRect]
    /// How many lattice dots one dot of the font takes: for the figures, their units, the labels and the clock.
    let figureScale: Int
    let unitScale: Int
    let labelScale: Int
    let clockScale: Int
    /// The empty rows between a tile's label and figure, and between figure and chart.
    let labelGap: Int
    let chartGap: Int

    /// About this many dots across a 16:9 screen, whatever its resolution: 8 pixels a dot at 4K, 4 at 1080p.
    static let dotsAcross = 480.0

    /// The longest figure each tile can show, number and unit: what the scale has to leave room for.
    static let longest: [(number: String, unit: String)] = [
        ("100", "%"), ("118", "°"), ("9999", "RPM"), ("9999", "W"), ("999", "KB/s"), ("1.2", "GB/s"), ("NONE", ""),
    ]

    init(width: Int, height: Int) {
        self.width = max(width, 320)
        self.height = max(height, 240)
        let (width, height) = (self.width, self.height)
        // The shorter side decides, so an ultra-wide screen gets more dots across and not bigger ones.
        let pitch = max(3, Int((min(Double(width), Double(height) * 16 / 9) / Self.dotsAcross).rounded()))
        let gap = max(1, (pitch + 1) / 4)
        self.pitch = pitch
        dot = pitch - gap
        lead = gap / 2
        drift = pitch
        cols = width / pitch + 4
        rows = height / pitch + 4
        originX = -((cols * pitch - width) / 2)
        originY = -((rows * pitch - height) / 2)

        func safeRange(_ origin: Int, _ extent: Int) -> (Int, Int) {
            let first = Int((Double(pitch - origin) / Double(pitch)).rounded(.up))
            let end = (extent - pitch - origin) / pitch
            return (first, end - first)
        }
        let (sx, sw) = safeRange(originX, width), (sy, sh) = safeRange(originY, height)
        safe = DotRect(x: sx, y: sy, width: sw, height: sh)
        let margin = max(4, Int((Double(min(sw, sh)) / 32).rounded()))
        let content = DotRect(x: sx + margin, y: sy + margin, width: sw - 2 * margin, height: sh - 2 * margin)
        self.content = content

        // Three across on a screen that is wider than tall; two across on one stood on its side, where the
        // ninth tile takes the whole last row.
        let wide = Double(content.width) >= Double(content.height) * 1.2
        let across = wide ? 3 : 2, down = wide ? 3 : 5
        let gapX = max(6, Int((Double(content.width) / 40).rounded()))
        let gapY = max(5, Int((Double(content.height) / 36).rounded()))
        let headerGap = gapY + 2
        let tileWidth = (content.width - (across - 1) * gapX) / across

        // The largest figures that leave every tile room for its longest reading and a chart worth looking at.
        var chosen = (figure: 1, tileHeight: 0)
        for scale in stride(from: 12, through: 1, by: -1) {
            let clock = max(2, scale - 1), label = max(1, scale / 4), unit = max(1, scale / 2)
            let tileHeight = (content.height - 7 * clock - headerGap - (down - 1) * gapY) / down
            let needed = 7 * label + (2 + label) + 7 * scale + (3 + label) + max(10, 3 * scale + 2)
            let widest = Self.longest.map { Self.figureColumns($0.number, $0.unit, scale: scale, unitScale: unit) }.max() ?? 0
            chosen = (scale, tileHeight)
            if needed <= tileHeight, widest <= tileWidth { break }
        }
        figureScale = chosen.figure
        unitScale = max(1, chosen.figure / 2)
        labelScale = max(1, chosen.figure / 4)
        clockScale = max(2, chosen.figure - 1)
        labelGap = 2 + labelScale
        chartGap = 3 + labelScale
        header = DotRect(x: content.x, y: content.y, width: content.width, height: 7 * clockScale)
        rule = header.maxY + headerGap / 2
        let top = header.maxY + headerGap
        let tileHeight = max(chosen.tileHeight, 1)
        var tiles: [DotRect] = []
        for index in 0..<WallTile.allCases.count {
            let column = index % across, row = index / across
            // The last tile of an uneven grid runs the full width.
            let alone = index == WallTile.allCases.count - 1 && column == 0 && across > 1 && !wide
            tiles.append(DotRect(
                x: content.x + column * (tileWidth + gapX), y: top + row * (tileHeight + gapY),
                width: alone ? content.width : tileWidth, height: tileHeight
            ))
        }
        self.tiles = tiles
    }

    /// The dots a figure and its unit take side by side.
    static func figureColumns(_ number: String, _ unit: String, scale: Int, unitScale: Int) -> Int {
        let figure = DotText.columns(number) * scale
        return unit.isEmpty ? figure : figure + unitGap(scale: scale, unitScale: unitScale) + DotText.columns(unit) * unitScale
    }

    /// The empty dots between a figure and its unit.
    static func unitGap(scale: Int, unitScale: Int) -> Int { max(unitScale + 1, scale - 1) }

    /// The rows of a tile: its label, its figure and its chart.
    struct Parts: Equatable {
        var labelY: Int
        var figureY: Int
        var chart: DotRect
    }

    func parts(_ tile: DotRect) -> Parts {
        let figureY = tile.y + 7 * labelScale + labelGap
        let chartY = figureY + 7 * figureScale + chartGap
        return Parts(labelY: tile.y, figureY: figureY, chart: DotRect(x: tile.x, y: chartY, width: tile.width, height: max(tile.maxY - chartY, 0)))
    }

    /// Where the picture sits after `step` minutes: a slow walk, back and forth across one pitch each way, at
    /// different paces across and down so that over an hour or two no pixel is always lit or always dark.
    func driftOffset(step: Int) -> (x: Int, y: Int) {
        func wave(_ position: Int, _ range: Int) -> Int {
            guard range > 0 else { return 0 }
            let period = 4 * range
            let k = ((position % period) + period) % period
            return k <= range ? k : (k <= 3 * range ? 2 * range - k : k - period)
        }
        let stride = max(1, pitch / 4)
        return (wave(step * stride, drift), wave(step * stride, max(drift - stride, 1)))
    }
}

/// The readings on the wall, in the order they are laid out.
enum WallTile: Int, CaseIterable {
    case cpu, gpu, memory, heat, fans, power, down, up, disk

    var label: String {
        switch self {
        case .cpu: return "PROCESSOR"
        case .gpu: return "GRAPHICS"
        case .memory: return "MEMORY"
        case .heat: return "HEAT"
        case .fans: return "FANS"
        case .power: return "POWER"
        case .down: return "DOWNLOAD"
        case .up: return "UPLOAD"
        case .disk: return "DISK"
        }
    }

    /// Read when a picture is drawn, so it follows the theme.
    var rgb: RGB {
        switch self {
        case .cpu: return AppSection.cpu.rgb
        case .gpu: return AppSection.gpu.rgb
        case .memory: return AppSection.memory.rgb
        case .heat: return AppSection.thermal.rgb
        case .fans: return PX.teal
        case .power: return AppSection.power.rgb
        case .down: return NetScale.down
        case .up: return NetScale.up
        case .disk: return AppSection.storage.rgb
        }
    }
}
