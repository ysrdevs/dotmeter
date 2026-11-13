import Foundation

/// The only things the helper will delete, whoever asks. It runs with the system's rights, so the rule is written
/// as a short list of places and shapes, and anything that does not fit is refused: an app in an Applications
/// folder, or one entry directly inside one of the folders where apps keep their own files. Nothing that is part
/// of macOS, nothing reached through a link, nothing deeper or shallower than that.
///
/// An app Apple sells through the App Store (iMovie, GarageBand, Keynote) is an app like any other: it sits on the
/// data volume and the Finder lets an administrator delete it. What is part of macOS sits on the sealed system
/// volume, and that is the line drawn here.
public enum RemovalPolicy {
    /// Folders the system owns in which an app's own entry may be removed.
    public static let systemRoots = [
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs",
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
        "/private/var/db/receipts",
    ]

    /// The same, inside a user's home folder.
    public static let userRoots = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs", "Library/Cookies",
        "Library/Application Scripts", "Library/Containers", "Library/Group Containers", "Library/LaunchAgents",
    ]

    /// Nil when the path may be removed, otherwise why not.
    public static func refusal(for path: String, home: String) -> String? {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//") else { return "not a full, plain path" }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains("."), !parts.contains(".."), let name = parts.last, parts.count >= 2 else { return "not a full, plain path" }
        let parent = "/" + parts.dropLast().joined(separator: "/")

        // The folder it sits in must be a real folder, not a link to somewhere else.
        guard let real = realpath(parent, nil) else { return "its folder does not exist" }
        let resolved = String(cString: real)
        free(real)
        guard resolved == parent else { return "its folder is reached through a link" }

        if name.hasSuffix(".app") {
            let places = ["/Applications", home + "/Applications"]
            let inPlace = places.contains(parent) || places.contains { parent.hasPrefix($0 + "/") && parts.count - $0.split(separator: "/").count == 2 }
            guard inPlace else { return "apps are only removed from an Applications folder" }
            return appRefusal(path)
        }

        let roots = systemRoots + userRoots.map { home + "/" + $0 }
        guard roots.contains(parent) else { return "not a place apps keep their files" }
        guard name.count >= 3, name != "Apple", !name.lowercased().hasPrefix("com.apple.") else { return "that belongs to macOS" }
        return nil
    }

    /// An app is refused when it lives on the system volume. Safari in Applications is a link into that volume,
    /// so the link is followed first.
    private static func appRefusal(_ path: String) -> String? {
        if let real = realpath(path, nil) {
            let resolved = String(cString: real)
            free(real)
            if resolved.hasPrefix("/System/") { return "that is part of macOS" }
        }
        return nil
    }
}
