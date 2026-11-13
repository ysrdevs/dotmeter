import Darwin
import Foundation
import IOKit

final class GPUSampler {
    private var previousTimes: [Int32: UInt64] = [:]
    private var previousWall: UInt64 = 0
    private var shares: [Int32: Double] = [:]
    private var model: String?
    private var cores: Int?

    /// Load and memory from the accelerator's own statistics. With `apps`, also each process's share of the
    /// graphics cores: every client of the accelerator carries the GPU time it has used so far and the pid
    /// that opened it, so a share is the time added since the last reading over the time that passed.
    func sample(apps wantApps: Bool = false) -> (stats: GPUStats?, shares: [Int32: Double]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return (nil, [:]) }
        defer { IOObjectRelease(iterator) }

        var result: GPUStats?
        var times: [Int32: UInt64] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let stats = raw.takeRetainedValue() as? [String: Any] {
                let device = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                let renderer = (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue
                let tiler = (stats["Tiler Utilization %"] as? NSNumber)?.doubleValue
                if let device {
                    if model == nil {
                        let value = IORegistryEntryCreateCFProperty(entry, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                        if let text = value as? String { model = text }
                        else if let data = value as? Data { model = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
                        cores = (IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                    }
                    result = GPUStats(
                        utilization: device / 100, rendererUtilization: renderer.map { $0 / 100 }, tilerUtilization: tiler.map { $0 / 100 },
                        memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value,
                        memoryAllocated: (stats["Alloc system memory"] as? NSNumber)?.uint64Value,
                        model: model, cores: cores
                    )
                    if wantApps { times = Self.clientTimes(of: entry) }
                }
            }
            IOObjectRelease(entry)
            if result != nil { break }
            entry = IOIteratorNext(iterator)
        }
        guard wantApps, result != nil else { return (result, [:]) }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousWall > 0 ? Double(now &- previousWall) : 0
        // Two readings a moment apart turn one frame into a wild share; keep the last figures instead.
        if elapsed > 0, elapsed < 0.5e9 { return (result, shares) }
        var next: [Int32: Double] = [:]
        if elapsed > 0 {
            for (pid, time) in times {
                guard let before = previousTimes[pid], time > before else { continue }
                next[pid] = min(Double(time - before) / elapsed, 1)
            }
        }
        previousTimes = times
        previousWall = now
        shares = next
        return (result, next)
    }

    /// GPU time used so far, in nanoseconds, by the process behind each client of the accelerator.
    private static func clientTimes(of accelerator: io_registry_entry_t) -> [Int32: UInt64] {
        var times: [Int32: UInt64] = [:]
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return times }
        defer { IOObjectRelease(children) }
        var child = IOIteratorNext(children)
        while child != 0 {
            // "pid 443, WindowServer"
            if let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               creator.hasPrefix("pid "), let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }),
               let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                for item in usage {
                    times[pid, default: 0] &+= (item["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        return times
    }
}

final class DiskSampler {
    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var previousTime: UInt64 = 0
    /// Requests served and the time they took, in nanoseconds, as last read.
    private var previousOps: (read: UInt64, write: UInt64, readTime: UInt64, writeTime: UInt64)?

    func sample() -> DiskStats {
        var fs = statfs()
        var total: UInt64 = 0
        var free: UInt64 = 0
        if statfs("/", &fs) == 0 {
            total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
            free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        }

        var read: UInt64 = 0
        var write: UInt64 = 0
        // The same dictionary counts the requests, the time they took and the ones that failed.
        var readOps: UInt64 = 0, writeOps: UInt64 = 0, readTime: UInt64 = 0, writeTime: UInt64 = 0, errors: UInt64 = 0, retries: UInt64 = 0
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let raw = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0),
                   let stats = raw.takeRetainedValue() as? [String: Any] {
                    func count(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
                    read &+= count("Bytes (Read)")
                    write &+= count("Bytes (Write)")
                    readOps &+= count("Operations (Read)")
                    writeOps &+= count("Operations (Write)")
                    readTime &+= count("Total Time (Read)")
                    writeTime &+= count("Total Time (Write)")
                    errors &+= count("Errors (Read)") &+ count("Errors (Write)")
                    retries &+= count("Retries (Read)") &+ count("Retries (Write)")
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var readRate = 0.0, writeRate = 0.0
        if previousTime > 0 {
            let dt = Double(now &- previousTime) / 1e9
            if dt > 0 {
                readRate = read >= previousRead ? Double(read - previousRead) / dt : 0
                writeRate = write >= previousWrite ? Double(write - previousWrite) / dt : 0
            }
        }
        var result = DiskStats(total: total, free: free, readBytesPerSecond: readRate, writeBytesPerSecond: writeRate)
        if let before = previousOps, previousTime > 0 {
            let dt = Double(now &- previousTime) / 1e9
            let reads = readOps >= before.read ? readOps - before.read : 0, writes = writeOps >= before.write ? writeOps - before.write : 0
            if dt > 0 {
                result.readOps = Double(reads) / dt
                result.writeOps = Double(writes) / dt
            }
            // Time spent over requests served: how long each one took, on average, since the last reading.
            if reads > 0, readTime >= before.readTime { result.readLatency = Double(readTime - before.readTime) / 1e9 / Double(reads) }
            if writes > 0, writeTime >= before.writeTime { result.writeLatency = Double(writeTime - before.writeTime) / 1e9 / Double(writes) }
        }
        result.bytesRead = read
        result.bytesWritten = write
        result.errors = errors
        result.retries = retries
        previousOps = (readOps, writeOps, readTime, writeTime)
        previousRead = read
        previousWrite = write
        previousTime = now
        return result
    }
}
