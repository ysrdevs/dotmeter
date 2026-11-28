import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Wall mode: a whole screen of live dot-matrix meters, for a spare display.
@MainActor
final class WallController {
    static let shared = WallController()

    private(set) var isOpen = false

    private var window: WallWindow?
    private let clock = WallClock()
    private var minuteTimer: Timer?
    private var assertion = IOPMAssertionID(0)
    private var watchingScreens = false

    /// Above the Dock, the menu bar and every menu, and above the floating meter, which the wall makes needless
    /// on its own screen.
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)

    /// Opens the wall, or closes it if it is open.
    func toggle(models: AppModels) {
        if isOpen { close() } else { open(models: models) }
    }

    func open(models: AppModels) {
        guard !isOpen, let screen = WallScreens.target(WallSettings.shared.screen) else { return }
        let window = WallWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = Self.level
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        window.onClose = { [weak self] in self?.close() }

        let root = WallView(clock: clock)
            .followsTheme()
            .dotmeterModels(models)
        let content = WallContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.onClick = { [weak self] in self?.close() }
        content.host(NSHostingView(rootView: root))
        window.contentView = content
        window.setFrame(screen.frame, display: true)
        self.window = window
        isOpen = true

        // Readings at the pace of an open window, with the apps, for as long as the wall is up.
        StatusController.shared?.setViewer("wall", on: true, detail: true)
        holdAwake(WallSettings.shared.keepAwake)
        trackSettings()
        startClock()
        watchScreens()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        content.pointerMoved()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        minuteTimer?.invalidate()
        minuteTimer = nil
        holdAwake(false)
        StatusController.shared?.setViewer("wall", on: false)
        NSCursor.setHiddenUntilMouseMoves(false)
        // A closed window is let go, views and layers with it.
        if let window {
            (window.contentView as? WallContentView)?.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        window = nil
    }

    // MARK: While it is open

    /// The clock turns over on the minute, and the picture takes one step of its drift with it.
    private func startClock() {
        clock.tick()
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func holdAwake(_ on: Bool) {
        if on, assertion == 0 {
            var id = IOPMAssertionID(0)
            let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "\(App.name) wall is open" as CFString, &id)
            if made == kIOReturnSuccess { assertion = id }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Whether the display is being held awake right now.
    var isHoldingAwake: Bool { assertion != 0 }

    /// The switch in Settings takes effect on a wall that is already up.
    private func trackSettings() {
        withObservationTracking {
            _ = WallSettings.shared.keepAwake
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                self.holdAwake(WallSettings.shared.keepAwake)
                self.trackSettings()
            }
        }
    }

    /// A screen that changes size is followed; one that is unplugged takes the wall with it.
    private func watchScreens() {
        guard !watchingScreens else { return }
        watchingScreens = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, let window = self.window else { return }
                if let screen = window.screen, NSScreen.screens.contains(screen) {
                    if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
                } else {
                    self.close()
                }
            }
        }
    }

    // MARK: Debug

    /// Debug (`--open`):
    /// DOTMETER_CAPTURE_WALL=<png> writes the wall as the graphics card composes it, without taking a screen, for
    /// a screen of DOTMETER_WALL_SIZE=<width>x<height> pixels (1920x1080 unless given; a 4K display is 3840x2160
    /// whether it runs at 1x or 2x, since the wall is laid out in pixels).
    /// DOTMETER_WALL_DEMO=1 shows made-up readings. DOTMETER_WALL_DRIFT=<minutes> captures it that far into its drift.
    /// DOTMETER_SHOW_WALL=1 opens it for real; DOTMETER_WALL_CLOSE_AFTER=<seconds> closes it again and says how
    /// many pictures it drew, and with DOTMETER_WALL_CLOSE_BY=esc|shortcut|click closes it by that key or a click.
    func debugRun(_ env: [String: String], models: AppModels) async {
        if env["DOTMETER_SHOW_WALL"] == "1" {
            open(models: models)
            let frame = window?.frame ?? .zero
            print("WALL open \(isOpen) on \(window?.screen?.localizedName ?? "no screen") \(Int(frame.width))x\(Int(frame.height)) points at \(window?.backingScaleFactor ?? 0)x, level \(window?.level.rawValue ?? 0), awake held \(isHoldingAwake)")
            // With a capture asked for as well, it is the open wall's own window that is written, as AppKit draws
            // it: proof that the real thing is laid out, though without the graphics card's smoothing of the glow.
            if let path = env["DOTMETER_CAPTURE_WALL"] {
                try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 2.5))
                if let view = window?.contentView { StatusController.capture(view, to: path) }
            }
            if let after = env["DOTMETER_WALL_CLOSE_AFTER"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(after))
                let surface = window?.contentView.flatMap(Self.surfaceView)?.surface
                if let layout = surface?.layout {
                    print("WALL drew \(surface?.draws ?? 0) pictures: \(layout.width)x\(layout.height) px, pitch \(layout.pitch), \(layout.cols) by \(layout.rows) dots, drift \(surface?.driftOffset.x ?? 0),\(surface?.driftOffset.y ?? 0)")
                }
                // DOTMETER_WALL_CLOSE_BY=esc|shortcut|click closes it the way a person would: the event is made
                // here and handed to the app, so it takes the same road as one from the keyboard or the mouse.
                let way = env["DOTMETER_WALL_CLOSE_BY"] ?? "call"
                if let window, let event = Self.closingEvent(way, in: window) { NSApp.sendEvent(event) } else { close() }
                try? await Task.sleep(for: .seconds(0.3))
                print("WALL closed by \(way): open \(isOpen), awake held \(isHoldingAwake), window \(window == nil ? "released" : "kept")")
                if isOpen { close() }
            }
        } else if let path = env["DOTMETER_CAPTURE_WALL"] {
            let size = (env["DOTMETER_WALL_SIZE"] ?? "").split(separator: "x").compactMap { Int($0) }
            let (width, height) = size.count == 2 ? (size[0], size[1]) : (1920, 1080)
            StatusController.shared?.setViewer("wall capture", on: true, detail: true)
            try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 2.5))
            let surface = WallSurface()
            surface.resize(pixelWidth: width, pixelHeight: height, scale: 1)
            if let minutes = env["DOTMETER_WALL_DRIFT"].flatMap(Int.init) { surface.drift(step: minutes) }
            surface.show(WallView.reading(snapshot: models.monitor.snapshot ?? models.monitor.latest, history: models.monitor.latestHistory))
            StatusController.shared?.setViewer("wall capture", on: false)
            if let image = surface.rendered(), let layout = surface.layout, Self.write(image, to: path) {
                print("CAPTURE \(path) \(image.width)x\(image.height) pitch \(layout.pitch) px, \(layout.dot) lit, \(layout.cols) by \(layout.rows) dots, figures x\(layout.figureScale), drift \(surface.driftOffset.x),\(surface.driftOffset.y)")
            } else {
                print("CAPTURE failed: \(path)")
            }
        }
        fflush(stdout)
    }

    private static func closingEvent(_ way: String, in window: NSWindow) -> NSEvent? {
        let now = ProcessInfo.processInfo.systemUptime
        switch way {
        case "esc":
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)
        case "shortcut":
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: now, windowNumber: window.windowNumber, context: nil, characters: "F", charactersIgnoringModifiers: "F", isARepeat: false, keyCode: 3)
        case "click":
            return NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 200), modifierFlags: [], timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        default:
            return nil
        }
    }

    /// The view carrying the wall's layers, somewhere under the window's content.
    private static func surfaceView(in view: NSView) -> WallSurfaceView? {
        if let found = view as? WallSurfaceView { return found }
        for child in view.subviews {
            if let found = surfaceView(in: child) { return found }
        }
        return nil
    }

    static func write(_ image: CGImage, to path: String) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// The minute the wall's clock shows, and how many minutes the wall has been up, which is how far its picture
