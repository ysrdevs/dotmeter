import AppKit
import Foundation
import Observation

/// State machine behind the storage card: unscanned → scanning → ready ⇄ clearing.
@MainActor
@Observable
final class StorageModel {
    enum Phase: Equatable {
        case unscanned, scanning, ready
        case clearing(String)
    }

    private(set) var phase: Phase = .unscanned
    private(set) var bytes: [String: Double] = [:]
    private(set) var details: [String: String] = [:]
    private(set) var volume = StorageVolume(capacity: 0, free: 0, purgeable: 0, name: "", format: "")
    private(set) var scannedAt: Date?
    /// Storage shared between files (clones, hard links) that was counted once rather than per file.
    private(set) var sharedSkipped = 0.0
    /// Below 1 when the measured folders still added up to more than the disk holds and were scaled to fit.
    private(set) var fitFactor = 1.0
    /// How much of System data was found in Library folders.
    private(set) var libraryBytes = 0.0

    var capacity: Double { volume.capacity }
    private var available: Double { volume.free }
    private(set) var activityPath = ""
    private(set) var freed: Double?
    private(set) var denied = false
    private(set) var armed: String?
    /// Path of the single item whose action is waiting for its second click.
    private(set) var armedItem: String?
    /// Why the last single-item action did not happen, if it did not.
    private(set) var notice: String?
    /// The last removal was refused for a reason the user can fix; the page offers the fix.
    private(set) var blocked: RemovalFailure?
    /// Set after something was moved to the Trash rather than deleted.
    private(set) var moved: (name: String, bytes: Double)?
    /// The row being removed right now, how far along it is, and what to call it ("Clearing").
    private(set) var busyItem: String?
    private(set) var busyProgress = 0.0
    /// What is being done to it. Only permanent actions have progress worth a percentage.
    private(set) var busyAction: ItemAction = .none
    /// Goes up each time a row is removed, so the list can animate just that.
    private(set) var removals = 0

    private(set) var children: [String: [StorageChild]] = [:]
    @ObservationIgnored private var cleared: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var disarmTask: Task<Void, Never>?
    @ObservationIgnored private let backend: StorageBackend
    @ObservationIgnored private let symbols: [String: String]
    /// False for a model made to be tested: it neither reads the saved scan nor saves one.
    @ObservationIgnored private let remembers: Bool
    /// The free space last handed to `follow`, when the volume was last asked.
    @ObservationIgnored private var followed = -1.0

    private static let cacheKey = "storageScan.v2"

