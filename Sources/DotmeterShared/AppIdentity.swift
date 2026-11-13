import Foundation

/// What the app is called and how macOS knows it, in one place. The app, its helper and the build scripts all
/// go by these, so a new name is a change here, in `Resources/Info.plist`, and nowhere else. (The scripts read
/// the name and identifier from the Info.plist and refuse to build if these do not match it.)
public enum AppIdentity {
    /// The name people see: the menu, the window, the Dock, every sentence that names the app.
    public static let name = "Dotmeter"
    /// How macOS knows the app: settings, the Keychain, permissions and the helper's trust all hang on it.
    public static let bundleID = "com.ysr.dotmeter"
    /// The helper's own identifier and launchd label.
    public static let helperID = bundleID + ".helper"
    /// The team whose signature the app and the helper each demand of the other.
    public static let team = "9RCV543M32"
    /// The folder under Application Support that holds the timeline and the followed cables.
    public static let supportFolder = "Dotmeter"

    /// "Dotmeter's" or "Name's", for sentences like "Dotmeter's helper".
    public static var possessive: String { name.hasSuffix("s") ? name + "'" : name + "'s" }
}
