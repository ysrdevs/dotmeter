import Foundation
import Observation

/// Polls the collectors on a background task and publishes snapshots to SwiftUI on the main actor.
@MainActor
@Observable
final class SystemMonitor {
    /// Enough for the five-minute charts at the two-second cadence, and close to an hour in the background.
    static let historyLength = 400

    /// What the panel and the window show. These only change while one of them is on screen: a window that
    /// has been closed keeps its views, and every change here would rebuild them for nobody.
    private(set) var snapshot: Snapshot?
    private(set) var history: [HistoryPoint] = []

    /// The newest reading and the full history, whether or not anything is on screen. The menu bar items
    /// and the alerts read these; nothing observes them.
    @ObservationIgnored private(set) var latest: Snapshot?
    @ObservationIgnored private(set) var latestHistory: [HistoryPoint] = []

    /// Fast cadence while the popover is open, slow heartbeat otherwise (icon tint + alerts).
    var panelVisible = false {
        didSet {
            guard panelVisible && !oldValue else { return }
            // Show the newest background reading at once; a full pass follows within a moment.
            if let latest {
                snapshot = latest
                history = latestHistory
            }
            restartLoop()
        }
    }

    /// A menu bar item is showing a live figure or graph, so the counters keep the fast cadence in the
    /// background too. Those passes are light ones (processor, memory, network, fans and the hottest die
    /// sensors, a few milliseconds), and the full pass with the process list drops back to every half minute.
    @ObservationIgnored var menuBarLive = false {
        didSet { if menuBarLive != oldValue { restartLoop() } }
    }
    /// Reasons to keep the counters at the fast pace while no panel or window is open, other than a menu bar
    /// item: the floating meter, another Mac watching this one. Each says whether it also wants the graphics
    /// load, which a light pass leaves out unless asked. Nothing is published to SwiftUI for these: whoever asks
    /// reads the readings through `addObserver`.
    @ObservationIgnored private var backgroundReasons: [String: Bool] = [:]

    func setBackgroundLive(_ reason: String, on: Bool, graphics: Bool = false) {
        let now: Bool? = on ? graphics : nil
        guard backgroundReasons[reason] != now else { return }
        let was = backgroundLive
        backgroundReasons[reason] = now
        if backgroundLive != was { restartLoop() }
    }

    /// A menu bar item or anything else wants live figures while nothing is open.
    private var backgroundLive: Bool { menuBarLive || !backgroundReasons.isEmpty }

    /// Something on screen shows per-app network traffic: how often to read it, in seconds. Each reading
    /// costs a helper process, so it is nil the rest of the time.
    @ObservationIgnored var networkAppsEvery: Double? {
        didSet { if networkAppsEvery != nil && oldValue == nil && panelVisible { restartLoop() } }
    }

    /// The Network area is on screen and latency measurement is switched on in Settings.
    @ObservationIgnored var networkLatencyWanted = false
    /// The Network page is on screen, which lists the apps listening for connections.
    @ObservationIgnored var networkPortsWanted = false

    /// What is on screen shows apps, processes, disk activity or every sensor, which only a full pass reads.
    /// False on the pages that show none of it (Timeline, Login Items, Ask Claude, USB): the counters keep
    /// their pace there, and the full pass with the process list drops back to every ten seconds.
    @ObservationIgnored var detailWanted = true {
        didSet { if detailWanted && !oldValue && panelVisible { restartLoop() } }
    }

