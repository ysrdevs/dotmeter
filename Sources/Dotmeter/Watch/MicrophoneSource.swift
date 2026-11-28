import AppKit
import CDotmeter
import CoreAudio
import Darwin

/// Which app a process belongs to, named as the rest of the app names it: by the outermost app it runs from.
enum ActivityApps {
    /// The system's own pieces that record on behalf of an app, named for that app. Everything else of the
    /// system's that is not an app (Siri's listener, dictation's recognizer) is left out: it listens for the
    /// system, in moments or all day long, and is not an app using the microphone.
    private static let standIns: [String: (name: String, bundle: String)] = [
        "avconferenced": ("FaceTime", "/System/Applications/FaceTime.app"),
    ]

    private static var names: [String: String] = [:]

    /// Who a recording process counts as. nil for a piece of the system that is left out.
    static func user(path: String?, bundleID: String?) -> ActivityUser? {
        if let path {
            if let bundle = ProcessSampler.bundlePath(for: path) {
                return ActivityUser(key: bundle, name: name(ofBundle: bundle), bundlePath: bundle)
            }
            let name = (path as NSString).lastPathComponent
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") {
                guard let app = standIns[name] else { return nil }
                return ActivityUser(key: app.bundle, name: app.name, bundlePath: app.bundle)
            }
            return ActivityUser(key: "proc:" + name, name: name, bundlePath: nil)
        }
        // A process whose path cannot be read: go by the identifier Core Audio gave, if it is an app's.
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let app = app(forBundleID: bundleID) { return ActivityUser(key: app.bundlePath, name: app.name, bundlePath: app.bundlePath) }
        return bundleID.hasPrefix("com.apple.") ? nil : ActivityUser(key: "id:" + bundleID, name: bundleID, bundlePath: nil)
    }

    static func user(pid: pid_t, bundleID: String?) -> ActivityUser? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        return user(path: path, bundleID: bundleID)
    }

    /// The app registered under an identifier, by its outermost bundle: a helper's identifier gives its app.
    static func app(forBundleID bundleID: String) -> (name: String, bundlePath: String)? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        guard let bundle = ProcessSampler.bundlePath(for: url.path + "/") else { return nil }
        return (name(ofBundle: bundle), bundle)
    }

    /// The bundle's display name, as the process list reads it.
    static func name(ofBundle path: String) -> String {
        if let cached = names[path] { return cached }
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let bundle = Bundle(path: path) {
            let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let short = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let candidate = [display, short].compactMap({ $0 }).first(where: { !$0.isEmpty }) { name = candidate }
        }
        names[path] = name
        return name
    }
}

/// What a sound device is, as far as telling a microphone from the rest needs.
struct SoundDevice {
    var transport: UInt32
    var hasInput: Bool
    /// For a device made of others, the ones it is made of.
    var parts: [AudioObjectID] = []

    /// Whether recording from this device is recording from a microphone. A made-up device that hands on the
    /// Mac's own sound is not one, and neither is a group that holds none. A device that cannot be described
    /// counts: better to note a use that was not a microphone than to miss one that was.
    static func isMicrophone(_ device: AudioObjectID, describe: (AudioObjectID) -> SoundDevice?, depth: Int = 0) -> Bool {
        guard let kind = describe(device) else { return true }
        if kind.transport == kAudioDeviceTransportTypeVirtual { return false }
        if kind.transport == kAudioDeviceTransportTypeAggregate {
            return depth < 2 && kind.parts.contains { isMicrophone($0, describe: describe, depth: depth + 1) }
        }
        return kind.hasInput
    }
}

/// Who is recording, from Core Audio's own list of the processes connected to it. Only properties are read:
/// no device is opened and nothing is recorded, so macOS has nothing to ask the user about.
///
/// Asking every process costs a message to the sound server each, so it is done once. After that a process is
/// asked again when Core Audio says it changed, and new ones when the list does.
@MainActor
final class MicrophoneSource {
    struct Reading {
        /// The processes recording from a microphone. Empty where macOS does not say who.
        var processes: [(pid: pid_t, bundleID: String?)] = []
        /// Whether anything is recording at all.
        var inUse = false
        /// How many processes (or, before 14.2, input devices) there are, and how many were asked this time.
        var known = 0
        var asked = 0
    }

    /// Whether this system says which process is recording. Before 14.2 only the devices can be asked.
    let byProcess: Bool
    /// Called on the main queue when something may have changed.
    var changed: () -> Void = {}

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listening = false
    private var listListener: AudioObjectPropertyListenerBlock?
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// The processes or devices there are, and for the ones that are recording, whose they are.
    private var known: Set<AudioObjectID> = []
    private var running: [AudioObjectID: (pid: pid_t, bundleID: String?)] = [:]
    /// What has to be asked again: the list, and the ones Core Audio said changed.
    private var listChanged = true
    private var stale: Set<AudioObjectID> = []
    private(set) var fired = 0

