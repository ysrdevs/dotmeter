import SwiftUI

/// What is noted in the Timeline without being a reading of the machine: an app using the microphone or the
/// camera, and an app that crashed.
@MainActor
@Observable
final class ActivityWatch {
    /// At launch. Watches for as long as the app runs.
    func start(models: AppModels) {}
}

/// The line at the foot of the sidebar that says the microphone or the camera is in use right now, and by what.
/// Nothing when neither is.
struct ActivityNotice: View {
    @Environment(ActivityWatch.self) private var watch

    var body: some View { EmptyView() }
}

extension DebugTools {
    static func watchSelfTest(models: AppModels) async { print("not written yet") }
}
