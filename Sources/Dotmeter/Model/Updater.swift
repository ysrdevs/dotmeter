import AppKit
import Observation
import Security
import DotmeterShared

/// "2.0.3" as numbers, so that 2.0.10 comes after 2.0.9 and a leading "v" does not matter.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0, y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    /// The version of the copy that is running.
    static let running = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!
}

/// A published version, as GitHub describes it.
struct UpdateRelease: Equatable, Sendable {
    var version: String
    /// What is new: the release's text up to its Install heading, which only makes sense on the web page.
    var notes: String
    var page: URL
    /// The disk image.
    var image: URL
    var size: Int64?
}

enum UpdateError: LocalizedError, Equatable {
    case unreachable, busy, unreadable, download, tooBig, image, noApp, signature, notNewer(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "GitHub could not be reached."
        case .busy: return "GitHub is not answering right now. Try again in a while."
        case .unreadable: return "GitHub's answer could not be read."
        case .download: return "The download did not finish."
        case .tooBig: return "The download is not the size GitHub said it would be."
        case .image: return "The disk image could not be opened."
        case .noApp: return "The disk image does not hold \(App.name)."
        case .signature: return "The download is not a copy of \(App.name) signed by its developer and checked by Apple, so it was not installed."
        case .notNewer(let version): return "The download is version \(version), which is not newer than this one."
        }
    }
}

/// Asking GitHub which version is the newest. One small request, with nothing about this Mac in it.
enum UpdateFeed {
    /// Debug: DOTMETER_UPDATE_FEED=<url or path> reads a release from there instead, and lets its disk image be a
    /// local file. What may be installed is decided by the signature either way.
    static let override: URL? = ProcessInfo.processInfo.environment["DOTMETER_UPDATE_FEED"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0) }

    static var source: URL { override ?? URL(string: "https://api.github.com/repos/\(AppIdentity.repository)/releases/latest")! }

    /// The newest published version, or nil when nothing has been published.
    static func latest(from source: URL = UpdateFeed.source) async throws -> UpdateRelease? {
        if source.isFileURL {
            guard let data = try? Data(contentsOf: source) else { throw UpdateError.unreachable }
            guard let release = parse(data, localFiles: true) else { throw UpdateError.unreadable }
            return release
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(App.name)/\(AppVersion.running)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { throw UpdateError.unreachable }
        switch http.statusCode {
        case 200:
            guard let release = parse(data, localFiles: false) else { throw UpdateError.unreadable }
            return release
        case 404: return nil
        case 403, 429: throw UpdateError.busy
        default: throw UpdateError.unreachable
        }
    }

    /// GitHub's description of one release. The version is its tag, the download its first `.dmg`, which has to
    /// come over HTTPS (a made-up feed may also name a file, or a server on this Mac).
    static func parse(_ data: Data, localFiles: Bool) -> UpdateRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let version = AppVersion(tag),
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let assets = object["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                  let link = asset["browser_download_url"] as? String, let image = URL(string: link),
                  image.scheme == "https" || (localFiles && (image.isFileURL || image.host == "127.0.0.1")) else { continue }
            let page = (object["html_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            return UpdateRelease(version: version.description, notes: notes(object["body"] as? String ?? ""),
                                 page: page ?? URL(string: "https://github.com/\(AppIdentity.repository)/releases")!,
                                 image: image, size: (asset["size"] as? NSNumber)?.int64Value)
        }
        return nil
    }

    /// The release's text up to its Install or Checksum heading.
    static func notes(_ body: String) -> String {
        var kept: [String] = []
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading.hasPrefix("#") {
                let title = heading.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                if title.hasPrefix("install") || title.hasPrefix("checksum") { break }
            }
            kept.append(line)
        }
        return String(kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
    }
}

/// Fetching a new version and putting it where the running one is.
///
/// Nothing is trusted because of where it came from. The disk image is opened read-only, and the app inside is
/// installed only if macOS confirms three things about it: it is Dotmeter, it was signed with the developer's
/// Developer ID, and Apple has notarized it. Its version also has to be newer than the one running, so an old
/// release cannot be put back. The copy that was checked is the copy that is installed.
enum UpdateInstaller {
    /// What a prepared update is: a checked copy waiting beside the app, or, where the app cannot replace
    /// itself, the checked disk image for the person to open.
    enum Prepared {
        case staged(URL, work: URL)
        case byHand(image: URL, why: String)
    }

