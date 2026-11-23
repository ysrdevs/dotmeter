import AppKit
import SwiftUI

/// A borderless panel that can take keyboard focus without activating the app, like Control Center.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu bar items, the panel they open, the desktop window and the settings window.
///
/// Any area can have its own item. The dashboard's is the heartbeat icon and opens the overview; the others
/// draw a small live graph with their figure and open a panel about that one area. There is one panel, and
/// it is rebuilt for whichever item was clicked, so only one area's views are ever kept alive.
@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private var items: [AppSection: NSStatusItem] = [:]
    /// What each item last drew, so an unchanged reading does not redraw the menu bar.
    private var itemKeys: [AppSection: String] = [:]
    private var faces: [AppSection: StatusFace] = [:]
    /// Whether the items show their pictures through layers of their own, which costs about a third as much as
    /// handing each picture to the button. Off unless asked for, until it has been looked at on a real menu bar:
    /// DOTMETER_ITEM_DRAW=layer for one run, or `defaults write com.ysr.dotmeter menuBarLayers -bool true`.
    private static let layerItems = ProcessInfo.processInfo.environment["DOTMETER_ITEM_DRAW"] == "layer"
        || (ProcessInfo.processInfo.environment["DOTMETER_ITEM_DRAW"] == nil && UserDefaults.standard.bool(forKey: "menuBarLayers"))
    private let models: AppModels
    private let monitor: SystemMonitor
    private let analysis: AnalysisSession
    private let storage: StorageModel

    private var panel: FloatingPanel?
    /// The area whose content the panel holds, and the item it hangs from.
    private var panelSection: AppSection?
    private var anchor: AppSection = .dashboard
    private var panelSize = CGSize(width: PopoverView.width, height: 560)
    private let panelActivity = ViewActivity(active: false)
    private var eventMonitors: [Any] = []
    /// The panel was just closed by a press on the very item it hangs from. See `dismissPanel(pressAt:)`.
    private var dismissedByItem: (section: AppSection, at: Date, onItem: Bool)?

    private var mainWindow: NSWindow?
    private let windowActivity = ViewActivity(active: false)
    private let router = AppRouter()
    private var settingsWindow: NSWindow?
    private var settingsOpen = false

    init(models: AppModels) {
        self.models = models
        monitor = models.monitor
        analysis = models.analysis
        storage = models.storage
        super.init()

        MainMenu.install(target: self)
        syncItems()
        monitor.addObserver { [weak self] _ in self?.updateItems() }
        // A screen added or taken away changes how the items are drawn: see `updateItems`.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.itemKeys.removeAll()
                self?.updateItems()
            }
        }
        trackSettings()
        trackRouter()
    }

    // MARK: Menu bar items

    private func trackSettings() {
        withObservationTracking {
            _ = AppSettings.shared.menuBarStyle
            _ = AppSettings.shared.menuBarItems
            _ = AppSettings.shared.menuBarItemStyles
            _ = AppSettings.shared.latencyEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncItems()
                self?.updateCadence()
                self?.trackSettings()
            }
        }
    }

    /// The window's area decides whether per-app network traffic is worth reading.
    private func trackRouter() {
        withObservationTracking {
            _ = router.section
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateCadence()
                self?.trackRouter()
            }
        }
    }

    /// Makes the menu bar match the settings: adds the items that are wanted, removes the ones that are not.
    private func syncItems() {
        let settings = AppSettings.shared
        let wanted = settings.menuBarItems
        for section in Array(items.keys) where !wanted.contains(section) {
            if panel?.isVisible == true, anchor == section { closePanel() }
            if let item = items.removeValue(forKey: section) { NSStatusBar.system.removeStatusItem(item) }
            itemKeys[section] = nil
            faces[section] = nil
        }
        // A new item appears to the left of the ones already there, so the right-most is made first.
        for section in wanted.reversed() where items[section] == nil {
            items[section] = makeItem(section)
        }
        // Anything but the plain icon shows a figure that should keep moving while nothing is open.
        // (The USB item is the exception: it changes when something is plugged in, not every two seconds.)
        monitor.menuBarLive = wanted.contains { $0 != .dashboard && $0 != .usb } || settings.menuBarStyle != .icon
        // The USB item is redrawn when something is plugged in or pulled out; the clock is only a fallback.
        monitor.setUSBBackground("menu bar", every: wanted.contains(.usb) ? 30 : nil)
        itemKeys.removeAll()
        updateItems()
    }

    private func makeItem(_ section: AppSection) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A fixed name keeps each item where the user dragged it. The dashboard keeps the name the single
        // icon always had, so it stays where it was.
        item.autosaveName = section == .dashboard ? "Item-0" : "Dotmeter." + section.rawValue
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = section == .dashboard ? "\(App.name)" : "\(App.name) · " + section.title
            button.imagePosition = .imageLeading
        }
        return item
    }

    private func updateItems() {
        let settings = AppSettings.shared
        // Other screens show copies of each item that macOS makes by asking the button to draw, so with more than
        // one screen the items are drawn the usual way.
        let layered = Self.layerItems && NSScreen.screens.count == 1
        for (section, item) in items {
            guard let button = item.button else { continue }
            if section == .dashboard {
                // Touching the button at all makes macOS redraw the item, and its copy on every other display,
                // so it is left alone unless the icon or the figure beside it is different.
                let severity = monitor.latestSeverity
                let text = MenuBarIcon.text(style: settings.menuBarStyle, snapshot: monitor.latest)
                let key = "\(severity)|\(text ?? "")"
                guard itemKeys[section] != key else { continue }
                itemKeys[section] = key
                button.image = MenuBarIcon.image(severity: severity)
                if let text {
                    button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.labelColor,
                    ])
                } else {
                    button.title = ""
                }
                continue
            }
            let style = settings.itemStyle(for: section)
            guard let snapshot = monitor.latest else {
                if button.image == nil {
                    let symbol = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
                    symbol?.isTemplate = true
                    button.image = symbol
                }
                continue
            }
            let content = MenuBarRenderer.content(for: section, snapshot: snapshot, history: monitor.latestHistory, storage: storage)
            // A dark menu bar wants white ink and a light one black; a template picture is given that by macOS,
            // a layer has to be told.
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
            let key = MenuBarRenderer.key(content, style: style) + (layered ? (dark ? ";layer-dark" : ";layer-light") : "")
            guard itemKeys[section] != key else { continue }
            itemKeys[section] = key
            if layered {
                // The picture goes to a layer of the item's own. The button is never asked to draw, which is what
                // made a changing item cost what it did: see `StatusFace`.
                let plan = MenuBarRenderer.plan(content, style: style, id: section.rawValue, color: content.tint ?? (dark ? .white : .black))
                guard let pixels = MenuBarRenderer.pixels(plan, scale: button.window?.backingScaleFactor ?? 2) else { continue }
                let face = faces[section] ?? {
                    let face = StatusFace(frame: button.bounds)
                    face.autoresizingMask = [.width, .height]
                    faces[section] = face
                    button.addSubview(face)
                    button.image = nil
                    button.toolTip = nil
                    // The tooltip is asked for when it is about to show, not written on every reading.
                    button.addToolTip(NSRect(x: 0, y: 0, width: 4000, height: 200), owner: face, userData: nil)
                    // A view is told its appearance as it joins a window, in the middle of this very loop, so the
                    // redraw waits for the loop to be over.
                    face.appearanceChanged = { [weak self] in
                        DispatchQueue.main.async {
                            self?.itemKeys[section] = nil
                            self?.updateItems()
                        }
                    }
                    return face
                }()
                // The picture's own width: macOS adds the same margin round it as it does round an image.
                let length = plan.size.width
                if item.length != length { item.length = length }
                face.tip = content.tooltip
                face.show(pixels, size: plan.size, template: content.tint == nil)
            } else {
                if let face = faces.removeValue(forKey: section) {
                    face.removeFromSuperview()
                    button.removeAllToolTips()
                    item.length = NSStatusItem.variableLength
                }
                button.image = MenuBarRenderer.image(content, style: style, id: section.rawValue)
                button.toolTip = content.tooltip
            }
        }
    }

    /// How often per-app network traffic is worth reading for what is on screen, if at all.
    private static func networkAppsPace(_ section: AppSection?) -> Double? {
        switch section {
        case .network: return 1.9
        case .dashboard: return 3.9
        default: return nil
        }
    }

    private func updateCadence() {
        let paces = [
            panelActivity.active ? Self.networkAppsPace(panelSection) : nil,
            windowActivity.active ? Self.networkAppsPace(router.section) : nil,
        ]
        monitor.networkAppsEvery = paces.compactMap { $0 }.min()
        let onNetwork = (panelActivity.active && panelSection == .network) || (windowActivity.active && router.section == .network)
        monitor.networkLatencyWanted = onNetwork && AppSettings.shared.latencyEnabled
        monitor.networkPortsWanted = windowActivity.active && router.section == .network
        // A panel always shows apps or sensors. The window does on its live pages; Settings lists every sensor.
        let windowNeedsDetail = windowActivity.active && router.section.isLive && router.section != .usb
        monitor.detailWanted = panelActivity.active && panelSection != .usb || windowNeedsDetail || settingsOpen
        monitor.usbWanted = (panelActivity.active && panelSection == .usb) || (windowActivity.active && router.section == .usb)
        // Settings lists the sensors live, so it counts as something on screen.
        monitor.panelVisible = panelActivity.active || windowActivity.active || settingsOpen
    }

    // MARK: Menu bar panel

    @objc private func handleClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let section = items.first(where: { $0.value.button === button })?.key else { return }
        let dismissed = dismissedByItem
        dismissedByItem = nil
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu(for: section)
            return
        }
        // The press that led to this click may already have closed this item's panel as a click outside it.
        // That was the second click on the item, which closes: opening again here would undo it.
        if let dismissed, dismissed.section == section, panel?.isVisible != true {
            let elapsed = Date().timeIntervalSince(dismissed.at)
            if dismissed.onItem ? elapsed < 3 : elapsed < 0.4 { return }
        }
        if panel?.isVisible == true, anchor == section { closePanel() } else { showPanel(for: section) }
    }

    /// A press anywhere outside the panel closes it. The item's own action only arrives when the button comes
    /// up again, so a press on the item the panel hangs from is remembered: its action must leave the panel
    /// closed. Where the press landed is checked against the item, and a press that is followed by the item's
    /// action within a moment counts as well, since no one clicks elsewhere and then on the item that fast.
    private func dismissPanel(pressAt point: NSPoint) {
        guard let panel, panel.isVisible else { return }
        let onItem = items[anchor]?.button?.window?.frame.insetBy(dx: -1, dy: -1).contains(point) ?? false
        dismissedByItem = (anchor, Date(), onItem)
        closePanel()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    /// Fills the panel with one area's content and measures it, so it opens at its real size.
    private func install(_ section: AppSection, in panel: FloatingPanel) {
        let screen = items[anchor]?.button?.window?.screen ?? NSScreen.main
        let room = max(360, (screen?.visibleFrame.height ?? 900) - 12)
        let root = PanelRootView(
            section: section,
            maxHeight: room,
            openApp: { [weak self] target in self?.openWindow(on: target) },
            openSettings: { [weak self] in self?.openSettings(nil) }
        )
        .pxCard(shadow: false)
        .dotmeterModels(models)
        .environment(\.pxActivity, panelActivity)

        let host = PanelHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.onFittingSize = { [weak self] size in self?.panelContentResized(size) }
        panel.contentView = host
        panelSection = section
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if size.width > 10, size.height > 10 { panelSize = CGSize(width: ceil(size.width), height: ceil(size.height)) }
    }

    private func panelContentResized(_ size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded != panelSize else { return }
        panelSize = rounded
        if panel?.isVisible == true { positionPanel() }
    }

    private func positionPanel() {
        guard let panel, let button = (items[anchor] ?? items.values.first)?.button, let buttonWindow = button.window else { return }
        let anchorFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = min(panelSize.height, max(200, visible.height - 12))
        var x = anchorFrame.midX - panelSize.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        let top = anchorFrame.minY - 6
        panel.setFrame(NSRect(x: x, y: top - height, width: panelSize.width, height: height), display: true)
        panel.invalidateShadow()
    }

    private func showPanel(for section: AppSection) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let wasVisible = panel.isVisible
        // An area without an item of its own (a debug request) hangs from whichever item there is.
        anchor = items[section] != nil ? section : (AppSettings.shared.menuBarItems.first ?? .dashboard)
        if panelSection != section { install(section, in: panel) }
        panelActivity.active = true
        updateCadence()
        positionPanel()
        if wasVisible {
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }

        // Debug: DOTMETER_PIN_PANEL=1 keeps the panel open when clicking elsewhere, for measurement and captures.
        let pinned = ProcessInfo.processInfo.environment["DOTMETER_PIN_PANEL"] == "1"
        let outside = pinned ? nil : NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissPanel(pressAt: point) }
        }
        let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePanel(); return nil }
                return event
            }
            if event.window !== panel && !self.isItemWindow(event.window) { self.dismissPanel(pressAt: NSEvent.mouseLocation) }
            return event
        }
        eventMonitors = [outside, inside].compactMap { $0 }
    }

    private func isItemWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return items.values.contains { $0.button?.window === window }
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panelActivity.active = false
        updateCadence()
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
    }

    // MARK: Status item menu

    private func showMenu(for section: AppSection) {
        closePanel()
        let settings = AppSettings.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: section == .dashboard ? "Open \(App.name)" : "Open \(section.title) in \(App.name)", action: #selector(openSection(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = section.rawValue
        menu.addItem(open)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())

        let heading = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for candidate in AppSettings.menuBarSections {
            let shown = settings.isInMenuBar(candidate)
            let toggle = NSMenuItem(title: candidate.title, action: #selector(toggleItem(_:)), keyEquivalent: "")
            toggle.target = self
            toggle.representedObject = candidate.rawValue
            toggle.state = shown ? .on : .off
            toggle.image = NSImage(systemSymbolName: candidate.symbol, accessibilityDescription: nil)
            // The last item stays, or there would be no way back to the app.
            toggle.isEnabled = !shown || settings.canRemoveFromMenuBar(candidate)
            menu.addItem(toggle)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(App.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        guard let item = items[section] else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = AppSection(rawValue: raw) else { return }
        AppSettings.shared.setInMenuBar(section, !AppSettings.shared.isInMenuBar(section))
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        let section = (sender.representedObject as? String).flatMap(AppSection.init(rawValue:))
        openWindow(on: section == .dashboard ? nil : section)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        AppSettings.shared.launchAtLogin.toggle()
    }

    // MARK: Desktop window

    /// Opens the window, on a particular area when one is given.
    func openWindow(on section: AppSection?) {
        if let section { router.section = section }
        openMainWindow(nil)
    }

    @objc func openMainWindow(_ sender: Any?) {
        closePanel()
        if mainWindow == nil {
            let root = MainView(openSettings: { [weak self] in self?.openSettings(nil) })
                .dotmeterModels(models)
                .environment(router)
                .environment(\.pxActivity, windowActivity)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = "\(App.name)"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // The window moves by its background. For that macOS works out, after every change to the page, which
            // parts of it can be dragged: about half a percent of a core on the Dashboard. A drag can only start
            // with the pointer over the window, so that is the only time it is switched on.
            window.isMovableByWindowBackground = NSMouseInRect(NSEvent.mouseLocation, window.frame, false)
            host.view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: ["window": "main"]))
            window.contentMinSize = NSSize(width: MainView.sidebarWidth + PX.cardWidth + 48, height: 480)
            window.setContentSize(NSSize(width: MainView.sidebarWidth + PX.cardWidth * 2 + 20 + 64, height: 940))
            window.center()
            // Debug: DOTMETER_WINDOW_SIZE=1458x1700 opens at that content size and leaves the saved frame alone.
            let debugSize = (ProcessInfo.processInfo.environment["DOTMETER_WINDOW_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
            if debugSize.count == 2 {
                window.setContentSize(NSSize(width: debugSize[0], height: debugSize[1]))
            } else {
                window.setFrameAutosaveName("DotmeterWindow.v2")
            }
            window.appearance = Self.debugAppearance
            window.delegate = self
            mainWindow = window
        }
        // A window deserves a Dock icon and a place in Cmd-Tab; both go away again when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        windowActivity.active = true
        updateCadence()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsOpen = false
            updateCadence()
            return
        }
        guard let closing = notification.object as? NSWindow, closing === mainWindow else { return }
        windowActivity.active = false
        updateCadence()
        if settingsWindow?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
        // A closed window that keeps its views keeps everything they hold, for a menu bar app that may not
        // show a window again for days. Let it go once it has finished closing; the next open builds a new one
        // on the same area, at the frame this one saved.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mainWindow === closing, !closing.isVisible else { return }
            closing.delegate = nil
            closing.contentViewController = nil
            self.mainWindow = nil
        }
    }

    /// The pointer came over the main window, or left it: see `openMainWindow`.
    @objc func mouseEntered(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["window"] as? String == "main" else { return }
        mainWindow?.isMovableByWindowBackground = true
    }

    @objc func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["window"] as? String == "main", let window = mainWindow else { return }
        // Not while a button is down: a drag that has started carries the pointer with the window.
        if NSEvent.pressedMouseButtons == 0 { window.isMovableByWindowBackground = false }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        if NSMouseInRect(NSEvent.mouseLocation, window.frame, false) { window.isMovableByWindowBackground = true }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        let forced = ProcessInfo.processInfo.environment["DOTMETER_FORCE_ACTIVE"] == "1"
        windowActivity.active = forced || (window.isVisible && window.occlusionState.contains(.visible))
        updateCadence()
    }

    // MARK: Settings

    @objc func openSettings(_ sender: Any?) {
        closePanel()
        if settingsWindow == nil {
            let view = SettingsView()
                .dotmeterModels(models)
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "\(App.name) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.appearance = Self.debugAppearance
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsOpen = true
        updateCadence()
    }

    // MARK: Debug

    static var debugAppearance: NSAppearance? {
        switch ProcessInfo.processInfo.environment["DOTMETER_APPEARANCE"] {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// Debug aid (`--open`): show the panel and/or window, drive a scripted storage demo, and write PNG captures.
    /// DOTMETER_CAPTURE_PANEL=path, DOTMETER_CAPTURE_WINDOW=path, DOTMETER_CAPTURE_SEQ=dir (window frames every 0.25 s),
    /// DOTMETER_DEBUG_ANALYZE=1, DOTMETER_SCRIPT=scan|clear|item (item: DOTMETER_DEBUG_ITEM, DOTMETER_SEQ_INTERVAL ms).
    func debugRun() {
        let env = ProcessInfo.processInfo.environment
        Task { @MainActor in
            if env["DOTMETER_CAPTURE_PANEL"] != nil || env["DOTMETER_SHOW_PANEL"] == "1" {
                // DOTMETER_PANEL=<area> opens that area's panel instead of the dashboard's.
                showPanel(for: AppSection(rawValue: env["DOTMETER_PANEL"] ?? "") ?? .dashboard)
                if env["DOTMETER_DEBUG_ANALYZE"] == "1", let snapshot = monitor.snapshot {
                    analysis.analyze(snapshot: snapshot, history: monitor.history)
                }
                // DOTMETER_DEBUG_EXPLAIN=1 presses Explain on whatever is shown, once readings exist.
                if env["DOTMETER_DEBUG_EXPLAIN"] == "1" {
                    try? await Task.sleep(for: .seconds(2.2))
                    if let snapshot = monitor.snapshot, let section = panelSection { models.explainer.explain(section, snapshot: snapshot, history: monitor.history) }
                }
                try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 2.5))
                if let path = env["DOTMETER_CAPTURE_PANEL"], let view = panel?.contentView { Self.capture(view, to: path) }
                if env["DOTMETER_CAPTURE_WINDOW"] != nil || env["DOTMETER_CAPTURE_SEQ"] != nil { closePanel() }
            }
            if env["DOTMETER_CAPTURE_WINDOW"] != nil || env["DOTMETER_CAPTURE_SEQ"] != nil || env["DOTMETER_SHOW_WINDOW"] == "1" {
                openMainWindow(nil)
                if env["DOTMETER_DEBUG_ANALYZE"] == "1", analysis.turns.isEmpty, let snapshot = monitor.snapshot {
                    analysis.analyze(snapshot: snapshot, history: monitor.history)
                }
                if let question = env["DOTMETER_DEBUG_ASK"], analysis.turns.isEmpty {
                    analysis.ask(question, snapshot: monitor.snapshot, history: monitor.history)
                }
                if env["DOTMETER_DEBUG_EXPLAIN"] == "1" || env["DOTMETER_DEBUG_SPEED"] == "1" {
                    try? await Task.sleep(for: .seconds(2.2))
                    if env["DOTMETER_DEBUG_EXPLAIN"] == "1", let snapshot = monitor.snapshot { models.explainer.explain(router.section, snapshot: snapshot, history: monitor.history) }
                    // DOTMETER_DEBUG_SPEED=1 starts a speed test (a real one unless DOTMETER_SPEED_DEMO=1).
                    if env["DOTMETER_DEBUG_SPEED"] == "1" { models.speed.run() }
                }
                try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 2.5))
                if let dir = env["DOTMETER_CAPTURE_SEQ"], let view = mainWindow?.contentView {
                    let script = env["DOTMETER_SCRIPT"] ?? "scan"
                    if script == "scan" {
                        storage.scan()
                    } else if script == "item" {
                        // Demo data only: arm and confirm one row (DOTMETER_DEBUG_ITEM, in DOTMETER_DEBUG_CATEGORY).
                        let category = env["DOTMETER_DEBUG_CATEGORY"] ?? "caches"
                        if storage.isDemo, let item = storage.items(in: category).first(where: { $0.name == env["DOTMETER_DEBUG_ITEM"] }) {
                            storage.requestItemAction(item, in: category)
                            storage.requestItemAction(item, in: category)
                        }
                    } else {
                        storage.requestClear("caches")
                    }
                    let frames = Int(env["DOTMETER_SEQ_FRAMES"] ?? "") ?? 26
                    let interval = Int(env["DOTMETER_SEQ_INTERVAL"] ?? "") ?? 250
                    for i in 0..<frames {
                        Self.capture(view, to: String(format: "%@/f_%02d.png", dir, i), quiet: true)
                        try? await Task.sleep(for: .milliseconds(interval))
                        if script == "clear", i == 13 { storage.requestClear("trash") }
                    }
                    print("SEQ_DONE \(frames)")
                }
                if let path = env["DOTMETER_CAPTURE_WINDOW"], let view = mainWindow?.contentView { Self.capture(view, to: path) }
            }
            // DOTMETER_LOG_ITEMS=1: where each menu bar item sits and how wide it is, since the menu bar itself
            // cannot be captured.
            // DOTMETER_DEBUG_TOGGLE=cpu,network,cpu: adds or removes those items one second apart, as the menu
            // and the page buttons do, and reports what is in the menu bar after each. Nothing is saved when
            // DOTMETER_MENU_ITEMS is set as well.
            if let list = env["DOTMETER_DEBUG_TOGGLE"] {
                for name in list.split(separator: ",") {
                    guard let section = AppSection(rawValue: String(name)) else { continue }
                    AppSettings.shared.setInMenuBar(section, !AppSettings.shared.isInMenuBar(section))
                    try? await Task.sleep(for: .seconds(1))
                    let present = AppSettings.menuBarSections.filter { items[$0] != nil }.map(\.rawValue).joined(separator: ",")
                    print("TOGGLE \(name) -> menu bar now: \(present) · panel \(panel?.isVisible == true ? "open on \(panelSection?.rawValue ?? "-")" : "closed") · live \(monitor.menuBarLive)")
                }
            }
            // DOTMETER_DEBUG_CLICKS=<area>: walks an item through open, second click, open again and a click
            // elsewhere, with the press arriving first as it does from the menu bar, and reports each state.
            if let name = env["DOTMETER_DEBUG_CLICKS"], let section = AppSection(rawValue: name), let button = items[section]?.button {
                let state: @MainActor () -> String = { [unowned self] in panel?.isVisible == true ? "open on \(panelSection?.rawValue ?? "-")" : "closed" }
                let onItem = button.window.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
                closePanel()
                handleClick(button)
                print("CLICKS 1 first click: \(state())")
                dismissPanel(pressAt: onItem)
                handleClick(button)
                print("CLICKS 2 second click, press seen as outside the panel first: \(state())")
                handleClick(button)
                print("CLICKS 3 third click: \(state())")
                handleClick(button)
                print("CLICKS 4 fourth click, press not seen first: \(state())")
                handleClick(button)
                dismissPanel(pressAt: NSPoint(x: onItem.x - 400, y: onItem.y - 300))
                print("CLICKS 5 opened, then a click elsewhere: \(state())")
                try? await Task.sleep(for: .seconds(0.6))
                handleClick(button)
                print("CLICKS 6 a click on the item after that: \(state())")
                closePanel()
            }
            if env["DOTMETER_LOG_ITEMS"] == "2" {
                // Positions over time, to tell a settled layout from one that is still sliding into place.
                for second in 0..<6 {
                    let row = AppSettings.menuBarSections.compactMap { section -> String? in
                        guard let frame = items[section]?.button?.window?.frame else { return nil }
                        return "\(section.rawValue)=\(Int(frame.minX))..\(Int(frame.maxX))"
                    }
                    print("ITEMS t+\(second)s " + row.joined(separator: " "))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if env["DOTMETER_LOG_ITEMS"] == "1" {
                for section in AppSettings.menuBarSections {
                    guard let item = items[section], let button = item.button else { continue }
                    let frame = button.window?.frame ?? .zero
                    if panel?.isVisible == true, anchor == section, let frame = panel?.frame, let under = button.window?.frame {
                        print("PANEL \(panelSection?.rawValue ?? "-") \(Int(frame.width))x\(Int(frame.height)) centre offset from its item \(Int(frame.midX - under.midX)), gap below menu bar \(Int(under.minY - frame.maxY))")
                    }
                    print("ITEM \(section.rawValue) visible=\(item.isVisible) x=\(Int(frame.minX)) width=\(Int(frame.width)) image=\(button.image.map { "\(Int($0.size.width))x\(Int($0.size.height)) template=\($0.isTemplate)" } ?? "none") tip=\(button.toolTip ?? "")")
                }
            }
            // DOTMETER_CAPTURE_ITEMS=folder: each item's own window as it stands, one picture an item.
            if let folder = env["DOTMETER_CAPTURE_ITEMS"] {
                for (section, item) in items {
                    guard let view = item.button?.window?.contentView else { continue }
                    Self.capture(view, to: folder + "/item-\(section.rawValue).png")
                }
            }
            // DOTMETER_CAPTURE_MENUBAR=path: every area's menu bar item in every style, on dark and light strips.
            if let path = env["DOTMETER_CAPTURE_MENUBAR"], let snapshot = monitor.snapshot {
                MenuBarRenderer.writeSheet(to: path, snapshot: snapshot, history: monitor.history, storage: storage)
            }
            if let path = env["DOTMETER_CAPTURE_SETTINGS"] {
                openSettings(nil)
                try? await Task.sleep(for: .seconds(1.5))
                if let view = settingsWindow?.contentView { Self.capture(view, to: path) }
            }
            // DOTMETER_DEBUG_LOOP=scan: demo data only, scan again and again so the scan animation can be measured.
            if env["DOTMETER_DEBUG_LOOP"] == "scan", storage.isDemo {
                Task { @MainActor [storage] in
                    while true {
                        if storage.phase == .ready || storage.phase == .unscanned { storage.scan() }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            // DOTMETER_CLOSE_AFTER=<seconds>: close the panel and window again, to measure what the app
            // costs in the background once they have been used.
            if let after = env["DOTMETER_CLOSE_AFTER"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(after))
                closePanel()
                mainWindow?.close()
                print("CLOSED panel and window")
                // DOTMETER_REOPEN_AFTER=<seconds>: open the window again after that, to check that a window which
                // was let go comes back on the same area (DOTMETER_REOPEN_CAPTURE=path writes what it shows).
                if let again = env["DOTMETER_REOPEN_AFTER"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(again))
                    print("WINDOW \(mainWindow == nil ? "was released" : "was kept")")
                    openMainWindow(nil)
                    try? await Task.sleep(for: .seconds(4))
                    print("REOPENED on \(router.section.rawValue), visible \(mainWindow?.isVisible == true)")
                    if let path = env["DOTMETER_REOPEN_CAPTURE"], let view = mainWindow?.contentView { Self.capture(view, to: path) }
                }
            }
            fflush(stdout)
        }
    }

    private static func capture(_ view: NSView, to path: String, quiet: Bool = false) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            if !quiet { print("CAPTURE \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)") }
        }
    }
}

