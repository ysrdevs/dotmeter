import Foundation
import DotmeterShared

// Dotmeter's helper: a few dozen lines that run with the system's rights so that uninstalling an app the system owns
// does not need a password each time. launchd starts it when Dotmeter asks for it and it exits when it has been idle.
// It does one thing, deleting, and only what `RemovalPolicy` allows, and only for a caller that macOS confirms is
// Dotmeter signed by the same developer.

final class Worker: NSObject, DotmeterHelperProtocol {
    private let home: String

    init(uid: uid_t) {
        home = getpwuid(uid).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? "/var/empty"
    }

    func version(reply: @escaping (Int) -> Void) {
        Idle.touch()
        reply(HelperInfo.version)
    }

    func remove(paths: [String], reply: @escaping ([String]) -> Void) {
        Idle.touch()
        let results = paths.map { path -> String in
            if let refusal = RemovalPolicy.refusal(for: path, home: home) { return "Refused: \(refusal)." }
            var info = stat()
            guard lstat(path, &info) == 0 else { return "" }
            // A background item is stopped before its file goes, or it would keep running until the next restart.
            if path.hasPrefix("/Library/LaunchDaemons/") { Self.run("/bin/launchctl", ["bootout", "system", path]) }
            do {
                try FileManager.default.removeItem(atPath: path)
                return ""
            } catch {
                return (error as NSError).localizedFailureReason ?? error.localizedDescription
            }
        }
        Idle.touch()
        reply(results)
    }

    func quit(reply: @escaping () -> Void) {
        reply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
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

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Every message on this connection is checked against the caller's signature; a caller that is not Dotmeter
        // is dropped by macOS before anything here runs.
        connection.setCodeSigningRequirement(HelperInfo.appRequirement)
        connection.exportedInterface = NSXPCInterface(with: DotmeterHelperProtocol.self)
        connection.exportedObject = Worker(uid: connection.effectiveUserIdentifier)
        connection.resume()
        Idle.touch()
        return true
    }
}

/// Exits the process once nothing has asked for it for a while.
enum Idle {
    nonisolated(unsafe) private static var last = Date()
    private static let lock = NSLock()

    static func touch() {
        lock.lock(); last = Date(); lock.unlock()
    }

    static func watch() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            lock.lock(); let quiet = Date().timeIntervalSince(last); lock.unlock()
            if quiet > 30 { exit(0) }
        }
        timer.resume()
        keep = timer
    }

    nonisolated(unsafe) private static var keep: DispatchSourceTimer?
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: HelperInfo.label)
listener.delegate = delegate
listener.resume()
Idle.watch()
dispatchMain()
