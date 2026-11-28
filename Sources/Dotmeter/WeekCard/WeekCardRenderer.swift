import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The dot font, with the few signs the card needs that it lacks, and narrow punctuation so figures set tightly.
enum WeekCardGlyphs {
    private static func make(_ lines: String) -> [UInt8] {
        lines.split(separator: " ").map { line in line.reduce(UInt8(0)) { ($0 << 1) | ($1 == "#" ? 1 : 0) } }
    }

    private static let extra: [Character: [UInt8]] = [
        "$": make("..#.. .#### #.#.. .###. ..#.# ####. ..#.."),
        "°": make(".##.. #..#. #..#. .##.. ..... ..... ....."),
        "…": make("..... ..... ..... ..... ..... ..... #.#.#"),
    ]

    /// These sit in the middle three columns of their cell; the card sets them three dots wide.
    private static let narrow: Set<Character> = [".", ",", ":", "'", "!", "·", " "]

    static func rows(_ character: Character) -> [UInt8] {
        if let known = extra[character] { return known }
        let rows = DotFont.rows(character)
        if rows.contains(where: { $0 != 0 }) || character == " " { return rows }
        // An accented letter is drawn as the letter.
        let plain = String(character).folding(options: .diacriticInsensitive, locale: nil)
        return plain.count == 1 && plain != String(character) ? DotFont.rows(Character(plain)) : rows
    }

    /// The columns of the cell a character is drawn from, and how many.
    static func span(_ character: Character) -> (first: Int, count: Int) {
        narrow.contains(character) ? (1, 3) : (0, DotFont.width)
    }

    /// How many dots wide `text` is, with one empty column between characters.
    static func columns(_ text: String) -> Int {
        max(text.reduce(0) { $0 + span($1).count + 1 } - 1, 0)
    }
}

/// The card as lit and unlit cells, in pixels from the top left, and every string that was set. The picture is
/// drawn from this; the strings are kept so a test can check what a card says without reading pixels.
struct WeekCardPlate {
    struct Ink: Hashable {
        var rgb: RGB
        var alpha: Double
    }

    static let width = 1080
    static let height = 1350

    var lit: [Ink: [CGRect]] = [:]
    var dim: [Ink: [CGRect]] = [:]
    var strings: [String] = []

    private static let white = RGB(0xFFFFFF)
    private static let gray = RGB(0x8E9094)
    private static let faint = RGB(0x66686C)

    private static let margin = 72
    /// A day's strip: cells this far apart, with an empty cell between hours.
    private static let cell = 6
    private static let figureWidth = 296
    private static let figureGap = 24

    // MARK: Setting text

    /// A lit dot's side for cells `pitch` apart: about seven tenths, as the app's bars have it, on whole pixels.
    static func dot(_ pitch: Int) -> Int { max(1, Int((Double(pitch) * 0.7).rounded())) }

    static func width(_ text: String, pitch: Int) -> Int {
        let columns = WeekCardGlyphs.columns(text)
        return columns == 0 ? 0 : columns * pitch - (pitch - dot(pitch))
    }

    /// The largest of `pitches` at which `text` fits; at the smallest, cut short if it must be.
    static func fit(_ text: String, width limit: Int, pitches: [Int]) -> (text: String, pitch: Int) {
        for pitch in pitches where width(text, pitch: pitch) <= limit { return (text, pitch) }
        let pitch = pitches.last ?? 4
        var cut = text
        while cut.count > 1, width(cut + "…", pitch: pitch) > limit { cut.removeLast() }
        return (cut.trimmingCharacters(in: .whitespaces) + "…", pitch)
    }

    private enum Align { case left, right }

