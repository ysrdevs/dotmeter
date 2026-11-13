import AppKit
import CDotmeter
import Darwin
import Foundation

/// Remembers which shared storage has already been counted. APFS lets files share blocks (clones) and names share
/// files (hard links); without this a disk full of them adds up to more than its own capacity.
final class ScanDeduper: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = Set<UInt64>()
    private(set) var bytesSkipped: Int64 = 0

    /// Hard links and clones live in different number spaces, so clone ids are tagged.
    static func linkKey(_ inode: UInt64) -> UInt64 { inode & 0x7FFF_FFFF_FFFF_FFFF }
    static func cloneKey(_ id: UInt64) -> UInt64 { id | 0x8000_0000_0000_0000 }

    /// True the first time this shared storage is seen; later callers count only their own part.
    func claim(_ key: UInt64, shared: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed.insert(key).inserted { return true }
        bytesSkipped += shared
        return false
    }
}

/// Measures folders with fts(3): allocated blocks only, never file contents.
enum DirectoryWalker {
    /// Clone lookups cost one extra system call, so they are only made for files big enough to matter.
    static let cloneCheckThreshold: Int64 = 96 * 1024

    /// A file whose storage is shared with other files. Who gets to count the shared part is decided after every
    /// folder has been walked, in category order, so the answer does not depend on which thread got there first.
    struct Shared {
        var key: UInt64
        var full: Int64
        var own: Int64
        var child: Int32
    }

    struct Stats {
        var bytes: Int64 = 0
        var files = 0
        var denied = false
        var shared: [Shared] = []
        var children: [(name: String, bytes: Int64)] = []
        var largestFile: (name: String, bytes: Int64)?
        var photos = 0
        var videos = 0
        var songs = 0
    }

    private static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "raw", "dng", "cr2", "cr3", "nef", "arw", "tiff", "tif", "gif", "webp"]
    private static let videoExt: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi", "webm"]
    private static let songExt: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "alac", "m4p"]

    static func walk(_ root: String, cancelled: () -> Bool, tick: (_ bytes: Int64, _ path: String) -> Void) -> Stats {
        var stats = Stats()
        guard let cRoot = strdup(root) else { return stats }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            stats.denied = true
            return stats
        }
        defer { fts_close(stream) }

        let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name) ?? 0
        var childName: String?
        var childBytes: Int64 = 0
        // Shared files are counted in full the first time this walk sees them, so the running total looks right
        // while scanning; the final split between folders is settled by `resolve` afterwards.
        var seenHere = Set<UInt64>()
        var optimistic: Int64 = 0
        var counter = 0
        var lastTick = DispatchTime.now().uptimeNanoseconds

        func name(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
            let pointer = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            return String(cString: pointer)
        }
        func flushChild() {
            if let childName { stats.children.append((childName, childBytes)) }
            childName = nil
            childBytes = 0
        }

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            switch info {
            case FTS_D:
                if level == 0, entry.pointee.fts_statp == nil { stats.denied = true }
                if level == 1 {
                    flushChild()
                    childName = name(entry)
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                var size = entry.pointee.fts_statp.map { Int64($0.pointee.st_blocks) * 512 } ?? 0
                if info == FTS_F, size > 0, let stat = entry.pointee.fts_statp {
                    var sharedKey: UInt64?
                    var own: Int64 = 0
                    if stat.pointee.st_nlink > 1 {
                        // The same file under several names.
                        sharedKey = ScanDeduper.linkKey(UInt64(stat.pointee.st_ino))
                    } else if size >= cloneCheckThreshold, let path = entry.pointee.fts_accpath {
                        var clone = dotmeter_clone_info_t()
                        if dotmeter_clone_info(path, &clone) == 0, clone.ref_count > 1 {
                            // Blocks shared with other files; only `own` belongs to this one alone.
                            sharedKey = ScanDeduper.cloneKey(clone.clone_id)
                            own = max(0, min(size, clone.private_size))
                        }
                    }
                    if let sharedKey {
                        let childIndex = level == 1 ? Int32(stats.children.count) : (childName == nil ? -1 : Int32(stats.children.count))
                        stats.shared.append(Shared(key: sharedKey, full: size, own: own, child: childIndex))
                        optimistic += seenHere.insert(sharedKey).inserted ? size : own
                        size = 0
                    }
                }
                stats.bytes += size
                stats.files += 1
                if level == 1 {
                    flushChild()
                    stats.children.append((name(entry), size))
                } else {
                    childBytes += size
                }
                if info == FTS_F {
                    let length = Int(entry.pointee.fts_namelen)
                    if length > 3 || size > 64_000_000 {
                        let fileName = name(entry)
                        if let dot = fileName.lastIndex(of: ".") {
                            let ext = fileName[fileName.index(after: dot)...].lowercased()
                            if photoExt.contains(ext) { stats.photos += 1 } else if videoExt.contains(ext) { stats.videos += 1 } else if songExt.contains(ext) { stats.songs += 1 }
                        }
                        if size > (stats.largestFile?.bytes ?? 64_000_000) { stats.largestFile = (fileName, size) }
                    }
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                if level <= 1 { stats.denied = true }
            default:
                break
            }

            counter += 1
            if counter & 0x3FF == 0 {
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastTick > 45_000_000 {
                    lastTick = now
                    if cancelled() { break }
                    let display = childName.map { root + "/" + $0 } ?? root
                    tick(stats.bytes + optimistic, display)
                }
            }
        }
        flushChild()
        return stats
    }

    /// Settles who counts each shared file: the first folder to claim it gets the whole file, later ones only
    /// the part that is theirs alone. Call once per walk, in priority order.
    static func resolve(_ stats: inout Stats, with deduper: ScanDeduper) {
        for item in stats.shared {
            let counted = deduper.claim(item.key, shared: item.full - item.own) ? item.full : item.own
            stats.bytes += counted
            let index = Int(item.child)
            if index >= 0 && index < stats.children.count { stats.children[index].bytes += counted }
        }
        stats.shared = []
    }
}

