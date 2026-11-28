import CDotmeter
import Foundation
import IOKit

/// The NVMe SMART / health log as the drive returns it: 512 bytes, little-endian, laid out by the NVMe
/// specification (log page 02h). Nothing here is worked out; `DriveHealth` is what the app shows.
struct SMARTLog: Equatable {
    /// The log's long counters are 128 bits wide. No drive will fill one, but they are read whole so a
    /// counter that has passed 64 bits is never shown as a small number.
    struct Counter: Equatable, CustomStringConvertible {
        var low: UInt64
        var high: UInt64 = 0

        /// The value, when it fits in 64 bits.
        var exact: UInt64? { high == 0 ? low : nil }
        /// The value, or the largest 64-bit number when it does not fit.
        var clamped: UInt64 { high == 0 ? low : .max }
        var double: Double { Double(high) * 18_446_744_073_709_551_616 + Double(low) }

        /// In decimal, however large.
        var description: String {
            if high == 0 { return String(low) }
            // Long division by ten over four 32-bit limbs, most significant first.
            var limbs = [UInt32(high >> 32), UInt32(truncatingIfNeeded: high), UInt32(low >> 32), UInt32(truncatingIfNeeded: low)]
            var digits: [Character] = []
            while limbs.contains(where: { $0 != 0 }) {
                var remainder: UInt64 = 0
                for index in limbs.indices {
                    let value = remainder << 32 | UInt64(limbs[index])
                    limbs[index] = UInt32(value / 10)
                    remainder = value % 10
                }
                digits.append(Character(String(remainder)))
            }
            return String(digits.reversed())
        }
    }

    /// Bit 0: spare below its threshold. 1: temperature outside its limits. 2: reliability degraded.
    /// 3: read-only. 4: the backup for its volatile memory failed. 5: persistent memory region unreliable.
    var criticalWarning: UInt8
    /// Composite temperature in kelvins. Zero when the drive reports none.
    var kelvin: UInt16
    /// Percent, 0...100.
    var spare: UInt8
    var spareThreshold: UInt8
    /// The drive's own estimate of how much of its rated life is used. It may pass 100, up to 255.
    var percentUsed: UInt8
    /// In units of 1000 sectors of 512 bytes.
    var dataUnitsRead: Counter
    var dataUnitsWritten: Counter
    var hostReads: Counter
    var hostWrites: Counter
    var busyMinutes: Counter
    var powerCycles: Counter
    var powerOnHours: Counter
    var unsafeShutdowns: Counter
    var mediaErrors: Counter
    var errorLogEntries: Counter

    static let length = 512

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.length else { return nil }
        func counter(_ offset: Int) -> Counter {
            func word(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << UInt64($1 * 8) } }
            return Counter(low: word(offset), high: word(offset + 8))
        }
        criticalWarning = bytes[0]
        kelvin = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        spare = bytes[3]
        spareThreshold = bytes[4]
        percentUsed = bytes[5]
        dataUnitsRead = counter(32)
        dataUnitsWritten = counter(48)
        hostReads = counter(64)
        hostWrites = counter(80)
        busyMinutes = counter(96)
        powerCycles = counter(112)
        powerOnHours = counter(128)
        unsafeShutdowns = counter(144)
        mediaErrors = counter(160)
        errorLogEntries = counter(176)
    }

    /// A log with nothing in it is no reading: some bridges answer the request with zeroes.
    var isBlank: Bool {
        criticalWarning == 0 && kelvin == 0 && spare == 0 && spareThreshold == 0 && percentUsed == 0
            && [dataUnitsRead, dataUnitsWritten, hostReads, hostWrites, powerCycles, powerOnHours, unsafeShutdowns, mediaErrors].allSatisfy { $0.low == 0 && $0.high == 0 }
    }
}

/// How worn the internal drive is, from its own SMART record. Read at launch and then every ten minutes.
struct DriveHealth: Codable, Equatable {
    var model: String?
    /// Percent of its rated life the drive says it has used. It may pass 100.
    var used: Int
    /// Spare blocks left, percent, and the level under which the drive raises a warning.
    var spare: Int
    var spareThreshold: Int
    /// Over the drive's whole life.
    var bytesRead: Double
    var bytesWritten: Double
    var powerOnHours: UInt64
    var powerCycles: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    /// The drive's critical-warning flags, as read (see `SMARTLog.criticalWarning`).
    var warningFlags: UInt8
    var celsius: Double?
    var readAt: Date

    /// A data unit is a thousand 512-byte sectors.
    static let unitBytes = 512_000.0

    init?(log: SMARTLog, model: String?, at time: Date = Date()) {
        guard !log.isBlank else { return nil }
        self.model = model
        used = Int(log.percentUsed)
        spare = Int(log.spare)
        spareThreshold = Int(log.spareThreshold)
        bytesRead = log.dataUnitsRead.double * Self.unitBytes
        bytesWritten = log.dataUnitsWritten.double * Self.unitBytes
        powerOnHours = log.powerOnHours.clamped
        powerCycles = log.powerCycles.clamped
        unsafeShutdowns = log.unsafeShutdowns.clamped
        mediaErrors = log.mediaErrors.clamped
        warningFlags = log.criticalWarning
        celsius = log.kelvin > 0 ? Double(log.kelvin) - 273.15 : nil
        readAt = time
    }

    init(model: String?, used: Int, spare: Int, spareThreshold: Int, bytesRead: Double, bytesWritten: Double, powerOnHours: UInt64, powerCycles: UInt64, unsafeShutdowns: UInt64, mediaErrors: UInt64, warningFlags: UInt8 = 0, celsius: Double?, readAt: Date = Date()) {
        self.model = model
        self.used = used
        self.spare = spare
        self.spareThreshold = spareThreshold
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.warningFlags = warningFlags
        self.celsius = celsius
        self.readAt = readAt
    }