    @discardableResult
    private mutating func text(_ string: String, x: Int, y: Int, pitch: Int, _ rgb: RGB, _ alpha: Double = 1, align: Align = .left) -> Int {
        let total = Self.width(string, pitch: pitch)
        guard total > 0 else { return 0 }
        strings.append(string)
        let side = CGFloat(Self.dot(pitch))
        var column = 0
        let origin = align == .left ? x : x - total
        var rects: [CGRect] = []
        for character in string {
            let rows = WeekCardGlyphs.rows(character)
            let span = WeekCardGlyphs.span(character)
            for (row, bits) in rows.enumerated() where bits != 0 {
                for offset in 0..<span.count where bits & (UInt8(1) << UInt8(DotFont.width - 1 - span.first - offset)) != 0 {
                    rects.append(CGRect(x: CGFloat(origin + (column + offset) * pitch), y: CGFloat(y + row * pitch), width: side, height: side))
                }
            }
            column += span.count + 1
        }
        lit[Ink(rgb: rgb, alpha: alpha), default: []].append(contentsOf: rects)
        return total
    }

    private static func height(_ pitch: Int) -> Int { DotFont.height * pitch - (pitch - dot(pitch)) }

    // MARK: The card

    init(_ spec: WeekCardSpec) {
        let left = Self.margin, right = Self.width - Self.margin
        var y = Self.margin

        // Which Mac, and which week.
        text(spec.dates, x: left, y: y, pitch: 4, spec.accent)
        y += Self.height(4) + 22
        let model = Self.fit(spec.model, width: right - left, pitches: [9, 8, 6, 5, 4])
        text(model.text, x: left, y: y, pitch: model.pitch, Self.white, 0.96)
        y += Self.height(model.pitch) + 20
        text(spec.chip, x: left, y: y, pitch: 4, Self.gray)
        y += Self.height(4)

        // The week: a strip a day, a column every twelve minutes, lit from the bottom by how high the reading went.
        y += 54
        text(spec.recorded, x: left, y: y, pitch: 3, Self.gray)
        text(spec.legend, x: right, y: y, pitch: 3, Self.gray, align: .right)
        y += Self.height(3) + 20
        let p = Self.cell, side = CGFloat(Self.dot(p))
        let stripColumns = WeekCardFigures.columns + 23
        let gridWidth = stripColumns * p - (p - Self.dot(p))
        let gridLeft = right - gridWidth
        let stripHeight = spec.rows * p - (p - Self.dot(p))
        let dayStep = stripHeight + 12
        for (day, counts) in spec.filled.enumerated() {
            let top = y + day * dayStep
            if day < spec.dayNames.count {
                text(spec.dayNames[day], x: left, y: top + (stripHeight - Self.height(4)) / 2, pitch: 4, Self.gray)
            }
            for (column, count) in counts.enumerated() {
                let x = CGFloat(gridLeft + (column + column / WeekCardFigures.columnsPerHour) * p)
                let tone = spec.tones[day][column]
                // The top cell of a column is white-hot, as on the Timeline, and the hotter the higher it stands.
                let cap = Ink(rgb: Self.white, alpha: ((0.3 + 0.62 * Double(count) / Double(spec.rows)) * 50).rounded() / 50)
                for row in 0..<spec.rows {
                    let cell = CGRect(x: x, y: CGFloat(top + (spec.rows - 1 - row) * p), width: side, height: side)
                    if count < 0 {
                        // An hour with no record stays dark: its cells are barely there.
                        dim[Ink(rgb: Self.white, alpha: 0.05), default: []].append(cell.insetBy(dx: 1, dy: 1))
                    } else if row >= count {
                        // A recorded hour is tinted all the way up, like the track of one of the app's bars.
                        lit[Ink(rgb: tone, alpha: 0.2), default: []].append(cell)
                    } else if row == count - 1, count > 1 {
                        lit[cap, default: []].append(cell)
                    } else {
                        lit[Ink(rgb: tone, alpha: 0.62 + 0.38 * Double(row) / Double(max(spec.rows - 1, 1))), default: []].append(cell)
                    }
                }
            }
        }
        y += 7 * dayStep - 12 + 16
        for hour in stride(from: 0, to: 24, by: 6) {
            text(String(format: "%02d", hour), x: gridLeft + hour * (WeekCardFigures.columnsPerHour + 1) * p, y: y, pitch: 3, Self.faint)
        }
        y += Self.height(3)

        // The figures, three to a row.
        y += 58
        let perRow = spec.figures.count == 4 ? 2 : 3
        for (index, figure) in spec.figures.enumerated() {
            let x = left + (index % perRow) * (Self.figureWidth + Self.figureGap)
            let top = y + (index / perRow) * 182
            text(figure.label, x: x, y: top, pitch: 4, Self.gray)
            let band = top + Self.height(4) + 16, bandHeight = 62
            let bottom = band + bandHeight
            if figure.isName {
                let lines = Self.name(figure.value, width: Self.figureWidth)
                let lineHeight = Self.height(lines.pitch)
                for (line, string) in lines.lines.enumerated() {
                    text(string, x: x, y: bottom - lineHeight - (lines.lines.count - 1 - line) * (lineHeight + 8), pitch: lines.pitch, figure.rgb)
                }
            } else {
                let unitWidth = figure.unit.isEmpty ? 0 : Self.width(figure.unit, pitch: 4) + 14
                let value = Self.fit(figure.value, width: Self.figureWidth - unitWidth, pitches: [8, 6, 5, 4])
                let drawn = text(value.text, x: x, y: bottom - Self.height(value.pitch), pitch: value.pitch, figure.rgb)
                if !figure.unit.isEmpty {
                    text(figure.unit, x: x + drawn + 14, y: bottom - Self.height(4), pitch: 4, figure.rgb, 0.8)
                }
            }
            text(figure.detail, x: x, y: bottom + 16, pitch: 3, Self.gray)
        }

        // The foot.
        let foot = Self.height - Self.margin - Self.height(4)
        let mark = Self.height(4)
        lit[Ink(rgb: spec.accent, alpha: 1), default: []].append(contentsOf: Self.mark(x: left, y: foot, size: mark))
        text(WeekCardSpec.wordmark, x: left + mark + 16, y: foot, pitch: 4, Self.white, 0.9)
    }