    init(forceDevices: Bool = false) {
        byProcess = !forceDevices && Self.hasProcessObjects
    }

    static var hasProcessObjects: Bool {
        guard #available(macOS 14.2, *) else { return false }
        var address = address(kAudioHardwarePropertyProcessObjectList)
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private var listSelector: AudioObjectPropertySelector { byProcess ? kAudioHardwarePropertyProcessObjectList : kAudioHardwarePropertyDevices }
    private var runningSelector: AudioObjectPropertySelector { byProcess ? kAudioProcessPropertyIsRunningInput : kAudioDevicePropertyDeviceIsRunningSomewhere }

    /// Listens for processes (or devices) coming and going. Each one's own listener is added as it is first read.
    func start() {
        guard !listening else { return }
        listening = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fired += 1
                self.listChanged = true
                self.changed()
            }
        }
        var address = Self.address(listSelector)
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr { listListener = block }
    }

    func stop() {
        listening = false
        if let block = listListener {
            var address = Self.address(listSelector)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, block)
            listListener = nil
        }
        var address = Self.address(runningSelector)
        for (object, block) in listeners { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
        listeners = [:]
    }

    /// Who is recording now, asking only what may have changed. `everything` asks every process again.
    func read(everything: Bool = false) -> Reading {
        var asked = 0
        if listChanged || everything {
            listChanged = false
            let objects = Set(byProcess ? Self.objects(system, kAudioHardwarePropertyProcessObjectList) : inputDevices())
            var address = Self.address(runningSelector)
            for gone in known.subtracting(objects) {
                if let block = listeners[gone] { AudioObjectRemovePropertyListenerBlock(gone, &address, .main, block) }
                listeners[gone] = nil
                running[gone] = nil
                stale.remove(gone)
            }
            for object in objects.subtracting(known) {
                stale.insert(object)
                // The listener goes on before the first look, so a change between the two is not lost.
                guard listening else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.fired += 1
                        self.stale.insert(object)
                        self.changed()
                    }
                }
                if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners[object] = block }
            }
            known = objects
        }
        for object in everything ? known : stale.intersection(known) {
            asked += 1
            running[object] = recording(object)
        }
        stale = []
        return Reading(processes: byProcess ? running.values.sorted { $0.pid < $1.pid } : [], inUse: !running.isEmpty, known: known.count, asked: asked)
    }

    /// Whether everything should be asked again at the slow check: only while a device that can record is
    /// running for someone, or a use is under way. At rest that is a question or two, not one per process.
    func worthAsking() -> Bool {
        if !running.isEmpty || !byProcess { return true }
        return Self.objects(system, kAudioHardwarePropertyDevices).contains { device in
            Self.size(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) > 0
                && (Self.number(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        }
    }

    /// For the test command: how many sound devices there are, and how many of them can record.
    static func deviceCounts() -> (all: Int, recording: Int) {
        let devices = objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return (devices.count, devices.filter { size($0, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) > 0 }.count)
    }

    /// Whose recording this is, if the process (or device) is recording from a microphone now.
    private func recording(_ object: AudioObjectID) -> (pid: pid_t, bundleID: String?)? {
        guard (Self.number(object, runningSelector) ?? 0) != 0 else { return nil }
        guard byProcess else { return (0, nil) }
        guard let pid = Self.number(object, kAudioProcessPropertyPID) else { return nil }
        let devices = Self.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        guard devices.isEmpty || devices.contains(where: { SoundDevice.isMicrophone($0, describe: Self.describe) }) else { return nil }
        return (pid_t(bitPattern: pid), Self.string(object, kAudioProcessPropertyBundleID))
    }

    private static func describe(_ device: AudioObjectID) -> SoundDevice? {
        guard let transport = number(device, kAudioDevicePropertyTransportType) else { return nil }
        return SoundDevice(
            transport: transport,
            hasInput: size(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) > 0,
            parts: transport == kAudioDeviceTransportTypeAggregate ? objects(device, kAudioAggregateDevicePropertyActiveSubDeviceList) : []
        )
    }

    /// Devices that only record. One that also plays (a headset, a display with speakers) says it is running
    /// while it is only playing, so it cannot be read as a microphone in use.
    private func inputDevices() -> [AudioObjectID] {
        Self.objects(system, kAudioHardwarePropertyDevices).filter { device in
            Self.size(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) > 0
                && Self.size(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) == 0
                && Self.number(device, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeVirtual
        }
    }

    // MARK: Reading properties

    private static func size(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return 0 }
        return size
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size = size(object, selector, scope: scope)
        guard size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let text = value.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }
}
