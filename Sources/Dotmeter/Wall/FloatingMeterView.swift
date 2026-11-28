import AppKit
import Observation
import SwiftUI

/// The figures the floating meter shows, as the words on it. Two that read the same are equal, and the meter is
/// only drawn again when they differ.
struct FloatingReadings: Hashable {
    var cpu = "--%"
    var gpu = "--%"
    var temperature = "--°"
    /// The temperature in whole degrees, which decides its colour.
    var celsius: Int?
    var power = "--W"
    var memory = "--%"
    var down = "0"
    var downUnit = "KB/s"
    var up = "0"
    var upUnit = "KB/s"

    init() {}

    init(_ snapshot: Snapshot) {
        cpu = Self.percent(snapshot.cpu.total)
        if let gpu = snapshot.gpu { self.gpu = Self.percent(gpu.utilization) }
        if let hottest = snapshot.thermal.hottest {
            temperature = Self.degrees(hottest.celsius)
            celsius = Int(hottest.celsius.rounded())
        }
        if let watts = snapshot.power.total { power = Self.watts(watts) }
        if snapshot.memory.total > 0 { memory = Self.percent(snapshot.memory.usedFraction) }
        (down, downUnit) = WallReading.rate(snapshot.network.inBytesPerSecond)
        (up, upUnit) = WallReading.rate(snapshot.network.outBytesPerSecond)
    }

    static func percent(_ fraction: Double) -> String { "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%" }
    static func degrees(_ celsius: Double) -> String { "\(Int(celsius.rounded()))°" }
    static func watts(_ watts: Double) -> String { "\(Int(max(watts, 0).rounded()))W" }

    /// Debug: DOTMETER_FLOATING_DEMO=1 shows made-up figures.
    static var demo: FloatingReadings {
        var readings = FloatingReadings()
        (readings.cpu, readings.gpu, readings.temperature, readings.celsius) = ("37%", "92%", "71°", 71)
        (readings.power, readings.memory) = ("148W", "58%")
        (readings.down, readings.downUnit, readings.up, readings.upUnit) = ("24", "MB/s", "1.8", "MB/s")
        return readings
    }
}

/// The meter's readings, kept apart from the monitor's so that nothing but the meter is told when they change.
@MainActor
@Observable
final class FloatingMeterModel {
    private(set) var readings = FloatingReadings()

    static let demo = ProcessInfo.processInfo.environment["DOTMETER_FLOATING_DEMO"] == "1"

    func take(_ snapshot: Snapshot) {
        let new = Self.demo ? FloatingReadings.demo : FloatingReadings(snapshot)
        // Most readings change no figure: a percent that is still the same percent is not worth a redraw.
        if new != readings { readings = new }
    }
}

/// The strip as it is drawn: one label and one figure for each thing shown.
struct FloatingStrip: Hashable {
    struct Segment: Hashable {
        var label: String
        var figure: String
        var rgb: RGB
        /// The longest figure this segment has to leave room for, in characters.
        var room = 4
        /// The figure's own colour where it is not the label's.
        var ink: RGB?
    }

    var segments: [Segment]
    var opacity: Double

    /// Points from one dot of a figure to the next; a label's dots are half that.
    static let pitch: CGFloat = 2
    static let labelPitch: CGFloat = 1
    static let padX: CGFloat = 12
    static let padY: CGFloat = 8
    static let gap: CGFloat = 13
    static let labelGap: CGFloat = 3
    static let radius: CGFloat = 10

    @MainActor
    init(readings: FloatingReadings, figures: [FloatingFigure], opacity: Double) {
        var segments: [Segment] = []
        for figure in figures {
            switch figure {
            case .cpu: segments.append(Segment(label: "CPU", figure: readings.cpu, rgb: AppSection.cpu.rgb))
            case .gpu: segments.append(Segment(label: "GPU", figure: readings.gpu, rgb: AppSection.gpu.rgb))
            case .temperature: segments.append(Segment(label: "TEMP", figure: readings.temperature, rgb: readings.celsius.map { heatColor(Double($0)) } ?? PX.gray))
            // A Mac that draws a kilowatt gets the fifth character it needs.
            case .power: segments.append(Segment(label: "POWER", figure: readings.power, rgb: AppSection.power.rgb, room: max(4, readings.power.count)))
            case .memory: segments.append(Segment(label: "MEM", figure: readings.memory, rgb: AppSection.memory.rgb))
            case .network:
                segments.append(Segment(label: "↓ \(readings.downUnit)", figure: readings.down, rgb: NetScale.down))
                segments.append(Segment(label: "↑ \(readings.upUnit)", figure: readings.up, rgb: NetScale.up))
            }
        }
        // A one-colour theme tells its areas apart by strength, and its darker shades are hard to read at this
        // size over a bright game. There every figure is lit at full strength; red still means hot.
        if let base = DotTheme.current.base {
            for index in segments.indices where segments[index].rgb != PX.red { segments[index].ink = base }
        }
        self.segments = segments
        self.opacity = opacity
    }

