import Foundation

/// Made-up leftovers for the demo disk, so the uninstall review can be shown without a real app.
enum UninstallDemo {
    static func plan(_ item: StorageChild) -> UninstallPlan {
        let name = (item.name as NSString).deletingPathExtension
        let id = "com.example." + name.lowercased().replacingOccurrences(of: " ", with: "")
        func leftover(_ path: String, _ kind: UninstallItem.Kind, _ megabytes: Double, system: Bool = false) -> UninstallItem {
            UninstallItem(path: path, kind: kind, bytes: megabytes * 1e6, system: system)
        }
        return UninstallPlan(name: name, path: "/Applications/" + item.name, bundleID: id, items: [
            UninstallItem(path: "/Applications/" + item.name, kind: .app, bytes: item.bytes, system: true),
            leftover(Uninstaller.home + "/Library/Application Support/" + name, .support, 412),
            leftover(Uninstaller.home + "/Library/Caches/" + id, .caches, 96.4),
            leftover(Uninstaller.home + "/Library/Preferences/" + id + ".plist", .settings, 0.02),
            leftover(Uninstaller.home + "/Library/Saved Application State/" + id + ".savedState", .state, 1.3),
            leftover(Uninstaller.home + "/Library/HTTPStorages/" + id, .webData, 4.1),
            leftover(Uninstaller.home + "/Library/LaunchAgents/" + id + ".agent.plist", .background, 0.001),
            leftover("/Library/LaunchDaemons/" + id + ".helper.plist", .background, 0.001, system: true),
            leftover("/Library/PrivilegedHelperTools/" + id + ".helper", .helperTool, 2.8, system: true),
        ])
    }
}
