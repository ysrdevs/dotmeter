import Foundation

/// Dotmeter was called Vitals until 2.0, under another identifier. To macOS a new identifier is a new app, with
/// no settings, no history and no saved keys, so the first launch under the new name carries over what the old
/// one kept: its settings, its folder under Application Support (the timeline and the followed cables) and the
/// API keys in the Keychain. Each is done once.
///
/// What cannot be carried over, because macOS ties it to the app and asks the person: the uninstall helper's
/// approval, Launch at Login, and the permissions for notifications, the local network, the Finder and Full Disk
/// Access. Those are asked for again when they are next needed.
enum Migration {
    static let oldBundleID = "com.ysr.vitals"
    static let oldSupportFolder = "Vitals"
    static let oldName = "Vitals"
    private static let doneKey = "carriedOverFromVitals"

    /// A run for testing (every such run names its own timeline file or menu bar items) leaves the real
    /// carry-over to the app's first real launch.
    private static var testing: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["DOTMETER_TIMELINE_PATH"] != nil || environment["DOTMETER_MENU_ITEMS"] != nil
    }

    /// Settings and the data folder. Called before anything reads a setting.
    static func carryOver() {
        let defaults = UserDefaults.standard
        guard !testing, !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        // Settings: every value the old name saved that the new one has not set itself. Window frames are kept
        // under names that held the old name.
        if let old = defaults.persistentDomain(forName: oldBundleID) {
            let mine = defaults.persistentDomain(forName: App.bundleID) ?? [:]
            for (key, value) in old {
                let renamed = key.replacingOccurrences(of: oldName, with: App.name)
                if mine[renamed] == nil { defaults.set(value, forKey: renamed) }
            }
        }

        // The timeline and the followed cables: the folder moves, unless the new name already has one.
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = support.appendingPathComponent(oldSupportFolder, isDirectory: true)
            let new = support.appendingPathComponent(App.supportFolder, isDirectory: true)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            }
        }
    }

    /// The API keys saved under the old name, moved to the new one. Reading an item another app saved makes
    /// macOS ask the person first, so this runs off the main thread, once, and only for a key the new name
    /// does not have. Returns true if any key came over.
    @discardableResult
    static func carryOverKeys() -> Bool {
        guard !testing else { return false }
        var moved = false
        for provider in AIProvider.allCases where !Keychain.exists(provider.keyAccount) && Keychain.exists(provider.keyAccount, service: oldBundleID) {
            guard let key = Keychain.read(provider.keyAccount, service: oldBundleID), !key.isEmpty else { continue }
            guard (try? Keychain.save(key, account: provider.keyAccount, label: "\(App.name) — \(provider.company) API key")) != nil else { continue }
            Keychain.delete(provider.keyAccount, service: oldBundleID)
            moved = true
        }
        return moved
    }
}
