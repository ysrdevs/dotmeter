import Darwin
import Foundation

final class CPUSampler {
    private var previousTicks: [UInt32] = []
    let performanceCores: Int
    let efficiencyCores: Int

    init() {
        performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
    }

    func sample() -> CPUStats {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else {
            return CPUStats(total: 0, user: 0, system: 0, perCore: [], performanceCores: performanceCores, efficiencyCores: efficiencyCores, loadAverage: load)
        }

        let states = 4 // user, system, idle, nice
        let count = Int(cpuCount)
        var ticks = [UInt32](repeating: 0, count: count * states)
        for i in 0..<(count * states) { ticks[i] = UInt32(bitPattern: info[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))

        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else {
            return CPUStats(total: 0, user: 0, system: 0, perCore: Array(repeating: 0, count: count), performanceCores: performanceCores, efficiencyCores: efficiencyCores, loadAverage: load)
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(count)
        var userSum = 0.0, systemSum = 0.0, totalSum = 0.0
        for core in 0..<count {
            let b = core * states
            let user = Double(ticks[b] &- previousTicks[b])
            let system = Double(ticks[b + 1] &- previousTicks[b + 1])
            let idle = Double(ticks[b + 2] &- previousTicks[b + 2])
            let nice = Double(ticks[b + 3] &- previousTicks[b + 3])
            let total = user + system + idle + nice
            perCore.append(total > 0 ? (user + system + nice) / total : 0)
            userSum += user + nice
            systemSum += system
            totalSum += total
        }
        return CPUStats(
            total: totalSum > 0 ? (userSum + systemSum) / totalSum : 0,
            user: totalSum > 0 ? userSum / totalSum : 0,
            system: totalSum > 0 ? systemSum / totalSum : 0,
            perCore: perCore,
            performanceCores: performanceCores,
            efficiencyCores: efficiencyCores,
            loadAverage: load
        )
    }
}
