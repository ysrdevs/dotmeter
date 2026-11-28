import AppKit
import SwiftUI

/// The week card: a picture of the Mac's week, made to be shared.
@MainActor
final class WeekCardController: NSObject, NSWindowDelegate {
    static let shared = WeekCardController()

    private var window: NSWindow?
    private var model: WeekCardModel?

    /// Opens the card's window: the picture, and Save, Copy and Share.
    func show(models: AppModels) {
        if window == nil {
            let model = WeekCardModel { Self.input(models) }
            model.follow(models.timeline)
            let host = NSHostingController(rootView: WeekCardView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Week Card"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(WeekCardView.background)
            window.center()
            window.delegate = self
            model.window = window
            self.window = window
            self.model = model
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A closed window is let go, with the picture it held; the next open makes a new card from the week as it is then.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === closing, !closing.isVisible else { return }
            self.model?.cleanUp()
            closing.delegate = nil
            closing.contentViewController = nil
            self.window = nil
            self.model = nil
        }
    }

    /// The week as the store has it, the price from Settings, and the Mac as the sidebar's footer names it.
    /// Debug: DOTMETER_CARD_HISTORY=<minutes> keeps only that much of the week, to see a card made from a little
    /// history (0: none at all). DOTMETER_CARD_MAC="MacBook Pro|M4 Max" names another Mac, to try the fit.
    static func input(_ models: AppModels) -> WeekCardInput {
        var input = models.timeline.weekCardInput(price: AppSettings.shared.energyPrice)
        let env = ProcessInfo.processInfo.environment
        if let keep = env["DOTMETER_CARD_HISTORY"].flatMap(Int.init) {
            let from = input.now.addingTimeInterval(-Double(keep) * 60)
            input.minutes = input.minutes.filter { $0.date > from }
            input.events = input.events.filter { $0.start > from }
        }
        if let mac = env["DOTMETER_CARD_MAC"]?.split(separator: "|").map(String.init), let name = mac.first {
            input.model = name
            input.chip = mac.count > 1 ? mac[1] : ""
        }
        return input
    }

    /// Debug (`--open`): DOTMETER_CAPTURE_CARD=<png> writes the card itself and says how long it took;
    /// DOTMETER_CAPTURE_CARD_WINDOW=<png> writes the window; DOTMETER_SHOW_CARD=1 opens the window and leaves it;
    /// DOTMETER_CARD_CLOSE_AFTER=<seconds> then closes it.
    func debugRun(_ env: [String: String], models: AppModels) async {
        if let path = env["DOTMETER_CAPTURE_CARD"] {
            let started = CFAbsoluteTimeGetCurrent()
            if let spec = WeekCardSpec(Self.input(models), light: WeekCardChoices.light, appNames: WeekCardChoices.appNames) {
                let specified = CFAbsoluteTimeGetCurrent()
                let made = await Task.detached(priority: .userInitiated) { () -> (Data?, Double, Double) in
                    let begun = CFAbsoluteTimeGetCurrent()
                    let image = WeekCardRenderer.render(WeekCardPlate(spec))
                    let drawn = CFAbsoluteTimeGetCurrent()
                    let data = image.flatMap(WeekCardRenderer.png)
                    return (data, drawn - begun, CFAbsoluteTimeGetCurrent() - drawn)
                }.value
                if let data = made.0, (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                    print(String(format: "CAPTURE %@ %dx%d · figures %.1f ms, picture %.1f ms, PNG %.1f ms", path, WeekCardPlate.width, WeekCardPlate.height, (specified - started) * 1000, made.1 * 1000, made.2 * 1000))
                } else {
                    print("CARD could not be written to \(path)")
                }
            } else {
                print("CARD nothing recorded, no picture")
            }
        }
        if env["DOTMETER_CAPTURE_CARD_WINDOW"] != nil || env["DOTMETER_SHOW_CARD"] == "1" {
            show(models: models)
            for _ in 0..<60 where model?.settled != true { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .seconds(Double(env["DOTMETER_CAPTURE_DELAY"] ?? "") ?? 0.8))
            if let path = env["DOTMETER_CAPTURE_CARD_WINDOW"], let view = window?.contentView { StatusController.capture(view, to: path) }
            if env["DOTMETER_SHOW_CARD"] == "1" { print("CARD window open, \(model?.image == nil ? "no picture" : "picture shown")") }
            // DOTMETER_CARD_CLOSE_AFTER=<seconds>: close it again and say whether the window and its picture were let go.
            if let after = env["DOTMETER_CARD_CLOSE_AFTER"].flatMap(Double.init) {
                let held = Held(model: model, window: window)
                try? await Task.sleep(for: .seconds(after))
                window?.close()
                try? await Task.sleep(for: .seconds(1))
                print("CARD window closed, \(window == nil && held.model == nil && held.window == nil ? "released" : "kept: window \(held.window != nil), picture \(held.model != nil)")")
            }
        }
    }
}

/// For the debug run: a look at the window and its card that does not keep them alive.
@MainActor
private final class Held {
    weak var model: WeekCardModel?
    weak var window: NSWindow?

