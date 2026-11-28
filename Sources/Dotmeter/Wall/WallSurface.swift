import AppKit
import Metal
import QuartzCore

/// The wall's layers.
///
/// A new reading changes two small pictures, a pixel for every dot (about 480 by 270 whatever the screen), and
/// the graphics card does the rest:
///
/// - `dots` is the picture of the dots scaled up without smoothing, so each becomes a square of one pitch;
/// - `columns` and `lines` are black stripes, one picture a pixel tall and one a pixel wide stretched across the
///   screen, that cut those squares apart into dots;
/// - `glow` is the lit dots blurred, scaled up smoothly and laid over everything, which puts light into the
///   gaps round a lit dot and leaves the dot itself as it was.
///
/// Nothing here is drawn at the screen's size by this process, which is what keeps a 4K wall at the cost of a
/// menu bar item.
@MainActor
final class WallSurface {
    let root = CALayer()
    private let picture = CALayer()
    private let dots = CALayer()
    private let columns = CALayer()
    private let lines = CALayer()
    private let glow = CALayer()

    private(set) var layout: WallLayout?
    private var scale: CGFloat = 1
    private var offset = (x: 0, y: 0)
    private var shown: WallReading?
    /// How many pictures have been drawn, for checking that one is drawn a reading and no more.
    private(set) var draws = 0

    init() {
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.masksToBounds = true
        root.isOpaque = true
        root.anchorPoint = .zero
        root.addSublayer(picture)
        for layer in [dots, columns, lines, glow] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            picture.addSublayer(layer)
        }
        glow.magnificationFilter = .linear
        dots.isOpaque = true
        // Nothing here ever fades or slides: a change is a new reading, shown at once.
        let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "sublayers": NSNull()]
        for layer in [root, picture, dots, columns, lines, glow] { layer.actions = still }
    }

    /// Fits the layers to a screen of this many pixels, `scale` of them to a point.
    func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) {
        let wanted = WallLayout(width: pixelWidth, height: pixelHeight)
        guard wanted != layout || scale != self.scale else { return }
        layout = wanted
        self.scale = scale
        root.bounds = CGRect(x: 0, y: 0, width: CGFloat(wanted.width) / scale, height: CGFloat(wanted.height) / scale)
        let size = CGSize(width: CGFloat(wanted.cols * wanted.pitch) / scale, height: CGFloat(wanted.rows * wanted.pitch) / scale)
        picture.bounds = CGRect(origin: .zero, size: size)
        picture.anchorPoint = .zero
        for layer in [dots, columns, lines, glow] { layer.frame = picture.bounds }
        columns.contents = Self.stripes(count: wanted.cols, layout: wanted, vertical: true)
        lines.contents = Self.stripes(count: wanted.rows, layout: wanted, vertical: false)
        place()
        if let shown {
            self.shown = nil
            show(shown)
        }
    }

    /// Black where the gaps between dots are, clear where the dots are: `count` dots in a row, one pixel thick.
    private static func stripes(count: Int, layout: WallLayout, vertical: Bool) -> CGImage? {
        let length = count * layout.pitch
        var bytes = [UInt8](repeating: 0, count: length * 4)
        for position in 0..<length {
            let within = position % layout.pitch
            if within < layout.lead || within >= layout.lead + layout.dot { bytes[position * 4 + 3] = 255 }
        }
        return DotCanvas.image(bytes, cols: vertical ? length : 1, rows: vertical ? 1 : length, alpha: .premultipliedLast)
    }

    /// Puts the picture where the drift has it. Layers count upward from the bottom; the lattice counts down
    /// from the top.
    private func place() {
        guard let layout else { return }
        let x = layout.originX + offset.x, top = layout.originY + offset.y
        let bottom = layout.height - top - layout.rows * layout.pitch
        picture.position = CGPoint(x: CGFloat(x) / scale, y: CGFloat(bottom) / scale)
    }

    /// Moves the whole picture to where it belongs `step` minutes into its walk.
    func drift(step: Int) {
        guard let layout else { return }
        offset = layout.driftOffset(step: step)
        place()
    }

    var driftOffset: (x: Int, y: Int) { offset }

    /// Draws a reading, unless it is the one already showing.
    func show(_ reading: WallReading) {
        guard let layout, reading != shown else { return }
        shown = reading
        guard let pictures = WallPicture.draw(reading, layout: layout).pictures() else { return }
        dots.contents = pictures.dots
        glow.contents = pictures.glow
        draws += 1
    }

    /// The layers as the graphics card composes them, at one pixel a point. For captures: the wall can be looked
    /// at without taking a screen.
    func rendered() -> CGImage? {
        guard let layout, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: layout.width, height: layout.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let space = ScreenInk.space
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: space, kCARendererMetalCommandQueue: queue])
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(root.bounds)
        renderer.render()
        renderer.endFrame()
        // The frame is drawn on the queue it was given; an empty command behind it finishes when the frame has.
        if let wait = queue.makeCommandBuffer() {
            wait.commit()
            wait.waitUntilCompleted()
        }
        let rowBytes = layout.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * layout.height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, layout.width, layout.height), mipmapLevel: 0)
        // Layers count upward and a texture's rows count downward, so the frame arrives upside down.
        var upright = [UInt8](repeating: 0, count: bytes.count)
        for row in 0..<layout.height {
            let from = (layout.height - 1 - row) * rowBytes
            upright.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: bytes[from..<from + rowBytes])
        }
        bytes = upright
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// The view that carries the wall's layers in its window.
final class WallSurfaceView: NSView {
    let surface = WallSurface()
    /// What to show once the layers have a size.
    var reading: WallReading? {
        didSet { if let reading { surface.show(reading) } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(surface.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        fit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fit()
    }

    private func fit() {
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.width > 0, bounds.height > 0 else { return }
        surface.resize(pixelWidth: Int((bounds.width * scale).rounded()), pixelHeight: Int((bounds.height * scale).rounded()), scale: scale)
        surface.root.position = .zero
        if let reading { surface.show(reading) }
    }
}
