import AppKit
import Observation

/// What the wall remembers: which screen it takes, and whether it keeps that screen awake.
///
/// Each has a switch that sets it for one run without saving, so a test never changes what the owner chose.
@MainActor
@Observable
final class WallSettings {
    static let shared = WallSettings()

    /// The screen the wall opens on, as that display's id (see `WallScreens.id`). Empty: wherever the pointer is.
    /// Debug: DOTMETER_WALL_SCREEN=<id, name or number counting from 1> chooses one for a run.
    var screen: String {
        didSet { if !temporaryScreen { defaults.set(screen, forKey: "wallScreen") } }
    }

    /// Hold the display awake for as long as the wall is open.
    /// Debug: DOTMETER_WALL_AWAKE=on|off decides for a run.
    var keepAwake: Bool {
        didSet { if !temporaryAwake { defaults.set(keepAwake, forKey: "wallKeepAwake") } }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let temporaryScreen: Bool
    @ObservationIgnored private let temporaryAwake: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        temporaryScreen = env["DOTMETER_WALL_SCREEN"] != nil
        temporaryAwake = env["DOTMETER_WALL_AWAKE"] != nil
        screen = env["DOTMETER_WALL_SCREEN"] ?? defaults.string(forKey: "wallScreen") ?? ""
        keepAwake = env["DOTMETER_WALL_AWAKE"].map { $0 != "off" } ?? (defaults.object(forKey: "wallKeepAwake") as? Bool ?? true)
    }
}

/// The screens the wall can take, and a name for each that survives a restart and a change of cable.
@MainActor
enum WallScreens {
    struct Choice: Identifiable, Hashable {
        var id: String
        var title: String
    }

    /// The display's own id, which macOS keeps for a display wherever it is plugged in.
    static func id(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static var choices: [Choice] {
        let screens = NSScreen.screens
        return screens.enumerated().map { index, screen in
            // Two of the same display are told apart by their place in the row.
            let twins = screens.filter { $0.localizedName == screen.localizedName }.count > 1
            return Choice(id: id(screen), title: twins ? "\(screen.localizedName) (\(index + 1))" : screen.localizedName)
        }
    }

    /// The screen a saved choice means, if it is connected. A name or a number counting from one also work, for
    /// the debug switch.
    static func screen(for choice: String) -> NSScreen? {
        guard !choice.isEmpty else { return nil }
        let screens = NSScreen.screens
        if let match = screens.first(where: { id($0) == choice }) { return match }
        if let match = screens.first(where: { $0.localizedName.caseInsensitiveCompare(choice) == .orderedSame }) { return match }
        if let number = Int(choice), number >= 1, number <= screens.count { return screens[number - 1] }
        return nil
    }

    /// Where the wall opens: the chosen screen while it is connected, else the one the pointer is on.
    static func target(_ choice: String) -> NSScreen? {
        if let chosen = screen(for: choice) { return chosen }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
