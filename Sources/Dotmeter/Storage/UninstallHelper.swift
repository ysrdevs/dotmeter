import Foundation
import Observation
import ServiceManagement
import DotmeterShared

/// The app's side of the uninstall helper: whether macOS has it switched on, switching it on and off, and asking
/// it to delete what the app cannot.
///
/// The helper is a launch daemon inside the app bundle, registered with `SMAppService`. Registering it makes macOS
/// list Dotmeter under Login Items & Extensions, where the user allows it once with an administrator's rights. From
/// then on launchd starts it whenever the app opens a connection, and it leaves again when idle.
///
/// Nothing here is switched on ahead of time. The first uninstall that is refused a plain delete asks for the
/// helper itself: it registers it, opens the Login Items window when macOS wants the user's OK, waits there, and
/// carries on by itself once it is given.
@MainActor
@Observable
final class UninstallHelper {
    enum State: Equatable {
        /// Not registered with macOS.
        case off
        /// Registered, waiting for the user to allow it under Login Items & Extensions.
        case needsApproval
        case on
        /// This copy of the app does not carry a helper (an unbundled build).
        case missing
    }

    private(set) var state: State = .off
    private(set) var lastError: String?
    /// The Login Items window is open and an uninstall is waiting for Dotmeter to be allowed there.
    private(set) var asking = false
    @ObservationIgnored private var askCancelled = false
    /// The helper has answered this copy of the app, whatever macOS reports about it.
    @ObservationIgnored private var answered = false
    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperInfo.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?

    init() { refresh() }

    func refresh() {
        let bundled = FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperInfo.plistName)").path)
        guard bundled else { state = .missing; return }
        switch service.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        default: state = answered ? .on : .off
        }
    }

    /// Registers the helper. macOS then asks for it to be allowed, once, under Login Items & Extensions.
    func turnOn() {
        do {
            try service.register()
            lastError = nil
        } catch {
            // Registering a daemon that still needs approval reports an error as well as the status.
            lastError = error.localizedDescription
        }
        refresh()
        if state == .needsApproval { lastError = nil }
    }

    func openApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func turnOff() async {
        connection?.invalidate()
        connection = nil
        answered = false
        try? await service.unregister()
        refresh()
    }

    /// Asks the helper to delete these. One answer per path, in order: nil when it is gone, otherwise why not.
    /// With `asking`, a helper that is not on yet is asked for first, which can wait on the user for minutes.
    func remove(_ paths: [String], asking: Bool = false) async -> [String?] {
        refresh()
        guard state != .missing else { return paths.map { _ in "This copy of \(App.name) was built without its helper." } }
        // What macOS reports is not trusted over the helper itself: if it answers, it is on.
        if await !reachable() {
            guard asking else { return paths.map { _ in "\(App.possessive) helper is not switched on." } }
            if let refusal = await obtain() { return paths.map { _ in refusal } }
        }
        let answers: [String]? = await call { proxy, done in proxy.remove(paths: paths) { done($0) } }
        guard let answers, answers.count == paths.count else { return paths.map { _ in "\(App.possessive) helper could not be reached." } }
        return answers.map { $0.isEmpty ? nil : $0 }
    }

    /// Stops waiting for the user to allow the helper. The uninstall that was waiting reports that it was not allowed.
    func stopAsking() {
        askCancelled = true
    }

    /// True when this copy's helper answers. A helper left running by an older copy of the app is asked to leave,
    /// and launchd starts this one's.
    private func reachable() async -> Bool {
        guard let running = await version() else {
            connection?.invalidate()
            connection = nil
            return false
        }
        if running != HelperInfo.version {
            await quit()
            connection?.invalidate()
            connection = nil
            try? await Task.sleep(for: .milliseconds(600))
            guard await version() == HelperInfo.version else { return false }
        }
        answered = true
        refresh()
        return true
    }

    private func reachableSoon() async -> Bool {
        // launchd takes a moment to learn of a helper that was allowed a second ago.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            if await reachable() { return true }
        }
        return false
    }

    /// Gets the helper switched on: registers it, and where macOS wants the user's OK, opens the Login Items window
    /// and waits there. Nil when the helper answers, otherwise why it does not.
    private func obtain() async -> String? {
        turnOn()
        if state == .on {
            if await reachableSoon() { return nil }
            // Registered and allowed, yet silent: a record left by a copy signed differently. Start over.
            try? await service.unregister()
            turnOn()
            if state == .on, await reachableSoon() { return nil }
        }
        guard state == .needsApproval else {
            return state == .on ? "\(App.possessive) helper is allowed but did not start. Restart \(App.name) and try again." : "macOS would not set up \(App.possessive) helper\(lastError.map { ": \($0)" } ?? ".")"
        }
        askCancelled = false
        asking = true
        defer { asking = false }
        openApproval()
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !askCancelled {
            try? await Task.sleep(for: .milliseconds(1200))
            refresh()
            if state == .on, await reachableSoon() { return nil }
        }
        return askCancelled ? "Not allowed, so it was left where it is." : "\(App.name) is still waiting to be switched on under Login Items & Extensions. Switch it on there, then press Uninstall again."
    }

    func version() async -> Int? {
        await call(timeout: 6) { proxy, done in proxy.version { done($0) } }
    }

    private func quit() async {
        let _: Bool? = await call(timeout: 4) { proxy, done in proxy.quit { done(true) } }
    }

    /// One message to the helper. Nil when it could not be delivered or was not answered, or not within `timeout`
    /// seconds where one is given (a delete is given none: a large app takes as long as it takes).
    private func call<Value: Sendable>(timeout: Double? = nil, _ body: @escaping (DotmeterHelperProtocol, @escaping (Value) -> Void) -> Void) async -> Value? {
        let connection = self.connection ?? makeConnection()
        self.connection = connection
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = Once()
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if once.claim() { continuation.resume(returning: nil) }
                }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                if once.claim() { continuation.resume(returning: nil) }
            } as? DotmeterHelperProtocol
            guard let proxy else {
                if once.claim() { continuation.resume(returning: nil) }
                return
            }
            body(proxy) { value in
                if once.claim() { continuation.resume(returning: value) }
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperInfo.label, options: .privileged)
        // The app is as careful as the helper: it only talks to a helper signed by the same developer.
        connection.setCodeSigningRequirement(HelperInfo.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: DotmeterHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        return connection
    }
}

/// Lets exactly one of two callbacks answer.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
