import Foundation

/// What the first line of one of macOS's diagnostic reports says. The rest of the file is never read.
struct CrashReport: Equatable {
    /// The report's own identifier, or its file name where it has none.
    var id: String
    var app: String
    var bundleID: String?
    var time: Date
    /// macOS's number for the kind of report. 309 is a crash.
    var bugType: String
    /// A report written about a fault the process lived through ("ExcUserFault"), not a crash.
    var simulated: Bool

    /// Crashes become events. The other kinds this was written against are not an app going down: 298 and
    /// 409 are the system's own, and the text reports beside them are about processor time and disk writes.
    var isCrash: Bool { bugType == "309" && !simulated }

    private static let stamps: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"].map { format in
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// From the header line, a small JSON object. nil if it is not one, or says too little to be of use.
    static func decode(header: Data, fileName: String) -> CrashReport? {
        guard let object = try? JSONSerialization.jsonObject(with: header), let fields = object as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            if let value = fields[key] as? String { return value.isEmpty ? nil : value }
            return (fields[key] as? NSNumber)?.stringValue
        }
        guard let type = text("bug_type"), let stamp = text("timestamp"), let time = stamps.lazy.compactMap({ $0.date(from: stamp) }).first else { return nil }
        guard let app = text("app_name") ?? text("name") else { return nil }
        return CrashReport(
            id: text("incident_id") ?? fileName, app: app, bundleID: text("bundleID"), time: time, bugType: type,
            simulated: (fields["is_simulated"] as? NSNumber)?.boolValue ?? false
        )
    }

    /// Reads the start of a report as far as the end of its header line, and uses that line alone. The body,
    /// megabytes of it at times, stays on the disk.
    static func read(_ path: String) -> CrashReport? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var head = Data()
        while head.count < 4096 {
            guard let piece = try? handle.read(upToCount: 1024), !piece.isEmpty else { return nil }
            head.append(piece)
            if let end = head.firstIndex(of: 0x0A) {
                return decode(header: head[head.startIndex..<end], fileName: (path as NSString).lastPathComponent)
            }
        }
        return nil
    }

    /// What reading the report folders once came to.
    struct Pass {
        var reports: [CrashReport] = []
        /// Files that need not be opened again: read, too old, or not a report.
        var done: [String] = []
        /// Files that could not be read yet and were written a moment ago: still being written, perhaps.
        var again: [String] = []
    }

    /// The reports in these folders from `since` on, leaving out files already dealt with. A folder that cannot
    /// be listed is passed over.
    static func pass(folders: [String], skipping: Set<String>, since: Date, now: Date) -> Pass {
        var pass = Pass()
        let manager = FileManager.default
        for folder in folders {
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".ips") && !name.hasPrefix(".") {
                let path = folder + "/" + name
                if skipping.contains(path) { continue }
                guard let written = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                // A report is written within moments of its crash, so an old file cannot hold a recent one.
                if written < since { pass.done.append(path); continue }
                if let report = read(path) {
                    pass.done.append(path)
                    if report.time >= since { pass.reports.append(report) }
                } else if now.timeIntervalSince(written) < 60 {
                    pass.again.append(path)
                } else {
                    pass.done.append(path)
                }
            }
        }
        return pass
    }
}

/// Writes crashes into the Timeline. Several crashes of one app within an hour are one event that counts
/// them, and a report is only ever counted once: the store remembers which ones it has taken.
@MainActor
final class CrashLog {
    nonisolated static let keep: TimeInterval = 7 * 86_400
    /// Crashes of one app this close to the first are the same event.
    static let together: TimeInterval = 3600

    private let store: TimelineStore
    /// Which app a report is about, or nil if it is not about an app.
    private let resolve: (CrashReport) -> ActivityUser?

    init(store: TimelineStore, resolve: @escaping (CrashReport) -> ActivityUser? = CrashLog.app) {
        self.store = store
        self.resolve = resolve
    }