    init(backend: StorageBackend? = nil, remembers: Bool = true) {
        let demo = ProcessInfo.processInfo.environment["DOTMETER_STORAGE_DEMO"] == "1"
        self.backend = backend ?? (demo ? DemoStorageBackend() : DiskStorageBackend())
        self.remembers = remembers
        var resolved: [String: String] = [:]
        for info in StorageCategoryInfo.all {
            resolved[info.id] = info.symbols.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "square.fill"
        }
        symbols = resolved

        volume = self.backend.volume()

        if self.backend.isDemo {
            bytes = DemoStorageBackend.final
            details = DemoStorageBackend.details
            children = DemoStorageBackend.children
            scannedAt = Date()
            phase = .ready
            // Debug: DOTMETER_DEBUG_ARM=<item name> shows that row waiting for its second click,
            // DOTMETER_DEBUG_BUSY=<item name> shows it part-way through being cleared.
            if let name = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_ARM"] {
                armedItem = children.values.joined().first { $0.name == name }?.path
            }
            // DOTMETER_DEBUG_UNINSTALL=<app name> shows that made-up app's row asking to be confirmed, or, with
            // DOTMETER_DEBUG_UNINSTALL_STATE=wait or run, waiting for permission or part-way through.
            if let name = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_UNINSTALL"], let item = children["apps"]?.first(where: { $0.name == name }) {
                switch ProcessInfo.processInfo.environment["DOTMETER_DEBUG_UNINSTALL_STATE"] {
                case "wait", "run":
                    let waiting = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_UNINSTALL_STATE"] == "wait"
                    busyItem = item.path
                    busyProgress = waiting ? 0 : 0.42
                    busyAction = .uninstall
                    awaitingPermission = waiting
                    clearingLabel = waiting ? "Waiting for your OK" : "Uninstalling"
                    activityPath = waiting ? "switch on \(App.name) in the Login Items window" : "/Applications/" + item.name
                    phase = .clearing("apps")
                default:
                    armedItem = item.path
                    armedPlan = UninstallDemo.plan(item)
                }
            }
            if let name = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_BUSY"], let item = children["caches"]?.first(where: { $0.name == name }) {
                busyItem = item.path
                busyProgress = Double(ProcessInfo.processInfo.environment["DOTMETER_DEBUG_PROGRESS"] ?? "") ?? 0.42
                busyAction = .clear
                clearingLabel = "Clearing"
                activityPath = item.path
                bytes["caches"] = (bytes["caches"] ?? 0) - item.bytes * busyProgress
                // DOTMETER_DEBUG_BUSY_ROW_ONLY=1 leaves the card's bar at rest, to measure the row's animation alone.
                if ProcessInfo.processInfo.environment["DOTMETER_DEBUG_BUSY_ROW_ONLY"] != "1" { phase = .clearing("caches") }
            }
        } else if remembers, let data = UserDefaults.standard.data(forKey: Self.cacheKey), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            bytes = cache.bytes
            details = cache.details
            children = cache.children
            denied = cache.denied
            scannedAt = cache.scannedAt
            sharedSkipped = cache.sharedSkipped
            libraryBytes = cache.libraryBytes ?? 0
            fitToDisk()
            phase = .ready
        }
    }

    private struct Cache: Codable {
        var bytes: [String: Double]
        var details: [String: String]
        var children: [String: [StorageChild]]
        var denied: Bool
        var scannedAt: Date?
        var sharedSkipped: Double
        var libraryBytes: Double?
    }

    private func persist() {
        guard !backend.isDemo, remembers else { return }
        let cache = Cache(bytes: bytes, details: details, children: children, denied: denied, scannedAt: scannedAt, sharedSkipped: sharedSkipped, libraryBytes: libraryBytes)
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    // MARK: Derived

    private var used: Double { max(0, capacity - available) }
    private var measured: Double { bytes.filter { $0.key != "system" }.values.reduce(0, +) }
    /// What is used. At rest that is what the disk says now, never what the folders came to when they were
    /// last measured; while a scan fills in or something is being cleared it is the folders so far.
    private var shownTotal: Double {
        phase == .unscanned ? used : min(bytes.values.reduce(0, +), backend.isDemo ? capacity : used)
    }

    /// Called with each reading of the startup disk's free space. The disk fills and empties while the app
    /// runs, so the figures follow it. Whatever changed since the last scan is kept in System data, the
    /// remainder, until the next scan says where it went.
    func follow(free: UInt64) {
        guard !backend.isDemo, phase == .ready || phase == .unscanned else { return }
        // A hundredth of a gigabyte: under any figure shown, so the disk's own flutter redraws nothing.
        // The reading handed in and the volume's own figure can sit a little apart for good, so the volume is
        // asked again only when the reading itself has moved: asking takes a couple of milliseconds.
        let step = 1e7
        if abs(Double(free) - followed) >= step {
            followed = Double(free)
            let now = backend.volume()
            if abs(now.free - volume.free) >= step || now.capacity != volume.capacity { volume = now }
        }
        guard phase == .ready else { return }
        let rest = max(0, used - measured)
        if abs(rest - (bytes["system"] ?? 0)) >= step { bytes["system"] = rest }
    }

    /// Largest items of a category, for the storage page.
    func items(in category: String) -> [StorageChild] {
        var list = children[category] ?? []
        if category == "system", phase != .unscanned {
            // System data is a remainder. Say plainly how much of it could not be itemized.
            let itemized = min(libraryBytes, bytes["system"] ?? 0)
            let rest = (bytes["system"] ?? 0) - itemized
            if rest > 1e8 {
                list.append(StorageChild(name: "macOS, app containers and snapshots", path: "", bytes: rest))
                list.sort { $0.bytes > $1.bytes }
            }
        }
        return list
    }
    var isDemo: Bool { backend.isDemo }
    var usedBytes: Double { shownTotal }

    func reveal(_ item: StorageChild) {
        guard !item.path.isEmpty else { return }
        let path = (item.path as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Makes the categories add up to what the disk actually holds.
    /// Whatever is used but not attributed to a folder is system data. If the folders still add up to more than the
    /// disk holds (small shared files are not de-duplicated), they are scaled to fit rather than shown as impossible.
    private func fitToDisk() {
        let total = measured
        if total > used, total > 0 {
            let factor = used / total
            for (id, value) in bytes where id != "system" { bytes[id] = value * factor }
            for (id, list) in children {
                children[id] = list.map { StorageChild(name: $0.name, path: $0.path, bytes: $0.bytes * factor) }
            }
            bytes["system"] = 0
            fitFactor *= factor
        } else {
            bytes["system"] = max(0, used - total)
        }
    }

    static func gb(_ bytes: Double) -> String { size(bytes / 1e9) }

    /// Decimal units, as Finder shows them. Past a thousand gigabytes, terabytes read better.
    static func size(_ gigabytes: Double) -> String {
        gigabytes >= 1000 ? String(format: "%.2f TB", gigabytes / 1000) : String(format: "%.1f GB", gigabytes)
    }

    private static func capacityLabel(_ bytes: Double) -> String {
        let gb = bytes / 1e9
        if gb >= 1000 {
            let tb = gb / 1000
            return tb == tb.rounded() ? "\(Int(tb)) TB" : String(format: "%.1f TB", tb)
        }
        return "\(Int(gb.rounded())) GB"
    }

    // MARK: Scan

    func scan() {
        guard phase == .ready || phase == .unscanned else { return }
        task?.cancel()
        phase = .scanning
        freed = nil
        armed = nil
        armedItem = nil
        notice = nil
        moved = nil
        cleared = []
        activityPath = ""
        for info in StorageCategoryInfo.all { bytes[info.id] = 0 }
        volume = backend.volume()
        fitFactor = 1

        let backend = self.backend
        let box = ProgressBox<StorageScanUpdate>()
        task = Task { [weak self] in
            // Give the bar its beat to collapse before it starts filling again.
            try? await Task.sleep(for: .milliseconds(560))
            let pump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.apply(box.drain())
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            let result = await backend.scan { box.push($0.id, $0) }
            pump.cancel()
            guard let self, !Task.isCancelled else { return }
            self.bytes.merge(result.bytes) { _, new in new }
            self.details = result.details
            self.children = result.children
            self.denied = result.denied
            self.sharedSkipped = result.sharedBytesSkipped
            self.libraryBytes = result.libraryBytes
            self.scannedAt = Date()
            if backend.isDemo { self.bytes = result.bytes } else { self.fitToDisk() }
            self.activityPath = ""
            self.phase = .ready
            self.persist()
        }
    }

    private func apply(_ updates: [String: StorageScanUpdate]) {
        guard phase == .scanning, !updates.isEmpty else { return }
        var fraction = 0.0
        for (id, update) in updates {
            bytes[id] = update.bytes
            fraction = max(fraction, update.fraction)
        }
        if let latest = updates.values.max(by: { $0.fraction < $1.fraction }) { activityPath = latest.path }
        // System data is only known at the end, so let it grow with overall progress.
        let target = backend.isDemo ? (DemoStorageBackend.final["system"] ?? 0) : max(0, used - measured)
        bytes["system"] = target * fraction * fraction
    }

    // MARK: Clear

    func requestClear(_ id: String) {
        guard phase == .ready else { return }
        notice = nil
        moved = nil
        armedItem = nil
        if !backend.isDemo && armed != id {
            armed = id
            disarmTask?.cancel()
            disarmTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.armed = nil }
            }
            return
        }
        disarmTask?.cancel()
        armed = nil
        freed = nil
        if id == "trash" { shownTrash = bytes[id] ?? 0 } else { shownCaches = bytes[id] ?? 0 }
        phase = .clearing(id)
        let start = bytes[id] ?? 0
        let items = children[id] ?? []
        let backend = self.backend
        let box = ProgressBox<(String, Double)>()
        task = Task { [weak self] in
            let pump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let (path, done) = box.drain()["p"] {
                        self?.activityPath = path
                        self?.bytes[id] = max(0, start - done)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let total = await backend.clear(id, children: items) { path, done in box.push("p", (path, done)) }
            pump.cancel()
            guard let self else { return }
            self.bytes[id] = max(0, start - total)
            self.children[id] = []
            self.cleared.insert(id)
            self.freed = total
            self.shownCaches = 0
            self.shownTrash = 0
            self.activityPath = ""
            if !backend.isDemo { self.volume = backend.volume() }
            self.phase = .ready
            self.persist()
        }
    }

    /// What Claude is told about the disk, so questions like "what can I delete?" have something to stand on.
    var claudeSummary: String? {
        guard phase != .unscanned, phase != .scanning else { return nil }
        var lines = ["Disk: \(Self.gb(usedBytes)) used of \(Self.gb(capacity)), \(Self.gb(volume.free)) free now, \(Self.gb(volume.purgeable)) more reclaimable by macOS."]
        for info in StorageCategoryInfo.all {
            let total = bytes[info.id] ?? 0
            guard total > 5e7 else { continue }
            let top = items(in: info.id).prefix(6).map { "\($0.name) \(Self.gb($0.bytes))" }.joined(separator: ", ")
            lines.append("- \(info.name): \(Self.gb(total))\(top.isEmpty ? "" : ". Largest: " + top)")
        }
        if denied { lines.append("Photos and Trash could not be measured (no Full Disk Access).") }
        lines.append("The app can clear individual caches, uninstall apps and move folders to the Trash from its Storage page.")
        return lines.joined(separator: "\n")
    }

    // MARK: Single items

    enum ItemAction: Equatable {
        case none, uninstall, clear, delete, trash

        var title: String {
            switch self {
            case .none: return ""
            case .uninstall: return "Uninstall"
            case .clear: return "Clear"
            case .delete: return "Delete"
            case .trash: return "Move to Trash"
            }
        }

        /// Clearing a cache and deleting from the Trash free space at once; a move to the Trash can be undone.
        /// (An uninstall is for good as well, but takes its own path and its own wording.)
        var permanent: Bool { self == .clear || self == .delete }

        var verb: String {
            switch self {
            case .uninstall: return "Uninstalling"
            case .clear: return "Clearing"
            case .delete: return "Deleting"
            default: return "Moving to the Trash"
            }
        }

        /// One word for the row itself while it works, and one for when it is done.
        var short: String {
            switch self {
            case .uninstall: return "Uninstalling"
            case .clear: return "Clearing"
            case .delete: return "Deleting"
            default: return "Moving"
            }
        }

        var done: String {
            switch self {
            case .uninstall: return "Uninstalled"
            case .clear: return "Cleared"
            case .delete: return "Deleted"
            default: return "Moved"
            }
        }
    }

    /// Folders macOS and the user rely on; they can be opened in Finder but not removed from here.
    private static let protectedNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library", "Applications", "Photos Library.photoslibrary",
    ]

    /// What the row's button does. Caches are cleared, apps uninstalled, Trash items deleted, other folders moved to the Trash.
    func action(for item: StorageChild, in category: String) -> ItemAction {
        guard !item.path.isEmpty, category != "system" else { return .none }
        let path = (item.path as NSString).expandingTildeInPath
        switch category {
        case "caches": return .clear
        case "trash": return .delete
        case "apps":
            // What ships with macOS sits on the sealed system volume (Safari in Applications is a link into it).
            if !backend.isDemo, URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix("/System/") { return .none }
            return item.name.hasSuffix(".app") ? .uninstall : .trash
        default:
            let name = (path as NSString).lastPathComponent
            // Only things inside the home folder, and never the standard folders themselves.
            if !backend.isDemo && !path.hasPrefix(NSHomeDirectory() + "/") { return .none }
            if Self.protectedNames.contains(name), (path as NSString).deletingLastPathComponent == NSHomeDirectory() || name.hasSuffix(".photoslibrary") { return .none }
            return .trash
        }
    }

    func dismissBlocked() { blocked = nil }

    // MARK: Uninstall

    /// Asks macOS for the right to remove what the system owns. Set once by the app.
    @ObservationIgnored var helper: UninstallHelper?
    /// What confirming the armed app would delete. Nil while the Library folders are still being looked through,
    /// and the row cannot be confirmed until it is known.
    private(set) var armedPlan: UninstallPlan?
    /// The uninstall under way is waiting for the user to allow Dotmeter under Login Items & Extensions.
    private(set) var awaitingPermission = false
    @ObservationIgnored private var planTask: Task<Void, Never>?

    // MARK: Any app

    /// Every app in the Applications folders, for the search. Listed again at most every twenty seconds.
    @ObservationIgnored private var installed: (at: Date, apps: [StorageChild])?
    /// Sizes measured for apps the scan did not keep (it keeps the forty largest), by path.
    private(set) var appSizes: [String: Double] = [:]
    /// An app dropped onto the page. It is offered whatever folder it sits in.
    private(set) var droppedApp: StorageChild?
    @ObservationIgnored private var measuring: Task<Void, Never>?
    @ObservationIgnored private var sizeAsked: Set<String> = []

    /// Installed apps whose name contains the query, the ones that start with it first, then the largest.
    /// An empty query gives every app. A dropped app is always first.
    func findApps(_ query: String) -> [StorageChild] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var known: [String: Double] = [:]
        for child in children["apps"] ?? [] { known[(child.path as NSString).expandingTildeInPath] = child.bytes }
        var apps: [StorageChild]
        if backend.isDemo {
            apps = children["apps"] ?? []
        } else {
            if installed == nil || Date().timeIntervalSince(installed?.at ?? .distantPast) > 20 {
                installed = (Date(), Self.listInstalledApps())
            }
            apps = (installed?.apps ?? []).map { app in
                var app = app
                app.bytes = known[app.path] ?? appSizes[app.path] ?? 0
                return app
            }
        }
        func title(_ app: StorageChild) -> String { (app.name as NSString).deletingPathExtension.lowercased() }
        var matches = needle.isEmpty ? apps : apps.filter { title($0).contains(needle) }
        matches.sort { a, b in
            let pa = title(a).hasPrefix(needle), pb = title(b).hasPrefix(needle)
            if pa != pb { return pa }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return title(a) < title(b)
        }
        if var dropped = droppedApp {
            dropped.bytes = known[dropped.path] ?? appSizes[dropped.path] ?? 0
            matches.removeAll { $0.path == dropped.path }
            matches.insert(dropped, at: 0)
        }
        return matches
    }

    /// Apps in the two Applications folders and one folder down, by path. Dotmeter itself is left out: it cannot
    /// remove the copy it is running from.
    private static func listInstalledApps() -> [StorageChild] {
        let fm = FileManager.default
        let own = Bundle.main.bundlePath
        var out: [StorageChild] = []
        func add(_ path: String) {
            guard path != own else { return }
            out.append(StorageChild(name: (path as NSString).lastPathComponent, path: path, bytes: 0))
        }
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for entry in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where !entry.hasPrefix(".") {
                let full = folder + "/" + entry
                if entry.hasSuffix(".app") { add(full) } else {
                    var isFolder: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isFolder), isFolder.boolValue else { continue }
                    for inner in (try? fm.contentsOfDirectory(atPath: full)) ?? [] where inner.hasSuffix(".app") { add(full + "/" + inner) }
                }
            }
        }
        return out
    }

    /// Measures the apps on show that have no size yet, one after another, off the main thread.
    func measureApps(_ apps: [StorageChild]) {
        let wanted = apps.filter { $0.bytes <= 0 && !sizeAsked.contains($0.path) }.map(\.path)
        guard !wanted.isEmpty, !backend.isDemo else { return }
        for path in wanted { sizeAsked.insert(path) }
        let previous = measuring
        measuring = Task { [weak self] in
            await previous?.value
            for path in wanted {
                if Task.isCancelled { return }
                let bytes = await Task.detached(priority: .utility) { Double(DirectoryWalker.walk(path, cancelled: { false }) { _, _ in }.bytes) }.value
                self?.appSizes[path] = bytes
            }
        }
    }

    /// An app dropped onto the page: it joins the list, wherever it lives, and its row asks at once.
    /// Nil when what was dropped is not an app Dotmeter can remove.
    @discardableResult
    func offerDropped(_ url: URL) -> StorageChild? {
        let path = url.standardizedFileURL.path
        guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path + "/Contents/Info.plist") else {
            notice = "\(url.lastPathComponent) is not an app."
            return nil
        }
        guard path != Bundle.main.bundlePath else {
            notice = "\(App.name) cannot remove the copy it is running from. Quit it and drag it to the Trash."
            return nil
        }
        let item = StorageChild(name: url.lastPathComponent, path: path, bytes: 0)
        guard action(for: item, in: "apps") == .uninstall else {
            notice = "\(url.lastPathComponent) is part of macOS and cannot be removed."
            return nil
        }
        droppedApp = item
        measureApps([item])
        if armedItem != item.path { requestItemAction(item, in: "apps") }
        return item
    }

    func forgetDropped() { droppedApp = nil }

    /// The first click on an app's Uninstall: the row itself asks, and says what would go with the app.
    private func armUninstall(_ item: StorageChild) {
        notice = nil
        blocked = nil
        if let blocker = runningBlocker(for: item, in: "apps") {
            notice = blocker
            return
        }
        armedItem = item.path
        armedPlan = nil
        armed = nil
        disarmTask?.cancel()
        planTask?.cancel()
        let path = (item.path as NSString).expandingTildeInPath
        let demo = backend.isDemo
        planTask = Task { [weak self] in
            // A size the scan or the search already has saves walking the app again.
            let size = item.bytes > 0 ? item.bytes : nil
            let plan = demo ? UninstallDemo.plan(item) : await Task.detached(priority: .userInitiated) { Uninstaller.plan(for: path, appBytes: size) }.value
            guard let self, !Task.isCancelled, self.armedItem == item.path else { return }
            self.armedPlan = plan
            // The clock starts once there is something to read.
            self.disarmTask?.cancel()
            self.disarmTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(9))
                if !Task.isCancelled, self?.armedItem == item.path {
                    self?.armedItem = nil
                    self?.armedPlan = nil
                }
            }
        }
    }

    /// Lets go of a row that is waiting for its second click.
    func disarmItem() {
        disarmTask?.cancel()
        planTask?.cancel()
        armedItem = nil
        armedPlan = nil
    }

    /// Stops waiting for permission. The app stays where it is.
    func cancelPermissionWait() {
        helper?.stopAsking()
    }

    /// The second click: the app and what it left behind are deleted, for good. Whatever a plain delete is refused
    /// goes to the helper, which asks macOS for itself the first time and carries on once it is allowed.
    private func runUninstall(_ item: StorageChild, plan: UninstallPlan) {
        disarmTask?.cancel()
        armedItem = nil
        armedPlan = nil
        if let blocker = runningBlocker(for: item, in: "apps") {
            notice = blocker
            return
        }
        freed = nil
        moved = nil
        let shown = DiskStorageBackend.abbreviate((item.path as NSString).expandingTildeInPath)
        clearingLabel = ItemAction.uninstall.verb
        activityPath = shown
        busyItem = item.path
        busyProgress = 0
        busyAction = .uninstall
        // An app can be found and removed before any scan; the card goes back to how it was afterwards.
        let before = phase
        phase = .clearing("apps")
        let demo = backend.isDemo
        let start = bytes["apps"] ?? 0
        let helper = self.helper
        let box = ProgressBox<Double>()
        task = Task { [weak self] in
            let pump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self {
                        if let fraction = box.drain()["p"] {
                            self.busyProgress = max(self.busyProgress, fraction)
                            self.bytes["apps"] = max(0, start - item.bytes * self.busyProgress)
                        }
                        // The row and the card say so while macOS is waiting for the user.
                        let waiting = helper?.asking ?? false
                        if waiting != self.awaitingPermission {
                            self.awaitingPermission = waiting
                            self.clearingLabel = waiting ? "Waiting for your OK" : ItemAction.uninstall.verb
                            self.activityPath = waiting ? "switch on \(App.name) in the Login Items window" : shown
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            async let minimum: Void = { try? await Task.sleep(for: .milliseconds(900)) }()
            let failures: [String: String]
            if demo {
                for step in 1...12 {
                    try? await Task.sleep(for: .milliseconds(90))
                    box.push("p", Double(step) / 12)
                }
                failures = [:]
            } else {
                failures = await Uninstaller.delete(
                    plan,
                    helper: { paths in await helper?.remove(paths, asking: true) ?? paths.map { _ in "\(App.possessive) helper is not part of this copy." } },
                    progress: { box.push("p", $0) }
                )
            }
            await minimum
            pump.cancel()
            guard let self else { return }
            self.awaitingPermission = false
            let appGone = failures[plan.path] == nil
            if appGone {
                // Let the row finish draining and show its check mark before it leaves the list.
                self.busyProgress = 1
                self.bytes["apps"] = max(0, start - item.bytes)
                try? await Task.sleep(for: .milliseconds(520))
            }
            self.clearingLabel = nil
            self.activityPath = ""
            self.busyItem = nil
            self.busyProgress = 0
            self.busyAction = .none
            self.bytes["apps"] = start
            let name = (item.name as NSString).deletingPathExtension
            if appGone {
                self.removals += 1
                self.children["apps"]?.removeAll { ($0.path as NSString).expandingTildeInPath == plan.path }
                self.installed?.apps.removeAll { $0.path == plan.path }
                if self.droppedApp?.path == item.path { self.droppedApp = nil }
                self.bytes["apps"] = max(0, start - item.bytes)
                self.freed = plan.chosen.filter { failures[$0.path] == nil }.compactMap(\.bytes).reduce(0, +)
                if let (path, reason) = failures.sorted(by: { $0.key < $1.key }).first {
                    // The app is gone; say what of its could not follow it.
                    let rest = failures.count - 1
                    self.notice = "\(name) is uninstalled. \(DiskStorageBackend.abbreviate(path))\(rest > 0 ? " and \(rest) more" : "") stayed behind: \(Self.sentence(reason))"
                }
            } else {
                self.notice = "\(name) was not uninstalled. \(Self.sentence(failures[plan.path] ?? ""))"
            }
            if !demo { self.volume = self.backend.volume() }
            self.phase = before == .unscanned ? .unscanned : .ready
            if before != .unscanned { self.persist() }
        }
    }

    /// A reason as it reads at the end of a line: the helper's "Refused: " dropped, a capital and a full stop.
    private static func sentence(_ reason: String) -> String {
        var text = reason.hasPrefix("Refused: ") ? String(reason.dropFirst(9)) : reason
        text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }
        text = first.uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    /// First call arms the row, second call (within a few seconds) does it.
    func requestItemAction(_ item: StorageChild, in category: String) {
        let action = action(for: item, in: category)
        // Everything else works on what a scan measured; an app can be found and removed without one.
        guard phase == .ready || (action == .uninstall && phase == .unscanned), action != .none else { return }
        // An app asks in its own row, once it knows what would go with it, and then goes for good.
        if action == .uninstall {
            if armedItem != item.path {
                armUninstall(item)
            } else if let plan = armedPlan {
                runUninstall(item, plan: plan)
            }
            return
        }
        notice = nil
        blocked = nil
        if armedItem != item.path {
            planTask?.cancel()
            armedPlan = nil
            armedItem = item.path
            armed = nil
            disarmTask?.cancel()
            disarmTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.armedItem = nil }
            }
            return
        }
        disarmTask?.cancel()
        armedItem = nil

        if let blocker = runningBlocker(for: item, in: category) {
            notice = blocker
            return
        }

        freed = nil
        moved = nil
        clearingLabel = action.verb
        activityPath = DiskStorageBackend.abbreviate((item.path as NSString).expandingTildeInPath)
        busyItem = item.path
        busyProgress = 0
        busyAction = action
        phase = .clearing(category)
        let backend = self.backend
        let start = bytes[category] ?? 0
        let box = ProgressBox<Double>()
        task = Task { [weak self] in
            // The row drains and the card's bar shrinks together, at the pace the files actually go.
            let pump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let fraction = box.drain()["p"], let self {
                        self.busyProgress = max(self.busyProgress, fraction)
                        if action.permanent { self.bytes[category] = max(0, start - item.bytes * self.busyProgress) }
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            async let minimum: Void = { try? await Task.sleep(for: .milliseconds(900)) }()
            let failure = await backend.remove(item, permanently: action.permanent) { box.push("p", $0) }
            await minimum
            pump.cancel()
            guard let self else { return }
            if failure == nil {
                // Let the row finish draining and show its check mark before it leaves the list.
                self.busyProgress = 1
                if action.permanent { self.bytes[category] = max(0, start - item.bytes) }
                try? await Task.sleep(for: .milliseconds(520))
            }
            self.clearingLabel = nil
            self.activityPath = ""
            self.busyItem = nil
            self.busyProgress = 0
            self.busyAction = .none
            self.bytes[category] = start
            if let failure {
                self.notice = failure.message
                self.blocked = failure.fix == nil ? nil : failure
            } else {
                self.removals += 1
                self.children[category]?.removeAll { $0.path == item.path }
                self.bytes[category] = max(0, (self.bytes[category] ?? 0) - item.bytes)
                if action.permanent {
                    self.freed = item.bytes
                } else {
                    // Still on the disk until the Trash is emptied.
                    self.bytes["trash"] = (self.bytes["trash"] ?? 0) + item.bytes
                    self.children["trash", default: []].insert(StorageChild(name: item.name, path: "~/.Trash/" + (item.path as NSString).lastPathComponent, bytes: item.bytes), at: 0)
                    self.cleared.remove("trash")
                    self.moved = (item.name, item.bytes)
                }
            }
            if !backend.isDemo { self.volume = backend.volume() }
            self.phase = .ready
            self.persist()
        }
    }

    /// Removing an app or its cache while it runs ends badly, so say so instead.
    private func runningBlocker(for item: StorageChild, in category: String) -> String? {
        guard !backend.isDemo else { return nil }
        let running = NSWorkspace.shared.runningApplications
        let path = (item.path as NSString).expandingTildeInPath
        if category == "apps", let app = running.first(where: { $0.bundleURL?.path == path }) {
            return "\(app.localizedName ?? item.name) is running. Quit it first."
        }
        if category == "caches" {
            let key = item.name.lowercased()
            if key == App.bundleID { return "That is \(App.possessive) own cache." }
            if let app = running.first(where: { ($0.bundleIdentifier?.lowercased()).map { key == $0 || key.hasPrefix($0 + ".") } ?? false }) {
                return "\(app.localizedName ?? item.name) is running. Quit it first."
            }
        }
        return nil
    }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Card model

    var meter: MeterModel {
        // The folders can come to more than is used now, when a lot was deleted since they were measured.
        let sum = bytes.values.reduce(0, +)
        let scale = phase != .unscanned && sum > shownTotal && sum > 0 ? shownTotal / sum : 1
        var items: [MeterItem] = StorageCategoryInfo.all.map { info in
            let value = bytes[info.id] ?? 0
            return MeterItem(
                id: info.id,
                name: info.name,
                icon: .symbol(symbols[info.id] ?? "square.fill"),
                rgb: info.rgb,
                amount: value * scale,
                number: value / 1e9,
                format: Self.size,
                detail: details[info.id] ?? ""
            )
        }
        if phase == .unscanned {
            // Nothing measured yet: the categories show a dash and the bar is one neutral block of what the OS reports.
            for i in items.indices {
                items[i].amount = 0
                items[i].format = { _ in "—" }
                items[i].detail = "Not measured yet."
            }
            items.append(MeterItem(
                id: "unmeasured", name: "Not measured yet", icon: .symbol("questionmark.square.dashed"), rgb: PX.gray,
                amount: used, number: used / 1e9, format: Self.size,
                detail: "Scan to see what this is made of.", inBar: true, inLegend: false
            ))
        }

        let free = max(0, capacity - shownTotal)
        var status: MeterStatus = .plain("\(Self.gb(free)) available")
        var mode: MatrixMode = .rest
        switch phase {
        case .unscanned:
            // An app can be removed before any scan, so the outcome has to be able to show here too.
            if let notice {
                status = .warning(notice)
            } else if let freed {
                status = .success("Freed \(Self.gb(freed)).", "\(Self.gb(free)) available")
            } else {
                status = .plain("\(Self.gb(free)) available")
            }
        case .scanning:
            status = .activity("Calculating", activityPath)
            mode = .scanning
        case .clearing(let id):
            status = .activity(clearingLabel ?? (id == "trash" ? "Emptying the Trash" : "Clearing caches"), activityPath)
            mode = .clearing(id)
        case .ready:
            if let notice {
                status = .warning(notice)
            } else if let moved {
                status = .success("Moved \(moved.name) to the Trash.", "Empty it to free \(Self.gb(moved.bytes))")
            } else if let freed {
                status = .success("Freed \(Self.gb(freed)).", "\(Self.gb(free)) available")
            }
        }

        return MeterModel(
            number: shownTotal / 1e9,
            numberFormat: Self.size,
            caption: "of \(Self.capacityLabel(capacity)) used",
            status: status,
            items: items,
            capacity: max(capacity, 1),
            mode: mode,
            footer: footer,
            trailing: MeterAction(
                title: phase == .unscanned ? "Scan" : "Rescan",
                symbol: "arrow.triangle.2.circlepath",
                spinning: phase == .scanning,
                enabled: phase == .ready || phase == .unscanned,
                symbolRotation: 90,
                action: { [weak self] in self?.scan() }
            ),
            animatesNumbers: mode != .rest
        )
    }

    private var footer: MeterFooter {
        let caches = StorageCategoryInfo.info("caches"), trash = StorageCategoryInfo.info("trash")
        func suggestion(_ info: StorageCategoryInfo, text: String, confirm: String, button: String, enabled: Bool) -> MeterFooter {
            let isArmed = armed == info.id
            return .suggestion(
                icon: .symbol(symbols[info.id] ?? "square.fill"),
                rgb: info.rgb,
                text: isArmed ? confirm : text,
                action: MeterAction(title: isArmed ? "Delete" : button, enabled: enabled, destructive: isArmed, action: { [weak self] in self?.requestClear(info.id) })
            )
        }

        switch phase {
        case .scanning:
            return .searching("Looking for things you can clear")
        case .unscanned:
            return .suggestion(
                icon: .symbol("magnifyingglass"), rgb: PX.gray,
                text: "Scan to see what is using your disk.",
                action: MeterAction(title: "Scan", action: { [weak self] in self?.scan() })
            )
        case .clearing(let id):
            let info = id == "trash" ? trash : caches
            return id == "trash"
                ? suggestion(info, text: trashText, confirm: "", button: "Empty Trash", enabled: false)
                : suggestion(info, text: cachesText, confirm: "", button: "Clear caches", enabled: false)
        case .ready:
            let cacheBytes = bytes["caches"] ?? 0, trashBytes = bytes["trash"] ?? 0
            if cacheBytes >= 1e9, !cleared.contains("caches") {
                return suggestion(caches, text: cachesText, confirm: "This permanently deletes \(Self.gb(cacheBytes)) of caches. Caches of running apps are kept.", button: "Clear caches", enabled: true)
            }
            if trashBytes >= 2e8, !cleared.contains("trash") {
                return suggestion(trash, text: trashText, confirm: "This permanently deletes everything in the Trash.", button: "Empty Trash", enabled: true)
            }
            if denied {
                return .suggestion(
                    icon: .symbol("lock.fill"), rgb: PX.gray,
                    text: "Some folders are private. Allow Full Disk Access for exact sizes.",
                    action: MeterAction(title: "Open Settings", action: { [weak self] in self?.openFullDiskAccess() })
                )
            }
            return .success(cleared.isEmpty ? "Nothing is worth clearing right now." : "Nothing else is worth clearing right now.")
        }
    }

    private var cachesText: String {
        "Caches are using \(Self.gb(max(bytes["caches"] ?? 0, shownCaches))). Apps rebuild them when they need them."
    }

    private var trashText: String {
        "The Trash is holding \(Self.gb(max(bytes["trash"] ?? 0, shownTrash))) of things you've already deleted."
    }

    /// What a single-item action calls itself while it runs ("Clearing", "Uninstalling").
    @ObservationIgnored private var clearingLabel: String?
    /// The amount a suggestion was made for stays in its sentence while the clearing runs, as in the reference.
    @ObservationIgnored private var shownCaches = 0.0
    @ObservationIgnored private var shownTrash = 0.0

    // MARK: Debug

    /// Design-review helper: puts the card in a named state without running anything.
    func debugSet(_ state: String) {
        guard backend.isDemo else { return }
        switch state {
        case "scan":
            phase = .scanning
            activityPath = "/System/Volumes/Data/.snapshots"
            bytes = ["apps": 52.6e9, "developer": 36.3e9, "photos": 56.9e9, "movies": 38.1e9, "documents": 35.7e9, "music": 10.9e9, "system": 24.1e9, "caches": 35.8e9, "trash": 0]
        case "clearing":
            phase = .clearing("caches")
            activityPath = "~/Library/Caches/com.penrose.studio"
            shownCaches = 46.8e9
            bytes["caches"] = 28.8e9
        case "done":
            bytes["caches"] = 1.2e9
            bytes["trash"] = 0
            cleared = ["caches", "trash"]
            freed = 31.4e9
        default:
            break
        }
    }
}
