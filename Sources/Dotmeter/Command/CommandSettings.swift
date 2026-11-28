import AppKit
import SwiftUI

/// What to type or paste to use the command and the AI server: this copy's own program, wherever it is.
enum CommandSetup {
    /// The name the AI apps list the server under.
    static let serverName = App.name.lowercased()

    /// This copy's own program. Debug: DOTMETER_COMMAND_DEMO=1 shows where an installed copy would be instead, so
    /// a capture of Settings does not show the folders of the Mac it was taken on.
    static var path: String {
        if Command.demo { return "/Applications/\(App.name).app/Contents/MacOS/\(App.name)" }
        return Bundle.main.executablePath ?? CommandLine.arguments.first ?? App.name
    }

    /// A path inside double quotes, with the four characters a shell still reads there made plain.
    static func quoted(_ path: String) -> String {
        var out = "\""
        for character in path {
            if "\"\\$`".contains(character) { out += "\\" }
            out.append(character)
        }
        return out + "\""
    }

    /// For a terminal: the path as it is where a shell takes it as one word, in quotes where it would not.
    static func terminal(_ path: String = CommandSetup.path) -> String {
        let plain = path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+".unicodeScalars.contains($0) }
        return "\(plain ? path : quoted(path)) status"
    }

    /// For the config file of Claude's desktop app.
    static func claude(_ path: String = CommandSetup.path) -> String {
        JSON.record(["mcpServers": .record([serverName: .record(["command": .string(path), "args": .array([.string("mcp")])])])]).pretty
    }

    /// For Claude Code, which takes a server in one line.
    static func claudeCode(_ path: String = CommandSetup.path) -> String {
        "claude mcp add \(serverName) -- \(quoted(path)) mcp"
    }
}

/// The section Settings shows about the command and the AI server.
struct CommandSettingsSection: View {
    @State private var copied: String?

    var body: some View {
        Section {
            row("In Terminal", detail: CommandSetup.terminal(), code: true, button: "Copy", copies: CommandSetup.terminal())
                .id("command")
            row("Claude", detail: "Paste into Claude: Settings › Developer › Edit Config", code: false, button: "Copy setup for Claude", copies: CommandSetup.claude())
            row("Claude Code", detail: CommandSetup.claudeCode(), code: true, button: "Copy", copies: CommandSetup.claudeCode())
        } header: {
            Text("Command line and AI apps")
        } footer: {
            Text("An AI app that is given the setup can read the meters and the timeline when you ask it about this Mac. It cannot change anything, and it is never told an address or a network's name. “\(App.name) help” in Terminal lists every command.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The name and the button on one line, and what the button copies under them at the row's full width: the
    /// path of an installed copy then fits on a line of its own.
    private func row(_ title: String, detail: String, code: Bool, button: String, copies text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 12)
                Button(copied == title ? "Copied" : button) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                    // The word goes back after a moment, unless another row has been copied since.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == title { copied = nil } }
                }
            }
            Text(detail)
                .font(code ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(text)
        }
    }
}
