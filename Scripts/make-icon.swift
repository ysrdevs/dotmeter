// Draws the Dotmeter app icon (rounded squircle, deep gradient, ECG pulse) and writes AppIcon.icns.
// Usage: swift Scripts/make-icon.swift Resources
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = size
    // macOS icon grid: artwork sits inside ~80% of the canvas
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.27, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.11, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Soft highlight at the top
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.maxY), startRadius: 0, endCenter: CGPoint(x: rect.midX, y: rect.maxY), endRadius: rect.width * 0.9, options: [])

    // ECG pulse line
    let w = rect.width
    let midY = rect.midY - rect.height * 0.02
    let x0 = rect.minX + w * 0.14
    let points: [CGPoint] = [
        CGPoint(x: x0, y: midY),
        CGPoint(x: x0 + w * 0.17, y: midY),
        CGPoint(x: x0 + w * 0.23, y: midY + w * 0.06),
        CGPoint(x: x0 + w * 0.29, y: midY - w * 0.05),
        CGPoint(x: x0 + w * 0.36, y: midY + w * 0.24),
        CGPoint(x: x0 + w * 0.44, y: midY - w * 0.20),
        CGPoint(x: x0 + w * 0.50, y: midY + w * 0.04),
        CGPoint(x: x0 + w * 0.56, y: midY),
        CGPoint(x: x0 + w * 0.72, y: midY),
    ]
    let path = CGMutablePath()
    path.move(to: points[0])
    for p in points.dropFirst() { path.addLine(to: p) }

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Glow pass
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: NSColor(calibratedRed: 0.35, green: 0.75, blue: 1.0, alpha: 0.9).cgColor)
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.0, alpha: 1).cgColor)
    ctx.setLineWidth(s * 0.055)
    ctx.strokePath()
    ctx.restoreGState()
    // Crisp pass
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(s * 0.03)
    ctx.strokePath()

    // Pulse dot at the end
    let end = points.last!
    ctx.setFillColor(NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.55, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: end.x + w * 0.04, y: end.y - s * 0.028, width: s * 0.056, height: s * 0.056))
    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
    try! png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    write(draw(size: size), to: "\(iconset)/\(name).png")
}
write(draw(size: 512), to: outDir + "/AppIcon-preview.png")
print("iconset written to \(iconset)")