/// The real thing: measures the user's disk, and deletes caches or Trash contents when asked.
struct DiskStorageBackend: StorageBackend {
    var isDemo: Bool { false }

    private static let home = NSHomeDirectory()

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func volume() -> StorageVolume {
        let url = URL(fileURLWithPath: Self.home)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else {
            return StorageVolume(capacity: 0, free: 0, purgeable: 0, name: "", format: "")
        }
        let free = Double(values.volumeAvailableCapacity ?? 0)
        // "Important usage" includes space macOS can reclaim on demand (local snapshots, purgeable caches).
        let reclaimable = max(0, Double(values.volumeAvailableCapacityForImportantUsage ?? 0) - free)
        return StorageVolume(capacity: Double(total), free: free, purgeable: reclaimable, name: values.volumeName ?? "", format: values.volumeLocalizedFormatDescription ?? "")
    }

    /// Which folders feed which category. Documents takes everything else in the home folder.
    static func roots() -> [String: [String]] {
        let h = home
        let fm = FileManager.default
        var roots: [String: [String]] = [
            "apps": ["/Applications", h + "/Applications"],
            "developer": [
                h + "/Library/Developer", "/Library/Developer", h + "/.cargo", h + "/.rustup", h + "/.gradle", h + "/.m2", h + "/.npm",
                h + "/.nvm", h + "/.pnpm-store", h + "/Library/pnpm", h + "/.bun", h + "/.pyenv", h + "/.conda", h + "/miniconda3",
                h + "/.docker", h + "/.android", h + "/Library/Android", h + "/go",
                h + "/.cocoapods", h + "/.swiftpm", h + "/.cache", h + "/.local", "/opt/homebrew",
            ],
            "photos": [h + "/Pictures"],
            "movies": [h + "/Movies"],
            "music": [h + "/Music"],
            "caches": [h + "/Library/Caches"],
            "trash": [h + "/.Trash"],
        ]
        let claimed = Set(roots.values.flatMap { $0 } + [h + "/Library"])
        let topLevel = (try? fm.contentsOfDirectory(atPath: h)) ?? []
        roots["documents"] = topLevel.map { h + "/" + $0 }.filter { !claimed.contains($0) && $0 != h + "/.Trash" }
        // Not a category of its own: what apps keep in Library is part of System data, measured so it can be itemized.
        // Other apps' containers and cloud folders are left out on purpose. Opening them makes macOS show a
        // permission dialog and block the scan until it is answered, which would hang the whole scan.
        let library = (try? fm.contentsOfDirectory(atPath: h + "/Library")) ?? []
        roots[libraryID] = library.filter { !promptingLibraryFolders.contains($0) }.map { h + "/Library/" + $0 }.filter { !claimed.contains($0) } + ["/Users/Shared"]
        return roots.mapValues { $0.filter { fm.fileExists(atPath: $0) } }
    }

