import AppKit
import SwiftUI

/// The floating meter: a small strip of figures that stays above every window, full-screen ones too.
@MainActor
final class FloatingMeterController: NSObject {
    static let shared = FloatingMeterController()

    private(set) var isOn = false

    private let model = FloatingMeterModel()
    private let settings = FloatingMeterSettings.shared
    private var panel: FloatingMeterPanel?
    private weak var monitor: SystemMonitor?
    /// What the app shares, kept from launch so that Settings can switch the meter without being handed it.
    private var models: AppModels?
    private var observing = false
    private var watchingScreens = false
    /// True while the controller itself is moving the panel, so that only a drag is remembered as its place.
    private var placing = false

    /// Above the Dock, the menu bar, menus and anything a game raises short of capturing the display.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    /// Shows the meter, or hides it if it is showing.
    func toggle(models: AppModels) {
        if isOn { hide() } else { show(models: models) }
        settings.isOn = isOn
    }

    /// At launch: shows the meter again if it was left on.
    func restore(models: AppModels) {
        self.models = models
        if settings.isOn { show(models: models) }
    }

    /// From Settings: shows or hides the meter.
    func set(on: Bool) {
        guard on != isOn, let models else { return }
        toggle(models: models)
    }

    func show(models: AppModels) {
        guard !isOn else { return }
        self.models = models
        let monitor = models.monitor
        self.monitor = monitor
        if !observing {
            observing = true
            // The meter has its own readings: the monitor's are only published while a window is open.
            monitor.addObserver { [weak self] snapshot in
                guard let self, self.isOn else { return }
                self.model.take(snapshot)
            }
        }
        if let latest = monitor.latest { model.take(latest) }

        let panel = FloatingMeterPanel(contentRect: NSRect(origin: .zero, size: stripSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Being a floating panel sets a level of its own, so the level wanted is set after it.
        panel.isFloatingPanel = true
        panel.level = Self.level
        panel.collectionBehavior = Self.behavior
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = settings.clickThrough

        let content = FloatingContentView(frame: NSRect(origin: .zero, size: stripSize))
        content.menuProvider = { [weak self] in self?.contextMenu() }
        let root = FloatingMeterView(model: model)
            .followsTheme()
            .dotmeterModels(models)
        content.host(NSHostingView(rootView: root))
        panel.contentView = content
        self.panel = panel
        isOn = true

        place()
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved(_:)), name: NSWindow.didMoveNotification, object: panel)
        watchScreens()
        trackSettings()
        // Readings at the live pace with no window open, the graphics load among them.
        monitor.setBackgroundLive("floating", on: true, graphics: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard isOn else { return }
        isOn = false
        monitor?.setBackgroundLive("floating", on: false)
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
    }

    // MARK: Size and place

    private var stripSize: CGSize {
        FloatingStrip(readings: model.readings, figures: settings.figures, opacity: settings.opacity).size
    }

    private var layoutKey: String { FloatingPlacement.layoutKey(NSScreen.screens.map(\.frame)) }

    /// Sizes the panel for the figures shown and puts it where it was left in this arrangement of screens.
    private func place() {
        guard let panel else { return }
        let screens = NSScreen.screens
        let main = screens.first ?? NSScreen.main
        let size = stripSize
        let corner = FloatingPlacement.topLeft(
            saved: settings.origin(for: layoutKey), size: size,
            screens: screens.map(\.frame), mainVisible: main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        placing = true
        panel.setFrame(NSRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height), display: true)
        placing = false
    }

    /// A drag ended somewhere: that is the meter's place in this arrangement of screens from now on.
    @objc private func panelMoved(_ notification: Notification) {
        guard !placing, let panel else { return }
        settings.setOrigin(CGPoint(x: panel.frame.minX, y: panel.frame.maxY), for: layoutKey)
    }

    /// More or fewer figures: the panel keeps its top left corner and grows or shrinks to the right.
    private func resize() {
        guard let panel else { return }
        let size = stripSize
        guard size != panel.frame.size else { return }
        let corner = FloatingPlacement.clamp(CGPoint(x: panel.frame.minX, y: panel.frame.maxY), size: size, screens: NSScreen.screens.map(\.frame))
        placing = true
        panel.setFrame(NSRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height), display: true)
        placing = false
    }

