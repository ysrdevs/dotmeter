import AppKit
import QuartzCore
import SwiftUI

struct MatrixSegment: Identifiable, Equatable {
    var id: String
    var rgb: RGB
    var value: Double
}

enum MatrixMode: Equatable {
    case rest
    /// The bar is filling: white-hot leading edge, dense cells.
    case scanning
    /// The named segment is being removed: hot line at its right edge and rising particles.
    case clearing(String)
}

/// Animation state for one bar. A reference type so the Canvas can advance it every frame without touching SwiftUI state.
final class MatrixEngine {
    struct Seg {
        var id: String
        var rgb: RGB
        var shown: Double
        var target: Double
        /// 0 = dimmed, 0.5 = resting, 1 = highlighted.
        var emphasis: Double
        /// Share of checker cells that are lit.
        var energy: Double
        var seed: Double
    }

    struct Particle {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var age: Double
        var life: Double
        var size: Double
        var rgb: RGB
    }

    private(set) var segs: [Seg] = []
    private var heat = 0.0
    private var pulse = 0.0
    private var clearHeat = 0.0
    private var particles: [Particle] = []
    private var lastTick = 0.0
    private var frameDt = 1.0 / 60
    private var spawnCarry = 0.0
    private var mode: MatrixMode = .rest
    private var highlight: String?
    private var initialized = false
    private var rng = SystemRandomNumberGenerator()

    // MARK: Inputs

    func sync(_ segments: [MatrixSegment], capacity: Double, highlight: String?, mode: MatrixMode, animateIn: Bool) {
        let cap = max(capacity, 1e-12)
        var old: [String: Seg] = [:]
        for s in segs { old[s.id] = s }
        var next: [Seg] = []
        next.reserveCapacity(segments.count + 2)
        for s in segments {
            let target = max(0, s.value / cap)
            if var existing = old.removeValue(forKey: s.id) {
                existing.target = target
                existing.rgb = s.rgb
                next.append(existing)
            } else {
                let start = (initialized || animateIn) ? 0 : target
                next.append(Seg(id: s.id, rgb: s.rgb, shown: start, target: target, emphasis: 0.5, energy: (animateIn && !initialized) ? 0.88 : 0, seed: Self.seed(s.id)))
            }
        }
        // Segments that disappeared shrink away at the end instead of popping.
        for s in segs where old[s.id] != nil && s.shown > 0.0006 {
            var leaving = s
            leaving.target = 0
            next.append(leaving)
        }
        if !initialized {
            initialized = true
            pulse = animateIn ? 1 : 0
        }
        segs = next
        self.highlight = segs.contains(where: { $0.id == highlight }) ? highlight : nil
        self.mode = mode
    }

    private static func seed(_ id: String) -> Double {
        var h: UInt32 = 2166136261
        for u in id.unicodeScalars { h = (h ^ u.value) &* 16777619 }
        return Double(h % 977)
    }

    /// Jump straight to the target state (used for still renders).
    func settle() {
        for i in segs.indices {
            segs[i].shown = segs[i].target
            if let highlight { segs[i].emphasis = segs[i].id == highlight ? 1 : 0 } else { segs[i].emphasis = 0.5 }
            segs[i].energy = mode == .scanning ? 0.62 : Self.lerp3(segs[i].emphasis, 0, 0, 0.94)
        }
        heat = mode == .scanning ? 1 : 0
        if case .clearing = mode { clearHeat = 1 } else { clearHeat = 0 }
        pulse = 0
    }

    // MARK: Simulation

    struct StepResult {
        /// Something big is moving: redraw at display rate.
        var moving: Bool
        /// Geometry, emphasis or heat changed: the static layer is stale.
        var changed: Bool
        /// A scan, a clear or an intro is running: the base changes on every frame.
        var lively: Bool
    }

    /// Advances the animation one frame.
    func step(now: Double) -> StepResult {
        let dt = lastTick == 0 ? 1.0 / 60 : min(max(now - lastTick, 0), 0.12)
        lastTick = now
        frameDt = dt
        var moving = false
        var settling = false

        let kSize = 1 - exp(-dt * 9)
        let kEmphasis = 1 - exp(-dt * 13)
        let kEnergy = 1 - exp(-dt * (mode == .scanning ? 8 : 2.2))

        for i in segs.indices {
            let d = segs[i].target - segs[i].shown
            if abs(d) > 0.004 {
                segs[i].shown += d * kSize
                if abs(d) > 0.06 { moving = true } else { settling = true }
            } else if d != 0 {
                // Under half a percent of the bar (a point or two): snap, so a routine refresh costs one redraw.
                segs[i].shown = segs[i].target
                settling = true
            }

            let emphasisTarget: Double
            if let highlight { emphasisTarget = segs[i].id == highlight ? 1 : 0 } else { emphasisTarget = 0.5 }
            let de = emphasisTarget - segs[i].emphasis
            if abs(de) > 0.004 { segs[i].emphasis += de * kEmphasis; moving = true } else if de != 0 { segs[i].emphasis = emphasisTarget; settling = true }

            var energyTarget = Self.lerp3(segs[i].emphasis, 0.0, 0.0, 0.94)
            if mode == .scanning { energyTarget = 0.62 }
            if case .clearing(let id) = mode, id == segs[i].id { energyTarget = max(energyTarget, 0.5) }
            let dn = energyTarget - segs[i].energy
            if abs(dn) > 0.004 {
                segs[i].energy += dn * kEnergy
                if abs(dn) > 0.25 { moving = true } else { settling = true }
            } else if dn != 0 {
                segs[i].energy = energyTarget
                settling = true
            }
        }

        let heatTarget = mode == .scanning ? 1.0 : 0.0
        heat += (heatTarget - heat) * (1 - exp(-dt * (heatTarget > heat ? 14 : 4.5)))
        pulse *= exp(-dt * 2.6)
        if pulse < 0.01 { pulse = 0 }
        var clearing = false
        if case .clearing = mode { clearing = true }
        clearHeat += ((clearing ? 1.0 : 0.0) - clearHeat) * (1 - exp(-dt * 7))

        for i in particles.indices {
            particles[i].age += dt
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].vx *= exp(-dt * 0.9)
            particles[i].vy *= exp(-dt * 0.5)
        }
        particles.removeAll { $0.age >= $0.life }

