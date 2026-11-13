import AppKit
import Darwin
import Foundation
import Observation

/// One thing macOS starts by itself: a launch agent or daemon described by a property list.
struct LaunchItem: Identifiable {
    enum Scope: String, CaseIterable {
        case user, everyone, system

        var title: String {
            switch self {
            case .user: return "Yours"
            case .everyone: return "All users"
            case .system: return "System services"
            }
        }

        var detail: String {
            switch self {
            case .user: return "Agents in your Library. They run as you, when you log in."
            case .everyone: return "Agents installed for every account on this Mac."
            case .system: return "Daemons. They run as root from startup, before anyone logs in."
            }
        }

        var rgb: RGB {
            switch self {
            case .user: return PX.blue
            case .everyone: return PX.purple
            case .system: return PX.orange
            }
        }

        var symbol: String {
            switch self {
            case .user: return "person.fill"
            case .everyone: return "person.2.fill"
            case .system: return "gearshape.2.fill"
            }
        }
    }

    var id: String { path }
    /// The property list.
    var path: String
    var label: String
    var scope: Scope
    /// What it runs.
    var program: String?
    var arguments: [String] = []
    var runAtLoad = false
    var keepAlive = false
    /// Starts on a timer or a calendar schedule.
    var scheduled = false
    var disabled = false
    /// The app it belongs to, when the program sits inside one.
    var appPath: String?
    var pid: Int32?
    /// Whether launchd has it loaded. Only known for the user's own agents.
    var loaded: Bool?

    var isRunning: Bool { pid != nil }

    /// "Google" from "com.google.keystone.agent".
    var vendor: String {
        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return label }
        let name = String(parts[1])
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A readable name: the app's, or the label without its reverse-DNS front.
    var title: String {
        if let appPath { return ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension }
        let parts = label.split(separator: ".")
        return parts.count > 2 ? parts.dropFirst(2).joined(separator: ".") : label
    }

    var trigger: String {
        if disabled { return "disabled" }
        if keepAlive { return "kept running" }
        if runAtLoad { return scope == .system ? "at startup" : "at login" }
        if scheduled { return "on a schedule" }
        return "on demand"
    }
}

/// Reads what starts by itself. The list of apps under "Open at Login" in System Settings is private to
/// macOS, so this covers the other half: the background items that apps install as launch agents and daemons.
@MainActor
@Observable
final class LoginItemsModel {
    private(set) var items: [LaunchItem] = []
    private(set) var loading = false
    private(set) var readAt: Date?
    /// The item whose Remove button is waiting for its second click.
    private(set) var armed: String?
    private(set) var busy: String?
    private(set) var notice: String?

    @ObservationIgnored private var disarm: Task<Void, Never>?

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = Self.read()
            await MainActor.run {
                self.items = found
                self.loading = false
                self.readAt = Date()
            }
        }
    }

    func reveal(_ item: LaunchItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Only the user's own agents can be removed from here: nothing else can be changed without an administrator.
    func canRemove(_ item: LaunchItem) -> Bool { item.scope == .user }

    /// First call arms, second call stops the agent and moves its property list to the Trash.
    func requestRemove(_ item: LaunchItem) {
        guard canRemove(item), busy == nil else { return }
        guard armed == item.id else {
            armed = item.id
            notice = nil
            disarm?.cancel()
            disarm = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.armed = nil
            }
            return
        }
        disarm?.cancel()
        armed = nil
        busy = item.id
        Task.detached(priority: .userInitiated) {
            let failure = Self.remove(item, allowAnywhere: false)
            await MainActor.run {
                self.busy = nil
                if let failure {
                    self.notice = failure
                } else {
                    self.items.removeAll { $0.id == item.id }
                    self.notice = "Stopped \(item.title) and moved its file to the Trash. Put it back from the Trash to undo."
                }
            }
        }
    }

    // MARK: Work

    /// Stops a user agent and moves its file to the Trash. `allowAnywhere` is for the test command, which
    /// works on a throwaway agent in a temporary folder.
    nonisolated static func remove(_ item: LaunchItem, allowAnywhere: Bool) -> String? {
        removeReportingLocation(item, allowAnywhere: allowAnywhere).failure
    }

    /// The same, also saying where in the Trash the file ended up, so a test can take it out again.
    nonisolated static func removeReportingLocation(_ item: LaunchItem, allowAnywhere: Bool) -> (failure: String?, landed: URL?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard allowAnywhere || item.path.hasPrefix(home + "/Library/LaunchAgents/") else { return ("Only agents in your own Library can be removed from here.", nil) }
        // Stopping it is best effort: an agent that was never loaded has nothing to stop.
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        do {
            var landed: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &landed)
            return (nil, landed as URL?)
        } catch {
            return ("Could not move it to the Trash: \(error.localizedDescription)", nil)
        }
    }

    nonisolated static func read() -> [LaunchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders: [(String, LaunchItem.Scope)] = [(home + "/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .everyone), ("/Library/LaunchDaemons", .system)]

        // What launchd has loaded for this user, and which of those are running.
        var loaded: [String: Int32?] = [:]
        if let listing = run("/bin/launchctl", ["list"]) {
            for line in listing.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 3 else { continue }
                loaded[String(fields[2])] = Int32(fields[0])
            }
        }
        // Every running executable, for the daemons launchd will not tell a user about.
        var running: [String: Int32] = [:]
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for index in 0..<max(0, min(count, pids.count)) where pids[index] > 0 {
            if proc_pidpath(pids[index], &buffer, UInt32(buffer.count)) > 0 { running[String(cString: buffer)] = pids[index] }
        }

        var items: [LaunchItem] = []
        for (folder, scope) in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                var item = LaunchItem(path: path, label: (plist["Label"] as? String) ?? (name as NSString).deletingPathExtension, scope: scope)
                let arguments = (plist["ProgramArguments"] as? [String]) ?? []
                item.program = (plist["Program"] as? String) ?? arguments.first
                item.arguments = Array(arguments.dropFirst())
                item.runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
                // KeepAlive is true, or a dictionary of conditions under which to keep it alive.
                item.keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
                item.scheduled = plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil
                item.disabled = (plist["Disabled"] as? Bool) ?? false
                if let program = item.program, let range = program.range(of: ".app/") { item.appPath = String(program[..<range.lowerBound]) + ".app" }
                if scope == .system {
                    item.pid = item.program.flatMap { running[$0] }
                } else if let entry = loaded[item.label] {
                    item.loaded = true
                    item.pid = entry ?? item.program.flatMap { running[$0] }
                } else {
                    item.loaded = false
                    item.pid = item.program.flatMap { running[$0] }
                }
                items.append(item)
            }
        }
        return items
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
