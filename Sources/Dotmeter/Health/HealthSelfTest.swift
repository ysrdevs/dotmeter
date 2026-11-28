import Foundation

extension DebugTools {
    /// A made-up SMART log, written out byte by byte as the NVMe specification lays the page out and kept as
    /// the runs that are not zero. No drive produced it: every value was chosen, and is what the test expects.
    private static let knownLog: [UInt8] = {
        var log = [UInt8](repeating: 0, count: SMARTLog.length)
        let runs: [(Int, [UInt8])] = [
            (0x00, [0x00, 0x34, 0x01, 0x64, 0x0a, 0x03]),   // no warning, 308 K, spare 100, threshold 10, 3% used
            (0x20, [0x15, 0xcd, 0x5b, 0x07]),               // data units read: 123,456,789
            (0x30, [0x78, 0x0a, 0xe3, 0x05]),               // data units written: 98,765,432
            (0x40, [0x00, 0x94, 0x35, 0x77]),               // read commands: 2,000,000,000
            (0x50, [0x00, 0x2f, 0x68, 0x59]),               // write commands: 1,500,000,000
            (0x70, [0x41, 0x01]),                           // power cycles: 321
            (0x80, [0xe1, 0x10]),                           // power-on hours: 4,321
            (0x90, [0x0c]),                                 // unsafe shutdowns: 12
            (0xb0, [0x03]),                                 // error log entries: 3
        ]
        for (offset, bytes) in runs { log.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        return log
    }()

    /// Drive health and accessory batteries: the decoders on known bytes and made-up registry entries, the
    /// low-battery event on a timeline of its own, then one real read of each on this Mac.
    @MainActor
    static func healthSelfTest(models: AppModels) async {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ note: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "ok    " : "FAILED") \(name)\(note.isEmpty ? "" : " · \(note)")")
        }

        // The known log.
        if let log = SMARTLog(knownLog), let health = DriveHealth(log: log, model: "TEST", at: Date(timeIntervalSince1970: 0)) {
            check("known log: warning flags, spare, threshold, wear", log.criticalWarning == 0 && log.spare == 100 && log.spareThreshold == 10 && log.percentUsed == 3)
            check("known log: temperature", log.kelvin == 308 && abs((health.celsius ?? 0) - 34.85) < 0.001, "308 K is \(Format.temperature(health.celsius ?? 0))")
            check("known log: data units", log.dataUnitsRead.exact == 123_456_789 && log.dataUnitsWritten.exact == 98_765_432)
            check("known log: commands", log.hostReads.exact == 2_000_000_000 && log.hostWrites.exact == 1_500_000_000)
            check("known log: cycles, hours, unsafe shutdowns, errors", log.powerCycles.exact == 321 && log.powerOnHours.exact == 4321 && log.unsafeShutdowns.exact == 12 && log.mediaErrors.exact == 0 && log.errorLogEntries.exact == 3)
            check("data units are 1000 sectors of 512 bytes", health.bytesWritten == 98_765_432 * 512_000 && health.bytesRead == 123_456_789 * 512_000,
                  "\(DriveHealth.amount(health.bytesWritten)) written, \(DriveHealth.amount(health.bytesRead)) read")
            check("as the panel words it", DriveHealth.amount(health.bytesWritten) == "50.6 TB" && DriveHealth.amount(health.bytesRead) == "63.2 TB" && DriveHealth.span(hours: health.powerOnHours) == "180 days" && health.warnings.isEmpty)
            check("survives the snapshot's coding", (try? JSONDecoder().decode(DriveHealth.self, from: JSONEncoder().encode(health))) == health)
        } else {
            check("known log decodes", false)
        }