    enum Step: Sendable { case downloading(Double), checking }

    static let requirement = "anchor apple generic and identifier \"\(AppIdentity.bundleID)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(AppIdentity.team)\" and notarized"

    private static let largest: Int64 = 400 << 20

    /// Downloads the release, checks it, and gets it ready to take the place of the app at `destination`.
    static func prepare(_ release: UpdateRelease, destination: URL, running: AppVersion, report: @escaping @Sendable (Step) -> Void) async throws -> Prepared {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("\(App.name)-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: work) } }

        let image = work.appendingPathComponent("\(App.name)-\(release.version).dmg")
        if release.image.isFileURL {
            do { try fm.copyItem(at: release.image, to: image) } catch { throw UpdateError.download }
        } else {
            try await Download.run(release.image, to: image, expecting: release.size, progress: { report(.downloading($0)) })
        }
        let size = ((try? fm.attributesOfItem(atPath: image.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= largest else { throw UpdateError.tooBig }
        if let expected = release.size, expected != size { throw UpdateError.tooBig }
        try Task.checkCancellation()
        report(.checking)

        let mount = work.appendingPathComponent("image", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path]) == 0 else { throw UpdateError.image }
        var mounted = true
        func unmount() {
            guard mounted else { return }
            mounted = false
            if run("/usr/bin/hdiutil", ["detach", mount.path]) != 0 { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        }
        defer { unmount() }

        let inside = mount.appendingPathComponent("\(App.name).app")
        let values = try? inside.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw UpdateError.noApp }
        try verify(inside, newerThan: running)
        try Task.checkCancellation()

        if let why = whyNotInPlace(destination) {
            unmount()
            keep = true
            return .byHand(image: image, why: why)
        }
        // Beside the app, on its own volume, so that taking its place is a rename.
        guard let folder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true) else {
            unmount()
            keep = true
            return .byHand(image: image, why: "there is nowhere beside it to put the new copy")
        }
        let staged = folder.appendingPathComponent(destination.lastPathComponent)
        do {
            try fm.copyItem(at: inside, to: staged)
            // The copy is what will run, so the copy is what gets checked.
            try verify(staged, newerThan: running)
        } catch {
            try? fm.removeItem(at: folder)
            throw (error as? UpdateError) ?? UpdateError.image
        }
        return .staged(staged, work: folder)
    }

    /// Throws unless the app at `url` is Dotmeter, signed by its developer, notarized by Apple and newer than
    /// `running`. Returns its version.
    @discardableResult
    static func verify(_ url: URL, newerThan running: AppVersion) throws -> AppVersion {
        var code: SecStaticCode?
        var wanted: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &wanted) == errSecSuccess, let wanted else { throw UpdateError.signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, wanted, nil) == errSecSuccess else { throw UpdateError.signature }
        // The Info.plist is covered by the signature just checked.
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let text = info?["CFBundleShortVersionString"] as? String, let version = AppVersion(text) else { throw UpdateError.signature }
        guard version > running else { throw UpdateError.notNewer(version.description) }
        return version
    }

    /// Why the app at `destination` cannot be replaced where it is, or nil when it can.
    static func whyNotInPlace(_ destination: URL) -> String? {
        guard destination.pathExtension == "app" else { return "this copy is not an app in a folder" }
        if destination.path.contains("/AppTranslocation/") { return "macOS is running it from a temporary place" }
        let folder = destination.deletingLastPathComponent()
        if access(folder.path, W_OK) != 0 { return "it may not change the folder it is in" }
        if (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return "it is on a disk that cannot be changed" }
        return nil
    }

    /// Puts the checked copy where the app is, in one step where the disk allows it, and removes the old one.
    static func swap(staged: URL, work: URL, destination: URL) throws {
        let fm = FileManager.default
        if renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) != 0 {
            let aside = work.appendingPathComponent("old-" + destination.lastPathComponent)
            try fm.moveItem(at: destination, to: aside)
            do {
                try fm.moveItem(at: staged, to: destination)
            } catch {
                try? fm.moveItem(at: aside, to: destination)
                throw error
            }
        }
        // What is left in the folder made for this is the old copy.
        try? fm.removeItem(at: work)
    }