        // `settling` changes ride the 10 fps resting tick; only `moving` asks for 60 fps.
        let lively = mode != .rest || heat > 0.012 || pulse > 0 || clearHeat > 0.012 || !particles.isEmpty
        return StepResult(moving: moving || lively, changed: moving || settling || lively, lively: lively)
    }

    private func spawnParticles(at x: Double, bar: CGRect, rgb: RGB, dt: Double) {
        spawnCarry += dt * 150
        while spawnCarry >= 1 {
            spawnCarry -= 1
            let insideBar = Double.random(in: 0...1, using: &rng) < 0.55
            let y = insideBar ? Double.random(in: bar.minY...bar.maxY, using: &rng) : bar.minY + Double.random(in: -6...4, using: &rng)
            particles.append(Particle(
                x: x + Double.random(in: -11...5, using: &rng),
                y: y,
                vx: Double.random(in: -16...9, using: &rng),
                vy: Double.random(in: -78 ... -22, using: &rng),
                age: 0,
                life: Double.random(in: 0.45...1.15, using: &rng),
                size: Double.random(in: 1.7...2.6, using: &rng),
                rgb: rgb.mixed(with: .white, Double.random(in: 0.15...1, using: &rng))
            ))
        }
        if particles.count > 520 { particles.removeFirst(particles.count - 520) }
    }

    // MARK: Drawing (CoreGraphics)

    fileprivate static func cg(_ rgb: RGB, _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    /// Rounded rect with different radii on the left and right ends.
    private static func capsule(_ rect: CGRect, left: CGFloat, right: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let l = min(left, rect.width / 2, rect.height / 2), r = min(right, rect.width / 2, rect.height / 2)
        path.move(to: CGPoint(x: rect.minX + l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - l), radius: l)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + l, y: rect.minY), radius: l)
        path.closeSubpath()
        return path
    }

    /// Soft halo: an elliptical radial gradient, which costs almost nothing compared with a blur.
    private static func halo(_ ctx: CGContext, center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, color: RGB, alpha: Double) {
        guard alpha > 0.01, radiusX > 0 else { return }
        let colors = [cg(color, alpha), cg(color, alpha * 0.45), cg(color, 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.45, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: radiusY / radiusX)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radiusX, options: [])
        ctx.restoreGState()
    }

    /// Widths and strengths of the stacked strokes that stand in for a blurred glow.
    private static let glowPasses: [(width: CGFloat, alpha: Double)] = [(14, 0.03), (10.5, 0.05), (7.5, 0.085), (5, 0.13), (3, 0.2)]

    // The bar is rendered in two parts. The base (track, tint, dim dots, borders, glow, particles) only changes
    // when the data or the animation state does. The lit cells twinkle ten times a second, so they live in a tiny
    // one-pixel-per-cell bitmap that the GPU scales up.
    //
    // On screen the base is never rasterized: `MatrixLiveLayers` composites it from layers (see `liveFrame`), and
    // a change only moves layers and sets colours. It used to be redrawn with CoreGraphics whenever a reading
    // moved a segment, about 2 ms a time plus a megabyte of bitmap sent to the window server, which on a page of
    // eight bars was half of everything the app did. `drawBase` stays the reference for the look and is what
    // every still render shows.

    struct Layout {
        var cols: Int
        var gx: Double
        var gy: Double
        var xs: [Double]
        var fillRight: Double
        var filledWidth: Double
    }

    func layout(bar: CGRect, rows: Int) -> Layout {
        let p = Double(PX.pitch)
        let W = Double(bar.width), H = Double(bar.height)
        let cols = max(1, Int((W / p).rounded(.down)))
        var xs: [Double] = [Double(bar.minX)]
        xs.reserveCapacity(segs.count + 1)
        for s in segs { xs.append(xs[xs.count - 1] + s.shown * W) }
        let fillRight = min(xs[xs.count - 1], Double(bar.maxX))
        return Layout(
            cols: cols,
            gx: Double(bar.minX) + (W - Double(cols) * p) / 2,
            gy: Double(bar.minY) + (H - Double(rows) * p) / 2,
            xs: xs, fillRight: fillRight, filledWidth: fillRight - Double(bar.minX)
        )
    }

    private struct Field {
        var level: Double
        var top: Double
        var bottom: Double
        var boost: Double
        var dim: Double
        var tint: Double
        var glow: Double
    }

    /// Each segment has its own slowly drifting density and top/bottom bands, so no two look alike.
    private func fields(time: Double) -> [Field] {
        let slow = floor(time * 10) / 10 * 0.07
        return segs.map { s in
            func stretch(_ n: Double) -> Double { min(max((n - 0.27) * 2.2, 0), 1) }
            let level = 0.10 + 0.52 * stretch(Self.noise(s.seed * 1.31, slow, 3.7))
            let top = 0.50 * stretch(Self.noise(s.seed * 2.17 + 11, slow * 1.3, 9.1))
            let bottom = 0.42 * stretch(Self.noise(s.seed * 0.73 + 5, slow * 1.1, 1.3))
            let dim = Self.lerp3(s.emphasis, 0.55, 1, 1)
            let density = min(max((level + 0.3 * (top + bottom) - 0.25) / 0.4, 0), 1)
            let lively = density + (1 - density) * s.energy
            let tint = (0.09 + 0.19 * lively) * Self.lerp3(s.emphasis, 0.45, 1, 1.15)
            return Field(level: level, top: top, bottom: bottom, boost: s.energy, dim: dim, tint: tint, glow: 0.45 + 0.55 * lively)
        }
    }

    private func currentClearEdge(_ l: Layout, bar: CGRect) -> (x: Double, rgb: RGB)? {
        if case .clearing(let id) = mode, let i = segs.firstIndex(where: { $0.id == id }), segs[i].shown > 0.0008 {
            return (min(l.xs[i + 1], Double(bar.maxX)), segs[i].rgb)
        }
        return nil
    }

    /// Visits every lit cell with its color. Shared by the live bitmap and the still renderer.
    func forEachLitCell(bar: CGRect, rows: Int, time: Double, _ body: (_ col: Int, _ row: Int, _ rgb: RGB, _ alpha: Double) -> Void) {
        let l = layout(bar: bar, rows: rows)
        guard l.filledWidth > 0.6 else { return }
        let p = Double(PX.pitch)
        let f = fields(time: time)
        let tq = floor(time * 10) / 10
        let slow = tq * 0.07
        let sparkleStep = Int32(truncatingIfNeeded: Int(floor(time * 2.5)))
        let edgeHeat = max(heat, pulse)
        let clearEdge = currentClearEdge(l, bar: bar)
        let heatWidth = 54.0
        let topSpan = Double(rows) * 0.34, bottomSpan = Double(rows) * 0.30

        var segIndex = 0
        for c in 0..<l.cols {
            let cx = l.gx + (Double(c) + 0.5) * p
            if cx > l.fillRight { break }
            while segIndex < segs.count - 1 && cx >= l.xs[segIndex + 1] { segIndex += 1 }
            if l.xs[segIndex + 1] - l.xs[segIndex] <= 0.4 { continue }
            let s = segs[segIndex]
            let field = f[segIndex]

            var h = 0.0
            if edgeHeat > 0.01 {
                let d = (l.fillRight - cx) / heatWidth
                if d < 1 { let k = 1 - d; h = edgeHeat * k * k * (3 - 2 * k) }
            }
            if let clearEdge, clearHeat > 0.01 {
                let d = abs(clearEdge.x - cx) / 13
                if d < 1 { h = max(h, clearHeat * (1 - d)) }
            }
            let ci = Int32(c)
            let litAlpha = Self.lerp3(s.emphasis, 0.42, 0.97, 1.0)

            for r in 0..<rows {
                let ri = Int32(r)
                var lit: Bool
                if h > 0.72 {
                    lit = true
                } else if r == rows - 1 {
                    lit = c % 2 == 0
                } else if r == 0 {
                    lit = c % 2 == 1
                } else if (c + r) % 2 == 0 {
                    // Every cell cycles through its own threshold at its own pace: that is the twinkle.
                    let u = (Self.hash(ci, ri, 17) + tq * (0.045 + 0.13 * Self.hash(ci, ri, 91))).truncatingRemainder(dividingBy: 1)
                    let low = Self.noise(Double(c) / 12 + s.seed, Double(r) / 7.5, slow * 2.2 + s.seed)
                    var d = field.level
                        + field.top * max(0, 1 - Double(r) / topSpan)
                        + field.bottom * max(0, (Double(r) - (Double(rows) - bottomSpan)) / bottomSpan)
                        + (low - 0.5) * 0.55
                    // Push toward all-or-nothing so cells gather into checker patches with quiet areas between.
                    let k = min(max((d - 0.30) / 0.30, 0), 1)
                    d = 0.035 + 0.965 * (k * k * (3 - 2 * k))
                    d = (d + (1 - d) * field.boost) * field.dim + h * 0.5
                    lit = u < d
                } else {
                    lit = false
                }
                guard lit else { continue }
                if h > 0.06 {
                    body(c, r, s.rgb.mixed(with: .white, (Double(min(3, Int(h * 4))) + 0.75) / 4), 1)
                } else if Self.hash(ci, ri, sparkleStep) > 0.9925 {
                    body(c, r, .white, 0.86)
                } else {
                    body(c, r, s.rgb, litAlpha)
                }
            }
        }
    }

    /// Writes the lit cells into a cols x rows RGBA8 premultiplied buffer, one pixel per cell.
    func fillCells(_ buffer: inout [UInt8], bar: CGRect, rows: Int, time: Double) {
        let cols = layout(bar: bar, rows: rows).cols
        let count = cols * rows * 4
        if buffer.count != count { buffer = [UInt8](repeating: 0, count: count) } else { buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        buffer.withUnsafeMutableBufferPointer { pointer in
            forEachLitCell(bar: bar, rows: rows, time: time) { c, r, rgb, alpha in
                let i = (r * cols + c) * 4
                pointer[i] = UInt8(min(255, rgb.r * alpha * 255))
                pointer[i + 1] = UInt8(min(255, rgb.g * alpha * 255))
                pointer[i + 2] = UInt8(min(255, rgb.b * alpha * 255))
                pointer[i + 3] = UInt8(min(255, alpha * 255))
            }
        }
    }

    /// Lit cells drawn as rects, for still renders.
    func drawCells(_ ctx: CGContext, bar: CGRect, rows: Int, time: Double) {
        let l = layout(bar: bar, rows: rows)
        guard l.filledWidth > 0.6 else { return }
        let p = Double(PX.pitch), side = p - 1.15
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil))
        ctx.clip()
        forEachLitCell(bar: bar, rows: rows, time: time) { c, r, rgb, alpha in
            ctx.setFillColor(Self.cg(rgb, alpha))
            ctx.fill(CGRect(x: l.gx + (Double(c) + 0.5) * p - side / 2, y: l.gy + (Double(r) + 0.5) * p - side / 2, width: side, height: side))
        }
        ctx.restoreGState()
    }

    /// Everything except the lit cells.
    func drawBase(_ ctx: CGContext, bar: CGRect, time: Double, rows: Int) {
        let dt = frameDt
        let p = Double(PX.pitch)
        let H = Double(bar.height), W = Double(bar.width)
        let l = layout(bar: bar, rows: rows)
        let xs = l.xs, fillRight = l.fillRight, filledWidth = l.filledWidth
        let trackPath = CGPath(roundedRect: bar, cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil)

        // 1. Empty track: fill, grid dots to the right of the filled part, hairline border.
        ctx.addPath(trackPath)
        ctx.setFillColor(Self.cg(RGB(0x1A1B1D)))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(trackPath)
        ctx.clip()
        var trackDots: [CGRect] = []
        trackDots.reserveCapacity(l.cols * rows)
        for c in 0..<l.cols {
            let cx = l.gx + (Double(c) + 0.5) * p
            if cx <= fillRight && filledWidth > 0.6 { continue }
            for r in 0..<rows {
                trackDots.append(CGRect(x: cx - 0.5, y: l.gy + (Double(r) + 0.5) * p - 0.5, width: 1, height: 1))
            }
        }
        ctx.setFillColor(Self.cg(.white, 0.075))
        ctx.fill(trackDots)
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: 0.25, dy: 0.25), cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil))
        ctx.setStrokeColor(Self.cg(.white, 0.075))
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        let clearEdge = currentClearEdge(l, bar: bar)
        if let clearEdge { spawnParticles(at: clearEdge.x, bar: bar, rgb: clearEdge.rgb, dt: dt) }

        guard filledWidth > 0.6 else {
            drawParticles(ctx)
            return
        }

        let atCapacity = Double(bar.maxX) - fillRight < 1
        let rightRadius: CGFloat = atCapacity ? PX.barRadius : 3
        let outlineRect = CGRect(x: bar.minX, y: bar.minY, width: filledWidth, height: H)
        let outline = Self.capsule(outlineRect, left: PX.barRadius, right: rightRadius)
        let strokeOutline = Self.capsule(outlineRect.insetBy(dx: 0.75, dy: 0.75), left: PX.barRadius - 0.75, right: max(rightRadius - 0.75, 0))
        let edgeHeat = max(heat, pulse)
        let f = fields(time: time)

        // 2. Glow behind the bar: stacked strokes per segment, plus halos at hot edges.
        for (i, s) in segs.enumerated() where xs[i + 1] - xs[i] > 0.4 {
            let strength = Self.lerp3(s.emphasis, 0.0, 0.62, 0.95) * f[i].glow
            guard strength > 0.01 else { continue }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: xs[i], y: Double(bar.minY) - 24, width: xs[i + 1] - xs[i], height: H + 48))
            for pass in Self.glowPasses {
                ctx.addPath(outline)
                ctx.setStrokeColor(Self.cg(s.rgb, pass.alpha * strength * 1.25))
                ctx.setLineWidth(pass.width)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        if edgeHeat > 0.01 {
            Self.halo(ctx, center: CGPoint(x: fillRight - 5, y: Double(bar.midY)), radiusX: 30, radiusY: H / 2 + 16, color: .white, alpha: 0.6 * edgeHeat)
        }
        if let clearEdge, clearHeat > 0.01 {
            Self.halo(ctx, center: CGPoint(x: clearEdge.x, y: Double(bar.midY)), radiusX: 15, radiusY: H / 2 + 10, color: clearEdge.rgb.mixed(with: .white, 0.7), alpha: 0.55 * clearHeat)
        }

        // 3. Tint and unlit dots, clipped to the filled shape. Lit cells are drawn over these by the cell layer.
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        for (i, s) in segs.enumerated() where xs[i + 1] - xs[i] > 0.4 {
            ctx.setFillColor(Self.cg(s.rgb, f[i].tint))
            ctx.fill(CGRect(x: xs[i], y: Double(bar.minY), width: xs[i + 1] - xs[i], height: H))
        }
        var dimRects = [[CGRect]](repeating: [], count: segs.count)
        var segIndex = 0
        let dimSide = 1.1
        for c in 0..<l.cols {
            let cx = l.gx + (Double(c) + 0.5) * p
            if cx > fillRight { break }
            while segIndex < segs.count - 1 && cx >= xs[segIndex + 1] { segIndex += 1 }
            if xs[segIndex + 1] - xs[segIndex] <= 0.4 { continue }
            for r in 0..<rows {
                dimRects[segIndex].append(CGRect(x: cx - dimSide / 2, y: l.gy + (Double(r) + 0.5) * p - dimSide / 2, width: dimSide, height: dimSide))
            }
        }
        for (i, s) in segs.enumerated() where !dimRects[i].isEmpty {
            ctx.setFillColor(Self.cg(s.rgb, Self.lerp3(s.emphasis, 0.16, 0.36, 0.46)))
            ctx.fill(dimRects[i])
        }
        ctx.restoreGState()

        // 4. Borders: each segment owns its slice of the outline; separators are neutral hairlines.
        for (i, s) in segs.enumerated() where xs[i + 1] - xs[i] > 0.4 {
            let isLast = !segs[(i + 1)...].contains(where: { $0.shown * W > 0.4 })
            var rgb = s.rgb
            if isLast && edgeHeat > 0.01 { rgb = rgb.mixed(with: .white, edgeHeat * 0.85) }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: xs[i], y: Double(bar.minY) - 2, width: xs[i + 1] - xs[i], height: H + 4))
            ctx.addPath(strokeOutline)
            ctx.setStrokeColor(Self.cg(rgb, Self.lerp3(s.emphasis, 0.36, 0.96, 1.0)))
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setStrokeColor(Self.cg(.white, highlight != nil ? 0.32 : 0.6))
        ctx.setLineWidth(0.6)
        for i in 1..<max(segs.count, 1) where xs[i] - xs[i - 1] > 0.4 && xs[i] < fillRight - 0.4 {
            ctx.move(to: CGPoint(x: xs[i], y: Double(bar.minY) + 1))
            ctx.addLine(to: CGPoint(x: xs[i], y: Double(bar.maxY) - 1))
        }
        ctx.strokePath()

        if let clearEdge, clearHeat > 0.01 {
            ctx.setStrokeColor(Self.cg(.white, 0.95 * clearHeat))
            ctx.setLineWidth(1.6)
            ctx.move(to: CGPoint(x: clearEdge.x, y: Double(bar.minY) + 0.5))
            ctx.addLine(to: CGPoint(x: clearEdge.x, y: Double(bar.maxY) - 0.5))
            ctx.strokePath()
        }

        drawParticles(ctx)
    }

    private func drawParticles(_ ctx: CGContext) {
        for particle in particles {
            let t = particle.age / particle.life
            let alpha = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85
            ctx.setFillColor(Self.cg(particle.rgb, max(0, alpha) * 0.95))
            ctx.fill(CGRect(x: particle.x - particle.size / 2, y: particle.y - particle.size / 2, width: particle.size, height: particle.size))
        }
    }

    // MARK: Layer renderer inputs

    /// One frame of the base, described as geometry and colours instead of drawn. Mirrors `drawBase` step by step.
    struct LiveFrame {
        struct Slice {
            var x0: Double
            var x1: Double
            var rgb: RGB
            /// Alpha of the colour under the glow sprite; 0 when the glow is too weak to show.
            var glow: Double
            var tint: Double
            var borderRGB: RGB
            var borderAlpha: Double
        }

        var layout: Layout
        var filled: Bool
        var rightRadius: CGFloat
        var slices: [Slice] = []
        var separators: [Double] = []
        var separatorAlpha = 0.6
        /// Alpha of the white halo at the fill's leading edge.
        var hotHalo = 0.0
        var clearX: Double?
        var clearRGB = RGB.white
        var clearHeat = 0.0
        /// Columns from this one on show the empty track's dots.
        var trackFromColumn = 0
    }

    func liveFrame(bar: CGRect, rows: Int, time: Double) -> LiveFrame {
        let l = layout(bar: bar, rows: rows)
        let p = Double(PX.pitch)
        let W = Double(bar.width)
        let filled = l.filledWidth > 0.6
        let atCapacity = Double(bar.maxX) - l.fillRight < 1
        var frame = LiveFrame(layout: l, filled: filled, rightRadius: atCapacity ? PX.barRadius : 3)
        if filled {
            var column = 0
            while column < l.cols, l.gx + (Double(column) + 0.5) * p <= l.fillRight { column += 1 }
            frame.trackFromColumn = column
        }

        let clearEdge = currentClearEdge(l, bar: bar)
        if let clearEdge { spawnParticles(at: clearEdge.x, bar: bar, rgb: clearEdge.rgb, dt: frameDt) }
        guard filled else { return frame }

        let edgeHeat = max(heat, pulse)
        let f = fields(time: time)
        for (i, s) in segs.enumerated() where l.xs[i + 1] - l.xs[i] > 0.4 {
            let strength = Self.lerp3(s.emphasis, 0.0, 0.62, 0.95) * f[i].glow
            let isLast = !segs[(i + 1)...].contains(where: { $0.shown * W > 0.4 })
            var border = s.rgb
            if isLast && edgeHeat > 0.01 { border = border.mixed(with: .white, edgeHeat * 0.85) }
            frame.slices.append(LiveFrame.Slice(
                x0: l.xs[i], x1: l.xs[i + 1], rgb: s.rgb,
                glow: strength > 0.01 ? Self.glowAlpha(strength) : 0,
                tint: f[i].tint,
                borderRGB: border, borderAlpha: Self.lerp3(s.emphasis, 0.36, 0.96, 1.0)
            ))
        }
        for i in 1..<max(segs.count, 1) where l.xs[i] - l.xs[i - 1] > 0.4 && l.xs[i] < l.fillRight - 0.4 {
            frame.separators.append(l.xs[i])
        }
        frame.separatorAlpha = highlight != nil ? 0.32 : 0.6
        if edgeHeat > 0.01 { frame.hotHalo = 0.6 * edgeHeat }
        if let clearEdge, clearHeat > 0.01 {
            frame.clearX = clearEdge.x
            frame.clearRGB = clearEdge.rgb
            frame.clearHeat = clearHeat
        }
        return frame
    }

    /// The glow sprite is baked at full strength. A colour layer at this alpha under it gives what the stacked
    /// strokes give at `strength`, exactly where all of them overlap and within a few percent elsewhere.
    private static func glowAlpha(_ strength: Double) -> Double {
        func combined(_ u: Double) -> Double { 1 - glowPasses.reduce(1.0) { $0 * (1 - min(1, $1.alpha * u)) } }
        return min(1, combined(strength * 1.25) / combined(1.25))
    }

    /// Colour of the unlit dot in each filled column, one pixel per column.
    func fillDims(_ buffer: inout [UInt8], layout l: Layout) {
        let count = l.cols * 4
        if buffer.count != count { buffer = [UInt8](repeating: 0, count: count) } else { buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard l.filledWidth > 0.6 else { return }
        let p = Double(PX.pitch)
        var segIndex = 0
        for c in 0..<l.cols {
            let cx = l.gx + (Double(c) + 0.5) * p
            if cx > l.fillRight { break }
            while segIndex < segs.count - 1 && cx >= l.xs[segIndex + 1] { segIndex += 1 }
            if l.xs[segIndex + 1] - l.xs[segIndex] <= 0.4 { continue }
            let s = segs[segIndex]
            let alpha = Self.lerp3(s.emphasis, 0.16, 0.36, 0.46)
            buffer[c * 4] = UInt8(min(255, s.rgb.r * alpha * 255 + 0.5))
            buffer[c * 4 + 1] = UInt8(min(255, s.rgb.g * alpha * 255 + 0.5))
            buffer[c * 4 + 2] = UInt8(min(255, s.rgb.b * alpha * 255 + 0.5))
            buffer[c * 4 + 3] = UInt8(min(255, alpha * 255 + 0.5))
        }
    }

    /// Writes the particles into an RGBA8 premultiplied buffer that covers only their bounding box, with the same
    /// edge coverage CoreGraphics gives a filled rect. Returns the box in pixels from the top left, or nil.
    func rasterizeParticles(into buffer: inout [UInt8], scale: Double, limit: CGSize) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard !particles.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for particle in particles {
            let half = particle.size / 2
            minX = min(minX, particle.x - half); maxX = max(maxX, particle.x + half)
            minY = min(minY, particle.y - half); maxY = max(maxY, particle.y + half)
        }
        let x0 = max(0, Int((minX * scale).rounded(.down))), y0 = max(0, Int((minY * scale).rounded(.down)))
        let x1 = min(Int((Double(limit.width) * scale).rounded(.up)), Int((maxX * scale).rounded(.up)))
        let y1 = min(Int((Double(limit.height) * scale).rounded(.up)), Int((maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        let w = x1 - x0, h = y1 - y0
        let count = w * h * 4
        if buffer.count != count { buffer = [UInt8](repeating: 0, count: count) } else { buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        buffer.withUnsafeMutableBufferPointer { out in
            for particle in particles {
                let t = particle.age / particle.life
                let fade = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85
                let alpha = max(0, fade) * 0.95
                guard alpha > 0.002 else { continue }
                let half = particle.size / 2
                let left = (particle.x - half) * scale - Double(x0), right = (particle.x + half) * scale - Double(x0)
                let top = (particle.y - half) * scale - Double(y0), bottom = (particle.y + half) * scale - Double(y0)
                let px0 = max(0, Int(left.rounded(.down))), px1 = min(w, Int(right.rounded(.up)))
                let py0 = max(0, Int(top.rounded(.down))), py1 = min(h, Int(bottom.rounded(.up)))
                guard px1 > px0, py1 > py0 else { continue }
                let r = particle.rgb.r * 255, g = particle.rgb.g * 255, b = particle.rgb.b * 255
                for py in py0..<py1 {
                    let cy = min(bottom, Double(py + 1)) - max(top, Double(py))
                    guard cy > 0 else { continue }
                    for px in px0..<px1 {
                        let cx = min(right, Double(px + 1)) - max(left, Double(px))
                        guard cx > 0 else { continue }
                        let k = alpha * cx * cy, keep = 1 - k
                        let i = (py * w + px) * 4
                        out[i] = UInt8(min(255, r * k + Double(out[i]) * keep + 0.5))
                        out[i + 1] = UInt8(min(255, g * k + Double(out[i + 1]) * keep + 0.5))
                        out[i + 2] = UInt8(min(255, b * k + Double(out[i + 2]) * keep + 0.5))
                        out[i + 3] = UInt8(min(255, 255 * k + Double(out[i + 3]) * keep + 0.5))
                    }
                }
            }
        }
        return (x0, y0, w, h)
    }

    // MARK: Sprites for the layer renderer

    /// Draws into a fresh 8-bit sRGB bitmap using top-left point coordinates.
    fileprivate static func bitmap(width: Int, height: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        return ctx.makeImage()
    }

    /// The filled shape, its glow and its border as masks. Made once and stretched along the bar, or made for one
    /// exact width when the fill is too narrow to have a straight middle.
    struct FrameSprites {
        var fill: CGImage
        var glow: CGImage
        var border: CGImage
        /// Size in points. The sprite starts at the bar's left edge and `pad` above its top.
        var size: CGSize
        var pad: CGFloat
        /// Unit rect of the strip that stretches.
        var center: CGRect
    }

    /// How much of each end must stay unstretched: the corner, or the reach of the widest glow stroke.
    static func spriteCaps(rightRadius: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let reach = (glowPasses.map(\.width).max() ?? 14) / 2
        return (max(PX.barRadius, reach).rounded(.up) + 1, max(rightRadius, reach).rounded(.up) + 1)
    }

    static func frameSprites(exactWidth: CGFloat?, height: CGFloat, rightRadius: CGFloat, scale: CGFloat) -> FrameSprites? {
        let pad: CGFloat = 8
        let caps = spriteCaps(rightRadius: rightRadius)
        let middle: CGFloat = 2
        let width = exactWidth ?? caps.left + middle + caps.right
        let pw = Int((width * scale).rounded(.up)), ph = Int(((height + pad * 2) * scale).rounded(.up))
        let outlineRect = CGRect(x: 0, y: pad, width: width, height: height)
        let outline = capsule(outlineRect, left: PX.barRadius, right: rightRadius)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

        let fill = bitmap(width: pw, height: ph, scale: scale) { ctx in
            ctx.addPath(outline)
            ctx.setFillColor(white)
            ctx.fillPath()
        }
        let glow = bitmap(width: pw, height: ph, scale: scale) { ctx in
            for pass in glowPasses {
                ctx.addPath(outline)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: min(1, pass.alpha * 1.25)))
                ctx.setLineWidth(pass.width)
                ctx.strokePath()
            }
        }
        let border = bitmap(width: pw, height: ph, scale: scale) { ctx in
            guard width > 1.6 else { return }
            ctx.addPath(capsule(outlineRect.insetBy(dx: 0.75, dy: 0.75), left: PX.barRadius - 0.75, right: max(rightRadius - 0.75, 0)))
            ctx.setStrokeColor(white)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        guard let fill, let glow, let border else { return nil }
        let size = CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        let center = exactWidth == nil ? CGRect(x: caps.left / size.width, y: 0, width: middle / size.width, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
        return FrameSprites(fill: fill, glow: glow, border: border, size: size, pad: pad, center: center)
    }

    /// The elliptical halo at full strength; the layer's opacity sets how strong it is.
    static func haloSprite(radiusX: CGFloat, radiusY: CGFloat, color: RGB, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let pw = Int((radiusX * 2 * scale).rounded(.up)), ph = Int((radiusY * 2 * scale).rounded(.up))
        let size = CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        guard let image = bitmap(width: pw, height: ph, scale: scale, { ctx in
            halo(ctx, center: CGPoint(x: size.width / 2, y: size.height / 2), radiusX: radiusX, radiusY: radiusY, color: color, alpha: 1)
        }) else { return nil }
        return (image, size)
    }

    /// A white vertical line `width` points wide with antialiased edges, one pixel tall, stretched along its length.
    /// Bilinear sampling then gives it the right coverage wherever it sits between pixels.
    static func lineSprite(width: CGFloat, scale: CGFloat) -> (image: CGImage, width: CGFloat)? {
        let pw = Int((width * scale).rounded(.up)) + 4
        guard let image = bitmap(width: pw, height: 1, scale: 1, { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: (CGFloat(pw) - width * scale) / 2, y: 0, width: width * scale, height: 1))
        }) else { return nil }
        return (image, CGFloat(pw) / scale)
    }

    // MARK: Math

    /// Piecewise-linear lookup for the three emphasis levels (dimmed, resting, highlighted).
    static func lerp3(_ e: Double, _ dim: Double, _ rest: Double, _ high: Double) -> Double {
        e < 0.5 ? dim + (rest - dim) * (e / 0.5) : rest + (high - rest) * ((e - 0.5) / 0.5)
    }

    @inline(__always)
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Double {
        var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263 &+ UInt32(bitPattern: z) &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
    }

    /// Smooth value noise in 0...1; gives the lit cells their drifting, clustered look.
    static func noise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xf = floor(x), yf = floor(y), zf = floor(z)
        let xi = Int32(truncatingIfNeeded: Int(xf)), yi = Int32(truncatingIfNeeded: Int(yf)), zi = Int32(truncatingIfNeeded: Int(zf))
        var tx = x - xf, ty = y - yf, tz = z - zf
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty); tz = tz * tz * (3 - 2 * tz)
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let a = mix(mix(hash(xi, yi, zi), hash(xi &+ 1, yi, zi), tx), mix(hash(xi, yi &+ 1, zi), hash(xi &+ 1, yi &+ 1, zi), tx), ty)
        let b = mix(mix(hash(xi, yi, zi &+ 1), hash(xi &+ 1, yi, zi &+ 1), tx), mix(hash(xi, yi &+ 1, zi &+ 1), hash(xi &+ 1, yi &+ 1, zi &+ 1), tx), ty)
        return mix(a, b, tz)
    }
}