        // Counters wider than 64 bits, and the edges.
        var wide = knownLog
        wide.replaceSubrange(48..<64, with: [5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])          // 2^64 + 5 data units written
        wide.replaceSubrange(128..<144, with: [UInt8](repeating: 0xff, count: 16))                      // the largest there is
        wide.replaceSubrange(112..<128, with: [0x15, 0x81, 0xe9, 0x7d, 0xf4, 0x10, 0x22, 0x11, 0, 0, 0, 0, 0, 0, 0, 0])
        if let log = SMARTLog(wide), let health = DriveHealth(log: log, model: nil) {
            check("128-bit counter past 64 bits", log.dataUnitsWritten.high == 1 && log.dataUnitsWritten.low == 5 && log.dataUnitsWritten.exact == nil && log.dataUnitsWritten.description == "18446744073709551621", log.dataUnitsWritten.description)
            check("128-bit counter, every bit set", log.powerOnHours.description == "340282366920938463463374607431768211455" && health.powerOnHours == .max)
            check("eight bytes in little-endian order", log.powerCycles.exact == 1_234_567_890_123_456_789, "\(log.powerCycles)")
            check("a wide counter is not shown small", health.bytesWritten > 9.4e24, DriveHealth.amount(health.bytesWritten))
        } else {
            check("wide counters decode", false)
        }
        check("a short log is refused", SMARTLog(Array(knownLog.prefix(511))) == nil)
        check("an empty log is no reading", SMARTLog([UInt8](repeating: 0, count: 512)).flatMap { DriveHealth(log: $0, model: nil) } == nil)
        var worn = knownLog
        worn[0] = 0x05
        worn[5] = 255
        worn[1] = 0
        worn[2] = 0
        if let health = SMARTLog(worn).flatMap({ DriveHealth(log: $0, model: nil) }) {
            check("warning flags are named", health.warnings == ["Spare blocks are under the drive's limit", "The drive says it is less reliable"], health.warnings.joined(separator: "; "))
            check("wear past 100% is kept, and the bar stays full", health.used == 255 && health.usedFraction == 1)
            check("no temperature when the drive gives none", health.celsius == nil)
        }
        check("amounts", DriveHealth.amount(512e9) == "512 GB" && DriveHealth.amount(1.5e12) == "1.5 TB" && DriveHealth.amount(1.24e15) == "1.24 PB" && DriveHealth.amount(250e12) == "250.0 TB")

        // Accessories, from made-up registry entries.
        let entries: [[String: Any]] = [
            ["Product": "Studio Keyboard", "Transport": "Bluetooth", "BatteryPercent": 82, "BatteryStatusFlags": 0, "SerialNumber": "TESTSERIAL-K", "DeviceAddress": "00-11-22-33-44-55"],
            // The same keyboard under a second driver: no serial number, the address written another way.
            ["Product": "Studio Keyboard", "Transport": "Bluetooth", "BatteryPercent": 82, "DeviceAddress": "00:11:22:33:44:55"],
            ["Transport": "BluetoothLowEnergy", "BatteryPercent": 40, "PrimaryUsagePage": 1, "PrimaryUsage": 2],                     // no name
            ["Product": "Broken Gauge", "Transport": "USB", "BatteryPercent": 255],                                                    // out of range
            ["Product": "Negative Gauge", "Transport": "USB", "BatteryPercent": -3],
            ["Product": "Wordy Gauge", "Transport": "USB", "BatteryPercent": "73"],                                                   // not a number
            ["Product": "Glass Trackpad", "Transport": "USB", "BatteryPercent": 64, "BatteryStatusFlags": 3, "SerialNumber": "TESTSERIAL-T"],
            ["Product": "Desk Mouse", "Transport": "Bluetooth", "BatteryPercent": 12, "SerialNumber": "TESTSERIAL-M1"],
            ["Product": "Desk Mouse", "Transport": "Bluetooth", "BatteryPercent": 90, "SerialNumber": "TESTSERIAL-M2"],              // a second mouse of the same make
            ["Product": "Built-in Thing", "BatteryPercent": 50, "Built-In": true],
            ["Product": "Empty One", "Transport": "Bluetooth", "BatteryPercent": 0],
        ]
        let devices = AccessoryBattery.decode(registry: entries)
        func named(_ name: String) -> [AccessoryBattery] { devices.filter { $0.name == name } }
        check("six devices from eleven entries", devices.count == 6, devices.map { "\($0.name) \($0.percent)%" }.joined(separator: ", "))
        check("a device listed twice appears once", named("Studio Keyboard").count == 1 && named("Studio Keyboard").first?.isCharging == false)
        check("a device with no name is called by what it is", named("Mouse").first.map { $0.percent == 40 && $0.kind == .mouse && $0.transport == "Bluetooth" } ?? false)
        check("levels out of range, and levels that are not numbers, are left out", named("Broken Gauge").isEmpty && named("Negative Gauge").isEmpty && named("Wordy Gauge").isEmpty)
        check("two of the same make stay two", named("Desk Mouse").map(\.percent).sorted() == [12, 90] && Set(named("Desk Mouse").map(\.id)).count == 2)
        check("charging is read, and unknown stays unknown", named("Glass Trackpad").first?.isCharging == true && named("Desk Mouse").allSatisfy { $0.isCharging == nil })
        check("what is built in is not an accessory", named("Built-in Thing").isEmpty)
        check("zero is a level", named("Empty One").first?.percent == 0)
        let coded = String(data: (try? JSONEncoder().encode(devices)) ?? Data(), encoding: .utf8) ?? "TESTSERIAL"
        check("no serial number or address in what is kept", !coded.contains("TESTSERIAL") && !coded.contains("11-22") && !coded.contains("11:22") && !coded.contains("112233"))
        check("ids hold from reading to reading", AccessoryBattery.decode(registry: entries.reversed()).map(\.id).sorted() == devices.map(\.id).sorted())
        check("kinds from names", named("Studio Keyboard").first?.kind == .keyboard && named("Glass Trackpad").first?.kind == .trackpad)

