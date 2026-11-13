import Foundation

enum Format {
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// 0...1 → "42%"
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Process CPU where 1.0 is one core → "182%" or "3.4%"
    static func cpu(_ cores: Double) -> String {
        let value = cores * 100
        if value < 10 { return String(format: "%.1f%%", value) }
        return "\(Int(value.rounded()))%"
    }

    /// Binary units, like Activity Monitor: "12.4 GB", "512 MB"
    static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 {
            let gb = value / 1_073_741_824
            return gb >= 100 || gb == gb.rounded() ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
        }
        if value >= 1_048_576 { return "\(Int((value / 1_048_576).rounded())) MB" }
        if value >= 1024 { return "\(Int((value / 1024).rounded())) KB" }
        return "\(bytes) B"
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    /// Decimal units for throughput: "1.2 GB/s", "12.4 MB/s", "380 KB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 999.5e6 { return String(format: "%.2f GB/s", bytesPerSecond / 1e9) }
        if bytesPerSecond >= 99.95e6 { return "\(Int((bytesPerSecond / 1e6).rounded())) MB/s" }
        if bytesPerSecond >= 0.9995e6 { return String(format: "%.1f MB/s", bytesPerSecond / 1e6) }
        if bytesPerSecond >= 1e3 { return "\(Int((bytesPerSecond / 1e3).rounded())) KB/s" }
        return "0 KB/s"
    }

    /// The same with fewer digits, for narrow places such as the menu bar: "12 MB/s" rather than "12.4 MB/s"
    static func shortRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 999.5e6 { return String(format: "%.1f GB/s", bytesPerSecond / 1e9) }
        if bytesPerSecond >= 9.95e6 { return "\(Int((bytesPerSecond / 1e6).rounded())) MB/s" }
        if bytesPerSecond >= 0.9995e6 { return String(format: "%.1f MB/s", bytesPerSecond / 1e6) }
        if bytesPerSecond >= 1e3 { return "\(Int((bytesPerSecond / 1e3).rounded())) KB/s" }
        return "0 KB/s"
    }

    /// Decimal units for an amount of data that went over a link: "14.2 GB", "380 MB"
    static func data(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 999.5e9 { return String(format: "%.2f TB", value / 1e12) }
        if value >= 99.95e9 { return "\(Int((value / 1e9).rounded())) GB" }
        if value >= 0.9995e9 { return String(format: "%.1f GB", value / 1e9) }
        if value >= 1e6 { return "\(Int((value / 1e6).rounded())) MB" }
        if value >= 1e3 { return "\(Int((value / 1e3).rounded())) KB" }
        return bytes == 0 ? "0 KB" : "1 KB"
    }

    /// Money, always with the dollar sign: "$0.17", "$12.48", "$1,248". Anything under a cent says so.
    static func dollars(_ value: Double) -> String {
        if value > 0, value < 0.005 { return "under $0.01" }
        if value < 99.995 { return String(format: "$%.2f", value) }
        return "$" + (grouping.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))")
    }

    /// A price per unit, to the third decimal when it has one: "$0.16", "$0.165".
    static func price(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        if text.hasSuffix("0") { text.removeLast() }
        return "$" + text
    }

    /// Link speeds are quoted in bits: "10 Gb/s", "2.4 Gb/s", "866 Mb/s"
    static func linkSpeed(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 0.9995e9 {
            let value = bitsPerSecond / 1e9
            return abs(value - value.rounded()) < 0.05 ? "\(Int(value.rounded())) Gb/s" : String(format: "%.1f Gb/s", value)
        }
        if bitsPerSecond >= 1e6 { return "\(Int((bitsPerSecond / 1e6).rounded())) Mb/s" }
        return "\(Int((bitsPerSecond / 1e3).rounded())) Kb/s"
    }

    /// Refresh rates: "60 Hz", "59.9 Hz"
    static func hertz(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.06 ? "\(Int(value.rounded())) Hz" : String(format: "%.1f Hz", value)
    }

    /// Current and voltage as they are printed on chargers and cables: "3 A", "2.25 A", "20 V", "5.2 V"
    static func amps(_ milliamps: Int) -> String { String(format: "%g A", (Double(milliamps) / 10).rounded() / 100) }
    static func volts(_ millivolts: Int) -> String { String(format: "%g V", (Double(millivolts) / 100).rounded() / 10) }

    static func count(_ value: UInt64) -> String {
        grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func rpm(_ value: Double) -> String {
        grouping.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }

    static func temperature(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// Wording for the figures that several pages and panels show the same way.
enum Detail {
    /// "P 12% · E 3%": the two kinds of core, each averaged.
    static func clusters(_ cpu: CPUStats) -> String? {
        guard cpu.efficiencyCores > 0, cpu.perCore.count > cpu.efficiencyCores else { return nil }
        let efficiency = cpu.perCore.prefix(cpu.efficiencyCores), performance = cpu.perCore.dropFirst(cpu.efficiencyCores)
        func average(_ values: ArraySlice<Double>) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        return "P \(Format.percent(average(performance))) · E \(Format.percent(average(efficiency)))"
    }

    /// "1,476 processes"
    static func count(_ value: Int, _ noun: String) -> String {
        "\(grouped.string(from: NSNumber(value: value)) ?? String(value)) \(noun)"
    }

    /// Made once: a formatter costs far more to build than to use, and these run on every reading.
    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// "1.2 GB of 2 GB", or "None" when nothing is in swap.
    static func swap(_ memory: MemoryStats) -> String {
        guard memory.swapUsed > 0 else { return "None" }
        return memory.swapTotal > memory.swapUsed ? "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))" : Format.bytes(memory.swapUsed)
    }

    /// What the memory system is doing this moment, most telling first, or nil when it is at rest.
    static func memoryActivity(_ activity: MemoryActivity) -> String? {
        var parts: [String] = []
        if activity.swapOut > 4096 { parts.append("swapping out \(Format.rate(activity.swapOut))") }
        if activity.swapIn > 4096 { parts.append("swapping in \(Format.rate(activity.swapIn))") }
        if activity.compress > 4096 { parts.append("compressing \(Format.rate(activity.compress))") }
        if activity.decompress > 4096 { parts.append("decompressing \(Format.rate(activity.decompress))") }
        return parts.isEmpty ? nil : parts.prefix(2).joined(separator: ", ")
    }

    /// "in 1.2 MB/s · out 0 KB/s": pages read from files and written back to them.
    static func paging(_ activity: MemoryActivity) -> String {
        "in \(Format.rate(activity.pageIn)) · out \(Format.rate(activity.pageOut))"
    }

    /// "1,240 a second" for requests, and how long each took: "0.12 ms each".
    static func requests(_ disk: DiskStats) -> String {
        let total = disk.readOps + disk.writeOps
        return total < 0.5 ? "None right now" : "\(count(Int(total.rounded()), "a second"))"
    }

    static func requestTime(_ disk: DiskStats) -> String? {
        let times = [disk.readLatency, disk.writeLatency].compactMap { $0 }
        guard let slowest = times.max() else { return nil }
        let ms = slowest * 1000
        return ms < 10 ? String(format: "%.2f ms each", ms) : String(format: "%.0f ms each", ms)
    }

    /// "no errors" or "3 errors, 12 retries" since the Mac started.
    static func diskErrors(_ disk: DiskStats) -> String {
        if disk.errors == 0, disk.retries == 0 { return "no errors" }
        var parts: [String] = []
        if disk.errors > 0 { parts.append(count(Int(disk.errors), disk.errors == 1 ? "error" : "errors")) }
        if disk.retries > 0 { parts.append(count(Int(disk.retries), disk.retries == 1 ? "retry" : "retries")) }
        return parts.joined(separator: ", ")
    }

    /// The hottest storage or memory sensor, where the Mac has one.
    static func temperature(of group: String, in thermal: ThermalStats) -> Double? {
        thermal.sensors.filter { $0.group == group }.map(\.celsius).max()
    }

    /// "router 2 ms · internet 14 ms"
    static func latency(_ targets: [LatencyTarget]) -> String? {
        let parts = targets.compactMap { target in target.last.map { "\(target.title.lowercased()) \(LatencyScale.text($0))" } }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func loss(_ targets: [LatencyTarget]) -> String {
        let worst = targets.map(\.loss).max() ?? 0
        return worst <= 0 ? "none lost" : "\(Format.percent(worst)) lost"
    }

    /// "Ran hot twice, 38 min" for today, or that it has not.
    static func hotToday(_ day: TimelineStore.DaySoFar) -> String {
        guard day.hotEvents > 0 else { return "Has not run hot" }
        let times = day.hotEvents == 1 ? "once" : (day.hotEvents == 2 ? "twice" : "\(day.hotEvents) times")
        return "Ran hot \(times), \(Format.duration(day.hotSeconds))"
    }
}