    static let promptingLibraryFolders: Set<String> = [
        "Containers", "Group Containers", "Daemon Containers", "Mobile Documents", "CloudStorage",
        "Mail", "Messages", "Safari", "Calendars", "Reminders", "Photos", "Metadata", "HomeKit", "Suggestions",
        "IdentityServices", "Sharing", "Biome", "DuetExpertCenter", "PersonalizationPortrait", "Trial", "Assistant",
        "Accounts", "Application Scripts", "com.apple.aiml.instrumentation", "CoreFollowUp", "StatusKit", "IntelligencePlatform",
    ]

    static let libraryID = "library"
    /// Shared storage goes to the first category in this list that contains it.
    static let priority = ["apps", "developer", "photos", "movies", "music", "caches", "trash", "documents", libraryID]

    func scan(update: @escaping @Sendable (StorageScanUpdate) -> Void) async -> StorageScanResult {
        let roots = Self.roots()
        let totalRoots = max(1, roots.values.reduce(0) { $0 + $1.count })
        let done = Counter()

        var walked: [String: ([DirectoryWalker.Stats], [String])] = [:]
        await withTaskGroup(of: (String, [DirectoryWalker.Stats], [String]).self) { group in
            for (id, paths) in roots {
                group.addTask {
                    var all: [DirectoryWalker.Stats] = []
                    var base: Int64 = 0
                    for path in paths {
                        let stats = DirectoryWalker.walk(path, cancelled: { Task.isCancelled }) { bytes, current in
                            update(StorageScanUpdate(id: id, bytes: Double(base + bytes), path: Self.abbreviate(current), fraction: Double(done.value) / Double(totalRoots)))
                        }
                        base += stats.bytes + stats.shared.reduce(Int64(0)) { $0 + $1.own }
                        all.append(stats)
                        let finished = done.increment()
                        update(StorageScanUpdate(id: id, bytes: Double(base), path: Self.abbreviate(path), fraction: Double(finished) / Double(totalRoots)))
                    }
                    return (id, all, paths)
                }
            }
            for await (id, stats, paths) in group { walked[id] = (stats, paths) }
        }

        // Shared storage is handed out in a fixed order, so a game that is cloned into the home folder
        // counts under Apps every time rather than under whichever folder was reached first.
        var result = StorageScanResult()
        let deduper = ScanDeduper()
        for id in Self.priority {
            guard var (stats, paths) = walked[id] else { continue }
            for i in stats.indices { DirectoryWalker.resolve(&stats[i], with: deduper) }
            let bytes = stats.reduce(Int64(0)) { $0 + $1.bytes }
            if stats.contains(where: \.denied), id != Self.libraryID { result.denied = true }
            var children: [StorageChild] = []
            for (stat, path) in zip(stats, paths) {
                let prefix = id == Self.libraryID ? (path as NSString).lastPathComponent + "/" : ""
                children += stat.children.map { StorageChild(name: prefix + $0.name, path: path + "/" + $0.name, bytes: Double($0.bytes)) }
            }
            children.sort { $0.bytes > $1.bytes }
            if id == Self.libraryID {
                // Itemizes System data; its total stays "whatever is used and not in a category".
                result.children["system"] = Array(children.prefix(40))
                result.libraryBytes = Double(bytes)
                paths = []
                continue
            }
            result.bytes[id] = Double(bytes)
            // Caches and Trash keep everything (they can be cleared); the rest keep their largest items for the detail view.
            result.children[id] = (id == "caches" || id == "trash") ? children : Array(children.prefix(40))
            result.details[id] = Self.detail(for: id, stats: stats, children: children)
        }
        if let top = result.children["system"]?.first, top.bytes > 0 {
            result.details["system"] = "macOS and what apps keep in Library. \(top.name) is the largest at \(Self.gb(top.bytes))."
        } else {
            result.details["system"] = "macOS, app data and everything kept out of sight."
        }
        result.sharedBytesSkipped = Double(deduper.bytesSkipped)
        return result
    }

