import CoreMediaIO
import Foundation

/// Whether a camera is running, from CoreMediaIO's list of video devices. macOS says that one is running but
/// not for whom. Only properties are read: no stream is started, so macOS has nothing to ask the user about.
@MainActor
final class CameraSource {
    /// Called on the main queue when something may have changed.
    var changed: () -> Void = {}

    private let system = CMIOObjectID(kCMIOObjectSystemObject)
    private var listListener: CMIOObjectPropertyListenerBlock?
    private var listeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private(set) var fired = 0

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    /// Listens for cameras being plugged in and pulled out. Each one's own listener is added as it is read.
    func start() {
        guard listListener == nil else { return }
        let block = listener()
        var address = Self.address(kCMIOHardwarePropertyDevices)
        if CMIOObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr { listListener = block }
    }

    func stop() {
        if let block = listListener {
            var address = Self.address(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListenerBlock(system, &address, .main, block)
            listListener = nil
        }
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for (device, block) in listeners { CMIOObjectRemovePropertyListenerBlock(device, &address, .main, block) }
        listeners = [:]
    }

    private func listener() -> CMIOObjectPropertyListenerBlock {
        { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.fired += 1
                self?.changed()
            }
        }
    }

    /// How many cameras there are and whether any of them is running.
    func read() -> (devices: Int, running: Bool) {
        let devices = self.devices()
        let running = devices.contains { Self.isRunning($0) }
        if listListener != nil { follow(devices) }
        return (devices.count, running)
    }

    private func follow(_ devices: [CMIOObjectID]) {
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        let present = Set(devices)
        for (device, block) in listeners where !present.contains(device) {
            CMIOObjectRemovePropertyListenerBlock(device, &address, .main, block)
            listeners[device] = nil
        }
        for device in devices where listeners[device] == nil {
            let block = listener()
            if CMIOObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { listeners[device] = block }
        }
    }

    private func devices() -> [CMIOObjectID] {
        var address = Self.address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &list) == noErr else { return [] }
        return Array(list.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return false }
        return value != 0
    }
}
