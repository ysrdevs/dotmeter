import Foundation

/// Made-up apps (`DOTMETER_APPS_DEMO=1`), for screenshots and design review: the readings stay this Mac's own
/// (load, memory, heat, power), and only who is using them is replaced, by apps every Mac has, in shares that
/// add up to the real totals. Nothing about what is actually running appears.
enum AppsDemo {
    static let on = ProcessInfo.processInfo.environment["DOTMETER_APPS_DEMO"] == "1"

    private struct Cast {
        var name: String
        var path: String?
        /// Shares of the Mac's busy cores, of its app memory, of its graphics load and of its power.
        var cpu: Double
        var memory: Double
        var gpu: Double
        var power: Double
        /// Bytes a second read and written.
        var read: Double = 0
        var write: Double = 0
        var helpers: [String] = []
    }

    private static let cast: [Cast] = [
        Cast(name: "Xcode", path: "/Applications/Xcode.app", cpu: 0.27, memory: 0.21, gpu: 0.04, power: 0.24, read: 2.4e6, write: 5.1e6, helpers: ["swift-frontend", "SourceKitService", "XCBBuildService"]),
        Cast(name: "Safari", path: "/Applications/Safari.app", cpu: 0.13, memory: 0.19, gpu: 0.17, power: 0.12, read: 3.0e5, write: 1.1e5, helpers: ["Safari Web Content", "Safari Networking", "Safari Graphics and Media"]),
        Cast(name: "Photos", path: "/System/Applications/Photos.app", cpu: 0.11, memory: 0.10, gpu: 0.12, power: 0.10, read: 9.6e5, write: 2.0e5, helpers: ["photoanalysisd", "photolibraryd"]),
        Cast(name: "WindowServer", path: nil, cpu: 0.08, memory: 0.04, gpu: 0.38, power: 0.07),
        Cast(name: "FaceTime", path: "/System/Applications/FaceTime.app", cpu: 0.06, memory: 0.03, gpu: 0.09, power: 0.06, helpers: ["avconferenced"]),
        Cast(name: "Music", path: "/System/Applications/Music.app", cpu: 0.035, memory: 0.04, gpu: 0.02, power: 0.03, read: 1.6e5),
        Cast(name: "Spotlight", path: nil, cpu: 0.03, memory: 0.02, gpu: 0, power: 0.03, read: 4.2e5, write: 6.0e4, helpers: ["mds_stores", "mdworker_shared"]),
        Cast(name: "Mail", path: "/System/Applications/Mail.app", cpu: 0.022, memory: 0.05, gpu: 0.01, power: 0.02, write: 4.0e4),
        Cast(name: "Messages", path: "/System/Applications/Messages.app", cpu: 0.014, memory: 0.03, gpu: 0.01, power: 0.012),
        Cast(name: "Time Machine", path: nil, cpu: 0.012, memory: 0.01, gpu: 0, power: 0.012, read: 1.8e6, write: 2.6e6, helpers: ["backupd"]),
        Cast(name: "Dotmeter", path: Bundle.main.bundlePath, cpu: 0.012, memory: 0.004, gpu: 0.02, power: 0.01),
        Cast(name: "Notes", path: "/System/Applications/Notes.app", cpu: 0.008, memory: 0.02, gpu: 0.005, power: 0.007),
        Cast(name: "Maps", path: "/System/Applications/Maps.app", cpu: 0.007, memory: 0.03, gpu: 0.02, power: 0.006),
        Cast(name: "Calendar", path: "/System/Applications/Calendar.app", cpu: 0.004, memory: 0.012, gpu: 0, power: 0.004),
        Cast(name: "Preview", path: "/System/Applications/Preview.app", cpu: 0.003, memory: 0.015, gpu: 0.004, power: 0.003),
        Cast(name: "cloudd", path: nil, cpu: 0.006, memory: 0.006, gpu: 0, power: 0.005, write: 9.0e4),
        Cast(name: "App Store", path: "/System/Applications/App Store.app", cpu: 0.005, memory: 0.01, gpu: 0.004, power: 0.004, read: 2.0e5, write: 7.5e5),
        Cast(name: "Freeform", path: "/System/Applications/Freeform.app", cpu: 0.002, memory: 0.02, gpu: 0.006, power: 0.002),
    ]

    /// The same reading with the made-up cast in place of the real apps and processes.
    static func apply(_ snapshot: Snapshot) -> Snapshot {
        var s = snapshot
        let time = s.timestamp.timeIntervalSinceReferenceDate
        // With the display asleep the graphics cores read idle, which makes an empty picture: give them
        // something to do.
        if var gpu = s.gpu, gpu.utilization < 0.08 {
            gpu.utilization = 0.27 + 0.05 * sin(time / 9)
            gpu.rendererUtilization = gpu.utilization * 0.94
            gpu.tilerUtilization = gpu.utilization * 0.88
            s.gpu = gpu
        }
        let cores = Double(max(s.cpu.perCore.count, 1))
        let busy = s.cpu.total * cores
        let appMemory = Double(s.memory.app)
        let graphics = s.gpu?.utilization ?? 0
        let watts = (s.power.total ?? 40) * 0.55
        var apps: [AppUsage] = []
        var processes: [ProcessUsage] = []
        for (index, member) in cast.enumerated() {
            // A slow wobble of its own, so the figures move the way real ones do.
            let wobble = 0.86 + 0.14 * sin(time / (7 + Double(index) * 1.3) + Double(index))
            let pid = Int32(410 + index * 53)
            let names = [member.name] + member.helpers
            let children: [ProcessUsage] = names.enumerated().map { offset, name in
                // The first helper does most of the work, as with a real app's renderer or compiler.
                let part = names.count == 1 ? 1.0 : (offset == 0 ? 0.3 : (offset == 1 ? 0.5 : 0.2 / Double(max(names.count - 2, 1))))
                return ProcessUsage(
                    pid: pid + Int32(offset), ppid: offset == 0 ? 1 : pid, name: name, path: nil,
                    cpu: busy * member.cpu * wobble * part, memory: UInt64(appMemory * member.memory * part),
                    parentName: offset == 0 ? nil : member.name, diskRead: member.read * part * wobble, diskWrite: member.write * part * wobble,
                    power: watts * member.power * wobble * part, gpu: graphics * member.gpu * wobble * part
                )
            }.sorted { $0.cpu > $1.cpu }
            apps.append(AppUsage(
                id: member.path ?? "proc:" + member.name, name: member.name, bundlePath: member.path, pid: pid,
                cpu: busy * member.cpu * wobble, memory: UInt64(appMemory * member.memory), processCount: children.count, children: children,
                diskRead: member.read * wobble, diskWrite: member.write * wobble, power: watts * member.power * wobble, gpu: graphics * member.gpu * wobble
            ))
            processes.append(contentsOf: children)
        }
        s.apps = apps.sorted { $0.cpu > $1.cpu }
        s.processes = processes.sorted { $0.cpu > $1.cpu }
        return s
    }
}