    init(model: WeekCardModel?, window: NSWindow?) {
        self.model = model
        self.window = window
    }
}

/// What the window remembers between one card and the next.
/// Debug: DOTMETER_CARD_LIGHT=heat|cpu|power and DOTMETER_CARD_APPS=0|1 choose for one run and save nothing.
@MainActor
enum WeekCardChoices {
    private static let env = ProcessInfo.processInfo.environment

    static var light: WeekCardLight {
        get { WeekCardLight(rawValue: env["DOTMETER_CARD_LIGHT"] ?? UserDefaults.standard.string(forKey: "weekCardLight") ?? "") ?? .heat }
        set { if env["DOTMETER_CARD_LIGHT"] == nil { UserDefaults.standard.set(newValue.rawValue, forKey: "weekCardLight") } }
    }

    /// On unless it has been switched off.
    static var appNames: Bool {
        get {
            if let forced = env["DOTMETER_CARD_APPS"] { return forced != "0" }
            return UserDefaults.standard.object(forKey: "weekCardAppNames") as? Bool ?? true
        }
        set { if env["DOTMETER_CARD_APPS"] == nil { UserDefaults.standard.set(newValue, forKey: "weekCardAppNames") } }
    }
}

/// The card on show: what it is made from, the two choices, and the picture once it is drawn.
@MainActor
@Observable
final class WeekCardModel {
    var light: WeekCardLight {
        didSet {
            guard light != oldValue else { return }
            if remembers { WeekCardChoices.light = light }
            refresh()
        }
    }

    var appNames: Bool {
        didSet {
            guard appNames != oldValue else { return }
            if remembers { WeekCardChoices.appNames = appNames }
            refresh()
        }
    }

    private(set) var spec: WeekCardSpec?
    private(set) var image: CGImage?
    /// The picture as the file that is saved, copied and shared, made once with the picture.
    @ObservationIgnored private(set) var png: Data?
    /// The week has been looked at: there is a picture, or there is nothing to make one from.
    private(set) var settled = false
    private(set) var copied = false

    @ObservationIgnored private let source: () -> WeekCardInput
    @ObservationIgnored private let remembers: Bool
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var shared: URL?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var shareAnchor: NSView?

    /// `remembers` is off for tests, which must not change what the window opens on.
    init(light: WeekCardLight? = nil, appNames: Bool? = nil, remembers: Bool = true, source: @escaping () -> WeekCardInput) {
        self.source = source
        self.remembers = remembers
        self.light = light ?? WeekCardChoices.light
        self.appNames = appNames ?? WeekCardChoices.appNames
        refresh()
    }

    /// Nothing was recorded in the seven days, so there is no card.
    var isEmpty: Bool { settled && spec == nil }

    /// Works the week out again and draws it. The drawing is done off the main thread; a picture that arrives
    /// after a newer one was asked for is dropped.
    func refresh() {
        serial += 1
        let current = serial
        guard let spec = WeekCardSpec(source(), light: light, appNames: appNames) else {
            self.spec = nil
            image = nil
            png = nil
            settled = true
            return
        }
        self.spec = spec
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = WeekCardRenderer.render(WeekCardPlate(spec))
            let png = image.flatMap(WeekCardRenderer.png)
            await self?.show(image, png, asked: current)
        }
    }

    private func show(_ drawn: CGImage?, _ data: Data?, asked: Int) {
        guard serial == asked else { return }
        png = data
        image = data == nil ? nil : drawn
        settled = true
    }

