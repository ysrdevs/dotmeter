import AppKit
import SwiftUI

/// Wall mode: a whole screen of live dot-matrix meters, for a spare display.
@MainActor
final class WallController {
    static let shared = WallController()

    private(set) var isOpen = false

    /// Opens the wall, or closes it if it is open.
    func toggle(models: AppModels) {}

    /// Debug (`--open`): whatever this feature's own switches ask for, such as a capture.
    func debugRun(_ env: [String: String], models: AppModels) async {}
}

/// The rows wall mode adds to Settings, under Display.
struct WallSettingsRows: View {
    var body: some View { EmptyView() }
}

extension DebugTools {
    static func wallSelfTest(models: AppModels) async { print("not written yet") }
}