    private func trackSettings() {
        withObservationTracking {
            _ = settings.figures
            _ = settings.clickThrough
            _ = model.readings.power.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isOn else { return }
                self.panel?.ignoresMouseEvents = self.settings.clickThrough
                self.resize()
                self.trackSettings()
            }
        }
    }

    private func watchScreens() {
        guard !watchingScreens else { return }
        watchingScreens = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    // MARK: Menus

    /// The menu a right-click on the meter brings up.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for figure in FloatingFigure.allCases {
            let item = NSMenuItem(title: figure.title, action: #selector(toggleFigure(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = figure.rawValue
            item.state = settings.shows(figure) ? .on : .off
            // The last figure stays.
            item.isEnabled = !(settings.shows(figure) && settings.figures.count == 1)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for value in FloatingMeterSettings.opacities {
            let item = NSMenuItem(title: "\(Int((value * 100).rounded()))%", action: #selector(chooseOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(settings.opacity - value) < 0.01 ? .on : .off
            levels.addItem(item)
        }
        opacity.submenu = levels
        menu.addItem(opacity)
        let through = NSMenuItem(title: "Click Through", action: #selector(toggleClickThrough(_:)), keyEquivalent: "")
        through.target = self
        through.state = settings.clickThrough ? .on : .off
        through.toolTip = "The meter ignores the mouse. Switch it back from a menu bar item's menu or in Settings."
        menu.addItem(through)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide", action: #selector(hideFromMenu(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        return menu
    }

    /// For the menu of a menu bar item: the way back once the meter ignores the mouse. Nil while the meter is
    /// hidden.
    func clickThroughItem() -> NSMenuItem? {
        guard isOn else { return nil }
        let item = NSMenuItem(title: "Click Through", action: #selector(toggleClickThrough(_:)), keyEquivalent: "")
        item.target = self
        item.state = settings.clickThrough ? .on : .off
        item.indentationLevel = 1
        return item
    }

    @objc private func toggleFigure(_ sender: NSMenuItem) {
        guard let figure = (sender.representedObject as? String).flatMap(FloatingFigure.init(rawValue:)) else { return }
        settings.setShows(figure, !settings.shows(figure))
    }

    @objc private func chooseOpacity(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { settings.opacity = value }
    }

    @objc private func toggleClickThrough(_ sender: Any?) {
        settings.clickThrough.toggle()
        panel?.ignoresMouseEvents = settings.clickThrough
    }

    @objc private func hideFromMenu(_ sender: Any?) {
        hide()
        settings.isOn = false
    }

    // MARK: Debug

    /// Debug (`--open`):
    /// DOTMETER_CAPTURE_FLOATING=<png> writes the meter as it is set, at 2x, on a dark and on a light backdrop;
    /// DOTMETER_FLOATING_DEMO=1 gives it made-up figures.
    /// With DOTMETER_FLOATING=on the meter is really shown, a line says where, and a capture is of the panel itself;
    /// DOTMETER_FLOATING_HIDE_AFTER=<seconds> then hides it again.
    func debugRun(_ env: [String: String], models: AppModels) async {
        if let path = env["DOTMETER_CAPTURE_FLOATING"], isOn, let view = panel?.contentView {
            // The meter is really showing: it is the panel itself that is written, as it stands.
            try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 2.5))
            StatusController.capture(view, to: path)
        } else if let path = env["DOTMETER_CAPTURE_FLOATING"] {
            if !isOn {
                // Readings as the meter would get them, for long enough to have a graphics load.
                models.monitor.setBackgroundLive("floating capture", on: true, graphics: true)
                try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 2.5))
                models.monitor.setBackgroundLive("floating capture", on: false)
            }
            var readings = FloatingMeterModel.demo ? FloatingReadings.demo : (models.monitor.latest.map(FloatingReadings.init) ?? FloatingReadings())
            if isOn { readings = model.readings }
            let strip = FloatingStrip(readings: readings, figures: settings.figures, opacity: settings.opacity)
            if let image = Self.sheet(strip), WallController.write(image, to: path) {
                print("CAPTURE \(path) \(image.width)x\(image.height) strip \(Int(strip.size.width))x\(Int(strip.size.height)) points, \(strip.segments.map(\.figure).joined(separator: " "))")
            } else {
                print("CAPTURE failed: \(path)")
            }
        }
        if isOn, let panel {
            let frame = panel.frame
            print("FLOATING on \(isOn) at \(Int(frame.minX)),\(Int(frame.maxY)) size \(Int(frame.width))x\(Int(frame.height)) level \(panel.level.rawValue) behavior \(panel.collectionBehavior.rawValue) click through \(panel.ignoresMouseEvents) visible \(panel.isVisible) figures \(model.readings.cpu) \(model.readings.gpu) \(model.readings.temperature) \(model.readings.power)")
            if let after = env["DOTMETER_FLOATING_HIDE_AFTER"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(after))
                print("FLOATING figures \(model.readings.cpu) \(model.readings.gpu) \(model.readings.temperature) \(model.readings.power)")
                toggle(models: models)
                print("FLOATING on \(isOn), panel \(self.panel == nil ? "released" : "kept")")
            }
        }
        fflush(stdout)
    }

    /// The strip over a dark and a light backdrop, since it has to read over whatever a game puts under it.
    static func sheet(_ strip: FloatingStrip) -> CGImage? {
        let size = strip.size, margin: CGFloat = 24
        let whole = CGSize(width: size.width + margin * 2, height: (size.height + margin * 2) * 2)
        return BitmapPen.render(size: whole, scale: 2) { pen in
            let half = whole.height / 2
            pen.fill(CGRect(x: 0, y: 0, width: whole.width, height: half), RGB(0x1B2430))
            pen.fill(CGRect(x: 0, y: half, width: whole.width, height: half), RGB(0xC9D3DE))
            // Something uneven behind it, so the translucency can be judged.
            for band in 0..<Int(whole.width / 28) + 1 {
                pen.fill(CGRect(x: CGFloat(band) * 28, y: 0, width: 14, height: half), RGB(0x2F5D8A), 0.55)
                pen.fill(CGRect(x: CGFloat(band) * 28, y: half, width: 14, height: half), RGB(0x7FA650), 0.55)
            }
            for row in 0..<2 {
                pen.context.saveGState()
                pen.context.translateBy(x: margin, y: margin + CGFloat(row) * half)
                strip.draw(pen, size, scale: 2)
                pen.context.restoreGState()
            }
        }
    }
}

