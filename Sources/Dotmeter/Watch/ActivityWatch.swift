import Foundation

/// What is noted in the Timeline without being a reading of the machine: an app using the microphone or the
/// camera, and an app that crashed.
@MainActor
final class ActivityWatch {
    /// At launch. Watches for as long as the app runs.
    func start(models: AppModels) {}
}

extension DebugTools {
    static func watchSelfTest(models: AppModels) async { print("not written yet") }
}