    /// A card left open keeps up: with the minute that was just recorded, a new price, another dot colour.
    func follow(_ store: TimelineStore) {
        withObservationTracking {
            _ = store.minutes.count
            _ = store.events.count
            _ = AppSettings.shared.theme
            _ = AppSettings.shared.energyPrice
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                self.refresh()
                self.follow(store)
            }
        }
    }

    // MARK: Out of the window

    /// The panel Save… shows: a PNG, named for the week.
    func savePanel() -> NSSavePanel? {
        guard let spec else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = spec.fileName
        panel.canCreateDirectories = true
        return panel
    }

    func save() {
        guard let window, let data = png, let panel = savePanel() else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// The picture on a pasteboard, as a PNG and as the TIFF older apps ask for.
    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image, let data = png else { return false }
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        let done = pasteboard.setData(data, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        guard done else { return false }
        copied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            self?.copied = false
        }
        return true
    }

    /// The picture as a file with its proper name, which is what Mail, Messages and AirDrop pass on.
    func share() {
        guard let spec, let anchor = shareAnchor, let data = png else { return }
        cleanUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(App.name)-week-card-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(spec.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return
        }
        shared = folder
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// The copy made for sharing is not kept.
    func cleanUp() {
        if let shared { try? FileManager.default.removeItem(at: shared) }
        shared = nil
    }
}

/// The window: the card scaled to fit, what lights it, and the three ways out.
struct WeekCardView: View {
    var model: WeekCardModel

    static let background = Color(hex: 0x141517)
    /// The card at four tenths of its size.
    static let picture = CGSize(width: 432, height: 540)
    private static let inset: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isEmpty {
                nothing
            } else {
                card
                HStack(spacing: 2) {
                    ForEach(WeekCardLight.allCases) { light in
                        PXPill(title: light.title, symbol: light.metric.symbol, rgb: light.metric.rgb, selected: model.light == light) { model.light = light }
                            .help("Light the week by \(light.title.lowercased())")
                    }
                    Spacer(minLength: 8)
                    AppNamesSwitch(on: model.appNames) { model.appNames.toggle() }
                }
                .padding(.top, 12)
                .padding(.horizontal, -5)
            }
            HStack(spacing: 7) {
                Text(model.isEmpty ? "" : "\(String(WeekCardPlate.width)) × \(String(WeekCardPlate.height)) PNG")
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.tertiary)
                Spacer(minLength: 8)
                PXButton(title: "Save…", symbol: "square.and.arrow.down", enabled: model.image != nil) { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                PXButton(title: model.copied ? "Copied" : "Copy", symbol: model.copied ? "checkmark" : "doc.on.doc", enabled: model.image != nil) { model.copy() }
                    .keyboardShortcut("c", modifiers: .command)
                PXButton(title: "Share", symbol: "square.and.arrow.up", enabled: model.image != nil) { model.share() }
                    .background(ShareAnchor(model: model))
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(width: Self.picture.width + Self.inset * 2)
        .background(Self.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            Color.black
            if let image = model.image {
                Image(image, scale: 1, label: Text("This Mac's week"))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: Self.picture.width, height: Self.picture.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Nothing recorded yet")
                .font(PX.font(13, .medium))
                .foregroundStyle(PX.text)
            Text("\(App.name) writes down one line a minute. Give it a few minutes and there is a week to make a card from.")
                .font(PX.font(12.5))
                .foregroundStyle(PX.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PX.inset)
        .frame(width: Self.picture.width, alignment: .leading)
        .pxCard()
    }
}

/// Whether the card may name an app. App names are the one thing on it that could be private.
private struct AppNamesSwitch: View {
    var on: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6.5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(on ? PX.buttonHover : PX.button)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(PX.text)
                    }
                }
                .frame(width: 13, height: 13)
                Text("App names")
                    .font(PX.font(11.5, on ? .medium : .regular))
                    .foregroundStyle(on ? PX.text : (hovering ? PX.soft : PX.secondary))
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? PX.ghostHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Leave app names off the card" : "Name the busiest app on the card")
    }
}

/// The view the share menu opens from.
private struct ShareAnchor: NSViewRepresentable {
    var model: WeekCardModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        model.shareAnchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        model.shareAnchor = view
    }
}
