import Foundation
import SwiftUI

/// The app's readings from a terminal (`dotmeter status`) and for AI apps (`dotmeter mcp`).
enum Command {
    /// Whether these arguments are a command for this, and not the app being opened.
    static func handles(_ arguments: [String]) -> Bool { false }

    static func run(_ arguments: [String]) -> Never { exit(0) }
}

/// The section Settings shows about the command and the AI server.
struct CommandSettingsSection: View {
    var body: some View { EmptyView() }
}

extension DebugTools {
    static func commandSelfTest(models: AppModels) async { print("not written yet") }
}