    /// The USB area is on screen. The ports are read when it opens, whenever something is plugged in or pulled
    /// out, and every ten seconds besides; a walk through the hardware registry on every pass would cost more
    /// than everything else the page does. While a charger is on a port its live figures are worth every pass.
    @ObservationIgnored var usbWanted = false {
        didSet { if usbWanted != oldValue { setUSBBackground("on screen", every: usbWanted ? 10 : nil) } }
    }
    /// Reasons to read the ports while the USB area is not on screen (a cable is being followed, USB sits in the
    /// menu bar, the timeline wants to know of a slow connection), each with the longest it will wait between
    /// readings, in seconds. While there is any, a watcher has the ports read the moment something is plugged in
    /// or pulled out, so the clock is only the fallback.
    @ObservationIgnored private var usbReasons: [String: Double] = [:]
    @ObservationIgnored private var lastUSB = Date.distantPast
    @ObservationIgnored private var usbDue = false
    @ObservationIgnored private var usbKick: Task<Void, Never>?
    @ObservationIgnored private lazy var usbWatcher = USBWatcher { [weak self] in self?.portsChanged() }

    func setUSBBackground(_ reason: String, every seconds: Double?) {
        guard usbReasons[reason] != seconds else { return }
        let had = !usbReasons.isEmpty
        usbReasons[reason] = seconds
        if usbReasons.isEmpty {
            usbWatcher.stop()
        } else {
            usbWatcher.start()
            // A new reason wants a reading now, not at the next tick of its clock.
            if !had || seconds != nil { portsChanged(settle: 0.05) }
        }
    }

    private var usbBackgroundEvery: Double? { usbReasons.values.min() }

    /// Something was plugged in or pulled out. A link takes a moment to come up and a hub's devices arrive one
    /// by one, so the ports are read shortly after, and once more when things have settled.
    private func portsChanged(settle: Double = 0.7) {
        usbKick?.cancel()
        usbKick = Task { [weak self] in
            for wait in [settle, 2.5] {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.usbDue = true
                await self.refreshNow(full: false)
            }
        }
    }

    @ObservationIgnored private let collectors = Collectors()