/// has drifted.
@MainActor
@Observable
final class WallClock {
    private(set) var minute = 0
    private(set) var step = 0

    func tick() {
        minute = Int(Date().timeIntervalSinceReferenceDate / 60)
        step += 1
    }
}

/// The wall's content: the newest reading handed to the layers.
struct WallView: View {
    var clock: WallClock
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        // Reading the minute is what brings this back when the clock turns over between two readings.
        let _ = clock.minute
        WallSurfaceHost(reading: Self.reading(snapshot: monitor.snapshot, history: monitor.history), step: clock.step)
            .ignoresSafeArea()
    }

    /// Debug: DOTMETER_WALL_DEMO=1 shows made-up readings, for pictures of the wall that give nothing away.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_WALL_DEMO"] == "1"

    static func reading(snapshot: Snapshot?, history: [HistoryPoint]) -> WallReading {
        demo ? WallReading.demo(at: Date()) : WallReading.make(snapshot: snapshot, history: history)
    }
}

private struct WallSurfaceHost: NSViewRepresentable {
    var reading: WallReading
    var step: Int

    func makeNSView(context: Context) -> WallSurfaceView {
        let view = WallSurfaceView(frame: .zero)
        view.surface.drift(step: step)
        view.reading = reading
        return view
    }

    func updateNSView(_ view: WallSurfaceView, context: Context) {
        view.surface.drift(step: step)
        view.reading = reading
    }
}

/// A borderless window that takes the keyboard, so Esc can close it.
final class WallWindow: NSWindow {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// ⇧⌘F closes the wall as it opened it, whether or not the menu that carries the shortcut is reachable.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if keys == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "f" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the wall's view and takes every click and movement of the pointer over it.
final class WallContentView: NSView {
    var onClick: (() -> Void)?
    private var pointerTimer: Timer?
    /// The pointer goes out of sight after this long without moving.
    static let pointerRest = 3.0

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func host(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    /// Everything over the wall is the wall.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func mouseMoved(with event: NSEvent) { pointerMoved() }
    override func mouseEntered(with event: NSEvent) { pointerMoved() }

    override func mouseExited(with event: NSEvent) {
        pointerTimer?.invalidate()
    }

    func pointerMoved() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pointerRest, repeats: false) { _ in
            MainActor.assumeIsolated { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    func stop() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }
}

/// The rows wall mode adds to Settings, under Display.
struct WallSettingsRows: View {
    @State private var settings = WallSettings.shared
    @State private var screens = WallScreens.choices

    var body: some View {
        @Bindable var settings = settings
        Group {
            // With one screen there is nothing to choose.
            if screens.count > 1 {
                Picker("Wall opens on", selection: $settings.screen) {
                    Text("The screen the pointer is on").tag("")
                    ForEach(screens) { screen in
                        Text(screen.title).tag(screen.id)
                    }
                    // A screen that was chosen and is not plugged in keeps its place in the list.
                    if !settings.screen.isEmpty, !screens.contains(where: { $0.id == settings.screen }) {
                        Text("A screen that is not connected").tag(settings.screen)
                    }
                }
            }
            Toggle("Wall keeps the screen awake", isOn: $settings.keepAwake)
                .help("While the wall is open the display does not sleep.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = WallScreens.choices
        }
    }
}
