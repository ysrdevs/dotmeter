import CoreGraphics
import Foundation

/// A small RGBA bitmap filled by hand: axis-aligned rects with the edge coverage CoreGraphics would give them.
/// For little animated strips this is far cheaper than a SwiftUI Canvas or a CoreGraphics context per tick.
struct PixelCanvas {
    let width: Int
    let height: Int
    private(set) var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        bytes = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// Fills a rect given in pixels from the top left, blending over what is already there.
    mutating func fill(x: Double, y: Double, width w: Double, height h: Double, rgb: RGB, alpha: Double) {
        guard alpha > 0.002, w > 0, h > 0 else { return }
        let right = x + w, bottom = y + h
        let px0 = max(0, Int(x.rounded(.down))), px1 = min(width, Int(right.rounded(.up)))
        let py0 = max(0, Int(y.rounded(.down))), py1 = min(height, Int(bottom.rounded(.up)))
        guard px1 > px0, py1 > py0 else { return }
        let ink = ScreenInk.faithful(rgb, min(1, alpha))
        let r = ink.r * 255, g = ink.g * 255, b = ink.b * 255
        let stride = width
        bytes.withUnsafeMutableBufferPointer { out in
            for py in py0..<py1 {
                let cy = min(bottom, Double(py + 1)) - max(y, Double(py))
                guard cy > 0 else { continue }
                for px in px0..<px1 {
                    let cx = min(right, Double(px + 1)) - max(x, Double(px))
                    guard cx > 0 else { continue }
                    let k = min(1, alpha) * cx * cy, keep = 1 - k
                    let i = (py * stride + px) * 4
                    out[i] = UInt8(min(255, r * k + Double(out[i]) * keep + 0.5))
                    out[i + 1] = UInt8(min(255, g * k + Double(out[i + 1]) * keep + 0.5))
                    out[i + 2] = UInt8(min(255, b * k + Double(out[i + 2]) * keep + 0.5))
                    out[i + 3] = UInt8(min(255, 255 * k + Double(out[i + 3]) * keep + 0.5))
                }
            }
        }
    }

    func image() -> CGImage? {
        let space = ScreenInk.space
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
