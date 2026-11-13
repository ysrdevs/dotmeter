import Foundation

enum SystemInfoProvider {
    static let modelIdentifier = Sysctl.string("hw.model") ?? "Mac"
    static let chip = Sysctl.string("machdep.cpu.brand_string") ?? "Apple silicon"
    static let modelName = marketingName(for: modelIdentifier)

    static func current(memoryTotal: UInt64) -> SystemInfo {
        SystemInfo(
            modelName: modelName,
            modelIdentifier: modelIdentifier,
            chip: chip,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            uptime: ProcessInfo.processInfo.systemUptime,
            memoryTotal: memoryTotal
        )
    }

    /// System Information caches the marketing name ("Mac Studio") per model identifier; fall back to the identifier.
    private static func marketingName(for identifier: String) -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.SystemProfiler.plist")
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let names = plist["CPU Names"] as? [String: String] {
            for (key, value) in names where key.hasPrefix(identifier + "-") { return value }
        }
        let prefixes: [(String, String)] = [
            ("Mac15,14", "Mac Studio"), ("Mac14,13", "Mac Studio"), ("Mac14,14", "Mac Studio"), ("Mac13,", "Mac Studio"),
            ("Mac16,", "MacBook Pro"), ("Mac15,", "MacBook Pro"), ("Mac14,", "MacBook"), ("Macmini", "Mac mini"), ("iMac", "iMac"),
        ]
        for (prefix, name) in prefixes where identifier.hasPrefix(prefix) { return name }
        return identifier
    }
}