    /// The width a segment keeps whatever its figure reads, so the strip does not shift as digits come and go.
    static func width(_ segment: Segment) -> CGFloat {
        let figure = CGFloat(segment.room * (DotFont.width + 1) - 1) * pitch
        let label = CGFloat(DotText.columns(segment.label)) * labelPitch
        return max(figure, label)
    }

    var size: CGSize {
        let widths = segments.map(Self.width).reduce(0, +)
        let height = Self.padY * 2 + 7 * Self.labelPitch + Self.labelGap + 7 * Self.pitch
        return CGSize(width: Self.padX * 2 + widths + Self.gap * CGFloat(max(segments.count - 1, 0)), height: height)
    }

    /// Draws the strip into a bitmap of `size` points.
    func draw(_ pen: BitmapPen, _ size: CGSize, scale: CGFloat) {
        let frame = CGRect(origin: .zero, size: size)
        pen.fill(rounded: frame, radius: Self.radius, continuous: true, RGB(0x000000), opacity)
        // The card's hairline: lighter at the top than at the bottom.
        let context = pen.context
        context.saveGState()
        context.addPath(Path(roundedRect: frame, cornerRadius: Self.radius, style: .continuous).cgPath)
        context.addPath(Path(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: Self.radius - 0.5, style: .continuous).cgPath)
        context.clip(using: .evenOdd)
        let colors = [CGColor(gray: 1, alpha: 0.20), CGColor(gray: 1, alpha: 0.07)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        context.restoreGState()

        // A lit dot fills three quarters of its cell, in whole pixels so that every dot is the same.
        let lit = max(1, (Self.pitch * scale * 0.75).rounded()) / scale
        let labelDot = Self.labelPitch
        var x = Self.padX
        for segment in segments {
            let labelY = Self.padY, figureY = Self.padY + 7 * Self.labelPitch + Self.labelGap
            var labelDots: [CGRect] = []
            var cursor = x
            for character in segment.label {
                let span = DotText.span(character)
                for (row, bits) in DotFont.rows(character).enumerated() where bits != 0 {
                    for column in 0..<span.count where bits & (0b10000 >> UInt8(span.first + column)) != 0 {
                        labelDots.append(CGRect(x: cursor + CGFloat(column) * labelDot, y: labelY + CGFloat(row) * labelDot, width: labelDot, height: labelDot))
                    }
                }
                cursor += CGFloat(span.count + 1) * labelDot
            }
            pen.fill(labelDots, segment.rgb.mixed(with: .white, 0.18), 0.82)

            var dim: [CGRect] = [], lights: [CGRect] = [], halo: [CGRect] = []
            let characters = Array(segment.figure.prefix(segment.room))
            // Unlit dots show round each character and not in the empty places after a short figure, which
            // would read as a smudge.
            for place in 0..<characters.count {
                let glyph = DotFont.rows(characters[place])
                for row in 0..<DotFont.height {
                    for column in 0..<DotFont.width {
                        let cell = CGPoint(x: x + CGFloat(place * (DotFont.width + 1) + column) * Self.pitch, y: figureY + CGFloat(row) * Self.pitch)
                        let rect = CGRect(x: cell.x, y: cell.y, width: lit, height: lit)
                        if glyph[row] & (0b10000 >> UInt8(column)) != 0 {
                            lights.append(rect)
                            halo.append(rect.insetBy(dx: -Self.pitch * 0.5, dy: -Self.pitch * 0.5))
                        } else {
                            dim.append(rect)
                        }
                    }
                }
            }
            pen.fill(dim, .white, 0.055)
            let ink = segment.ink ?? segment.rgb
            pen.fill(halo, ink, 0.10)
            pen.fill(lights, ink.mixed(with: .white, 0.22), 1)
            x += Self.width(segment) + Self.gap
        }
    }
}

/// The meter's content: the strip, drawn again only when a figure or a setting changes.
struct FloatingMeterView: View {
    var model: FloatingMeterModel
    @State private var settings = FloatingMeterSettings.shared
    @Environment(\.displayScale) private var scale

    var body: some View {
        let strip = FloatingStrip(readings: model.readings, figures: settings.figures, opacity: settings.opacity)
        let scale = scale
        BitmapPicture(spec: { _ in strip }, draw: { pen, size, strip in strip.draw(pen, size, scale: scale) })
            .frame(width: strip.size.width, height: strip.size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
