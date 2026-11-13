import AppKit
import Observation

/// Asking an app to quit, or making it. Apps are asked the way the Dock asks them; bare processes get a
/// signal. Nothing here needs privileges, so only the user's own processes can be stopped.
enum ProcessControl {
    /// Stopping these logs the user out, freezes the screen, or stops this app.
    private static let protected: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "\(App.name)", "Finder", "Dock", "SystemUIServer", "ControlCenter", "Control Center", "runningboardd", "launchservicesd"]

    static func canQuit(_ app: AppUsage) -> Bool {
        if protected.contains(app.name) { return false }
        if app.children.contains(where: { $0.pid <= 1 || $0.pid == ProcessInfo.processInfo.processIdentifier }) { return false }
        return !app.children.isEmpty
    }

    /// nil when the request went out, otherwise why it could not.
    @MainActor
    static func quit(_ app: AppUsage, force: Bool) -> String? {
        guard canQuit(app) else { return "\(app.name) is part of macOS and cannot be quit from here." }
        if let bundlePath = app.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundlePath }
            if !running.isEmpty {
                let sent = running.map { force ? $0.forceTerminate() : $0.terminate() }
                return sent.contains(true) ? nil : "\(app.name) did not accept the request."
            }
        }
        return signal(app.children.map(\.pid), force: force, name: app.name)
    }

    /// Sends the polite signal, or the one that cannot be refused, to each process.
    static func signal(_ pids: [Int32], force: Bool, name: String) -> String? {
        var refused = 0, sent = 0
        for pid in pids where pid > 1 {
            if kill(pid, force ? SIGKILL : SIGTERM) == 0 { sent += 1 } else if errno == EPERM { refused += 1 }
        }
        if sent > 0 { return nil }
        return refused > 0 ? "\(name) belongs to macOS or another user, so it cannot be stopped without an administrator." : "\(name) is no longer running."
    }
}

/// Two clicks to quit anything, the same as deleting anything: the first arms the button for six seconds,
/// the second sends the request. A row then shows that it is closing until the app is gone.
@MainActor
@Observable
final class QuitModel {
    struct Pending: Equatable {
        var force: Bool
        var since: Date
    }

    /// The app whose button is waiting for its second click, and which button it was.
    private(set) var armed: String?
    private(set) var armedForce = false
    /// Apps that have been asked to quit and have not gone yet.
    private(set) var pending: [String: Pending] = [:]
    private(set) var notice: String?

    @ObservationIgnored private var disarm: Task<Void, Never>?

    func isArmed(_ id: String, force: Bool) -> Bool { armed == id && armedForce == force }

    /// First call arms, second call acts.
    func request(_ app: AppUsage, force: Bool) {
        guard isArmed(app.id, force: force) else {
            armed = app.id
            armedForce = force
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
        if let failure = ProcessControl.quit(app, force: force) {
            notice = failure
            return
        }
        pending[app.id] = Pending(force: force, since: Date())
        // An app can refuse to quit (an unsaved document, a stuck process). After a while, stop saying it is closing.
        let id = app.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(force ? 5 : 12))
            guard let self, self.pending[id] != nil else { return }
            self.pending[id] = nil
            self.notice = force ? "\(app.name) is still running." : "\(app.name) has not quit. It may be waiting for you, or stuck: Force Quit will end it."
        }
    }

    /// Called with each reading: an app that is gone is no longer pending.
    func reconcile(with apps: [AppUsage]) {
        guard !pending.isEmpty else { return }
        let alive = Set(apps.map(\.id))
        for id in pending.keys where !alive.contains(id) { pending[id] = nil }
    }

    func dismissNotice() { notice = nil }
}