    private static func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1e9) }

    private static func detail(for id: String, stats: [DirectoryWalker.Stats], children: [StorageChild]) -> String {
        let largestChild = children.first
        let largestFile = stats.compactMap(\.largestFile).max { $0.bytes < $1.bytes }
        let files = stats.reduce(0) { $0 + $1.files }
        let number = NumberFormatter()
        number.numberStyle = .decimal
        func n(_ v: Int) -> String { number.string(from: NSNumber(value: v)) ?? "\(v)" }

        switch id {
        case "apps":
            let apps = children.filter { $0.name.hasSuffix(".app") }
            guard let top = children.first, !apps.isEmpty else { return "No apps found." }
            return "\(n(apps.count)) apps. \((top.name as NSString).deletingPathExtension) is the largest at \(gb(top.bytes))."
        case "developer":
            guard let top = largestChild, top.bytes > 0 else { return "Toolchains, packages and build data." }
            return "Toolchains, packages and build data. \(abbreviate(top.path)) is the largest at \(gb(top.bytes))."
        case "photos":
            let photos = stats.reduce(0) { $0 + $1.photos }, videos = stats.reduce(0) { $0 + $1.videos }
            if photos + videos == 0 { return stats.contains(where: \.denied) ? "The Photos library is private. Allow Full Disk Access to measure it." : "No photos kept on this device." }
            return "\(n(photos)) photos and \(n(videos)) videos, all kept on this device."
        case "movies":
            let videos = stats.reduce(0) { $0 + $1.videos }
            guard let file = largestFile else { return videos == 0 ? "No movies kept on this device." : "\(n(videos)) videos." }
            return "\(n(videos)) videos. \(file.name) is the largest at \(gb(Double(file.bytes)))."
        case "documents":
            guard let file = largestFile else { return "\(n(files)) files in your home folder." }
            return "Your largest file is \(file.name) at \(gb(Double(file.bytes)))."
        case "music":
            let songs = stats.reduce(0) { $0 + $1.songs }
            return songs == 0 ? "No music kept on this device." : "\(n(songs)) songs kept on this device."
        case "caches":
            return "Apps rebuild these when they need them again."
        case "trash":
            if stats.contains(where: \.denied) && children.isEmpty { return "The Trash is private. Allow Full Disk Access to measure it." }
            return children.isEmpty ? "The Trash is empty." : "\(n(children.count)) items you've already deleted, still taking space."
        default:
            return ""
        }
    }

    func clear(_ id: String, children: [StorageChild], update: @escaping @Sendable (String, Double) -> Void) async -> Double {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var freed = 0.0
            // Caches that belong to an app that is running right now are left alone.
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
            for child in children {
                if id == "caches" {
                    let key = child.name.lowercased()
                    if key == App.bundleID || running.contains(key) || running.contains(where: { key.hasPrefix($0 + ".") }) { continue }
                }
                update(Self.abbreviate(child.path), freed)
                do {
                    try fm.removeItem(atPath: child.path)
                    freed += child.bytes
                } catch {
                    continue
                }
                update(Self.abbreviate(child.path), freed)
            }
            return freed
        }.value
    }
}