        // The system's accessory power sources, in the shapes macOS lists them: a pair of earbuds as one source
        // with its halves inside, the case on its own. All made up.
        func half(_ part: String, _ level: Int) -> [String: Any] {
            ["Type": "Accessory Source", "Name": "Test Buds", "Part Identifier": part, "Current Capacity": level, "Max Capacity": 100, "Is Present": true, "Accessory Identifier": "TEST-A"]
        }
        let sources: [[String: Any]] = [
            ["Type": "Accessory Source", "Name": "Test Buds", "Current Capacity": 79, "Max Capacity": 100, "Is Charging": true, "Is Present": true, "Transport Type": "Bluetooth", "Accessory Category": "Headset", "Part Identifier": "Combined", "Accessory Identifier": "TEST-A", "Combined Parts": [half("Left", 79), half("Right", 79)]],
            ["Type": "Accessory Source", "Name": "Test Buds Case", "Current Capacity": 56, "Max Capacity": 100, "Is Charging": false, "Is Present": true, "Transport Type": "Bluetooth LE", "Accessory Category": "Audio Battery Case", "Part Identifier": "Case", "Accessory Identifier": "TEST-A"],
            // A pair whose halves have drifted apart.
            ["Type": "Accessory Source", "Name": "Uneven Buds", "Current Capacity": 64, "Max Capacity": 100, "Is Present": true, "Transport Type": "Bluetooth", "Accessory Category": "Headset", "Part Identifier": "Combined", "Accessory Identifier": "TEST-B", "Combined Parts": [half("Right", 64), half("Left", 80)]],
            // Halves listed on their own.
            ["Type": "Accessory Source", "Name": "Split Buds", "Current Capacity": 41, "Max Capacity": 100, "Accessory Category": "Headset", "Part Identifier": "Left", "Accessory Identifier": "TEST-C"],
            ["Type": "Accessory Source", "Name": "Split Buds", "Current Capacity": 90, "Max Capacity": 100, "Accessory Category": "Headset", "Part Identifier": "Right", "Accessory Identifier": "TEST-C"],
            // Missing fields: no name, no full capacity, no type, no transport, nothing about charging.
            ["Current Capacity": 33, "Accessory Category": "Audio Battery Case"],
            ["Type": "Accessory Source", "Name": "Half Scale", "Current Capacity": 5, "Max Capacity": 10],
            ["Type": "Accessory Source", "Name": "No Level", "Max Capacity": 100, "Is Present": true],
            ["Type": "Accessory Source", "Name": "Too Full", "Current Capacity": 130, "Max Capacity": 100],
            ["Type": "Accessory Source", "Name": "Gone Buds", "Current Capacity": 50, "Max Capacity": 100, "Is Present": false],
            ["Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 70, "Max Capacity": 100],
            ["Type": "Accessory Source", "Name": "Studio Keyboard", "Current Capacity": 81, "Max Capacity": 100, "Transport Type": "Bluetooth"],
        ]
        let fromSources = AccessoryBattery.decode(sources: sources)
        func source(_ name: String) -> AccessoryBattery? { fromSources.first { $0.name == name } }
        check("power sources: eight devices from twelve entries", fromSources.map(\.name) == ["Charging case", "Half Scale", "Split Buds (left)", "Split Buds (right)", "Studio Keyboard", "Test Buds", "Test Buds Case", "Uneven Buds"],
              fromSources.map { "\($0.name) \($0.percent)%" }.joined(separator: ", "))
        check("power sources: a pair is one row with one figure", source("Test Buds").map { $0.percent == 79 && $0.kind == .headphones && $0.isCharging == true && $0.detail == nil && $0.transport == "Bluetooth" } ?? false)
        check("power sources: the case is a row of its own", source("Test Buds Case").map { $0.percent == 56 && $0.kind == .chargingCase && $0.isCharging == false } ?? false)
        check("power sources: halves that differ are both stated", source("Uneven Buds")?.detail == "left 80% · right 64%" && source("Uneven Buds")?.percent == 64, source("Uneven Buds")?.detail ?? "none")
        check("power sources: halves listed apart keep apart", source("Split Buds (left)")?.percent == 41 && source("Split Buds (right)")?.percent == 90 && source("Split Buds (left)")?.id != source("Split Buds (right)")?.id)
        check("power sources: missing fields", source("Charging case").map { $0.percent == 33 && $0.transport == nil && $0.isCharging == nil } ?? false)
        check("power sources: a level is a share of the full capacity", source("Half Scale")?.percent == 50)
        check("power sources: no level, an impossible level, not present and not an accessory are left out", ["No Level", "Too Full", "Gone Buds", "InternalBattery-0"].allSatisfy { source($0) == nil })
        check("power sources: every one is marked as not news", fromSources.allSatisfy { $0.origin == .powerSources && !$0.announces } && devices.allSatisfy(\.announces))
        let both = AccessoryBattery.merged(registry: devices, sources: fromSources)
        check("a device both lists know appears once, as the registry has it", both.filter { $0.name == "Studio Keyboard" }.map(\.percent) == [82] && both.first { $0.name == "Studio Keyboard" }?.announces == true && both.count == devices.count + fromSources.count - 1)

        // Running low: once, and again only after it has been above 20%.
        var watch = AccessoryWatch()
        func mouse(_ percent: Int, charging: Bool? = nil) -> AccessoryBattery { AccessoryBattery(id: "m", name: "Desk Mouse", percent: percent, transport: "Bluetooth", isCharging: charging, kind: .mouse) }
        var script: [String] = []
        for (list, note) in [([mouse(40)], "40"), ([mouse(16)], "16"), ([mouse(15)], "15"), ([mouse(12)], "12"), ([], "gone"), ([mouse(9)], "9"), ([mouse(18)], "18"), ([mouse(20)], "20"),
                             ([mouse(21)], "21"), ([mouse(15)], "15"), ([mouse(15)], "15"), ([mouse(60)], "60"), ([mouse(10, charging: true)], "10 charging"), ([mouse(10, charging: false)], "10")] {
            for change in watch.step(list) {
                switch change {
                case .low(let device): script.append("low at \(device.percent)")
                case .over: script.append("over at \(note)")
                }
            }
        }
        check("the watch: once per device until it has been above 20% again", script == ["low at 15", "over at gone", "low at 15", "over at 60", "low at 10"], script.joined(separator: ", "))
        var drawer = AccessoryBattery(id: "c", name: "Test Buds Case", percent: 5, transport: "Bluetooth", isCharging: false, kind: .chargingCase)
        drawer.origin = .powerSources
        var quiet = AccessoryWatch()
        check("the watch: a device known only from the power sources is never news", quiet.step([drawer]).isEmpty && quiet.step([drawer]).isEmpty && drawer.isLow)

        // The same through the alert centre, into a timeline of its own.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotmeter-health-\(getpid()).json")
        setenv("DOTMETER_TIMELINE_PATH", path.path, 1)
        let store = TimelineStore()
        let center = AlertCenter.forTesting(store: store)
        for _ in 0..<50 where models.monitor.latest == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if var base = models.monitor.latest {
            // A quiet Mac, so nothing else becomes an event.
            base.thermal.state = .nominal
            base.thermal.cpuSpeedLimit = 100
            base.thermal.hottest?.celsius = 50
            for index in base.thermal.fans.indices { base.thermal.fans[index].percent = 0.1 }
            base.memory.pressure = .normal
            for index in base.apps.indices { base.apps[index].cpu = min(base.apps[index].cpu, 0.2) }
            base.cpu.total = 0.1
            base.power.battery = nil
            base.usb = nil
            if base.disk.total > 0 { base.disk.free = base.disk.total / 2 }
            if base.network.primary == nil { base.network.primary = "en0" }
            var clock = Date().addingTimeInterval(-3600)
            func feed(_ list: [AccessoryBattery]?) {
                var reading = base
                clock = clock.addingTimeInterval(60)
                reading.timestamp = clock
                reading.accessories = list
                center.feed(reading)
            }
            let keyboard = AccessoryBattery(id: "k", name: "Studio Keyboard", percent: 80, transport: "Bluetooth", isCharging: false, kind: .keyboard)
            func events() -> [TimelineEvent] { store.events.filter { $0.kind == .accessory } }
            feed(nil)
            feed([keyboard, mouse(30)])
            check("nothing while every level is fine", events().isEmpty && store.events.isEmpty, "\(store.events.count) events")
            feed([keyboard, mouse(15)])
            feed([keyboard, mouse(14)])
            feed([keyboard, mouse(13)])
            check("one event when a device reaches 15%", events().count == 1 && events().first?.summary == "Desk Mouse at 15%" && events().first?.end == nil, events().map(\.summary).joined(separator: "; "))
            feed([keyboard, mouse(19)])
            check("still running at 19%", events().count == 1 && events().first?.end == nil)
            feed([keyboard, mouse(55)])
            check("over once it is back above 20%", events().count == 1 && events().first?.end != nil)
            var lowKeyboard = keyboard
            lowKeyboard.percent = 8
            feed([lowKeyboard, mouse(11)])
            check("armed again: a second event, and one for the other device", events().count == 3 && Set(events().suffix(2).map(\.summary)) == ["Desk Mouse at 11%", "Studio Keyboard at 8%"], events().map(\.summary).joined(separator: "; "))
            feed([lowKeyboard])
            feed([lowKeyboard, mouse(10)])
            check("a device that went away and came back low is not news twice", events().count == 3 && events().filter { $0.end == nil }.count == 1)
            // A case at 5% that only the power sources know of, for five minutes: no event. The same name from
            // the registry is the registry's device, and that one is news.
            for _ in 0..<5 { feed([lowKeyboard, mouse(10), drawer]) }
            check("no event from a power-source-only device at 5%", events().count == 3, events().map(\.summary).joined(separator: "; "))
            var inUse = drawer
            inUse.origin = .registry
            feed(AccessoryBattery.merged(registry: [lowKeyboard, mouse(10), inUse], sources: [drawer]))
            check("the same device from the registry does start one", events().count == 4 && events().last?.summary == "Test Buds Case at 5%")
            check("nothing else became an event", store.events.count == 4)

            // What an explanation is told.
            var shown = base
            shown.drive = HealthDemo.drive
            shown.accessories = HealthDemo.accessories
            let storageAsk = AnalysisPrompt.explainMessage(section: .storage, snapshot: shown, history: [], storage: nil, timeline: nil, question: nil, extra: nil)
            let powerAsk = AnalysisPrompt.explainMessage(section: .power, snapshot: shown, history: [], storage: nil, timeline: nil, question: nil, extra: nil)
            check("the Storage explanation is given the drive's record", storageAsk.contains("7% of its rated life used") && storageAsk.contains("48.2 TB written") && storageAsk.contains("no warnings raised"), HealthDemo.drive.summaryLine)
            check("the Power explanation is given the accessories, by what they are and not by name", powerAsk.contains("Accessory batteries: Mouse 12%, Trackpad 64% (charging), Keyboard 82%.") && !powerAsk.contains("Desk Mouse"))
            shown.drive = nil
            shown.accessories = []
            check("and neither when there is nothing to say", !AnalysisPrompt.explainMessage(section: .storage, snapshot: shown, history: [], storage: nil, timeline: nil, question: nil, extra: nil).contains("SMART")
                  && !AnalysisPrompt.explainMessage(section: .power, snapshot: shown, history: [], storage: nil, timeline: nil, question: nil, extra: nil).contains("Accessory batteries"))
        } else {
            check("a reading to build on", false)
        }
        try? FileManager.default.removeItem(at: path)

        // Made-up hardware for captures.
        check("demo: a drive and three accessories, one low and one charging", HealthDemo.accessories.count == 3 && HealthDemo.accessories.filter(\.isLow).count == 1 && HealthDemo.accessories.filter { $0.isCharging == true }.count == 1 && HealthDemo.drive.warnings.isEmpty)

        // This Mac, for real. Figures only: no serial number is ever read, and names stay out of the output.
        func milliseconds(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        var first: Result<(health: DriveHealth, raw: [UInt8]), DriveHealth.ReadFailure> = .failure(.noDrive)
        let firstCost = milliseconds { first = DriveHealth.readInternal() }
        let capable = DriveHealth.capableServices()
        for entry in capable { IOObjectRelease(entry.service) }
        print("live  \(capable.count) \(capable.count == 1 ? "drive offers" : "drives offer") the SMART log: \(capable.map { $0.location ?? "unknown place" }.joined(separator: ", ").lowercased())")
        switch first {
        case .success(let read):
            let h = read.health
            var again = 0.0
            for _ in 0..<20 { again += milliseconds { _ = DriveHealth.read() } }
            print("live  internal drive\(h.model.map { " (\($0))" } ?? ""): \(h.used)% used · spare \(h.spare)% (warns under \(h.spareThreshold)%) · written \(DriveHealth.amount(h.bytesWritten)) · read \(DriveHealth.amount(h.bytesRead)) · \(Format.count(h.powerOnHours)) hours · \(Format.count(h.powerCycles)) cycles · \(Format.count(h.unsafeShutdowns)) unsafe shutdowns · \(Format.count(h.mediaErrors)) media errors · \(h.celsius.map { Format.temperature($0) } ?? "no temperature") · flags \(h.warningFlags)")
            print(String(format: "live  drive read: %.2f ms the first time (the plug-in is loaded), %.2f ms after that", firstCost, again / 20))
            check("live drive record is believable", h.spare <= 100 && h.spareThreshold <= 100 && h.bytesWritten > 0 && h.powerCycles > 0 && (h.celsius.map { $0 > -20 && $0 < 120 } ?? true))
        case .failure(let why):
            print("live  no drive record on this Mac: \(why). The Storage page shows no Drive health panel.")
        }
        var entriesNow: [[String: Any]] = []
        let scanCost = milliseconds { entriesNow = AccessoryBattery.registryEntries(publishing: "BatteryPercent") }
        var more = 0.0
        for _ in 0..<10 { more += milliseconds { _ = AccessoryBattery.read() } }
        let live = AccessoryBattery.decode(registry: entriesNow)
        print("live  registry entries with BatteryPercent: \(entriesNow.count) · devices: \(live.count)\(live.isEmpty ? "" : " (" + live.map { "\($0.kind.rawValue) \($0.transport ?? "?") \($0.percent)%\($0.isCharging == true ? " charging" : "")" }.joined(separator: ", ") + ")")")
        print(String(format: "live  accessory read: %.2f ms for the registry alone, %.2f ms for a whole read%@", scanCost, more / 10, AccessoryBattery.usesPowerSources ? " (registry and power sources)" : " (power sources switched off)"))
        // The search itself, on a key this Mac is sure to have if it has an NVMe drive: an empty answer above
        // then means no device, not a search that finds nothing.
        let probe = AccessoryBattery.registryEntries(publishing: "NVMe SMART Capable").count
        check("the registry search finds entries by key", probe == capable.count, "\(probe) with NVMe SMART Capable, \(capable.count) by property match")
        if AccessoryBattery.usesPowerSources {
            let listed = AccessoryBattery.powerSources()
            let decoded = listed.map(AccessoryBattery.decode(sources:)) ?? []
            print("live  accessory power sources: \(listed.map { "\($0.count)" } ?? "not available on this macOS") · devices: \(decoded.count)\(decoded.isEmpty ? "" : " (" + decoded.map { "\($0.kind.rawValue) \($0.transport ?? "?") \($0.percent)%\($0.isCharging == true ? " charging" : "")\($0.detail.map { ", " + $0 } ?? "")" }.joined(separator: ", ") + ")")")
            let shown = AccessoryBattery.read()
            print("live  the panel would list \(shown.count), of which \(shown.filter(\.announces).count) can start an event")
        }
        print(failed == 0 ? "all \(passed) checks pass" : "\(failed) FAILED, \(passed) passed")
    }
}