/// One 10 Hz timer for every resting bar, so they all update in the same display pass.
@MainActor
final class MatrixTicker {
    static let shared = MatrixTicker()
    private let views = NSHashTable<MatrixLayerView>.weakObjects()
    private var timer: Timer?

    func add(_ view: MatrixLayerView) {
        views.add(view)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func remove(_ view: MatrixLayerView) {
        views.remove(view)
        if views.count == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func fire() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in views.allObjects { view.tick() }
        CATransaction.commit()
        if views.count == 0 {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// The bar's base as layers. Nothing here is rasterized per frame except the particles of a clear, which are
/// written straight into a small bitmap. Positions and colours are layer
/// properties; the glow, the border and the filled shape are stretchable sprites used as masks over plain colour
/// layers, one per segment. The GPU does the rest.
@MainActor
final class MatrixLiveLayers {
    let root = CALayer()
    private let track = CALayer()
    private let trackDotsClip = CALayer()
    private let trackDots = CALayer()
    private let glowHost = CALayer()
    private let glowMask = CALayer()
    private let hotHalo = CALayer()
    private let clearHalo = CALayer()
    private let tintHost = CALayer()
    private let fillMask = CALayer()
    private let dims = CALayer()
    private let dimMask = CALayer()
    private let borderHost = CALayer()
    private let borderMask = CALayer()
    private let separatorHost = CALayer()
    private let clearLine = CALayer()
    private let particles = CALayer()

    private var glowSlices: [CALayer] = []
    private var tintSlices: [CALayer] = []
    private var borderSlices: [CALayer] = []
    private var separators: [CALayer] = []

    private var staticKey = ""
    private var spriteKey = ""
    private var clearHaloKey = ""
    private var sprites: MatrixEngine.FrameSprites?
    private var trackSize = CGSize.zero
    private var hotHaloSize = CGSize.zero
    private var clearHaloSize = CGSize.zero
    private var separatorImage: CGImage?
    private var separatorWidth: CGFloat = 0
    private var clearLineWidth: CGFloat = 0
    private var dimBuffer: [UInt8] = []
    private var particleBuffer: [UInt8] = []

    init() {
        root.masksToBounds = true
        root.isHidden = true
        trackDotsClip.masksToBounds = true
        trackDotsClip.addSublayer(trackDots)
        glowHost.mask = glowMask
        tintHost.mask = fillMask
        borderHost.mask = borderMask
        dims.mask = dimMask
        dims.magnificationFilter = .nearest
        dims.minificationFilter = .nearest
        dims.contentsGravity = .resize
        clearLine.contentsGravity = .resize
        // Back to front, in the order `drawBase` paints.
        for layer in [track, trackDotsClip, glowHost, hotHalo, clearHalo, tintHost, dims, borderHost, separatorHost, clearLine, particles] {
            root.addSublayer(layer)
        }
    }

    /// Call inside a transaction with actions disabled.
    func update(_ f: MatrixEngine.LiveFrame, engine: MatrixEngine, bar: CGRect, rows: Int, bounds: CGRect, scale: CGFloat) {
        let viewHeight = bounds.height
        // The engine works from the top left; these layers are positioned from the bottom left.
        func place(_ layer: CALayer, _ r: CGRect) {
            layer.frame = CGRect(x: r.minX, y: viewHeight - r.maxY, width: r.width, height: r.height)
        }
        let l = f.layout
        let p = PX.pitch
        let H = bar.height
        root.frame = bounds
        let full = CGRect(origin: .zero, size: bounds.size)

        let key = "\(bounds.width)x\(bounds.height)|\(rows)|\(scale)"
        if key != staticKey {
            staticKey = key
            rebuildStatics(bar: bar, layout: l, rows: rows, scale: scale)
        }

        // Empty track, and its dots from the first column the fill has not reached.
        let trackRect = CGRect(origin: bar.origin, size: trackSize)
        place(track, trackRect)
        let clipX = CGFloat(l.gx) + CGFloat(f.trackFromColumn) * p
        place(trackDotsClip, CGRect(x: clipX, y: bar.minY, width: max(0, trackRect.maxX - clipX), height: trackRect.height))
        trackDots.frame = CGRect(x: bar.minX - clipX, y: 0, width: trackRect.width, height: trackRect.height)

        let filled = f.filled
        for layer in [glowHost, tintHost, dims, borderHost, separatorHost] { layer.isHidden = !filled }
        if filled {
            let filledWidth = CGFloat(l.filledWidth)
            let caps = MatrixEngine.spriteCaps(rightRadius: f.rightRadius)
            let narrow = filledWidth < caps.left + caps.right
            // A narrow fill gets sprites made for its exact width, to a quarter pixel. Anything wider stretches one set.
            let exact = (filledWidth * scale * 4).rounded() / (scale * 4)
            let wanted = narrow ? "n\(exact)|\(f.rightRadius)|\(H)|\(scale)" : "w|\(f.rightRadius)|\(H)|\(scale)"
            if wanted != spriteKey, let made = MatrixEngine.frameSprites(exactWidth: narrow ? exact : nil, height: H, rightRadius: f.rightRadius, scale: scale) {
                spriteKey = wanted
                sprites = made
                for (mask, image) in [(glowMask, made.glow), (fillMask, made.fill), (borderMask, made.border)] {
                    mask.contents = image
                    mask.contentsScale = scale
                    mask.contentsCenter = made.center
                }
            }
            if let sprites {
                let maskRect = CGRect(x: bar.minX, y: bar.minY - sprites.pad, width: narrow ? sprites.size.width : filledWidth, height: sprites.size.height)
                for host in [glowHost, tintHost, borderHost] { host.frame = full }
                for mask in [glowMask, fillMask, borderMask] { place(mask, maskRect) }
            }

            resize(&glowSlices, to: f.slices.count, in: glowHost)
            resize(&tintSlices, to: f.slices.count, in: tintHost)
            resize(&borderSlices, to: f.slices.count, in: borderHost)
            for (i, s) in f.slices.enumerated() {
                let x = CGFloat(s.x0), w = CGFloat(s.x1 - s.x0)
                place(glowSlices[i], CGRect(x: x, y: bar.minY - 24, width: w, height: H + 48))
                glowSlices[i].backgroundColor = MatrixEngine.cg(s.rgb, s.glow)
                place(tintSlices[i], CGRect(x: x, y: bar.minY, width: w, height: H))
                tintSlices[i].backgroundColor = MatrixEngine.cg(s.rgb, s.tint)
                place(borderSlices[i], CGRect(x: x, y: bar.minY - 2, width: w, height: H + 4))
                borderSlices[i].backgroundColor = MatrixEngine.cg(s.borderRGB, s.borderAlpha)
            }

            // Unlit dots: one pixel per column, scaled up through a mask that gives each dot its shape.
            place(dims, CGRect(x: CGFloat(l.gx), y: CGFloat(l.gy), width: CGFloat(l.cols) * p, height: CGFloat(rows) * p))
            dimMask.frame = dims.bounds
            engine.fillDims(&dimBuffer, layout: l)
            dims.contents = Self.image(dimBuffer, width: l.cols, height: 1)

            separatorHost.frame = full
            resize(&separators, to: f.separators.count, in: separatorHost)
            for (i, x) in f.separators.enumerated() {
                let layer = separators[i]
                if layer.contents == nil {
                    layer.contents = separatorImage
                    layer.contentsGravity = .resize
                }
                place(layer, CGRect(x: CGFloat(x) - separatorWidth / 2, y: bar.minY + 1, width: separatorWidth, height: H - 2))
                layer.opacity = Float(f.separatorAlpha)
            }
        }

        if filled, f.hotHalo > 0.01 {
            hotHalo.isHidden = false
            place(hotHalo, CGRect(x: CGFloat(l.fillRight) - 5 - hotHaloSize.width / 2, y: bar.midY - hotHaloSize.height / 2, width: hotHaloSize.width, height: hotHaloSize.height))
            hotHalo.opacity = Float(f.hotHalo)
        } else {
            hotHalo.isHidden = true
        }

        if filled, let clearX = f.clearX {
            let tone = f.clearRGB.mixed(with: .white, 0.7)
            let haloKey = "\(tone.r),\(tone.g),\(tone.b)|\(H)|\(scale)"
            if haloKey != clearHaloKey, let made = MatrixEngine.haloSprite(radiusX: 15, radiusY: H / 2 + 10, color: tone, scale: scale) {
                clearHaloKey = haloKey
                clearHalo.contents = made.image
                clearHaloSize = made.size
            }
            clearHalo.isHidden = false
            place(clearHalo, CGRect(x: CGFloat(clearX) - clearHaloSize.width / 2, y: bar.midY - clearHaloSize.height / 2, width: clearHaloSize.width, height: clearHaloSize.height))
            clearHalo.opacity = Float(0.55 * f.clearHeat)
            clearLine.isHidden = false
            place(clearLine, CGRect(x: CGFloat(clearX) - clearLineWidth / 2, y: bar.minY + 0.5, width: clearLineWidth, height: H - 1))
            clearLine.opacity = Float(0.95 * f.clearHeat)
        } else {
            clearHalo.isHidden = true
            clearLine.isHidden = true
        }

        if let box = engine.rasterizeParticles(into: &particleBuffer, scale: Double(scale), limit: bounds.size) {
            particles.isHidden = false
            particles.contents = Self.image(particleBuffer, width: box.width, height: box.height)
            particles.frame = CGRect(
                x: CGFloat(box.x) / scale, y: viewHeight - CGFloat(box.y + box.height) / scale,
                width: CGFloat(box.width) / scale, height: CGFloat(box.height) / scale
            )
        } else {
            particles.isHidden = true
            particles.contents = nil
        }
    }

    /// Drops every bitmap. Only the CoreGraphics debug renderer has a use for this.
    func release() {
        for layer in [track, trackDots, glowMask, fillMask, borderMask, dims, dimMask, hotHalo, clearHalo, clearLine, particles] + separators {
            layer.contents = nil
        }
        sprites = nil
        separatorImage = nil
        staticKey = ""
        spriteKey = ""
        clearHaloKey = ""
        dimBuffer = []
        particleBuffer = []
    }

    private func resize(_ layers: inout [CALayer], to count: Int, in host: CALayer) {
        while layers.count < count {
            let layer = CALayer()
            host.addSublayer(layer)
            layers.append(layer)
        }
        for (i, layer) in layers.enumerated() { layer.isHidden = i >= count }
    }

    /// Everything that only depends on the bar's size: the empty track, all of its dots, the shape of the unlit
    /// dots, and the small sprites for halos and hairlines.
    private func rebuildStatics(bar: CGRect, layout l: MatrixEngine.Layout, rows: Int, scale: CGFloat) {
        let p = PX.pitch
        let pw = Int((bar.width * scale).rounded(.up)), ph = Int((bar.height * scale).rounded(.up))
        trackSize = CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        let local = CGRect(origin: .zero, size: bar.size)
        let trackPath = CGPath(roundedRect: local, cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil)
        let gridX = CGFloat(l.gx) - bar.minX, gridY = CGFloat(l.gy) - bar.minY

        track.contents = MatrixEngine.bitmap(width: pw, height: ph, scale: scale) { ctx in
            ctx.addPath(trackPath)
            ctx.setFillColor(MatrixEngine.cg(RGB(0x1A1B1D)))
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: local.insetBy(dx: 0.25, dy: 0.25), cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil))
            ctx.setStrokeColor(MatrixEngine.cg(.white, 0.075))
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
        trackDots.contents = MatrixEngine.bitmap(width: pw, height: ph, scale: scale) { ctx in
            ctx.addPath(trackPath)
            ctx.clip()
            var rects: [CGRect] = []
            rects.reserveCapacity(l.cols * rows)
            for c in 0..<l.cols {
                for r in 0..<rows {
                    rects.append(CGRect(x: gridX + (CGFloat(c) + 0.5) * p - 0.5, y: gridY + (CGFloat(r) + 0.5) * p - 0.5, width: 1, height: 1))
                }
            }
            ctx.setFillColor(MatrixEngine.cg(.white, 0.075))
            ctx.fill(rects)
        }
        let gw = Int((CGFloat(l.cols) * p * scale).rounded(.up)), gh = Int((CGFloat(rows) * p * scale).rounded(.up))
        dimMask.contents = MatrixEngine.bitmap(width: gw, height: gh, scale: scale) { ctx in
            ctx.addPath(CGPath(roundedRect: local.offsetBy(dx: -gridX, dy: -gridY), cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil))
            ctx.clip()
            let side: CGFloat = 1.1
            var rects: [CGRect] = []
            rects.reserveCapacity(l.cols * rows)
            for c in 0..<l.cols {
                for r in 0..<rows {
                    rects.append(CGRect(x: (CGFloat(c) + 0.5) * p - side / 2, y: (CGFloat(r) + 0.5) * p - side / 2, width: side, height: side))
                }
            }
            ctx.setFillColor(MatrixEngine.cg(.white))
            ctx.fill(rects)
        }
        for layer in [track, trackDots, dimMask] { layer.contentsScale = scale }

        if let made = MatrixEngine.haloSprite(radiusX: 30, radiusY: bar.height / 2 + 16, color: .white, scale: scale) {
            hotHalo.contents = made.image
            hotHaloSize = made.size
        }
        if let made = MatrixEngine.lineSprite(width: 0.6, scale: scale) {
            separatorImage = made.image
            separatorWidth = made.width
        }
        if let made = MatrixEngine.lineSprite(width: 1.6, scale: scale) {
            clearLine.contents = made.image
            clearLineWidth = made.width
        }
        for layer in separators { layer.contents = nil }
        spriteKey = ""
        clearHaloKey = ""
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Wraps an RGBA8 premultiplied buffer, first row at the top.
    private static func image(_ buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, buffer.count >= width * height * 4, let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// The bar itself: layers composited by the GPU. See the note above `MatrixEngine.Layout`.
final class MatrixLayerView: NSView {
    static let marginX: CGFloat = 14
    static let marginTop: CGFloat = 54
    static let marginBottom: CGFloat = 14

    static func barHeight(rows: Int) -> CGFloat { CGFloat(rows) * PX.pitch + 1 }

    var segments: [MatrixSegment] = []
    var capacity = 1.0
    var highlight: String?
    var mode: MatrixMode = .rest
    var rows = PX.fullRows
    var active = true {
        didSet { if active != oldValue { reschedule() } }
    }

    private let engine = MatrixEngine()
    private let baseLayer = CALayer()
    private let cellLayer = CALayer()
    private let maskLayer = CALayer()
    private var cellBuffer: [UInt8] = []
    private var shownCells: [UInt8] = []
    private var maskKey = ""
    private var baseContext: CGContext?
    private var lastBase = 0.0
    private var fast = false
    private var link: CADisplayLink?
    private var ticking = false
    private let live = MatrixLiveLayers()
    private var isLive = false

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    /// Debug: DOTMETER_BAR=cg draws the base with CoreGraphics instead of compositing it from layers (how a resting
    /// bar used to work), to compare the two pictures.
    private static let renderer = ProcessInfo.processInfo.environment["DOTMETER_BAR"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let quiet: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        for sublayer in [baseLayer, cellLayer, maskLayer] { sublayer.actions = quiet }
        cellLayer.magnificationFilter = .nearest
        cellLayer.minificationFilter = .nearest
        cellLayer.contentsGravity = .resize
        cellLayer.mask = maskLayer
        layer?.addSublayer(baseLayer)
        layer?.addSublayer(live.root)
        layer?.addSublayer(cellLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reschedule()
    }

    override func layout() {
        super.layout()
        update(force: true)
    }

    func inputsChanged() {
        update(force: true)
    }

    func tick() {
        update(force: false)
    }

    /// 60 fps from a display link while something big is moving, otherwise the shared 10 Hz tick.
    private func reschedule() {
        link?.invalidate()
        link = nil
        if ticking { MatrixTicker.shared.remove(self); ticking = false }
        guard active, window != nil else { return }
        if fast {
            let link = displayLink(target: self, selector: #selector(frameTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            MatrixTicker.shared.add(self)
            ticking = true
        }
        update(force: true)
    }

    @objc private func frameTick() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update(force: false)
        CATransaction.commit()
    }

    private func update(force: Bool) {
        guard bounds.width > Self.marginX * 2 + 8, bounds.height > 4 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let now = CACurrentMediaTime()
        // Layer changes here are positions and colours that must land at once, never as implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        engine.sync(segments, capacity: capacity, highlight: highlight, mode: mode, animateIn: !PX.staticRender)
        let state = engine.step(now: now)
        // Top-left coordinates, as the engine draws.
        let bar = CGRect(x: Self.marginX, y: Self.marginTop, width: bounds.width - Self.marginX * 2, height: Self.barHeight(rows: rows))

        if Self.renderer != "cg" {
            // The base is layers, so nothing is rasterized here: positions and colours are set again only when
            // something in the base changed. At rest that is a few times after each new reading, and once every
            // two seconds for the slow drift of tint and glow. The lit cells twinkle on their own layer below.
            if force || state.changed || !isLive || now - lastBase > 2 {
                live.update(engine.liveFrame(bar: bar, rows: rows, time: now), engine: engine, bar: bar, rows: rows, bounds: bounds, scale: scale)
                lastBase = now
                DrawCounter.base()
            }
            if !isLive {
                isLive = true
                live.root.isHidden = false
                baseLayer.isHidden = true
                baseLayer.contents = nil
                baseContext = nil
            }
        } else {
            // Debug only (DOTMETER_BAR=cg): the base drawn with CoreGraphics, the reference for the look.
            if force || state.changed || isLive || now - lastBase > 2 {
                redrawBase(bar: bar, time: now, scale: scale)
                lastBase = now
                DrawCounter.base()
            }
            if isLive {
                isLive = false
                baseLayer.isHidden = false
                live.root.isHidden = true
                live.release()
            }
        }
        redrawCells(bar: bar, time: now, scale: scale)
        DrawCounter.tick()

        if state.moving != fast {
            fast = state.moving
            DispatchQueue.main.async { [weak self] in self?.reschedule() }
        }
    }

    private func redrawBase(bar: CGRect, time: Double, scale: CGFloat) {
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        if baseContext?.width != w || baseContext?.height != h {
            baseContext = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo)
        }
        guard let ctx = baseContext else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        engine.drawBase(ctx, bar: bar, time: time, rows: rows)
        ctx.restoreGState()
        baseLayer.frame = bounds
        baseLayer.contentsScale = scale
        baseLayer.contents = ctx.makeImage()
    }

    private func redrawCells(bar: CGRect, time: Double, scale: CGFloat) {
        let l = engine.layout(bar: bar, rows: rows)
        let p = PX.pitch
        let gridWidth = CGFloat(l.cols) * p, gridHeight = CGFloat(rows) * p
        // This view is not flipped, so convert the grid's top-left origin to bottom-left.
        cellLayer.frame = CGRect(x: l.gx, y: bounds.height - CGFloat(l.gy) - gridHeight, width: gridWidth, height: gridHeight)

        engine.fillCells(&cellBuffer, bar: bar, rows: rows, time: time)
        // An empty or nearly empty bar shows the same cells tick after tick: leave the layer alone then.
        if cellBuffer != shownCells || cellLayer.contents == nil, let provider = CGDataProvider(data: Data(cellBuffer) as CFData) {
            shownCells = cellBuffer
            cellLayer.contents = CGImage(
                width: l.cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: l.cols * 4,
                space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }

        // The mask gives every cell its square shape and rounds the bar's ends. It only depends on the geometry.
        let key = "\(l.cols)x\(rows)@\(scale)|\(bar.width)"
        if key != maskKey {
            maskKey = key
            let w = Int((gridWidth * scale).rounded(.up)), h = Int((gridHeight * scale).rounded(.up))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                let track = bar.offsetBy(dx: -CGFloat(l.gx), dy: -CGFloat(l.gy))
                ctx.addPath(CGPath(roundedRect: track, cornerWidth: PX.barRadius, cornerHeight: PX.barRadius, transform: nil))
                ctx.clip()
                let side = p - 1.15
                var rects: [CGRect] = []
                rects.reserveCapacity(l.cols * rows)
                for c in 0..<l.cols {
                    for r in 0..<rows {
                        rects.append(CGRect(x: (CGFloat(c) + 0.5) * p - side / 2, y: (CGFloat(r) + 0.5) * p - side / 2, width: side, height: side))
                    }
                }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(rects)
                maskLayer.contents = ctx.makeImage()
            }
            maskLayer.contentsScale = scale
        }
        maskLayer.frame = cellLayer.bounds
    }

    /// Still image of a settled bar, for offscreen renders that cannot host AppKit views.
    static func stillImage(segments: [MatrixSegment], capacity: Double, highlight: String?, mode: MatrixMode, rows: Int, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let engine = MatrixEngine()
        engine.sync(segments, capacity: capacity, highlight: highlight, mode: mode, animateIn: false)
        engine.settle()
        let bar = CGRect(x: marginX, y: marginTop, width: size.width - marginX * 2, height: barHeight(rows: rows))
        engine.drawBase(ctx, bar: bar, time: 1000, rows: rows)
        engine.drawCells(ctx, bar: bar, rows: rows, time: 1000)
        return ctx.makeImage()
    }
}

struct MatrixCanvasHost: NSViewRepresentable {
    var segments: [MatrixSegment]
    var capacity: Double
    var highlight: String?
    var mode: MatrixMode
    var rows: Int
    var active: Bool

    func makeNSView(context: Context) -> MatrixLayerView {
        let view = MatrixLayerView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MatrixLayerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MatrixLayerView) {
        var changed = false
        if view.segments != segments { view.segments = segments; changed = true }
        if view.capacity != capacity { view.capacity = capacity; changed = true }
        if view.highlight != highlight { view.highlight = highlight; changed = true }
        if view.mode != mode { view.mode = mode; changed = true }
        if view.rows != rows { view.rows = rows; changed = true }
        if view.active != active { view.active = active }
        if changed { view.inputsChanged() }
    }
}

/// The segmented dot-matrix bar as cards use it: lays out the bar, hosts the renderer, reports hover.
struct MatrixBar: View {
    var segments: [MatrixSegment]
    var capacity: Double
    var highlight: String?
    var mode: MatrixMode = .rest
    var rows: Int = PX.fullRows
    var onHover: (String?) -> Void = { _ in }
    var onTap: (String) -> Void = { _ in }

    @Environment(\.pxActivity) private var activity
    @State private var width: CGFloat = 1

    var body: some View {
        let height = MatrixLayerView.barHeight(rows: rows)
        Color.clear
            .frame(height: height)
            .overlay {
                GeometryReader { geo in
                    let size = CGSize(width: geo.size.width + MatrixLayerView.marginX * 2, height: height + MatrixLayerView.marginTop + MatrixLayerView.marginBottom)
                    renderer(size: size)
                        .frame(width: size.width, height: size.height)
                        .offset(x: -MatrixLayerView.marginX, y: -MatrixLayerView.marginTop)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    onHover(segmentID(atFraction: Double(point.x)))
                case .ended:
                    onHover(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                if let id = segmentID(atFraction: Double(tap.location.x)) { onTap(id) }
            })
            .background(WidthReader(width: $width))
    }

    @ViewBuilder
    private func renderer(size: CGSize) -> some View {
        if PX.staticRender {
            if let image = MatrixLayerView.stillImage(segments: segments, capacity: capacity, highlight: highlight, mode: mode, rows: rows, size: size) {
                Image(decorative: image, scale: 2)
            }
        } else {
            MatrixCanvasHost(segments: segments, capacity: capacity, highlight: highlight, mode: mode, rows: rows, active: activity?.active != false)
        }
    }

    private func segmentID(atFraction x: Double) -> String? {
        guard width > 1, capacity > 0 else { return nil }
        var edge = 0.0
        for s in segments {
            let w = max(0, s.value / capacity) * Double(width)
            if x >= edge && x < edge + w { return w > 1.5 ? s.id : nil }
            edge += w
        }
        return nil
    }
}

private struct WidthReader: View {
    @Binding var width: CGFloat
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, new in width = new }
        }
    }
}

/// Debug: DOTMETER_LOG_FPS=1 prints how often bars update, so CPU readings can be trusted
/// (nothing updates while the display is asleep, which makes the app look cheaper than it is).
enum DrawCounter {
    static let enabled = ProcessInfo.processInfo.environment["DOTMETER_LOG_FPS"] == "1"
    private static var ticks = 0
    private static var bases = 0
    private static var windowStart = Date()

    static func base() { if enabled { bases += 1 } }

    static func tick() {
        guard enabled else { return }
        ticks += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 3 {
            print(String(format: "UPDATES %.1f per second, of which full redraws %.1f per second", Double(ticks) / elapsed, Double(bases) / elapsed))
            fflush(stdout)
            ticks = 0
            bases = 0
            windowStart = Date()
        }
    }
}