/// A menu bar item's picture shown by a layer of its own.
///
/// Giving a status item's button a new image makes AppKit draw the button, lay the item out again, and draw it a
/// second time for the copies it keeps for other screens: about six milliseconds an item, every time a figure
/// changes. A layer's contents go straight to the compositor and none of that happens. Five live items cost
/// 1.1% of a core the first way and 0.4% this way, which is what the plain icon alone costs.
final class StatusFace: NSView, NSViewToolTipOwner {
    private let picture = CALayer()
    var tip = ""
    var appearanceChanged: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(picture)
        picture.contentsGravity = .resize
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks belong to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { tip }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func layout() {
        super.layout()
        place()
    }

    private var size = NSSize.zero

    private func place() {
        // Whole pixels, or the picture is resampled and its dots blur.
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        picture.frame = NSRect(x: snap((bounds.width - size.width) / 2), y: snap((bounds.height - size.height) / 2), width: size.width, height: size.height)
    }

    /// A template picture is one macOS would ink itself. It does so at nine tenths strength, measured from a
    /// button's own drawing; a picture in a warning colour is shown as it is.
    func show(_ pixels: CGImage, size: NSSize, template: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.size = size
        picture.opacity = template ? 0.9 : 1
        picture.contentsScale = window?.backingScaleFactor ?? 2
        place()
        picture.contents = pixels
        CATransaction.commit()
    }
}
