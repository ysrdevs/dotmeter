import AppKit
import Observation

/// One figure the floating meter can show.
enum FloatingFigure: String, CaseIterable, Identifiable {
    case cpu, gpu, temperature, power, memory, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
        case .temperature: return "Temperature"
        case .power: return "Power"
        case .memory: return "Memory"
        case .network: return "Network"
        }
    }

    /// What the meter shows until told otherwise.
    static let usual: [FloatingFigure] = [.cpu, .gpu, .temperature, .power]
}

/// What the floating meter remembers. Each setting has a switch that sets it for one run without saving, so a
/// test never changes what the owner chose.
@MainActor
@Observable
final class FloatingMeterSettings {
    static let shared = FloatingMeterSettings()

    static let opacities: [Double] = [0.4, 0.55, 0.7, 0.85, 1]

    /// Whether the meter is showing. Debug: DOTMETER_FLOATING=on|off decides for a run.
    var isOn: Bool {
        didSet { if !fixed.contains("on") { defaults.set(isOn, forKey: "floatingMeterOn") } }
    }

    /// The figures shown, in the order of `FloatingFigure.allCases`. Never empty.
    /// Debug: DOTMETER_FLOATING_FIGURES=cpu,gpu,temperature,power,memory,network
    private(set) var figures: [FloatingFigure]

    /// How solid the black behind the figures is; the figures themselves stay fully lit.
    /// Debug: DOTMETER_FLOATING_OPACITY=0.4
    var opacity: Double {
        didSet { if !fixed.contains("opacity") { defaults.set(opacity, forKey: "floatingMeterOpacity") } }
    }

    /// The meter ignores the mouse, so what is under it can be clicked.
    /// Debug: DOTMETER_FLOATING_CLICK_THROUGH=on|off
    var clickThrough: Bool {
        didSet { if !fixed.contains("through") { defaults.set(clickThrough, forKey: "floatingMeterClickThrough") } }
    }

    /// Where the meter's top left corner was left, for each arrangement of screens it has been placed in.
    /// Debug: DOTMETER_FLOATING_ORIGIN=<x>,<top> puts it there for a run.
    @ObservationIgnored private var origins: [String: [Double]]

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// The settings a switch has decided for this run, which are therefore not saved.
    @ObservationIgnored private let fixed: Set<String>
    @ObservationIgnored private let fixedOrigin: CGPoint?

    private init() {
        let env = ProcessInfo.processInfo.environment
        var fixed = Set<String>()
        if env["DOTMETER_FLOATING"] != nil { fixed.insert("on") }
        if env["DOTMETER_FLOATING_FIGURES"] != nil { fixed.insert("figures") }
        if env["DOTMETER_FLOATING_OPACITY"] != nil { fixed.insert("opacity") }
        if env["DOTMETER_FLOATING_CLICK_THROUGH"] != nil { fixed.insert("through") }
        let point = (env["DOTMETER_FLOATING_ORIGIN"] ?? "").split(separator: ",").compactMap { Double($0) }
        fixedOrigin = point.count == 2 ? CGPoint(x: point[0], y: point[1]) : nil
        // A run that was told where to put the meter, or whether to show it, leaves the saved places alone too.
        if fixedOrigin != nil || fixed.contains("on") { fixed.insert("origin") }
        self.fixed = fixed

        isOn = env["DOTMETER_FLOATING"].map { $0 == "on" } ?? defaults.bool(forKey: "floatingMeterOn")
        let names = env["DOTMETER_FLOATING_FIGURES"].map { $0.split(separator: ",").map(String.init) } ?? defaults.stringArray(forKey: "floatingMeterFigures")
        figures = Self.figures(named: names)
        let saved = env["DOTMETER_FLOATING_OPACITY"].flatMap(Double.init) ?? (defaults.object(forKey: "floatingMeterOpacity") as? Double ?? 0.85)
        opacity = min(max(saved, 0.2), 1)
        clickThrough = env["DOTMETER_FLOATING_CLICK_THROUGH"].map { $0 == "on" } ?? defaults.bool(forKey: "floatingMeterClickThrough")
        origins = defaults.dictionary(forKey: "floatingMeterOrigins") as? [String: [Double]] ?? [:]
    }

    /// The figures a list of names means: in the usual order, and the usual four when the list names none.
    static func figures(named names: [String]?) -> [FloatingFigure] {
        guard let names else { return FloatingFigure.usual }
        let chosen = FloatingFigure.allCases.filter { names.contains($0.rawValue) }
        return chosen.isEmpty ? FloatingFigure.usual : chosen
    }

    func shows(_ figure: FloatingFigure) -> Bool { figures.contains(figure) }

    /// The last figure stays: a meter with nothing on it could not be found again.
    func setShows(_ figure: FloatingFigure, _ on: Bool) {
        var wanted = Set(figures)
        if on { wanted.insert(figure) } else { wanted.remove(figure) }
        guard !wanted.isEmpty, wanted != Set(figures) else { return }
        figures = FloatingFigure.allCases.filter { wanted.contains($0) }
        if !fixed.contains("figures") { defaults.set(figures.map(\.rawValue), forKey: "floatingMeterFigures") }
    }

    func origin(for layout: String) -> CGPoint? {
        if let fixedOrigin { return fixedOrigin }
        guard let point = origins[layout], point.count == 2 else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    func setOrigin(_ point: CGPoint, for layout: String) {
        guard !fixed.contains("origin") else { return }
        origins[layout] = [Double(point.x), Double(point.y)]
        // A handful of arrangements is all a Mac ever sees; past that the list starts again.
        if origins.count > 24 { origins = [layout: [Double(point.x), Double(point.y)]] }
        defaults.set(origins, forKey: "floatingMeterOrigins")
    }
}

/// Where the meter goes. Its place is kept as its top left corner, in the coordinates screens are arranged in
/// (upward from the main screen's bottom left), so it stays put when the figures shown make it wider.
enum FloatingPlacement {
    /// A name for an arrangement of screens: the same screens in the same places give the same name.
    static func layoutKey(_ screens: [CGRect]) -> String {
        screens.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }.sorted().joined(separator: "|")
    }

    /// The top right corner of the main screen, under the menu bar.
    static func usual(size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - 12)
    }

    /// The meter's top left corner: where it was left, brought back onto a screen if that place is no longer on
    /// one, or the usual corner if it was never moved. `screens` are whole frames; the first is the main one.
    static func topLeft(saved: CGPoint?, size: CGSize, screens: [CGRect], mainVisible: CGRect) -> CGPoint {
        guard let saved else { return clamp(usual(size: size, visible: mainVisible), size: size, screens: screens) }
        return clamp(saved, size: size, screens: screens)
    }

    /// Moves a place as little as it takes to put the whole meter on one screen: the screen it mostly covers,
    /// or with none under it the nearest.
    static func clamp(_ topLeft: CGPoint, size: CGSize, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return topLeft }
        let frame = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        func distance(_ screen: CGRect) -> CGFloat {
            let dx = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
            let dy = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
            return dx * dx + dy * dy
        }
        let covered = screens.max { overlap($0) < overlap($1) }
        let screen = covered.flatMap { overlap($0) > 0 ? $0 : nil } ?? screens.min { distance($0) < distance($1) } ?? screens[0]
        let x = min(max(topLeft.x, screen.minX), max(screen.maxX - size.width, screen.minX))
        let y = max(min(topLeft.y, screen.maxY), min(screen.minY + size.height, screen.maxY))
        return CGPoint(x: x, y: y)
    }
}
