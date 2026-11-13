import Foundation

/// What the app and its helper agree on.
public enum HelperInfo {
    public static let label = AppIdentity.helperID
    public static let plistName = AppIdentity.helperID + ".plist"
    /// Raised whenever the helper's behaviour changes, so an app can tell an old helper that is still running
    /// from the one it shipped with.
    public static let version = 2

    /// Who each side will talk to: code signed by this team under the other side's identifier. macOS checks this
    /// against the caller's signature on every message, so no other program can borrow the helper's rights.
    public static let appRequirement = "identifier \"\(AppIdentity.bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(AppIdentity.team)\""
    public static let helperRequirement = "identifier \"\(AppIdentity.helperID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(AppIdentity.team)\""
}

@objc public protocol DotmeterHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    /// Deletes each path the rules allow (see `RemovalPolicy`) on behalf of the user who is asking. The reply has
    /// one entry per path, in order: empty when it is gone, otherwise why it is not.
    func remove(paths: [String], reply: @escaping ([String]) -> Void)
    /// Ends the helper's process. launchd starts a fresh one the next time it is needed.
    func quit(reply: @escaping () -> Void)
}
