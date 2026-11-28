import AppKit
import QuartzCore
import SwiftUI

/// Plain RGB triple so the bar renderer can mix colors cheaply every frame.
struct RGB: Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
    }

    func color(_ alpha: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        return RGB(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k)
    }

    static let white = RGB(0xFFFFFF)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self = RGB(hex).color(alpha)
    }
}

/// The "pixel" design language: one dark card, one dot-matrix bar, one legend grid, one footer action.
/// Every dimension is in points and was measured from the reference at 2x.
enum PX {
    // Geometry
    static let cardWidth: CGFloat = 583
    static let cardRadius: CGFloat = 13
    static let inset: CGFloat = 22
    static let pitch: CGFloat = 3.635
    static let barRadius: CGFloat = 11
    static let fullRows = 22
    static let compactRows = 11

    // Surfaces
    static let card = Color(hex: 0x191A1C)
    static let trackRGB = RGB(0x1A1B1D)
    static let trackFill = trackRGB.color()
    static let button = Color(hex: 0x28292B)
    static let buttonHover = Color(hex: 0x323336)
    static let ghostHover = Color(hex: 0x232427)
    static let rowHover = Color(hex: 0x242628)
    static let dividerDark = Color(hex: 0x0F1012)
    static let dividerLight = Color(hex: 0x242527)

    // Text
    static let text = Color.white
    static let label = Color(hex: 0xE6E7E9)
    static let soft = Color(hex: 0xD3D4D6)
    static let secondary = Color(hex: 0x8A8B8D)
    static let tertiary = Color(hex: 0x727375)
    static let green = Color(hex: 0x57C27A)

    // Category colors, in the order the reference uses them. They follow the theme: see `DotTheme`.
    static var tones = DotTheme.current.tones
    static var blue: RGB { tones.blue }
    static var greenRGB: RGB { tones.green }
    static var pink: RGB { tones.pink }
    static var purple: RGB { tones.purple }
    static var cyan: RGB { tones.cyan }
    static var yellow: RGB { tones.yellow }
    static var gray: RGB { tones.gray }
    static var orange: RGB { tones.orange }
    static var red: RGB { tones.red }
    static var lime: RGB { tones.lime }
    static var teal: RGB { tones.teal }
    static var indigo: RGB { tones.indigo }
    static var palette: [RGB] { [blue, greenRGB, pink, purple, cyan, yellow, orange, red] }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The reference face sets tighter than SF Pro; this tracking brings line lengths back in line.
    static func tracking(_ size: CGFloat) -> CGFloat {
        size >= 18 ? -size * 0.04 : -size * 0.017
    }

    static let ghostText = Color(hex: 0xA9AAAD)

    /// SF's weight axis is continuous; the reference headline sits between regular and medium.
    static func headline(_ size: CGFloat) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: NSFont.Weight(0.15)))
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Debug: DOTMETER_SCROLL=<points> shifts every page up by that much, to capture what is below the fold.
    static let debugScroll = CGFloat(Double(ProcessInfo.processInfo.environment["DOTMETER_SCROLL"] ?? "") ?? 0)

    /// Debug: DOTMETER_STATIC=1 skips entrance animations so still renders show the settled state.
    static let staticRender = ProcessInfo.processInfo.environment["DOTMETER_STATIC"] == "1"
}

/// Shared flag that pauses every timeline when its window is hidden or covered.
@MainActor
@Observable
final class ViewActivity {
    var active: Bool
    init(active: Bool = true) { self.active = active }
}

private struct PXActivityKey: EnvironmentKey {
    static let defaultValue: ViewActivity? = nil
}

extension EnvironmentValues {
    var pxActivity: ViewActivity? {
        get { self[PXActivityKey.self] }
        set { self[PXActivityKey.self] = newValue }
    }
}

struct PXCardModifier: ViewModifier {
    var shadow = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PX.cardRadius, style: .continuous)
        content
            .background(PX.card)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            )
            // The shadow belongs to a static shape behind the card. Attached to the content it would be
            // re-blurred on every animation frame inside the card.
            .background {
                if shadow {
                    shape.fill(PX.card).shadow(color: .black.opacity(0.20), radius: 14, y: 8)
                }
            }
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func pxCard(shadow: Bool = true) -> some View { modifier(PXCardModifier(shadow: shadow)) }
}

/// The reference's divider is a groove: a dark hairline with a light one under it.
struct PXDivider: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PX.dividerDark).frame(height: 0.5)
            Rectangle().fill(PX.dividerLight).frame(height: 0.5)
        }
    }
}

struct PXButton: View {
    enum Style { case filled, ghost }