    /// The mark beside the wordmark: three columns of cells, each a cell taller than the last, like a small meter.
    private static func mark(x: Int, y: Int, size: Int) -> [CGRect] {
        let step = (size + 2) / 3, side = CGFloat(step - 2)
        var rects: [CGRect] = []
        for row in 0..<3 {
            for column in 0..<3 where row >= 2 - column {
                rects.append(CGRect(x: CGFloat(x + column * step), y: CGFloat(y + row * step), width: side, height: side))
            }
        }
        return rects
    }

    /// An app's name as large as it fits: on one line if it can be, else broken in two at a space.
    static func name(_ name: String, width limit: Int) -> (lines: [String], pitch: Int) {
        for pitch in [8, 6, 5] where width(name, pitch: pitch) <= limit { return ([name], pitch) }
        let words = name.split(separator: " ").map(String.init)
        if words.count > 1 {
            // The break that leaves the longer line shortest.
            let breaks = (1..<words.count).map { (words[..<$0].joined(separator: " "), words[$0...].joined(separator: " ")) }
            if let best = breaks.min(by: { max(width($0.0, pitch: 4), width($0.1, pitch: 4)) < max(width($1.0, pitch: 4), width($1.1, pitch: 4)) }) {
                return ([fit(best.0, width: limit, pitches: [4]).text, fit(best.1, width: limit, pitches: [4]).text], 4)
            }
        }
        return ([fit(name, width: limit, pitches: [4]).text], 4)
    }
}

/// A card's worth of pixels, mapped for the drawing and handed back to the system the moment it is done with.
/// The usual allocator keeps large blocks it has been given back, so the working space of one card would stay
/// on the app's account long after the picture was made.
private final class WeekCardPixels {
    static let bytesPerRow = WeekCardPlate.width * 4
    static let bytes = bytesPerRow * WeekCardPlate.height
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    let pointer: UnsafeMutableRawPointer
    private let size: Int

