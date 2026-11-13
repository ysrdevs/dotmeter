import AppKit
import Darwin
import Foundation
import DotmeterShared

/// One thing an uninstall would remove.
struct UninstallItem: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case app, support, caches, settings, state, webData, logs, container, background, helperTool, receipt

        var title: String {
            switch self {
            case .app: return "The app"
            case .support: return "Support files"
            case .caches: return "Caches"
            case .settings: return "Settings"
            case .state: return "Saved windows"
            case .webData: return "Web data"
            case .logs: return "Logs"
            case .container: return "App container"
            case .background: return "Background item"
            case .helperTool: return "Helper tool"
            case .receipt: return "Install receipt"
            }
        }
    }

    var id: String { path }
    var path: String
    var kind: Kind
    /// Nil where it was not measured.
    var bytes: Double?
    /// Another account owns it (root, for an app from the App Store or an installer), so a plain delete is
    /// expected to be refused and the helper asked instead.
    var system: Bool
    var selected = true
}

/// An app and everything found that belongs to it.
struct UninstallPlan: Sendable, Equatable {
    var name: String
    var path: String
    var bundleID: String?
    var items: [UninstallItem]
    /// Another installed copy has the same identifier, so the files they share were left out.
    var sharesFiles = false

    var chosen: [UninstallItem] { items.filter(\.selected) }
    var bytes: Double { chosen.compactMap(\.bytes).reduce(0, +) }
    var leftovers: [UninstallItem] { items.filter { $0.kind != .app } }

    /// What confirming will do, in a few words, for the row that asks.
    var summary: String {
        let extra = leftovers
        if extra.isEmpty { return sharesFiles ? "deletes this copy for good · its files stay for the other copy" : "deletes the app for good" }
        let size = extra.compactMap(\.bytes).reduce(0, +)
        let amount = size < 1e6 ? "" : " (\(size < 1e9 ? "\(Int((size / 1e6).rounded())) MB" : String(format: "%.1f GB", size / 1e9)))"
        return "deletes the app and \(extra.count) \(extra.count == 1 ? "thing" : "things") it left behind\(amount) for good"
    }

    var shortSummary: String {
        let extra = leftovers.count
        return extra == 0 ? "the app, for good" : "app + \(extra) leftover\(extra == 1 ? "" : "s")"
    }
}

/// Finds what an app left around the Mac, and deletes it.
///
/// Matching is deliberately narrow, because what is found is deleted for good: an entry belongs to the app when it
/// is named for the app's own identifier (exactly, or the identifier followed by a dot and more), or, in the three
/// folders where apps use their plain name, exactly for the app. An entry that another installed app has a better
/// claim to is left out, and when another installed copy has the very same identifier nothing but the app goes.
/// Only the folders apps are meant to keep their files in are looked at, one level deep.
///
/// One of Apple's own apps (iMovie, Xcode) is matched by its identifier alone and only in the user's Library:
/// Apple's apps share folders named for each other (GarageBand's sounds are Logic's too), and what sits under
/// `/Library` with an Apple name belongs to macOS.
enum Uninstaller {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let kinds: [(root: String, kind: UninstallItem.Kind, byName: Bool)] = [
        ("Library/Application Support", .support, true), ("Library/Caches", .caches, true), ("Library/Preferences", .settings, false),
        ("Library/Preferences/ByHost", .settings, false), ("Library/Saved Application State", .state, false), ("Library/HTTPStorages", .webData, false),
        ("Library/WebKit", .webData, false), ("Library/Cookies", .webData, false), ("Library/Logs", .logs, true),
        ("Library/Application Scripts", .container, false), ("Library/LaunchAgents", .background, false),
    ]

    private static let systemKinds: [(root: String, kind: UninstallItem.Kind, byName: Bool)] = [
        ("/Library/Application Support", .support, true), ("/Library/Caches", .caches, true), ("/Library/Preferences", .settings, false),
        ("/Library/Logs", .logs, true), ("/Library/LaunchAgents", .background, false), ("/Library/LaunchDaemons", .background, false),
        ("/Library/PrivilegedHelperTools", .helperTool, false), ("/private/var/db/receipts", .receipt, false),
    ]

