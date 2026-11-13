import Foundation
import IOKit
import IOKit.pwr_mgt

/// Thermal state from Apple's public API plus fans and die temperatures from the SMC.
final class ThermalSampler {
    private let smc = SMC()
    private var temperatureKeys: [String] = []
    private var fanCount = 0
    private var lastScan = Date.distantPast

    /// Reading all ~600 sensors costs ~120 ms, so most samples only refresh the hottest few per group
    /// and a full pass runs every `fullReadEvery` samples to re-pick them.
    private var cachedSensors: [TemperatureReading] = []
    private var trackedKeys: [String] = []
    private var sampleCount = 0
    private var lastFans: [FanReading] = []
    private let fullReadEvery = 10
    private let trackedPerGroup = 8

    init() {
        scan()
    }

    /// Enumerate SMC keys once (and again every ~10 minutes in case sensors wake up) so each sample only reads the keys that matter.
    private func scan() {
        guard let smc else { return }
        lastScan = Date()
        fanCount = Int(smc.readDouble("FNum") ?? 0)
        var keys: [String] = []
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let info = smc.info(for: key), info.type == "flt " || info.type == "sp78" else { continue }
            if let value = smc.readDouble(key), value > 1, value < 130 { keys.append(key) }
        }
        temperatureKeys = keys
    }

    func sample() -> ThermalStats {
        if Date().timeIntervalSince(lastScan) > 600 { scan() }

        var fans: [FanReading] = []
        if let smc {
            for i in 0..<fanCount {
                guard let rpm = smc.readDouble("F\(i)Ac") else { continue }
                let minRPM = smc.readDouble("F\(i)Mn") ?? 0
                let maxRPM = smc.readDouble("F\(i)Mx") ?? 0
                let target = smc.readDouble("F\(i)Tg")
                fans.append(FanReading(index: i, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM, target: target, percent: Self.percent(rpm, minRPM, maxRPM)))
            }
        }
        lastFans = fans
        return assemble(fans: fans, sensors: readSensors())
    }

    /// The headline only: fan speeds and the hottest few die sensors, seven SMC reads instead of ninety.
    /// Everything else keeps its last value. Used while nothing but the menu bar is showing.
    func sampleLight() -> ThermalStats {
        guard let smc, !cachedSensors.isEmpty else { return sample() }
        var fans = lastFans
        for i in fans.indices {
            guard let rpm = smc.readDouble("F\(fans[i].index)Ac") else { continue }
            fans[i].rpm = rpm
            fans[i].percent = Self.percent(rpm, fans[i].minRPM, fans[i].maxRPM)
        }
        lastFans = fans
        // The sensors are kept hottest first, and which ones lead changes slowly: the three hottest in the
        // processor and the two hottest in the graphics cores carry the headline until the next full pass.
        var die = Set<String>()
        var counts = ["CPU": 0, "GPU": 0]
        for sensor in cachedSensors {
            guard let count = counts[sensor.group], count < (sensor.group == "CPU" ? 3 : 2) else { continue }
            counts[sensor.group] = count + 1
            die.insert(sensor.key)
        }
        for i in cachedSensors.indices where die.contains(cachedSensors[i].key) {
            if let value = smc.readDouble(cachedSensors[i].key), value > 1, value < 130 { cachedSensors[i].celsius = value }
        }
        cachedSensors.sort { $0.celsius > $1.celsius }
        return assemble(fans: fans, sensors: cachedSensors)
    }

    private static func percent(_ rpm: Double, _ minRPM: Double, _ maxRPM: Double) -> Double {
        maxRPM > minRPM ? min(1, max(0, (rpm - minRPM) / (maxRPM - minRPM))) : 0
    }

    private func assemble(fans: [FanReading], sensors: [TemperatureReading]) -> ThermalStats {
        let state: ThermalLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = .nominal
        case .fair: state = .fair
        case .serious: state = .serious
        case .critical: state = .critical
        @unknown default: state = .nominal
        }
        let cpu = sensors.filter { $0.group == "CPU" }.map(\.celsius).max()
        let gpu = sensors.filter { $0.group == "GPU" }.map(\.celsius).max()
        let dieSensors = sensors.filter { $0.group == "CPU" || $0.group == "GPU" }
        let hottest = dieSensors.first ?? sensors.first
        return ThermalStats(
            state: state,
            fans: fans,
            sensors: sensors,
            hottest: hottest,
            cpuTemperature: cpu,
            gpuTemperature: gpu,
            cpuSpeedLimit: cpuSpeedLimit()
        )
    }

    private func readSensors() -> [TemperatureReading] {
        guard let smc else { return [] }
        defer { sampleCount += 1 }
        let full = sampleCount % fullReadEvery == 0 || cachedSensors.isEmpty
        if full {
            var all: [TemperatureReading] = []
            for key in temperatureKeys {
                guard let value = smc.readDouble(key), value > 1, value < 130 else { continue }
                all.append(TemperatureReading(key: key, label: Self.label(for: key), celsius: value, group: Self.group(for: key)))
            }
            all.sort { $0.celsius > $1.celsius }
            var perGroup: [String: Int] = [:]
            trackedKeys = all.compactMap { reading in
                let n = perGroup[reading.group, default: 0]
                guard n < trackedPerGroup else { return nil }
                perGroup[reading.group] = n + 1
                return reading.key
            }
            cachedSensors = all
            return all
        }
        let tracked = Set(trackedKeys)
        for i in cachedSensors.indices where tracked.contains(cachedSensors[i].key) {
            if let value = smc.readDouble(cachedSensors[i].key), value > 1, value < 130 { cachedSensors[i].celsius = value }
        }
        cachedSensors.sort { $0.celsius > $1.celsius }
        return cachedSensors
    }

    private func cpuSpeedLimit() -> Int? {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&dictionary) == kIOReturnSuccess,
              let dict = dictionary?.takeRetainedValue() as? [String: Any] else { return nil }
        return (dict["CPU_Speed_Limit"] as? NSNumber)?.intValue
    }

    // SMC key naming is undocumented. Verified on an M3 Ultra by stressing the CPU: Tp* core sensors rise 10–15°,
    // Te* (efficiency) and Tc* follow, Tg* is the GPU, while the Tf* family never moves, so it is reported but never headlined.
    static func group(for key: String) -> String {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tc") || key.hasPrefix("TC") { return "CPU" }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") { return "GPU" }
        if key.hasPrefix("Tf") { return "SoC" }
        if key.hasPrefix("Ta") { return "Airflow" }
        if key.hasPrefix("TM") || key.hasPrefix("Tm") { return "Memory" }
        if key.hasPrefix("TH") || key.hasPrefix("Th") { return "Storage" }
        if key.hasPrefix("TB") { return "Battery" }
        if key.hasPrefix("TW") { return "Wireless" }
        if key.hasPrefix("Ts") { return "Enclosure" }
        if key.hasPrefix("TP") || key.hasPrefix("TV") || key.hasPrefix("TR") || key.hasPrefix("Tr") { return "Power" }
        return "Other"
    }

    static func label(for key: String) -> String {
        "\(group(for: key)) \(key)"
    }
}