    /// Zeroed, which is clear, or black where there is no alpha. `size` is for working space that is not a picture.
    init?(size: Int = WeekCardPixels.bytes) {
        guard size > 0, let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), mapped != MAP_FAILED else { return nil }
        pointer = mapped
        self.size = size
    }

    deinit { munmap(pointer, size) }

    private static func info(alpha: Bool) -> UInt32 {
        (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    }

    /// Draws into these pixels. Not to be used once they are let go.
    func context(alpha: Bool) -> CGContext? {
        CGContext(data: pointer, width: WeekCardPlate.width, height: WeekCardPlate.height, bitsPerComponent: 8, bytesPerRow: Self.bytesPerRow, space: Self.sRGB, bitmapInfo: Self.info(alpha: alpha))
    }

    /// The pixels as a picture, without copying them: the picture keeps them until it is itself let go.
    /// They go as data, not as a bare pointer, because whoever shows the picture asks for its data, and a
    /// provider that only has a pointer answers with a copy.
    func image(alpha: Bool) -> CGImage? {
        let data = NSData(bytesNoCopy: pointer, length: size, deallocator: { _, _ in withExtendedLifetime(self) {} })
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: WeekCardPlate.width, height: WeekCardPlate.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.bytesPerRow, space: Self.sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: Self.info(alpha: alpha)), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    var buffer: vImage_Buffer {
        vImage_Buffer(data: pointer, height: vImagePixelCount(WeekCardPlate.height), width: vImagePixelCount(WeekCardPlate.width), rowBytes: Self.bytesPerRow)
    }
}

/// Draws a plate. Nothing here touches the app's state, so it runs off the main thread.
enum WeekCardRenderer {
    /// Cells are whole pixels, so they are filled without smoothing, in pixels from the top left.
    private static func fill(_ cells: [WeekCardPlate.Ink: [CGRect]], in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(WeekCardPlate.height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(false)
        for (ink, rects) in cells {
            context.setFillColor(CGColor(colorSpace: WeekCardPixels.sRGB, components: [ink.rgb.r, ink.rgb.g, ink.rgb.b, ink.alpha]) ?? CGColor(gray: 1, alpha: ink.alpha))
            context.fill(rects)
        }
        context.restoreGState()
    }

    /// A soft copy of `source` in `result`: three box blurs, which is as near a Gaussian as makes no difference.
    /// vImage is handed its working space, which for the wide blur is three cards' worth: left to find its own
    /// it takes it from the allocator, which keeps it on the app's account afterwards.
    private static func blur(_ source: WeekCardPixels, into result: WeekCardPixels, spare: WeekCardPixels, radius: Int) -> Bool {
        var input = source.buffer, one = result.buffer, two = spare.buffer
        let kernel = UInt32(radius) | 1
        let flags = vImage_Flags(kvImageEdgeExtend)
        let needed = vImageBoxConvolve_ARGB8888(&input, &one, nil, 0, 0, kernel, kernel, nil, flags | vImage_Flags(kvImageGetTempBufferSize))
        let scratch = needed > 0 ? WeekCardPixels(size: Int(needed)) : nil
        let room = scratch?.pointer
        return vImageBoxConvolve_ARGB8888(&input, &one, room, 0, 0, kernel, kernel, nil, flags) == kvImageNoError
            && vImageBoxConvolve_ARGB8888(&one, &two, room, 0, 0, kernel, kernel, nil, flags) == kvImageNoError
            && vImageBoxConvolve_ARGB8888(&two, &one, room, 0, 0, kernel, kernel, nil, flags) == kvImageNoError
    }

    /// The picture: black, the unlit cells, the glow of the lit ones, and the lit ones themselves on top.
    static func render(_ plate: WeekCardPlate) -> CGImage? {
        guard let lit = WeekCardPixels(), let soft = WeekCardPixels(), let spare = WeekCardPixels(), let card = WeekCardPixels(),
              let onLit = lit.context(alpha: true), let onCard = card.context(alpha: false) else { return nil }
        fill(plate.lit, in: onLit)
        let full = CGRect(x: 0, y: 0, width: WeekCardPlate.width, height: WeekCardPlate.height)
        fill(plate.dim, in: onCard)
        // Light added to light, as it is on a real display: a wide faint halo and a tight bright one.
        onCard.setBlendMode(.plusLighter)
        for (radius, strength) in [(31, 0.55), (9, 0.75)] where blur(lit, into: soft, spare: spare, radius: radius) {
            onCard.setAlpha(strength)
            if let halo = soft.image(alpha: true) { onCard.draw(halo, in: full) }
        }
        onCard.setBlendMode(.normal)
        onCard.setAlpha(1)
        if let crisp = lit.image(alpha: true) { onCard.draw(crisp, in: full) }
        onCard.flush()
        return card.image(alpha: false)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
