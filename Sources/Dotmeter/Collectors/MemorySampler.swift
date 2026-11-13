import Darwin
import Foundation

final class MemorySampler {
    let total: UInt64 = UInt64(Sysctl.int("hw.memsize") ?? 0)
    private let pageSize = UInt64(sysconf(_SC_PAGESIZE))
    /// The kernel's running totals of pages moved, as last read, to turn into rates.
    private var previous: (pageIn: UInt64, pageOut: UInt64, swapIn: UInt64, swapOut: UInt64, compress: UInt64, decompress: UInt64)?
    private var previousTime: UInt64 = 0
    private var activity = MemoryActivity()

    func sample() -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .empty(total: total) }

        let p = pageSize
        let wired = UInt64(stats.wire_count) * p
        let compressed = UInt64(stats.compressor_page_count) * p
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * p
        let cached = (UInt64(stats.external_page_count) + purgeable) * p

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        let pressure: MemoryPressure = level >= 4 ? .critical : (level >= 2 ? .warning : .normal)

        // The same structure carries the totals of pages moved since the Mac started; the difference since the
        // last reading is what is happening now. Readings a moment apart keep the last figures.
        let counters = (UInt64(stats.pageins), UInt64(stats.pageouts), UInt64(stats.swapins), UInt64(stats.swapouts), UInt64(stats.compressions), UInt64(stats.decompressions))
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = previousTime > 0 ? Double(now &- previousTime) / 1e9 : 0
        if let before = previous, seconds >= 0.5 {
            func rate(_ new: UInt64, _ old: UInt64) -> Double { new >= old ? Double((new - old) * p) / seconds : 0 }
            activity = MemoryActivity(
                pageIn: rate(counters.0, before.pageIn), pageOut: rate(counters.1, before.pageOut),
                swapIn: rate(counters.2, before.swapIn), swapOut: rate(counters.3, before.swapOut),
                compress: rate(counters.4, before.compress), decompress: rate(counters.5, before.decompress)
            )
        }
        if previous == nil || seconds >= 0.5 {
            previous = counters
            previousTime = now
        }

        return MemoryStats(
            total: total,
            used: app + wired + compressed,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: pressure,
            activity: activity
        )
    }
}