    var title: String
    var symbol: String?
    var style: Style = .filled
    var spinning = false
    var enabled = true
    var tint: Color?
    var height: CGFloat = 29
    /// Resting rotation of the symbol; the rescan arrows sit a quarter turn round in the reference.
    var symbolRotation: Double = 0
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6.5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(symbolRotation + (spinning ? 360 : 0)))
                        .animation(spinning ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: spinning)
                }
                if !title.isEmpty {
                    Text(title)
                        .font(PX.font(12, .medium))
                        .tracking(PX.tracking(12))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(foreground)
            .padding(.leading, style == .filled ? 11 : 8)
            .padding(.trailing, style == .filled ? 11 : 6.5)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PXPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: enabled)
    }

    private var foreground: Color {
        if let tint { return tint }
        switch style {
        case .filled: return .white
        case .ghost: return hovering && enabled ? .white : PX.ghostText
        }
    }

    private var background: Color {
        switch style {
        case .filled: return hovering && enabled ? PX.buttonHover : PX.button
        case .ghost: return hovering && enabled ? PX.ghostHover : .clear
        }
    }
}

struct PXPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A number that counts toward its value instead of jumping, like the reference's headline during a scan.
struct CountingText: View, Animatable {
    var value: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value)).monospacedDigit()
    }

    /// Counting re-lays out text every frame, so it is reserved for scans and clears (see MeterModel.animatesNumbers).
    /// Debug: DOTMETER_COUNT=step shows each new value as it arrives instead, to measure what the counting costs.
    static let animation: Animation? = ProcessInfo.processInfo.environment["DOTMETER_COUNT"] == "step" ? nil : .easeOut(duration: 0.3)
}

struct PXCheck: View {
    var size: CGFloat = 11
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(PX.green)
    }
}

/// The reference's eight-spoke activity spinner: eight layers whose opacity steps round inside the render server,
/// so a spinner costs this process nothing while it turns.
/// It used to be a SwiftUI Canvas on a timeline. That cost about 5% of a core, and for as long as one was on
/// screen SwiftUI held about 500 MB of GPU memory for it.
struct PXSpinner: View {
    var size: CGFloat = 13
    @Environment(\.pxActivity) private var activity

    var body: some View {
        SpinnerHost(active: activity?.active != false)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

private struct SpinnerHost: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> SpinnerLayerView {
        let view = SpinnerLayerView(frame: .zero)
        view.active = active
        return view
    }

    func updateNSView(_ view: SpinnerLayerView, context: Context) {
        view.active = active
    }
}

final class SpinnerLayerView: NSView {
    /// One step of the wheel, as in the reference.
    static let stepTime = 0.09
    private static let spokeCount = 8

    var active = true {
        didSet { if active != oldValue { applyAnimation() } }
    }

    private var spokes: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<Self.spokeCount {
            let spoke = CALayer()
            spoke.backgroundColor = CGColor(srgbRed: 0x8A / 255.0, green: 0x8B / 255.0, blue: 0x8D / 255.0, alpha: 1)
            layer?.addSublayer(spoke)
            spokes.append(spoke)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        arrange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAnimation()
    }

    /// Brightness of spoke `index` at a given step: the lit spoke leads and the others trail off behind it.
    private static func alpha(spoke index: Int, step: Int) -> Double {
        0.95 - Double((step - index + spokeCount) % spokeCount) * 0.11
    }

    private func arrange() {
        let outer = min(bounds.width, bounds.height) / 2
        guard outer > 0 else { return }
        let lineWidth = outer * 0.23
        let inner = outer * 0.46, tip = outer * 0.95
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, spoke) in spokes.enumerated() {
            // Spoke 0 points up and the rest follow clockwise. Layers count angles the other way round.
            let angle = Double(i) / Double(Self.spokeCount) * 2 * .pi - .pi / 2
            let middle = (inner + tip) / 2
            // Round caps reach half a line width past each end of the stroke.
            spoke.bounds = CGRect(x: 0, y: 0, width: tip - inner + lineWidth, height: lineWidth)
            spoke.cornerRadius = lineWidth / 2
            spoke.position = CGPoint(x: bounds.midX + cos(angle) * middle, y: bounds.midY - sin(angle) * middle)
            spoke.setAffineTransform(CGAffineTransform(rotationAngle: -angle))
            spoke.opacity = Float(Self.alpha(spoke: i, step: 0))
        }
        CATransaction.commit()
        applyAnimation()
    }

    private func applyAnimation() {
        for (i, spoke) in spokes.enumerated() {
            spoke.removeAnimation(forKey: "spin")
            guard active, window != nil else { continue }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = (0..<Self.spokeCount).map { Self.alpha(spoke: i, step: $0) }
            animation.calculationMode = .discrete
            animation.duration = Self.stepTime * Double(Self.spokeCount)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            spoke.add(animation, forKey: "spin")
        }
    }
}