    /// Debug access for `--dump`-style tools.
    var debugCollectors: Collectors { collectors }
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(Snapshot) -> Void] = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var lastFull = Date.distantPast
    @ObservationIgnored private let launchDate = Date()
    /// Debug: DOTMETER_LOG_SELF=1 prints this app's own CPU share on every refresh.
    private static let logSelf = ProcessInfo.processInfo.environment["DOTMETER_LOG_SELF"] == "1"
    /// Debug: DOTMETER_LOG_COST=1 prints how long each pass took to collect and to publish.
    private static let logCost = ProcessInfo.processInfo.environment["DOTMETER_LOG_COST"] == "1"
    private static let heartbeat = 10.0
    private static let fullEveryWhenLive = 30.0

    var severity: Severity { snapshot.map(Severity.from) ?? .nominal }
    var latestSeverity: Severity { latest.map(Severity.from) ?? .nominal }

    func start() { restartLoop() }

    func addObserver(_ observer: @escaping (Snapshot) -> Void) {
        observers.append(observer)
    }


    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let detailed = self.panelVisible && self.detailWanted
                let fullEvery = self.backgroundLive && !self.panelVisible ? Self.fullEveryWhenLive : Self.heartbeat
                let full = detailed || !self.primed || Date().timeIntervalSince(self.lastFull) >= fullEvery - 0.5
                await self.refreshNow(full: full)
                // CPU percentages are deltas; take a quick second reading at launch so the first open is never blank.
                let interval: Double
                if !self.primed { self.primed = true; interval = 1 }
                else if let override = ProcessInfo.processInfo.environment["DOTMETER_INTERVAL"].flatMap(Double.init) { interval = override }
                else if self.panelVisible { interval = AppSettings.shared.refreshInterval }
                else { interval = self.backgroundLive ? max(AppSettings.shared.refreshInterval, 2) : Self.heartbeat }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refreshNow(full: Bool = true) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let collectors = self.collectors
        var options = CollectOptions()
        options.light = !full
        options.graphics = !full && (panelVisible || backgroundReasons.values.contains(true))
        options.networkApps = full && panelVisible ? networkAppsEvery : nil
        options.networkLatency = full && panelVisible && networkLatencyWanted
        options.networkPorts = full && panelVisible && networkPortsWanted
        let metering = panelVisible && usbWanted && (latest?.usb.map { $0.charger != nil || $0.ports.contains { $0.powerSource != nil } } ?? false)
        options.usb = metering || usbDue || (usbBackgroundEvery.map { Date().timeIntervalSince(lastUSB) >= $0 - 0.5 } ?? false)
        if options.usb {
            lastUSB = Date()
            usbDue = false
        }
        if full { lastFull = Date() }
        let started = DispatchTime.now().uptimeNanoseconds
        let snap = await Task.detached(priority: .utility) { collectors.collect(options) }.value
        let collected = DispatchTime.now().uptimeNanoseconds
        latest = snap
        if Self.logSelf, let me = snap.processes.first(where: { $0.pid == ProcessInfo.processInfo.processIdentifier }) {
            print(String(format: "SELF t=%.1fs cpu=%@ panel=%@ %@", Date().timeIntervalSince(launchDate), Format.cpu(me.cpu), panelVisible ? "open" : "closed", full ? "full" : "light"))
            fflush(stdout)
        }
        if full { IconCache.prewarm(snap.apps.prefix(8)) }
        if NetworkSampler.demo, latestHistory.isEmpty { backfillDemoHistory(from: snap) }
        latestHistory.append(HistoryPoint(snapshot: snap))
        if latestHistory.count > Self.historyLength { latestHistory.removeFirst(latestHistory.count - Self.historyLength) }
        if panelVisible || snapshot == nil {
            snapshot = snap
            history = latestHistory
        }
        for observer in observers { observer(snap) }
        if Self.logCost {
            let done = DispatchTime.now().uptimeNanoseconds
            print(String(format: "COST %@ pass: collect %.2f ms, publish and menu bar %.2f ms", full ? "full" : "light", Double(collected - started) / 1e6, Double(done - collected) / 1e6))
            fflush(stdout)
        }
    }

    /// Demo only: five minutes of made-up traffic behind the first real reading, so the charts have a past.
    private func backfillDemoHistory(from snap: Snapshot) {
        let base = HistoryPoint(snapshot: snap)
        for step in stride(from: 150, to: 0, by: -1) {
            var point = base
            point.time = snap.timestamp.addingTimeInterval(-Double(step) * 2)
            let traffic = NetworkDemo.totals(at: point.time)
            if AppsDemo.on {
                // With the made-up apps on as well, the other charts get a past too: the first reading, with a
                // slow swell and a little grain, so a screenshot shows a chart and not one column.
                let t = Double(step)
                let swell = 0.5 + 0.5 * sin(t / 19) * cos(t / 7.3), grain = 0.5 + 0.5 * sin(t * 1.7)
                // The very first reading has no load figure yet (load is a difference between two readings).
                let load = base.cpu > 0.03 ? base.cpu : 0.14, graphics = base.gpu > 0.03 ? base.gpu : 0.27
                point.cpu = min(max(load * (0.55 + 0.9 * swell + 0.12 * grain), 0.01), 1)
                point.gpu = min(max(graphics * (0.6 + 0.8 * swell), 0.01), 1)
                point.memory = min(base.memory * (0.975 + 0.04 * swell), 1)
                point.temperature = base.temperature.map { $0 - 5 + 9 * swell }
                point.cpuTemperature = base.cpuTemperature.map { $0 - 5 + 9 * swell }
                point.power = base.power.map { $0 * (0.8 + 0.4 * swell + 0.05 * grain) }
            }
            point.networkIn = traffic.down
            point.networkOut = traffic.up
            point.networkBytesPerSecond = traffic.down + traffic.up
            let wifi = NetworkDemo.stats(at: point.time, apps: false).wifi
            let echoes = NetworkDemo.stats(at: point.time, apps: false, latency: true).latency
            point.latencyRouter = echoes.first?.last
            point.latencyInternet = echoes.last?.last
            point.wifiRSSI = wifi?.rssi.map { Double($0) }
            point.wifiRate = wifi?.transmitRate
            latestHistory.append(point)
        }
    }
}