/// A panel that never takes the keyboard or brings the app forward.
final class FloatingMeterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the strip and takes the mouse for it: a drag moves the meter, a right-click brings up its menu.
final class FloatingContentView: NSView {
    var menuProvider: (() -> NSMenu?)?

    func host(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(with: event) }

    private func showMenu(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// The rows the floating meter adds to Settings, under Display.
struct FloatingMeterSettingsRows: View {
    @State private var settings = FloatingMeterSettings.shared
    /// Follows the meter itself, which the menus and a right-click can switch as well.
    @State private var shown = FloatingMeterController.shared.isOn

    var body: some View {
        @Bindable var settings = settings
        Toggle("Floating meter", isOn: Binding(get: { shown }, set: { setShown($0) }))
            .onChange(of: settings.isOn) { _, _ in shown = FloatingMeterController.shared.isOn }
            .onAppear { shown = FloatingMeterController.shared.isOn }
        LabeledContent("Floating meter shows") {
            Menu(settings.figures.count == FloatingFigure.allCases.count ? "Everything" : "\(settings.figures.count) of \(FloatingFigure.allCases.count) figures") {
                ForEach(FloatingFigure.allCases) { figure in
                    Toggle(figure.title, isOn: Binding(get: { settings.shows(figure) }, set: { settings.setShows(figure, $0) }))
                        .disabled(settings.shows(figure) && settings.figures.count == 1)
                }
            }
            .fixedSize()
        }
        Picker("Floating meter opacity", selection: $settings.opacity) {
            ForEach(FloatingMeterSettings.opacities, id: \.self) { value in
                Text("\(Int((value * 100).rounded()))%").tag(value)
            }
            // A value set some other way keeps its place in the list.
            if !FloatingMeterSettings.opacities.contains(where: { abs($0 - settings.opacity) < 0.001 }) {
                Text("\(Int((settings.opacity * 100).rounded()))%").tag(settings.opacity)
            }
        }
        Toggle("Floating meter ignores the mouse", isOn: $settings.clickThrough)
            .help("Clicks go through the meter to what is under it. Switch it back here or from a menu bar item's menu.")
    }

    private func setShown(_ on: Bool) {
        FloatingMeterController.shared.set(on: on)
        shown = FloatingMeterController.shared.isOn
    }
}
