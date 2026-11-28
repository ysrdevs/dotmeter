import SwiftUI

/// Local AI models: what is running them on this Mac, which models are loaded and what they hold.
@MainActor
@Observable
final class RunnersModel {
    /// What the sidebar shows beside "Models": how many are loaded, or nothing.
    var sidebarValue: String { "" }
}

struct RunnersPage: View {
    var body: some View {
        PageScaffold(title: "Models", subtitle: "Not written yet", section: .models) { gridWidth, _ in
            LoadingCard(width: gridWidth)
        }
    }
}

extension DebugTools {
    static func modelsSelfTest(models: AppModels) async { print("not written yet") }
}
