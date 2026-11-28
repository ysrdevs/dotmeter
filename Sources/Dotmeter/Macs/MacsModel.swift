import SwiftUI

/// The user's other Macs, found on the local network, and this Mac shown to them.
@MainActor
@Observable
final class MacsModel {
    /// What the sidebar shows beside "Macs": how many others are in view, or nothing.
    var sidebarValue: String { "" }

    /// At launch. Does nothing on the network unless the user has switched this on.
    func start(models: AppModels) {}
}

struct MacsPage: View {
    var body: some View {
        PageScaffold(title: "Macs", subtitle: "Not written yet", section: .macs) { gridWidth, _ in
            LoadingCard(width: gridWidth)
        }
    }
}

/// The section Settings shows for this feature. Empty when there is nothing to set.
struct MacsSettingsSection: View {
    var body: some View { EmptyView() }
}

extension DebugTools {
    static func macsSelfTest(models: AppModels) async { print("not written yet") }
}
