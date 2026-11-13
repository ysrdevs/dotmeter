import Foundation
import IOKit

/// Tells the app the moment something is plugged in or pulled out, so the ports are read then instead of on a
/// clock. It asks the hardware registry to say when a USB device, or one of a port's transports (USB, Thunderbolt,
/// DisplayPort, the configuration channel), appears or goes. Nothing is read here; the reading follows.
///
/// Used from the main thread only: the registry delivers on the main queue.
final class USBWatcher {
    /// Classes whose coming and going means a port changed. A name matches its subclasses too.
    static let classes = ["IOUSBHostDevice", "IOPortTransportState"]

    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let onChange: () -> Void
    private let names: [String]

    /// `classes` is for the test, which watches something it can make appear by itself.
    init(classes: [String] = USBWatcher.classes, onChange: @escaping () -> Void) {
        names = classes
        self.onChange = onChange
    }

    deinit { stop() }

    var running: Bool { port != nil }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // The iterator has to be emptied, or the registry will not call again.
            USBWatcher.drain(iterator)
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        for name in names {
            for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching(name), callback, context, &iterator) == KERN_SUCCESS else { continue }
                // What is already there is not news; emptying the iterator arms it for what comes next.
                Self.drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    func stop() {
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators = []
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
    }
}
