import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SeverityDot: View {
    var color: Color

    var body: some View {
        ZStack {
            // A gradient halo instead of a shadow: same glow, no offscreen render pass every refresh.
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.55), color.opacity(0)], center: .center, startRadius: 3, endRadius: 10))
                .frame(width: 20, height: 20)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        }
        .frame(width: 12, height: 12)
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct HeightReader: View {
    @Binding var height: CGFloat
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: HeightKey.self, value: geo.size.height)
        }
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static let generic: NSImage = downscale(NSWorkspace.shared.icon(for: .unixExecutable))

    static func prewarm<S: Sequence>(_ apps: S) where S.Element == AppUsage {
        for app in apps { _ = icon(for: app) }
    }

    static func icon(for app: AppUsage) -> NSImage { icon(forBundlePath: app.bundlePath) }

    static func icon(forBundlePath bundlePath: String?) -> NSImage {
        guard let path = bundlePath else { return generic }
        if let cached = cache[path] { return cached }
        let image = downscale(NSWorkspace.shared.icon(forFile: path))
        cache[path] = image
        return image
    }

    /// Workspace icons carry reps up to 1024px; rows only need 18pt, so keep a single 40px bitmap.
    private static func downscale(_ source: NSImage, points: CGFloat = 20) -> NSImage {
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: points, height: points))
        image.addRepresentation(rep)
        return image
    }
}
