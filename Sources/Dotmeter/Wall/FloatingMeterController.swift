import AppKit
import SwiftUI

/// The floating meter: a small strip of figures that stays above every window, full-screen ones too.
@MainActor
final class FloatingMeterController {
    static let shared = FloatingMeterController()

    private(set) var isOn = false

    /// Shows the meter, or hides it if it is showing.
    func toggle(models: AppModels) {}

    /// At launch: shows the meter again if it was left on.
    func restore(models: AppModels) {}

    /// Debug (`--open`): whatever this feature's own switches ask for, such as a capture.
    func debugRun(_ env: [String: String], models: AppModels) async {}
}

/// The rows the floating meter adds to Settings, under Display.
struct FloatingMeterSettingsRows: View {
    var body: some View { EmptyView() }
}

extension DebugTools {
    static func floatingSelfTest(models: AppModels) async { print("not written yet") }
}
