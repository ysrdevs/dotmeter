import Foundation
import UserNotifications

/// Watches each reading for the conditions worth remembering. Every one becomes an event in the timeline,
/// whether or not a notification is wanted for it; the settings only decide which ones also knock.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    private var store: TimelineStore?
    /// The event that is running for each kind of condition, if one is.
    private var active: [TimelineEvent.Kind: UUID] = [:]
    private var lastNotified: [TimelineEvent.Kind: Date] = [:]
    /// When each app first went over the busy threshold.
    private var busySince: [String: Date] = [:]
    private var busyApp: String?
    private var wasOnline = false
    /// A condition has to hold this long before it counts, so one odd reading does not make an event.
    private var pendingSince: [TimelineEvent.Kind: Date] = [:]
    /// Connections that are running below what their parts could do, by port and what is on it, each with the
    /// event that is running for it. Nil until the ports have been read once: what was already slow when Dotmeter
    /// started is not news.
    private var slowConnections: [String: UUID?]?
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func attach(to monitor: SystemMonitor, store: TimelineStore) {
        self.store = store
        monitor.addObserver { [weak self] snapshot in self?.evaluate(snapshot) }
    }

    /// For the test command: an evaluator of its own, writing to a store of its own.
    static func forTesting(store: TimelineStore) -> AlertCenter {
        let center = AlertCenter()
        center.store = store
        return center
    }

    /// For the test command: one reading, as if it had just been taken.
    func feed(_ snapshot: Snapshot) { evaluate(snapshot) }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluate(_ s: Snapshot) {
        store?.record(s)
        let settings = AppSettings.shared
        let severity = Severity.from(s)
        let top = Array(s.apps.prefix(3))

        // Hot and throttled.
        check(.throttled, holds: s.thermal.isThrottled, s: s, top: top) {
            "macOS limited the processor to \(s.thermal.cpuSpeedLimit ?? 0)% to cool down"
        }
        check(.hot, holds: severity >= .high && !s.thermal.isThrottled, s: s, top: top) {
            if let first = top.first, first.cpu >= 0.5 { return "\(first.name) was using \(Self.cores(first.cpu))" }
            return "Nothing stood out; the heat came from many small things"
        }

        // Memory.
        // (The lists of apps are only worked out while the condition holds: sorting hundreds of apps on every
        // reading, for an event that starts once a week, is wasted work.)
        let tight = s.memory.pressure != .normal
        check(.memory, holds: tight, s: s, top: tight ? Array(s.apps.sorted { $0.memory > $1.memory }.prefix(3)) : []) {
            let first = s.apps.max { $0.memory < $1.memory }
            return first.map { "\($0.name) was holding \(Format.bytes($0.memory))" } ?? "Memory was tight"
        }

        // Disk.
        let freeGB = Double(s.disk.free) / 1e9
        check(.disk, holds: s.disk.total > 0 && freeGB < settings.diskAlertGB, s: s, top: []) {
            "\(Int(freeGB.rounded())) GB free of \(Format.bytes(s.disk.total))"
        }

        // One app holding several cores for minutes.
        let limit = settings.appAlertCores
        let over = Set(s.apps.filter { $0.cpu >= limit }.map(\.id))
        for id in busySince.keys where !over.contains(id) { busySince[id] = nil }
        for id in over where busySince[id] == nil { busySince[id] = s.timestamp }
        let sustained = s.apps.first { app in
            guard let since = busySince[app.id] else { return false }
            return s.timestamp.timeIntervalSince(since) >= settings.appAlertMinutes * 60
        }
        if let sustained { busyApp = sustained.name }
        check(.app, holds: sustained != nil, s: s, top: sustained.map { [$0] } ?? [], immediate: true) {
            "\(self.busyApp ?? "An app") held \(Self.cores(sustained?.cpu ?? limit)) for over \(Int(settings.appAlertMinutes)) minutes"
        }

        // The battery, on a Mac that has one and is running on it.
        if let battery = s.power.battery {
            let low = !battery.isPluggedIn && battery.charge * 100 < settings.batteryAlertPercent
            check(.battery, holds: low, s: s, top: low ? Array(s.apps.sorted { $0.power > $1.power }.prefix(3)) : []) {
                let left = battery.minutesRemaining.map { ", about \(BatteryLook.time($0)) left" } ?? ""
                return "\(Format.percent(battery.charge)) on battery\(left)"
            }
        }

        // Something plugged in that runs slower than it could.
        if let usb = s.usb { checkPorts(USBOverview.of(usb), at: s.timestamp) }

        // The connection.
        if s.network.online { wasOnline = true }
        check(.offline, holds: wasOnline && !s.network.online, s: s, top: []) {
            "No network port had a route"
        }
    }

    /// One event per connection that turns up slow, from the reading it first shows in to the one it is gone
    /// from (pulled out, or put right). Each knocks once, with no ten-minute rule: two slow cables are two things.
    private func checkPorts(_ overview: USBOverview, at time: Date) {
        let slow = overview.slow
        func key(_ port: USBOverview.Port) -> String { port.id + "|" + port.attached + "|" + (port.slow?.id ?? "") }
        guard var known = slowConnections else {
            slowConnections = Dictionary(slow.map { (key($0), nil) }, uniquingKeysWith: { first, _ in first })
            return
        }
        let current = Set(slow.map(key))
        for (gone, id) in known where !current.contains(gone) {
            if let id { store?.update(id) { $0.end = time } }
            known[gone] = nil
        }
        for port in slow where known[key(port)] == nil {
            guard let verdict = port.slow else { continue }
            let event = TimelineEvent(kind: .usb, start: time, summary: "\(port.attached) on \(port.title): \(verdict.title.lowercasedFirst)\(port.figure.map { ", at \($0)" } ?? "")")
            store?.begin(event)
            known[key(port)] = .some(event.id)
            notifyPort(port, verdict: verdict)
        }
        slowConnections = known
    }

    private func notifyPort(_ port: USBOverview.Port, verdict: USBVerdict) {
        guard available, AppSettings.shared.notifies(.usb) else { return }
        let content = UNMutableNotificationContent()
        content.title = verdict.id == "power" ? "Charging is held back by the cable" : "\(port.attached) is running slower than it could"
        content.body = "\(verdict.title) on \(port.title)\(port.figure.map { ", now \($0)" } ?? ""). Open USB in \(App.name) to see which part is holding it back."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dotmeter.usb." + port.id, content: content, trigger: nil))
    }

    private static func cores(_ value: Double) -> String {
        let whole = Int(value.rounded())
        return whole >= 2 ? "\(whole) cores" : "a full core"
    }

    /// Starts, updates or ends the event for one kind of condition.
    private func check(_ kind: TimelineEvent.Kind, holds: Bool, s: Snapshot, top: [AppUsage], immediate: Bool = false, summary: () -> String) {
        guard let store else { return }
        if let id = active[kind] {
            if holds {
                store.update(id) { event in
                    let hottest = s.thermal.hottest?.celsius ?? 0
                    if hottest > (event.peakCelsius ?? 0) {
                        event.peakCelsius = hottest
                        if !top.isEmpty { event.apps = top.map { .init(name: $0.name, bundlePath: $0.bundlePath, cpu: $0.cpu) } }
                    }
                    event.peakRPM = max(event.peakRPM ?? 0, s.thermal.averageRPM)
                    event.peakCPU = max(event.peakCPU ?? 0, s.cpu.total)
                }
            } else {
                store.update(id) { $0.end = s.timestamp }
                active[kind] = nil
            }
            return
        }
        guard holds else {
            pendingSince[kind] = nil
            return
        }
        // Twenty seconds of it, unless the condition has already waited its own minutes.
        let since = pendingSince[kind] ?? s.timestamp
        pendingSince[kind] = since
        guard immediate || s.timestamp.timeIntervalSince(since) >= 20 else { return }
        pendingSince[kind] = nil

        var event = TimelineEvent(kind: kind, start: since, summary: summary())
        event.peakCelsius = s.thermal.hottest?.celsius
        event.peakRPM = s.thermal.fans.isEmpty ? nil : s.thermal.averageRPM
        event.peakCPU = s.cpu.total
        event.apps = top.map { .init(name: $0.name, bundlePath: $0.bundlePath, cpu: $0.cpu) }
        store.begin(event)
        active[kind] = event.id
        notify(event, s: s)
    }

    /// For events that do not come from a reading (an app that crashed, the microphone coming on): sends the
    /// notification if that kind is switched on in Settings. The event itself is the caller's to write down.
    func announce(_ event: TimelineEvent) { notify(event, s: nil) }

    private func notify(_ event: TimelineEvent, s: Snapshot?) {
        guard available, AppSettings.shared.notifies(event.kind) else { return }
        guard Date().timeIntervalSince(lastNotified[event.kind] ?? .distantPast) > 600 else { return }
        lastNotified[event.kind] = Date()

        let content = UNMutableNotificationContent()
        switch event.kind {
        case .hot: content.title = "Your Mac is running hot"
        case .throttled: content.title = "Your Mac is throttling"
        case .memory: content.title = "Memory is tight"
        case .disk: content.title = "The disk is nearly full"
        case .app: content.title = "An app is working hard"
        case .offline: content.title = "The connection dropped"
        case .battery: content.title = "The battery is low"
        case .usb: content.title = "A connection is slower than it could be"
        case .microphone: content.title = "The microphone is in use"
        case .camera: content.title = "The camera is in use"
        case .crash: content.title = "An app crashed"
        case .accessory: content.title = "An accessory's battery is low"
        }
        var parts = [event.summary]
        if let s, event.kind == .hot || event.kind == .throttled {
            if let hottest = s.thermal.hottest { parts.append(Format.temperature(hottest.celsius)) }
            if !s.thermal.fans.isEmpty { parts.append("fans at \(Format.rpm(s.thermal.averageRPM)) rpm") }
        }
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dotmeter." + event.kind.rawValue, content: content, trigger: nil))
    }
}
