import Foundation

struct StorageCategoryInfo: Identifiable {
    let id: String
    let name: String
    let symbols: [String]
    let rgb: RGB

    /// The reference's nine categories, in bar order.
    static let all: [StorageCategoryInfo] = [
        .init(id: "apps", name: "Apps", symbols: ["cursorarrow.square.fill", "macwindow"], rgb: PX.blue),
        .init(id: "developer", name: "Developer", symbols: ["archivebox.fill", "shippingbox.fill"], rgb: PX.greenRGB),
        .init(id: "photos", name: "Photos", symbols: ["mountain.2.fill", "photo.fill"], rgb: PX.pink),
        .init(id: "movies", name: "Movies", symbols: ["film.fill"], rgb: PX.purple),
        .init(id: "documents", name: "Documents", symbols: ["doc.text.fill"], rgb: PX.cyan),
        .init(id: "music", name: "Music", symbols: ["music.quarternote.3", "music.note"], rgb: PX.yellow),
        .init(id: "system", name: "System data", symbols: ["gear", "gearshape.fill"], rgb: PX.gray),
        .init(id: "caches", name: "Caches", symbols: ["square.stack.3d.up.fill"], rgb: PX.orange),
        .init(id: "trash", name: "Trash", symbols: ["trash.fill"], rgb: PX.red),
    ]

    static func info(_ id: String) -> StorageCategoryInfo { all.first { $0.id == id } ?? all[0] }
}

struct StorageChild: Codable, Sendable {
    var name: String
    var path: String
    var bytes: Double
}

struct StorageScanUpdate: Sendable {
    var id: String
    var bytes: Double
    var path: String
    /// Overall progress 0...1 across every folder being measured.
    var fraction: Double
}

struct StorageScanResult: Sendable {
    var bytes: [String: Double] = [:]
    var details: [String: String] = [:]
    var children: [String: [StorageChild]] = [:]
    var denied = false
    /// Storage that several files share (hard links and clones), counted once instead of once per file.
    var sharedBytesSkipped = 0.0
    /// The part of System data that was found in Library folders.
    var libraryBytes = 0.0
}

struct StorageVolume: Sendable {
    var capacity: Double
    /// Space that is empty right now.
    var free: Double
    /// Space macOS can reclaim on demand, on top of `free`.
    var purgeable: Double
    var name: String
    var format: String
}

/// Why a removal did not happen, and whether there is something the user can do about it.
struct RemovalFailure: Sendable, Equatable {
    enum Fix: Sendable, Equatable {
        /// The item needs the Finder to move it, and the user has not allowed Dotmeter to ask the Finder.
        case finderAccess
    }

    var message: String
    var fix: Fix?
    /// The item, for pointing the Finder at it.
    var path: String?
}

protocol StorageBackend: Sendable {
    var isDemo: Bool { get }
    func volume() -> StorageVolume
    func scan(update: @escaping @Sendable (StorageScanUpdate) -> Void) async -> StorageScanResult
    /// Deletes the given items and returns the bytes actually freed.
    func clear(_ id: String, children: [StorageChild], update: @escaping @Sendable (_ path: String, _ freed: Double) -> Void) async -> Double
    /// Removes one item, either for good or by moving it to the Trash. `progress` is called with 0...1 as it goes.
    /// Returns nil on success, or why not.
    func remove(_ item: StorageChild, permanently: Bool, progress: @escaping @Sendable (Double) -> Void) async -> RemovalFailure?
}

/// Latest-value mailbox between scanner threads and the main actor, so the UI updates at its own pace.
final class ProgressBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: Value] = [:]

    func push(_ key: String, _ value: Value) {
        lock.lock(); pending[key] = value; lock.unlock()
    }

    func drain() -> [String: Value] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }
}

/// The reference recording's dataset, replayed with its timing. Touches nothing on disk.
struct DemoStorageBackend: StorageBackend {
    var isDemo: Bool { true }

    static let final: [String: Double] = [
        "apps": 52.6e9, "developer": 36.3e9, "photos": 58.6e9, "movies": 44.1e9, "documents": 41.7e9,
        "music": 12.1e9, "system": 34.2e9, "caches": 46.8e9, "trash": 31.4e9,
    ]

    static let details: [String: String] = [
        "apps": "142 apps. Penrose Studio is the largest at 12.4 GB.",
        "developer": "Toolchains and build data. DerivedData is the largest at 11.8 GB.",
        "photos": "14,870 photos and 402 videos, all kept on this device.",
        "movies": "Screen recordings take 24.6 GB, most from this autumn.",
        "documents": "Your largest file is Northwind lookbook.psd at 3.8 GB.",
        "music": "1,204 songs downloaded for offline listening.",
        "system": "macOS, snapshots and everything apps keep out of sight.",
        "caches": "Apps rebuild these when they need them again.",
        "trash": "Things you've already deleted, still taking space.",
    ]