    /// What the drive is warning about, in plain words. Empty when it warns about nothing.
    var warnings: [String] {
        var list: [String] = []
        if warningFlags & 0x01 != 0 { list.append("Spare blocks are under the drive's limit") }
        if warningFlags & 0x02 != 0 { list.append("Temperature is outside the drive's limits") }
        if warningFlags & 0x04 != 0 { list.append("The drive says it is less reliable") }
        if warningFlags & 0x08 != 0 { list.append("The drive has gone read-only") }
        if warningFlags & 0x10 != 0 { list.append("The backup for its memory failed") }
        if warningFlags & 0x20 != 0 { list.append("Its persistent memory is unreliable") }
        return list
    }

    /// 0...1 for the bar. A drive past its rating fills it.
    var usedFraction: Double { min(max(Double(used) / 100, 0), 1) }

    /// Decimal, as drives are sold: "80.9 TB", "512 GB", "1.24 PB". A lifetime total keeps its tenth of a terabyte.
    static func amount(_ bytes: Double) -> String {
        if bytes >= 999.5e12 { return String(format: "%.2f PB", bytes / 1e15) }
        if bytes >= 0.9995e12 { return String(format: "%.1f TB", bytes / 1e12) }
        return Format.data(UInt64(max(0, bytes)))
    }

    /// "74 days" or "2.1 years" of being switched on.
    static func span(hours: UInt64) -> String {
        let days = Double(hours) / 24
        if days >= 730 { return String(format: "%.1f years", days / 365.25) }
        if days >= 2 { return "\(Int(days.rounded())) days" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// One line for an explanation: every figure, nothing that identifies the drive beyond its model.
    var summaryLine: String {
        var parts = ["\(used)% of its rated life used", "\(Self.amount(bytesWritten)) written and \(Self.amount(bytesRead)) read since new",
                     "\(Detail.count(Int(clamping: powerOnHours), "power-on hours"))", "\(Detail.count(Int(clamping: powerCycles), "power cycles"))",
                     "\(Detail.count(Int(clamping: unsafeShutdowns), "unsafe shutdowns"))", "spare \(spare)% (the drive warns under \(spareThreshold)%)",
                     "\(Detail.count(Int(clamping: mediaErrors), "media errors"))"]
        if let celsius { parts.append("\(Int(celsius.rounded()))°C") }
        parts.append(warnings.isEmpty ? "no warnings raised" : "WARNINGS: " + warnings.joined(separator: "; "))
        return "Internal drive's own SMART record\(model.map { " (\($0))" } ?? ""): " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - Reading

extension DriveHealth {
    /// Why a read gave nothing, for the test command and the report.
    enum ReadFailure: Error, CustomStringConvertible {
        case noDrive
        case plugIn(Int32)
        case noInterface(Int32)
        case refused(Int32)
        case blank

        var description: String {
            switch self {
            case .noDrive: return "no internal drive says it is NVMe SMART capable"
            case .plugIn(let code): return String(format: "the SMART plug-in could not be loaded (0x%08x)", UInt32(bitPattern: code))
            case .noInterface(let code): return String(format: "the plug-in does not offer the SMART interface (0x%08x)", UInt32(bitPattern: code))
            case .refused(let code): return String(format: "the drive refused the read (0x%08x)", UInt32(bitPattern: code))
            case .blank: return "the drive answered with an empty log"
            }
        }
    }

    /// The internal drive's record, or nil where there is none to read: a Mac whose drive is not NVMe, or one
    /// that keeps the log to itself.
    static func read() -> DriveHealth? { try? readInternal().get().health }

    /// The same with the raw log and the reason for a failure.
    static func readInternal() -> Result<(health: DriveHealth, raw: [UInt8]), ReadFailure> {
        guard let drive = internalService() else { return .failure(.noDrive) }
        defer { IOObjectRelease(drive.service) }
        var raw = [UInt8](repeating: 0, count: SMARTLog.length)
        var detail: Int32 = 0
        switch dotmeter_nvme_smart_log(drive.service, &raw, &detail) {
        case 0: break
        case -1: return .failure(.plugIn(detail))
        case -2: return .failure(.noInterface(detail))
        default: return .failure(.refused(detail))
        }
        guard let log = SMARTLog(raw), let health = DriveHealth(log: log, model: drive.model) else { return .failure(.blank) }
        return .success((health, raw))
    }

    /// Every registry entry that offers the SMART log, with where it sits. The caller releases the services.
    static func capableServices() -> [(service: io_service_t, location: String?, model: String?)] {
        guard let matching = IOServiceMatching("IOService") as NSMutableDictionary? else { return [] }
        matching[kIOPropertyMatchKey] = ["NVMe SMART Capable": true]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(io_service_t, String?, String?)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let traits = IORegistryEntryCreateCFProperty(service, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            // The model is on the controller above; the serial number beside it is never asked for.
            let model = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Model Number" as CFString, kCFAllocatorDefault,
                                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
            found.append((service, traits?["Physical Interconnect Location"] as? String, model?.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return found
    }

    /// The drive built into the Mac. A drive in an enclosure answers the same request, but it is not this
    /// Mac's own and may be gone tomorrow, so it is not what the Storage page reports on.
    private static func internalService() -> (service: io_service_t, model: String?)? {
        var chosen: (io_service_t, String?)?
        for entry in capableServices() {
            if chosen == nil, entry.location == "Internal" {
                chosen = (entry.service, entry.model)
            } else {
                IOObjectRelease(entry.service)
            }
        }
        return chosen
    }
}
