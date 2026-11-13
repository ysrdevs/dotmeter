import CDotmeter
import Darwin
import Foundation

/// Per-process CPU and memory via libproc, grouped into apps by bundle so "Chrome" is one row, not thirty.
final class ProcessSampler {
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousWall: UInt64 = 0
    private var bundleNames: [String: String] = [:]
    /// What a process is. It only changes when the process replaces itself with another program, which shows
    /// as a new short name, so the path, the name and the app it belongs to are worked out once and kept.
    private struct Identity {
        var comm: String
        var path: String?
        var name: String
        /// The app bundle it runs from, if any.
        var bundle: String?
        /// What its rows are grouped under: the bundle, or its own name.
        var key: String
    }

    private var identities: [pid_t: Identity] = [:]
    private var lastCPU: [pid_t: Double] = [:]

    /// Running totals the kernel keeps per process, and the rates worked out from them last time.
    private struct Counters {
        var read: UInt64
        var written: UInt64
        var energy: UInt64
    }

    private struct Rates {
        var read = 0.0
        var write = 0.0
        var power = 0.0
    }

    private var previousCounters: [pid_t: Counters] = [:]
    private var lastRates: [pid_t: Rates] = [:]
    /// Below this wall-clock gap a single burst of work reads as a huge percentage, so we reuse the last figures.
    private let minimumInterval: Double = 0.75e9

    /// `gpu` is each process's share of the graphics cores, from the graphics sampler.
    func sample(gpu: [Int32: Double] = [:]) -> (apps: [AppUsage], processes: [ProcessUsage]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let wallDelta = previousWall > 0 ? Double(now &- previousWall) : 0
        let tooSoon = wallDelta > 0 && wallDelta < minimumInterval

        var pids = [pid_t](repeating: 0, count: 4096)
        var count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        if count >= pids.count - 64 {
            pids = [pid_t](repeating: 0, count: count + 1024)
            count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        }

        var nextCPUTime: [pid_t: UInt64] = [:]
        nextCPUTime.reserveCapacity(count)
        var nextCounters: [pid_t: Counters] = [:]
        nextCounters.reserveCapacity(count)
        var nextRates: [pid_t: Rates] = [:]
        let seconds = wallDelta / 1e9
        var processes: [ProcessUsage] = []
        processes.reserveCapacity(count)
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var owners: [Identity] = []
        owners.reserveCapacity(count)

        for i in 0..<count {
            let pid = pids[i]
            var cpuNanos: UInt64 = 0
            var footprint: UInt64 = 0

            var usage = dotmeter_proc_usage_t()
            var rates = Rates()
            if dotmeter_proc_usage(pid, &usage) == 0 {
                cpuNanos = MachTime.shared.nanoseconds(usage.cpu_time)
                footprint = usage.footprint
                let counters = Counters(read: usage.disk_read, written: usage.disk_written, energy: usage.energy_nj)
                nextCounters[pid] = counters
                if tooSoon {
                    rates = lastRates[pid] ?? Rates()
                } else if let before = previousCounters[pid], seconds > 0 {
                    if counters.read >= before.read { rates.read = Double(counters.read - before.read) / seconds }
                    if counters.written >= before.written { rates.write = Double(counters.written - before.written) / seconds }
                    if usage.has_energy != 0, counters.energy >= before.energy { rates.power = Double(counters.energy - before.energy) / 1e9 / seconds }
                }
                nextRates[pid] = rates
            } else {
                var task = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
                cpuNanos = MachTime.shared.nanoseconds(task.pti_total_user &+ task.pti_total_system)
                footprint = task.pti_resident_size
            }
            nextCPUTime[pid] = cpuNanos

            var cpu = 0.0
            if tooSoon {
                cpu = lastCPU[pid] ?? 0
            } else if let previous = previousCPUTime[pid], wallDelta > 0, cpuNanos >= previous {
                cpu = Double(cpuNanos - previous) / wallDelta
            }

            var ppid: pid_t = 0
            var comm = ""
            var bsd = proc_bsdshortinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsdSize) == bsdSize {
                ppid = pid_t(bsd.pbsi_ppid)
                comm = withUnsafePointer(to: &bsd.pbsi_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
                }
            }

            let identity: Identity
            if let known = identities[pid], known.comm == comm {
                identity = known
            } else {
                var path: String?
                if pid != 0, proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                    path = String(cString: pathBuffer)
                }
                let name: String
                if pid == 0 { name = "kernel_task" }
                else if let path { name = (path as NSString).lastPathComponent }
                else { name = comm.isEmpty ? "pid \(pid)" : comm }
                let bundle = path.flatMap(Self.bundlePath(for:))
                identity = Identity(comm: comm, path: path, name: name, bundle: bundle, key: bundle ?? "proc:" + name)
                identities[pid] = identity
            }
            owners.append(identity)

            processes.append(ProcessUsage(pid: pid, ppid: ppid, name: identity.name, path: identity.path, cpu: cpu, memory: footprint, parentName: nil, diskRead: rates.read, diskWrite: rates.write, power: rates.power, gpu: gpu[pid] ?? 0))
        }

        if !tooSoon {
            previousCPUTime = nextCPUTime
            previousCounters = nextCounters
            lastRates = nextRates
            previousWall = now
            lastCPU = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.cpu) })
        }
        if identities.count > nextCPUTime.count * 2 { identities = identities.filter { nextCPUTime[$0.key] != nil } }

        var namesByPid: [pid_t: String] = [:]
        for p in processes { namesByPid[p.pid] = p.name }
        for i in processes.indices { processes[i].parentName = namesByPid[processes[i].ppid] }

        return (group(processes, owners: owners), processes)
    }

    /// Outermost ".app" bundle containing `path`, if any.
    static func bundlePath(for path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    func bundleName(_ bundlePath: String) -> String {
        if let cached = bundleNames[bundlePath] { return cached }
        var name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        if let bundle = Bundle(path: bundlePath) {
            let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let short = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let candidate = [display, short].compactMap({ $0 }).first(where: { !$0.isEmpty }) { name = candidate }
        }
        bundleNames[bundlePath] = name
        return name
    }

    /// Groups are built in place. Taking one out of a dictionary, adding a process and putting it back copied
    /// its whole list of processes every time, which for an app with two hundred of them was most of the work.
    private func group(_ processes: [ProcessUsage], owners: [Identity]) -> [AppUsage] {
        var index: [String: Int] = [:]
        var groups: [AppUsage] = []
        for (i, p) in processes.enumerated() {
            let owner = owners[i]
            if let at = index[owner.key] {
                groups[at].cpu += p.cpu
                groups[at].memory += p.memory
                groups[at].diskRead += p.diskRead
                groups[at].diskWrite += p.diskWrite
                groups[at].power += p.power
                groups[at].gpu += p.gpu
                groups[at].processCount += 1
                groups[at].children.append(p)
                if p.pid < groups[at].pid { groups[at].pid = p.pid }
            } else {
                index[owner.key] = groups.count
                let name = owner.bundle.map(bundleName) ?? p.name
                groups.append(AppUsage(id: owner.key, name: name, bundlePath: owner.bundle, pid: p.pid, cpu: p.cpu, memory: p.memory, processCount: 1, children: [p], diskRead: p.diskRead, diskWrite: p.diskWrite, power: p.power, gpu: p.gpu))
            }
        }
        for i in groups.indices { groups[i].children.sort { $0.cpu > $1.cpu } }
        groups.sort { $0.cpu > $1.cpu }
        return groups
    }
}