    /// Reads folders and measures them, so not for the main thread. `appBytes` is the app's size where it is
    /// already known, which saves walking it again; `others` stands in for the installed apps in tests.
    static func plan(for appPath: String, appBytes: Double? = nil, others known: [(id: String, name: String)]? = nil) -> UninstallPlan {
        let fm = FileManager.default
        let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")
        let fileName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? fileName
        let bundleID = info?["CFBundleIdentifier"] as? String
        var plan = UninstallPlan(name: name, path: appPath, bundleID: bundleID, items: [item(appPath, .app, bytes: appBytes)])
        guard let bundleID, bundleID.count >= 5 else { return plan }

        let id = bundleID.lowercased()
        let apple = id.hasPrefix("com.apple.")
        let others = known ?? installedApps(except: appPath)
        // A second copy of the same app (a beta beside the release, a renamed duplicate) uses the same files.
        if others.contains(where: { $0.id == id }) {
            plan.sharesFiles = true
            return plan
        }
        let names = Set([name.lowercased(), fileName.lowercased()]).filter { $0.count >= 4 }
        let nameTaken = apple || others.contains { names.contains($0.name) }

        func belongs(_ entry: String, byName: Bool) -> Bool {
            let lower = entry.lowercased()
            if lower == id || lower.hasPrefix(id + ".") {
                // "com.maker.app.beta" may be another app's own identifier: that app has the better claim.
                return !others.contains { $0.id.count > id.count && (lower == $0.id || lower.hasPrefix($0.id + ".")) }
            }
            return byName && !nameTaken && names.contains(lower)
        }

        for (root, kind, byName) in kinds.map({ (home + "/" + $0.root, $0.kind, $0.byName) }) + (apple ? [] : systemKinds) {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where belongs(entry, byName: byName) {
                plan.items.append(item(root + "/" + entry, kind))
            }
        }
        // Another app's container is private, and even listing the folder they sit in makes macOS ask. So the two
        // names the app's own container can have are looked for directly, and their size is left unmeasured.
        for candidate in ["Library/Containers/" + bundleID, "Library/Group Containers/group." + bundleID] {
            let path = home + "/" + candidate
            var info = stat()
            if lstat(path, &info) == 0 { plan.items.append(UninstallItem(path: path, kind: .container, bytes: nil, system: info.st_uid != getuid())) }
        }
        return plan
    }

    private static func item(_ path: String, _ kind: UninstallItem.Kind, bytes known: Double? = nil) -> UninstallItem {
        var info = stat()
        let owned = lstat(path, &info) == 0 && info.st_uid == getuid()
        let bytes = known ?? Double(DirectoryWalker.walk(path, cancelled: { false }) { _, _ in }.bytes)
        return UninstallItem(path: path, kind: kind, bytes: bytes, system: !owned)
    }

    /// Every other app in the Applications folders, by identifier and name.
    static func installedApps(except path: String) -> [(id: String, name: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        func add(_ app: String) {
            guard app != path, let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"), let id = info["CFBundleIdentifier"] as? String else { return }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            out.append((id.lowercased(), name.lowercased()))
        }
        for folder in ["/Applications", home + "/Applications"] {
            for entry in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let full = folder + "/" + entry
                if entry.hasSuffix(".app") { add(full) } else {
                    for inner in (try? fm.contentsOfDirectory(atPath: full)) ?? [] where inner.hasSuffix(".app") { add(full + "/" + inner) }
                }
            }
        }
        return out
    }

    /// Deletes what is chosen, the app first: if the app will not go, nothing of its is touched. What the user
    /// owns is deleted directly; what is refused goes to the helper in one request. Returns why, for each path
    /// that is still there.
    static func delete(_ plan: UninstallPlan, helper: @Sendable ([String]) async -> [String?], progress: @escaping @Sendable (Double) -> Void) async -> [String: String] {
        let chosen = plan.chosen
        guard !chosen.isEmpty else { return [:] }
        var failures: [String: String] = [:]
        var refused: [String] = []
        var step = 0.0
        let fm = FileManager.default

        func plain(_ item: UninstallItem) -> Bool {
            if item.kind == .background, item.path.hasPrefix(home + "/") || item.path.hasPrefix("/Library/LaunchAgents/") {
                // Stop it for this user before its file goes.
                run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.path])
            }
            if (try? fm.removeItem(atPath: item.path)) != nil { return true }
            return !fm.fileExists(atPath: item.path) && (try? fm.destinationOfSymbolicLink(atPath: item.path)) == nil
        }

        // The app itself decides whether anything else is touched.
        if let app = chosen.first(where: { $0.kind == .app }) {
            let gone = await Task.detached { plain(app) }.value
            if !gone {
                if let reason = await helper([app.path]).first ?? "\(App.possessive) helper could not be reached." {
                    return [app.path: reason]
                }
            }
            step += 1
            progress(step / Double(chosen.count))
        }
        for item in chosen where item.kind != .app {
            let gone = await Task.detached { plain(item) }.value
            if gone {
                step += 1
                progress(step / Double(chosen.count))
            } else {
                refused.append(item.path)
            }
        }
        if !refused.isEmpty {
            let answers = await helper(refused)
            for (path, answer) in zip(refused, answers) {
                if let answer { failures[path] = answer }
                step += 1
                progress(step / Double(chosen.count))
            }
        }
        progress(1)
        return failures
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