    /// The app a report is about. Reports with no bundle identifier are command-line tools and background
    /// processes, and Apple's identifiers that belong to no app are pieces of the system: neither is an app
    /// crashing, and on a Mac used for development they come by the dozen.
    nonisolated static func app(_ report: CrashReport) -> ActivityUser? {
        guard let bundleID = report.bundleID else { return nil }
        if let app = ActivityApps.app(forBundleID: bundleID) { return ActivityUser(key: app.bundlePath, name: app.name, bundlePath: app.bundlePath) }
        return bundleID.hasPrefix("com.apple.") ? nil : ActivityUser(key: "id:" + bundleID, name: report.app, bundlePath: nil)
    }

    /// Takes the reports that are news and returns the events they began (not the ones they were added to).
    @discardableResult
    func take(_ reports: [CrashReport], now: Date) -> [TimelineEvent] {
        var begun: [TimelineEvent] = []
        var taken: [String: Date] = [:]
        let since = now.addingTimeInterval(-Self.keep)
        for report in reports.sorted(by: { $0.time < $1.time }) {
            guard report.isCrash, report.time >= since, store.crashReports[report.id] == nil, taken[report.id] == nil else { continue }
            guard let user = resolve(report), let name = user.name else { continue }
            taken[report.id] = report.time
            let earlier = store.events.last { $0.kind == .crash && $0.apps.first?.name == name && abs(report.time.timeIntervalSince($0.start)) <= Self.together }
            if let earlier {
                store.update(earlier.id) { event in
                    let times = (event.count ?? 1) + 1
                    event.count = times
                    event.end = max(event.end ?? event.start, report.time)
                    event.summary = ActivityWords.crashed(name, times: times)
                }
            } else {
                // Over the moment it happened: a crash has no length.
                var event = TimelineEvent(kind: .crash, start: report.time, end: report.time, summary: ActivityWords.crashed(name, times: 1))
                event.apps = [.init(name: name, bundlePath: user.bundlePath, cpu: 0)]
                store.begin(event)
                begun.append(event)
            }
        }
        if !taken.isEmpty { store.noteCrashReports(taken, now: now) }
        return begun
    }
}

/// Watches the folders macOS writes its reports into. The file system says when one changes, so nothing is
/// read until there is something new.
@MainActor
final class CrashFolders {
    private let folders: [String]
    private var sources: [DispatchSourceFileSystemObject] = []
    private var done: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var scheduled = false
    private var first = true
    /// Called with what a pass found, and whether it was the look at launch.
    var found: (_ reports: [CrashReport], _ atLaunch: Bool) -> Void = { _, _ in }
    private(set) var passes = 0
    var count: Int { folders.count }
    /// How many of the folders could be opened to watch.
    var watching: Int { sources.count }

    init(folders: [String]) {
        self.folders = folders
    }

    static var standard: [String] {
        [NSHomeDirectory() + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
    }

    func start() {
        for folder in folders {
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule(after: 1.5) } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        look()
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    /// A report is written in several steps, each of which changes the folder: one look shortly after the
    /// first of them sees the finished file.
    private func schedule(after seconds: Double) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.look()
            }
        }
    }

    private func look() {
        let folders = folders, skipping = done, atLaunch = first
        first = false
        let now = Date()
        Task.detached(priority: .utility) { [weak self] in
            let pass = CrashReport.pass(folders: folders, skipping: skipping, since: now.addingTimeInterval(-CrashLog.keep), now: now)
            await MainActor.run { [weak self] in self?.finish(pass, atLaunch: atLaunch) }
        }
    }

    private func finish(_ pass: CrashReport.Pass, atLaunch: Bool) {
        passes += 1
        done.formUnion(pass.done)
        var retry = false
        for path in pass.again {
            attempts[path, default: 0] += 1
            if attempts[path, default: 0] >= 3 { done.insert(path) } else { retry = true }
        }
        if retry { schedule(after: 5) }
        ActivityWatch.log("crash folders: pass \(passes), \(pass.done.count) files looked at, \(pass.reports.count) reports in the last week, \(pass.again.count) to try again")
        found(pass.reports, atLaunch)
    }
}
