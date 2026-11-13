import CoreGraphics
import SwiftUI

/// A picture drawn with CoreGraphics into a bitmap the size of the view and shown as an image.
///
/// Every chart and strip used to be a SwiftUI `Canvas`. A Canvas that redraws on each reading makes SwiftUI keep
/// a pool of GPU surfaces for as long as one is on screen: about 455 MB, however small the drawing. An image has
/// no such cost, and the bitmap is only drawn again when what it shows has changed.
struct BitmapPicture<Spec: Hashable>: View {
    /// What to draw at a given size. Cheap to make; compared with the last one to decide whether to redraw.
    var spec: (CGSize) -> Spec
    /// Draws a spec. Points from the top left, as a Canvas has them.
    var draw: (BitmapPen, CGSize, Spec) -> Void
    /// Small pictures that many views show alike (a cell, a table row's strip) share their bitmaps.
    var shared = false

    @Environment(\.displayScale) private var scale
    @State private var cache = BitmapCache<Spec>()

    var body: some View {
        GeometryReader { geo in
            if let image = image(spec(geo.size), size: geo.size) {
                Image(decorative: image, scale: scale)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func image(_ spec: Spec, size: CGSize) -> CGImage? {
        guard shared else { return cache.image(for: spec, size: size, scale: scale, draw: draw) }
        let key = SharedBitmaps.Key(spec: AnyHashable(spec), width: size.width, height: size.height, scale: scale)
        if let image = SharedBitmaps.images[key] { return image }
        guard let image = BitmapPen.render(size: size, scale: scale, { draw($0, size, spec) }) else { return nil }
        // A few hundred small pictures cover every state in use; past that, start again rather than grow.
        if SharedBitmaps.images.count >= 600 { SharedBitmaps.images.removeAll(keepingCapacity: true) }
        SharedBitmaps.images[key] = image
        return image
    }
}

/// The last picture one view drew, kept so an unchanged spec costs nothing.
final class BitmapCache<Spec: Hashable> {
    private var spec: Spec?
    private var size = CGSize.zero
    private var scale: CGFloat = 0
    private var image: CGImage?

    func image(for spec: Spec, size: CGSize, scale: CGFloat, draw: (BitmapPen, CGSize, Spec) -> Void) -> CGImage? {
        if let image, self.spec == spec, self.size == size, self.scale == scale { return image }
        image = BitmapPen.render(size: size, scale: scale) { draw($0, size, spec) }
        self.spec = spec
        self.size = size
        self.scale = scale
        return image
    }
}

/// Only touched while views are being laid out, which is always on the main thread.
private enum SharedBitmaps {
    struct Key: Hashable {
        var spec: AnyHashable
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
    }

    nonisolated(unsafe) static var images: [Key: CGImage] = [:]
}

/// The few drawing calls the charts need, over a CoreGraphics bitmap.
struct BitmapPen {
    let context: CGContext

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An 8-bit sRGB bitmap of `size` points at `scale`, drawn in points from the top left.
    static func render(size: CGSize, scale: CGFloat, _ draw: (BitmapPen) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(BitmapPen(context: context))
        return context.makeImage()
    }

    private func setFill(_ rgb: RGB, _ alpha: Double) {
        context.setFillColor(CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha))
    }

    func fill(_ rects: [CGRect], _ rgb: RGB, _ alpha: Double = 1) {
        guard !rects.isEmpty, alpha > 0 else { return }
        setFill(rgb, alpha)
        context.fill(rects)
    }

    func fill(_ rect: CGRect, _ rgb: RGB, _ alpha: Double = 1) {
        guard alpha > 0 else { return }
        setFill(rgb, alpha)
        context.fill(rect)
    }

    /// `continuous` rounds the corners the way the cards and tracks do.
    func fill(rounded rect: CGRect, radius: CGFloat, continuous: Bool = false, _ rgb: RGB, _ alpha: Double = 1) {
        guard alpha > 0 else { return }
        setFill(rgb, alpha)
        context.addPath(Self.rounded(rect, radius: radius, continuous: continuous))
        context.fillPath()
    }

    /// Everything drawn after this stays inside the rounded rect.
    func clip(rounded rect: CGRect, radius: CGFloat, continuous: Bool = false) {
        context.addPath(Self.rounded(rect, radius: radius, continuous: continuous))
        context.clip()
    }

    private static func rounded(_ rect: CGRect, radius: CGFloat, continuous: Bool) -> CGPath {
        Path(roundedRect: rect, cornerRadius: radius, style: continuous ? .continuous : .circular).cgPath
    }
}