    /// Largest items per category, for the storage page.
    static let children: [String: [StorageChild]] = {
        func items(_ base: String, _ list: [(String, Double)]) -> [StorageChild] {
            list.map { StorageChild(name: $0.0, path: base + "/" + $0.0, bytes: $0.1 * 1e9) }
        }
        return [
            "apps": items("/Applications", [("Penrose Studio.app", 12.4), ("Xcode.app", 11.8), ("Northwind Mail.app", 6.2), ("Halftone.app", 4.9), ("Atlas.app", 3.7), ("Sundial.app", 2.8), ("Keynote.app", 1.9), ("Pages.app", 1.4)]),
            "developer": items("~/Library/Developer", [("Xcode/DerivedData", 11.8), ("CoreSimulator", 9.6), ("Xcode/iOS DeviceSupport", 6.1), ("Toolchains", 4.4), ("Xcode/Archives", 2.7)]),
            "photos": items("~/Pictures", [("Photos Library.photoslibrary", 54.2), ("Lightroom", 2.9), ("Screenshots", 1.5)]),
            "movies": items("~/Movies", [("Screen recordings", 24.6), ("Final Cut Projects", 12.3), ("Exports", 5.8), ("TV", 1.4)]),
            "documents": items("~", [("Documents", 18.9), ("Downloads", 11.2), ("Code", 7.4), ("Desktop", 4.2)]),
            "music": items("~/Music", [("Music/Media", 10.7), ("GarageBand", 1.4)]),
            "caches": items("~/Library/Caches", [("pnpm", 18.4), ("com.penrose.studio", 12.6), ("Northwind Mail", 8.1), ("Halftone", 6.5), ("com.dotmeter.demo", 1.2)]),
            "trash": items("~/.Trash", [("Old exports", 19.6), ("Screen recording 2026-08-14.mov", 7.9), ("atlas-backup.zip", 3.9)]),
            "system": items("~/Library", [("Application Support/Penrose", 9.8), ("Containers/Northwind Mail", 6.4), ("Application Support/Halftone", 4.1), ("Group Containers/Atlas", 2.2)]),
        ]
    }()

    func volume() -> StorageVolume { StorageVolume(capacity: 512e9, free: 154.2e9, purgeable: 0, name: "Macintosh HD", format: "APFS") }

    func scan(update: @escaping @Sendable (StorageScanUpdate) -> Void) async -> StorageScanResult {
        let paths = [
            "~/Applications/Chrome Apps", "/Applications/Penrose Studio.app", "~/Code/sundial/.next/cache",
            "~/Pictures/Photos Library/resources", "~/Movies/Screen recordings", "/System/Volumes/Data/.snapshots",
            "~/Library/Caches/pnpm", "~/.Trash/Old exports", "~/Library/Logs",
        ]
        // Each category starts a little after the previous one and they overlap, as in the recording.
        let order = ["apps", "developer", "photos", "movies", "documents", "music", "caches", "trash"]
        let duration = 3.9
        let steps = Int(duration / 0.05)
        for step in 0...steps {
            let p = Double(step) / Double(steps)
            for (i, id) in order.enumerated() {
                let start = Double(i) * 0.085
                let local = min(max((p - start) / (1 - start) * 1.18, 0), 1)
                let eased = local * local * (3 - 2 * local)
                update(StorageScanUpdate(id: id, bytes: (Self.final[id] ?? 0) * eased, path: paths[min(Int(p * Double(paths.count)), paths.count - 1)], fraction: p))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        var result = StorageScanResult()
        result.bytes = Self.final
        result.details = Self.details
        result.children = Self.children
        return result
    }

    func remove(_ item: StorageChild, permanently: Bool, progress: @escaping @Sendable (Double) -> Void) async -> RemovalFailure? {
        // Bigger items take longer, as they would for real.
        let steps = permanently ? Int(min(70, max(22, item.bytes / 1e9 * 3.2))) : 10
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(50))
            let t = Double(step) / Double(steps)
            progress(permanently ? 1 - pow(1 - t, 1.5) : t)
        }
        return nil
    }

    func clear(_ id: String, children: [StorageChild], update: @escaping @Sendable (String, Double) -> Void) async -> Double {
        let paths = id == "caches"
            ? ["~/Library/Caches/Northwind Mail", "~/Library/Caches/pnpm", "~/Library/Caches/com.penrose.studio", "~/Library/Caches/pnpm", "~/Library/Caches/Halftone/previews"]
            : ["~/.Trash/Old exports", "~/.Trash/Screen recording 2026-08-14.mov", "~/.Trash/atlas-backup.zip"]
        let total = id == "caches" ? 45.6e9 : 31.4e9
        let duration = id == "caches" ? 2.7 : 2.2
        let steps = Int(duration / 0.05)
        for step in 0...steps {
            let p = Double(step) / Double(steps)
            let eased = 1 - pow(1 - p, 1.6)
            update(paths[min(Int(p * Double(paths.count)), paths.count - 1)], total * eased)
            try? await Task.sleep(for: .milliseconds(50))
        }
        return total
    }
}
