import Darwin
import Foundation

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Converts mach absolute time to nanoseconds (identity on Intel, 125/3 on Apple silicon).
struct MachTime {
    static let shared = MachTime()
    private let numer: UInt64
    private let denom: UInt64

    private init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = UInt64(max(info.denom, 1))
    }

    func nanoseconds(_ absolute: UInt64) -> UInt64 {
        numer == denom ? absolute : absolute * numer / denom
    }

    /// A length of time in the clock's own ticks.
    func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9) * denom / numer
    }
}
