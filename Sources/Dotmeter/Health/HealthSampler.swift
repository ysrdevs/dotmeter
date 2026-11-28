import Foundation

/// Reads the drive's health record and the accessories' batteries, each on its own slow clock. Both are asked
/// for on every full pass and answer from memory in between: the drive's wear moves over months and a
/// keyboard's charge over days.
final class HealthSampler {
    /// Debug: DOTMETER_HEALTH_DEMO=1 reports a made-up drive and three made-up accessories, one of them low and
    /// one charging, so both panels can be seen on a Mac that has neither.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_HEALTH_DEMO"] == "1"

    static let driveEvery = 600.0
    static let accessoriesEvery = 60.0

    private var drive: DriveHealth?
    private var driveRead = Date.distantPast
    private var accessories: [AccessoryBattery]?
    private var accessoriesRead = Date.distantPast

    /// The internal drive's record: read at launch, then at most every ten minutes.
    func drive(at now: Date = Date()) -> DriveHealth? {
        if Self.demo { return HealthDemo.drive }
        if now.timeIntervalSince(driveRead) >= Self.driveEvery {
            driveRead = now
            drive = DriveHealth.read()
        }
        return drive
    }

    /// What reports a battery level: read at most once a minute. Empty when nothing does.
    func accessories(at now: Date = Date()) -> [AccessoryBattery] {
        if Self.demo { return HealthDemo.accessories }
        if now.timeIntervalSince(accessoriesRead) >= Self.accessoriesEvery {
            accessoriesRead = now
            accessories = AccessoryBattery.read()
        }
        return accessories ?? []
    }
}

/// Invented hardware for captures and design review. None of it is read from this Mac.
enum HealthDemo {
    static var drive: DriveHealth {
        DriveHealth(model: "Dotdrive SSD 1 TB", used: 7, spare: 100, spareThreshold: 10, bytesRead: 61.7e12, bytesWritten: 48.2e12,
                    powerOnHours: 3912, powerCycles: 1204, unsafeShutdowns: 9, mediaErrors: 0, celsius: 34, readAt: Date())
    }

    static var accessories: [AccessoryBattery] {
        [
            AccessoryBattery(id: "demo-mouse", name: "Desk Mouse", percent: 12, transport: "Bluetooth", isCharging: false, kind: .mouse),
            AccessoryBattery(id: "demo-trackpad", name: "Glass Trackpad", percent: 64, transport: "USB", isCharging: true, kind: .trackpad),
            AccessoryBattery(id: "demo-keyboard", name: "Studio Keyboard", percent: 82, transport: "Bluetooth", isCharging: false, kind: .keyboard),
        ]
    }
}