extension DiskStorageBackend {
    func remove(_ item: StorageChild, permanently: Bool, progress: @escaping @Sendable (Double) -> Void) async -> RemovalFailure? {
        let path = (item.path as NSString).expandingTildeInPath
        // What ships with macOS sits on a sealed volume. Nothing can remove it, so say so instead of trying.
        // (Safari in Applications is a link into that volume, so follow links first.)
        if URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix("/System/") {
            return RemovalFailure(message: "\(item.name) is part of macOS and cannot be removed.", path: path)
        }
        do {
            if permanently {
                try await Task.detached(priority: .userInitiated) { try Self.deleteInPieces(path, progress: progress) }.value
            } else {
                _ = try await Self.moveToTrash(URL(fileURLWithPath: path))
            }
            progress(1)
            return nil
        } catch {
            return Self.failure(error, item: item, path: path)
        }
    }

    /// Moves something to the Trash, and says where it landed when that is known.
    ///
    /// The plain call works for anything the user owns. It is refused for an app that belongs to the system (one
    /// from the App Store or put there by an installer) and for anything locked, and then the Finder is asked to
    /// do it instead: see `FinderTrash`.
    static func moveToTrash(_ url: URL) async throws -> URL? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                var landed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                return landed as URL?
            }.value
        } catch let error as NSError where isPermission(error) {
            try await Task.detached(priority: .userInitiated) { try FinderTrash.moveToTrash(url) }.value
            return nil
        }
    }

    /// "You don't have permission", from either layer that says it.
    static func isPermission(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(underlying) }
        return false
    }

    private static func failure(_ error: Error, item: StorageChild, path: String) -> RemovalFailure {
        if let refusal = error as? FinderTrash.Refusal {
            switch refusal {
            case .notAllowed:
                return RemovalFailure(message: "\(App.name) has not been allowed to ask the Finder to move \(item.name) to the Trash.", fix: .finderAccess, path: path)
            case .cancelled:
                return RemovalFailure(message: "\(item.name) was left where it is: the request was cancelled.", path: path)
            case .failed(let code, let text):
                return RemovalFailure(message: "The Finder could not move \(item.name) to the Trash. " + (text ?? "It gave error \(code)."), path: path)
            }
        }
        let error = error as NSError
        let reason = error.localizedFailureReason ?? error.localizedDescription
        return RemovalFailure(message: "Couldn't remove \(item.name). \(reason)", path: path)
    }

    /// Deletes a folder a piece at a time so there is real progress to show, then the folder itself.
    /// Pieces are its entries, or their entries when it only has a handful.
    private static func deleteInPieces(_ path: String, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        let type = (try fm.attributesOfItem(atPath: path))[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            try fm.removeItem(atPath: path)
            return
        }
        func entries(_ directory: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).map { directory + "/" + $0 }
        }
        func isRealDirectory(_ p: String) -> Bool {
            ((try? fm.attributesOfItem(atPath: p))?[.type] as? FileAttributeType) == .typeDirectory
        }
        var pieces = entries(path)
        if pieces.count < 24 {
            // Too few steps to be informative: go one level deeper, and keep the parents to remove afterwards.
            pieces = pieces.flatMap { isRealDirectory($0) ? entries($0) : [$0] } + pieces
        }
        let total = Double(pieces.count + 1)
        for (index, piece) in pieces.enumerated() {
            try? fm.removeItem(atPath: piece)
            progress(Double(index + 1) / total)
        }
        // Anything that would not go makes this throw, with the reason.
        try fm.removeItem(atPath: path)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