    /// Starts the app at `url` once this process has gone, the way this one was started: the same arguments and
    /// the same DOTMETER_ switches, which is what keeps a test copy a test copy.
    static func relaunch(_ url: URL) {
        var arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; shift; exec /usr/bin/open \"$@\"", "sh", "\(ProcessInfo.processInfo.processIdentifier)", "-n", url.path]
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("DOTMETER_") {
            arguments += ["--env", "\(key)=\(value)"]
        }
        let own = Array(CommandLine.arguments.dropFirst())
        if !own.isEmpty { arguments += ["--args"] + own }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// One download to a file, reporting how far along it is.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expecting: Int64?
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var saved = false

    private init(destination: URL, expecting: Int64?, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expecting = expecting
        self.progress = progress
    }

    static func run(_ source: URL, to destination: URL, expecting: Int64?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let download = Download(destination: destination, expecting: expecting, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: source)
        request.setValue("\(App.name)/\(AppVersion.running)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expecting ?? 0)
        if total > 0 { progress(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { failure = UpdateError.download; return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            saved = true
        } catch {
            failure = UpdateError.download
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : UpdateError.download)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else if saved {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: UpdateError.download)
        }
    }
}

/// Whether a newer version is out, and installing it when the person says so.
///
/// Once a day, unless that is switched off in Settings, the app asks GitHub for the newest release. A newer one
/// brings up a window that says what is new; nothing is downloaded until Install is pressed there.
@MainActor
@Observable
final class UpdateModel {
    enum Phase: Equatable {
        /// Nothing has been asked yet.
        case idle
        case checking
        case current
        /// `release` is newer than this copy.
        case available
        case downloading(Double)
        case verifying
        /// The new copy is in place and the app is about to start again.
        case restarting
        /// The new version is checked and waiting as a disk image: this copy cannot replace itself.
        case byHand(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var release: UpdateRelease?
    private(set) var checkedAt: Date?
    /// Shows the update window. `quietly` when nobody asked: the window comes up without taking the keyboard.
    @ObservationIgnored var present: (_ quietly: Bool) -> Void = { _ in }

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var image: URL?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// A run against a made-up feed saves nothing: not when it last asked, not what was skipped.
    @ObservationIgnored private let temporary = UpdateFeed.override != nil || UpdateModel.demo != nil
    @ObservationIgnored private var skipped: String?

    /// Debug: DOTMETER_UPDATE_DEMO=available|downloading|verifying|restarting|failed|byhand|current|checking shows
    /// that state with a made-up release, for captures. Nothing is asked and nothing can be installed.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_UPDATE_DEMO"]
    private static let every: TimeInterval = 86_400

    init() {
        checkedAt = temporary ? nil : defaults.object(forKey: "updateCheckedAt") as? Date
        skipped = temporary ? nil : defaults.string(forKey: "updateSkipped")
        if let demo = Self.demo { showDemo(demo) }
    }

    /// A newer version is known and has not been installed.
    var waiting: Bool {
        guard release != nil else { return false }
        switch phase {
        case .idle, .checking, .current: return false
        default: return true
        }
    }

    /// Downloading, checking or restarting: not the moment to ask again or to close up.
    var busy: Bool {
        switch phase {
        case .downloading, .verifying, .restarting: return true
        default: return false
        }
    }

    /// Starts the daily look. The first is a little after launch, so that a Mac that has just woken has its
    /// connection back; one that fails is tried again within the hour.
    func start() {
        guard clock == nil, Self.demo == nil else { return }
        clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdateFeed.override == nil ? 20 : 1))
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.checkedAt.map { Date().timeIntervalSince($0) >= Self.every } ?? true
                if AppSettings.shared.updateChecks, due, !self.busy, self.phase != .checking { await self.look(asked: false) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Asks now, because somebody pressed the button, and shows the answer whatever it is.
    func check() {
        guard !busy, phase != .checking, Self.demo == nil else { present(false); return }
        present(false)
        Task { await look(asked: true) }
    }

    private func look(asked: Bool) async {
        let before = phase
        if asked || !waiting { phase = .checking }
        do {
            let found = try await UpdateFeed.latest()
            checkedAt = Date()
            if !temporary { defaults.set(checkedAt, forKey: "updateCheckedAt") }
            if let found, let version = AppVersion(found.version), version > AppVersion.running {
                release = found
                phase = .available
                if asked || found.version != skipped { present(!asked) }
                // Debug: with a made-up feed, DOTMETER_UPDATE_AUTO=1 presses Install as well, for a test of the whole way.
                if UpdateFeed.override != nil, ProcessInfo.processInfo.environment["DOTMETER_UPDATE_AUTO"] == "1" { install() }
            } else {
                release = nil
                phase = .current
            }
        } catch {
            // A look nobody asked for fails quietly and is tried again later.
            phase = asked ? .failed(error.localizedDescription) : (waiting ? before : .idle)
        }
    }

    /// Downloads the waiting version, checks it and, where the app can replace itself, does so and starts again.
    func install() {
        guard let release, work == nil, Self.demo == nil else { return }
        phase = .downloading(0)
        let destination = Bundle.main.bundleURL
        work = Task { [weak self] in
            do {
                let prepared = try await UpdateInstaller.prepare(release, destination: destination, running: .running) { step in
                    Task { @MainActor in self?.report(step) }
                }
                guard let self else { return }
                self.work = nil
                switch prepared {
                case .byHand(let image, let why):
                    self.image = image
                    self.phase = .byHand(why)
                case .staged(let staged, let folder):
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: folder)
                        self.phase = .available
                        return
                    }
                    self.phase = .restarting
                    do {
                        try UpdateInstaller.swap(staged: staged, work: folder, destination: destination)
                    } catch {
                        try? FileManager.default.removeItem(at: folder)
                        self.phase = .failed("The new copy could not be put in place: \(error.localizedDescription)")
                        return
                    }
                    UpdateInstaller.relaunch(destination)
                    // Long enough for the window to say what is happening.
                    try? await Task.sleep(for: .seconds(0.8))
                    NSApp.terminate(nil)
                }
            } catch {
                guard let self else { return }
                self.work = nil
                self.phase = error is CancellationError ? .available : .failed(error.localizedDescription)
            }
        }
    }

    private func report(_ step: UpdateInstaller.Step) {
        guard work != nil else { return }
        switch step {
        case .downloading(let fraction):
            if case .downloading(let shown) = phase, fraction - shown < 0.01, fraction < 1 { return }
            if case .downloading = phase { phase = .downloading(fraction) }
        case .checking:
            if case .downloading = phase { phase = .verifying }
        }
    }

    /// Stops a download or a check of one.
    func cancel() {
        work?.cancel()
    }

    /// Not this version: the daily look stops bringing it up. Asking by hand still finds it.
    func skip() {
        guard let release, !busy else { return }
        skipped = release.version
        if !temporary { defaults.set(release.version, forKey: "updateSkipped") }
    }

    /// Opens the checked disk image, for a copy that cannot replace itself.
    func openImage() {
        if let image { NSWorkspace.shared.open(image) }
    }

    func openPage() {
        NSWorkspace.shared.open(release?.page ?? URL(string: "https://github.com/\(AppIdentity.repository)/releases")!)
    }

    private func showDemo(_ state: String) {
        release = UpdateRelease(version: "2.1", notes: "Dotmeter can keep itself up to date.\n\n## New\n\n- A new version shows up here, with what changed.\n- Install and relaunch takes about ten seconds.\n\n## Fixed\n\n- The storage figures follow the disk while the app runs.",
                                page: URL(string: "https://github.com/\(AppIdentity.repository)/releases")!, image: URL(string: "https://github.com/\(AppIdentity.repository)/releases")!, size: 10_248_709)
        switch state {
        case "downloading": phase = .downloading(0.43)
        case "verifying": phase = .verifying
        case "restarting": phase = .restarting
        case "failed": phase = .failed(UpdateError.signature.localizedDescription)
        case "byhand": phase = .byHand("it may not change the folder it is in")
        case "current": release = nil; phase = .current
        case "checking": release = nil; phase = .checking
        case "unreachable": release = nil; phase = .failed(UpdateError.unreachable.localizedDescription)
        default: phase = .available
        }
    }
}
