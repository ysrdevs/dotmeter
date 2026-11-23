import AppKit

/// The colour space every picture is made in: the screen's own.
///
/// A picture handed to a layer in any other space is converted and copied by macOS on arrival, on this
/// process's time, every time it changes: a bar's cells cost three times as much to show in sRGB as in the
/// screen's space, and a chart ten times. CoreGraphics converts the colours it is asked to draw; buffers
/// filled by hand convert theirs here, so a colour looks the same as it always did.
///
/// Only ever used on the main thread, where pictures are drawn.
enum ScreenInk {
    /// Trial: DOTMETER_INK=srgb keeps every picture in sRGB, as before, to compare the cost and the look.
    private static let plain = ProcessInfo.processInfo.environment["DOTMETER_INK"] == "srgb"
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    nonisolated(unsafe) private static var current: CGColorSpace?
    nonisolated(unsafe) private static var converted: [RGB: RGB] = [:]
    nonisolated(unsafe) private static var watching = false

    static var space: CGColorSpace {
        if let current { return current }
        let found = read()
        current = found
        if !watching {
            watching = true
            // Another screen, or another profile for this one: later pictures are made for it. Pictures already
            // made keep the space they were made in, so they still show the right colours.
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                current = nil
                converted.removeAll()
            }
        }
        return found
    }

    private static func read() -> CGColorSpace {
        guard !plain, let screen = NSScreen.screens.first?.colorSpace?.cgColorSpace, screen.model == .rgb, screen.supportsOutput else { return sRGB }
        return screen
    }

    /// A see-through sRGB colour as macOS itself would carry it into `space`: it converts the colour already
    /// multiplied by its alpha, which on a screen whose tone curve is not sRGB's is not quite the colour converted
    /// and then multiplied. Pictures made here have to come out exactly as they did when macOS converted them,
    /// so this does the same. The result is the colour to draw with at that alpha.
    static func faithful(_ rgb: RGB, _ alpha: Double) -> RGB {
        guard alpha > 0.004, alpha < 0.996, space !== sRGB else { return convert(rgb) }
        let carried = convert(RGB(r: rgb.r * alpha, g: rgb.g * alpha, b: rgb.b * alpha))
        return RGB(r: min(carried.r / alpha, 1), g: min(carried.g / alpha, 1), b: min(carried.b / alpha, 1))
    }

    /// An sRGB colour as the numbers that show the same colour in `space`.
    static func convert(_ rgb: RGB) -> RGB {
        if let known = converted[rgb] { return known }
        let target = space
        var result = rgb
        if target !== sRGB, let color = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).converted(to: target, intent: .defaultIntent, options: nil),
           let parts = color.components, parts.count >= 3 {
            result = RGB(r: min(max(parts[0], 0), 1), g: min(max(parts[1], 0), 1), b: min(max(parts[2], 0), 1))
        }
        if converted.count > 4096 { converted.removeAll(keepingCapacity: true) }
        converted[rgb] = result
        return result
    }
}
