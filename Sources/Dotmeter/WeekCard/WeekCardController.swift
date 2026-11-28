import AppKit
import SwiftUI

/// The week card: a picture of the Mac's week, made to be shared.
@MainActor
final class WeekCardController {
    static let shared = WeekCardController()

    /// Opens the card's window: the picture, and Save, Copy and Share.
    func show(models: AppModels) {}

    /// Debug (`--open`): whatever this feature's own switches ask for, such as a capture.
    func debugRun(_ env: [String: String], models: AppModels) async {}
}

extension DebugTools {
    static func cardSelfTest(models: AppModels) async { print("not written yet") }
}
