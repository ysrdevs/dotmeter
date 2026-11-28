import Foundation
import Network
import Observation

/// How long things are given. The self-test shortens them.
struct MacsTiming {
    /// The watching side says it is still there this often, and the showing side lets go of one that has said
    /// nothing for `watcherTimeout`: a Mac that fell asleep while watching must not keep this one working.
    var heartbeat = 5.0
    var watcherTimeout = 16.0
    /// A Mac counts as not answering once this many of its readings are overdue, and never sooner than the floor.
    var quietAfterReadings = 2.5
    var quietFloor = 5.0
    /// Between tries to reach a Mac that is advertised but not connected.
    var reconnect = 5.0
    /// The same for one that refused the code: it only changes when somebody types a code.
    var refusedRetry = 30.0
    /// A connection that has neither opened nor failed by now is given up.
    var connectTimeout = 8.0
    /// A Mac that has not answered for this long leaves the list.
    var dropAfter = 300.0
}

/// What a run was told through the environment. Any of these makes the run a trial: nothing is saved, so a test
/// copy never changes what the installed app remembers.
struct MacsConfig {
    /// `DOTMETER_MACS=on|off`: the switch, for this run.
    var on: Bool?
    /// `DOTMETER_MACS_CODE=<code>`: the group code, for this run.
    var code: String?
    /// `DOTMETER_MACS_LOOPBACK=<port>`: listen on 127.0.0.1 at that port and advertise nothing.
    var loopback: UInt16?
    /// `DOTMETER_MACS_PEER=127.0.0.1:<port>[,…]`: connect straight to these and look for nobody.
    var peers: [(host: String, port: UInt16)] = []
    /// `DOTMETER_MACS_DEMO=1`: made-up Macs, and nothing on the network at all.
    var demo = false
    /// `DOTMETER_MACS_NAME=<name>`: what this Mac calls itself to the others, for this run.
    var name: String?
    var id: String?
    var trial = false
    var timing = MacsTiming()

    /// Bonjour is neither advertised nor browsed. True whenever a test names its own ports, so that nothing a
    /// test does can make macOS ask about the local network.
    var offline: Bool { loopback != nil || !peers.isEmpty || demo }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MacsConfig {
        var config = MacsConfig()
        config.on = env["DOTMETER_MACS"].map { $0 == "on" || $0 == "1" }
        config.code = env["DOTMETER_MACS_CODE"].flatMap(MacsCode.normalized)
        config.loopback = env["DOTMETER_MACS_LOOPBACK"].flatMap { UInt16($0) }
        config.peers = (env["DOTMETER_MACS_PEER"] ?? "").split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            return (String(parts[0]), port)
        }
        config.demo = env["DOTMETER_MACS_DEMO"] == "1"
        config.name = env["DOTMETER_MACS_NAME"]
        config.trial = env.keys.contains { $0.hasPrefix("DOTMETER_MACS") }
        return config
    }
}

/// Another Mac, as this one sees it.
@MainActor
@Observable
final class MacPeer: Identifiable {
    nonisolated let id: String
    var hello: MacHello
    var reading: MacReading?
    /// When it last sent anything.
    var lastSeen: Date
    /// Readings are arriving. False from the moment the connection ends or goes silent.
    var answering = false
    /// "last seen 40 s ago", kept by the model's clock while it is not answering.
    var seen = ""
    /// The most it has been seen to draw and to move, which the power and network strips are drawn against.
    var peakWatts = 0.0
    var peakRate = 0.0
    @ObservationIgnored var link: MacsLink?

    init(hello: MacHello, lastSeen: Date = Date()) {
        id = hello.id
        self.hello = hello
        self.lastSeen = lastSeen
    }

    func take(_ reading: MacReading, at time: Date = Date()) {
        self.reading = reading
        lastSeen = time
        if !answering { answering = true }
        if !seen.isEmpty { seen = "" }
        peakWatts = max(peakWatts, reading.watts ?? 0)
        peakRate = max(peakRate, reading.down + reading.up)
    }
}

/// The user's other Macs, found on the local network, and this Mac shown to them.
///
/// Off until the user switches it on. Then this Mac listens, advertised over Bonjour, and that is all it does
/// until another Mac connects: readings are sent only down open connections, and this Mac looks for the others
/// and connects to them only while its Macs page is on screen.
@MainActor
@Observable
final class MacsModel {
    private(set) var isOn: Bool
    /// "KQ4M-7TXA-9HWE". Empty until the feature is first switched on.
    private(set) var code: String
    /// The other Macs, in the order they were found.
    private(set) var peers: [MacPeer] = []
    /// What the sidebar shows beside "Macs": how many others are in view, or nothing.
    private(set) var sidebarValue = ""
    /// Macs in sight that would not open a connection: they hold another code.
    private(set) var otherCodes = 0
    /// A Mac here answered in a way only a newer version of the app can read.
    private(set) var newerNearby = false
    /// macOS is not letting the app use the local network (Privacy & Security › Local Network).
    private(set) var blocked = false
    /// The listener could not start, and why.
    private(set) var problem: String?
    /// How many Macs are reading this one right now.
    private(set) var watcherCount = 0
    /// The page is on screen and the others are being looked for.
    private(set) var watching = false

    @ObservationIgnored let config: MacsConfig
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var id: String
    @ObservationIgnored private weak var monitor: SystemMonitor?

    // Showing this Mac.
    @ObservationIgnored private var listener: MacsListener?
    /// Connections that have opened, and those still in their handshake.
    @ObservationIgnored private var watchers: [MacsLink] = []
    @ObservationIgnored private var arriving: [MacsLink] = []
    @ObservationIgnored private var lastSent: Date?
    @ObservationIgnored private var listenTries = 0
    /// The port the listener got. For tests.
    @ObservationIgnored private(set) var listeningPort: UInt16?
    /// How many readings have gone out. For tests.
    @ObservationIgnored private(set) var readingsSent = 0
    private static let watcherLimit = 12

    // Watching the others.
    private enum TargetState: Equatable {
        case idle, connecting, refused, own
        case connected(String?)
        /// The Mac behind it is already connected another way.
        case duplicate(String)
    }

    private struct Target {
        var endpoint: NWEndpoint
        var state = TargetState.idle
        var link: MacsLink?
        var lastTry = Date.distantPast
        var listed = true
    }

    @ObservationIgnored private var targets: [String: Target] = [:]
    @ObservationIgnored private var browser: MacsBrowser?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    /// Each Macs page on screen, with the flag that says whether its window can be seen.
    @ObservationIgnored private var pages: [UUID: Page] = [:]

    private struct Page {
        var activity: ViewActivity?
        @MainActor var hidden: Bool { activity?.active == false }
    }
    @ObservationIgnored private var demo: MacsDemo?

    convenience init() {
        self.init(config: .fromEnvironment())
    }

    init(config: MacsConfig) {
        self.config = config
        isOn = config.on ?? (config.demo ? true : defaults.bool(forKey: "macsOn"))
        code = config.demo ? MacsDemo.code : config.code ?? defaults.string(forKey: "macsCode").flatMap(MacsCode.normalized) ?? ""
        // Two test copies on one Mac share the saved id and would each take the other for itself, so a trial
        // run gets an id of its own.
        id = config.id ?? (config.trial ? MacsIdentity.newID() : defaults.string(forKey: "macsID") ?? "")
        if isOn { prepare() }
    }

    /// The name this Mac is advertised under: part of its id, which says nothing about it. Its real name only
    /// travels inside a connection, to a Mac that holds the code.
    private var serviceName: String { String(id.prefix(12)) }

    /// What this Mac says it is. Asking for the Mac's name is a round trip to another process, so the answer is
    /// kept and asked for again only when a page opens or a Mac connects.
    var hello: MacHello {
        if let known, known.id == id { return known }
        let made = MacsIdentity.hello(id: id, name: config.demo ? MacsDemo.thisMac : config.name)
        known = made
        return made
    }

    @ObservationIgnored private var known: MacHello?

    // MARK: Switching it on and off

    /// At launch. Does nothing on the network unless the user has switched this on.
    func start(models: AppModels) {
        guard monitor == nil else { return }
        monitor = models.monitor
        models.monitor.addObserver { [weak self] snapshot in self?.serve(snapshot) }
        if isOn { beginListening() }
    }

    /// Makes the code and the id the first time they are needed.
    private func prepare() {
        if code.isEmpty {
            code = MacsCode.make()
            save { $0.set(code, forKey: "macsCode") }
        }
        if id.isEmpty {
            id = MacsIdentity.newID()
            save { $0.set(id, forKey: "macsID") }
        }
    }

    /// Debug: DOTMETER_MACS_LOG=1 prints what happens on the network side, one line an event.
    private static let logging = ProcessInfo.processInfo.environment["DOTMETER_MACS_LOG"] == "1"

    private func log(_ text: @autoclosure () -> String) {
        guard Self.logging else { return }
        print("MACS \(text())")
        fflush(stdout)
    }

    private func save(_ write: (UserDefaults) -> Void) {
        if !config.trial { write(defaults) }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        save { $0.set(on, forKey: "macsOn") }
        if on {
            prepare()
            beginListening()
        } else {
            endListening()
            endWatching(forget: true)
            blocked = false
            problem = nil
        }
        reconcile()
    }

    /// Takes a code typed from another Mac. False when it cannot be a code.
    @discardableResult
    func useCode(_ text: String) -> Bool {
        guard let typed = MacsCode.normalized(text) else { return false }
        if typed != code { change(to: typed) }
        return true
    }

    /// A fresh code, when the old one has been seen by someone it should not have been.
    func newCode() { change(to: MacsCode.make()) }

    private func change(to new: String) {
        guard !config.demo else { return }
        code = new
        save { $0.set(new, forKey: "macsCode") }
        guard isOn else { return }
        // Everything open was opened with the old key. Start again with the new one.
        endListening()
        endWatching(forget: true)
        beginListening()
        reconcile()
    }

    // MARK: Showing this Mac to the others

    private func beginListening() {
        guard isOn, listener == nil, monitor != nil, !config.demo else { return }
        let place: MacsListener.Place
        if let port = config.loopback {
            place = .loopback(port)
        } else if config.offline {
            // Told to connect straight to a peer and given no port of its own: this run only watches.
            return
        } else {
            place = .network(service: serviceName)
        }
        guard let listener = MacsListener(code: code, place: place) else {
            problem = "This Mac could not start listening for the others."
            return
        }
        listener.onLink = { [weak self] link in self?.arrived(link) }
        listener.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready(let port):
                self.listeningPort = port
                self.problem = nil
                self.listenTries = 0
                self.log("listening on port \(port)\(place == .loopback(self.config.loopback ?? 0) ? ", this Mac only, not advertised" : ", advertised as \(self.serviceName)")")
                if case .network = place { self.blocked = false }
            case .blocked:
                self.blocked = true
                self.log("listener blocked: macOS is not allowing the local network")
            case .failed(let why):
                self.log("listener failed: \(why)")
                // Said on the page only once it has failed a few times running: the first failure after a
                // change of code is the old listener still letting go.
                if self.listenTries >= 2 { self.problem = "This Mac could not start listening for the others (\(why))." }
                // A listener that has failed stays failed. Put it away and try a new one: soon the first time
                // (a port just given up takes a moment to come free), then less and less often.
                self.endListening()
                let wait = min(15, 0.5 * pow(2, Double(self.listenTries)))
                self.listenTries += 1
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    self?.beginListening()
                }
            case .starting:
                break
            }
        }
        self.listener = listener
        listener.start()
    }

    private func endListening() {
        listener?.stop()
        listener = nil
        listeningPort = nil
        for link in watchers + arriving { link.onEnd = nil; link.close() }
        watchers = []
        arriving = []
        served()
    }

    /// Another Mac has connected. Until its handshake is through it has proved nothing and is told nothing.
    private func arrived(_ link: MacsLink) {
        guard watchers.count + arriving.count < Self.watcherLimit else {
            link.close()
            return
        }
        arriving.append(link)
        known = nil
        link.onReady = { [weak self, weak link] in
            guard let self, let link else { return }
            self.arriving.removeAll { $0 === link }
            self.watchers.append(link)
            link.send(.hello(self.hello))
            // Its card should fill at once, not at the next reading.
            if let latest = self.monitor?.latest { link.send(.reading(MacReading(snapshot: latest, every: self.pace))) }
            self.served()
            self.log("a Mac connected: \(self.watchers.count) watching")
        }
        link.onEnd = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.arriving.removeAll { $0 === link }
            let was = self.watchers.count
            self.watchers.removeAll { $0 === link }
            self.served()
            self.log(was == self.watchers.count ? "a connection was turned away at the handshake" : "a Mac left: \(self.watchers.count) watching")
        }
        link.start()
    }

    /// The readings keep their live pace for exactly as long as a Mac is watching.
    private func served() {
        if watcherCount != watchers.count { watcherCount = watchers.count }
        monitor?.setBackgroundLive("macs", on: !watchers.isEmpty, graphics: true)
        if watchers.isEmpty { lastSent = nil }
    }

    /// Seconds between readings, as the other side should expect them.
    private var pace: Double {
        max(AppSettings.shared.refreshInterval, monitor?.panelVisible == true ? 0 : 2)
    }

    /// Every reading the monitor takes comes through here. With nobody watching it costs one comparison.
    private func serve(_ snapshot: Snapshot) {
        guard !watchers.isEmpty || !arriving.isEmpty else { return }
        let now = Date()
        // A watcher that has gone silent, or a handshake that never finished, is let go.
        for link in watchers where now.timeIntervalSince(link.lastHeard) > config.timing.watcherTimeout { link.close() }
        for link in arriving where now.timeIntervalSince(link.started) > config.timing.connectTimeout { link.close() }
        guard !watchers.isEmpty else { return }
        let every = lastSent.map { min(max(now.timeIntervalSince($0), 0.5), 30) } ?? pace
        lastSent = now
        let line = MacsWire.line(.reading(MacReading(snapshot: snapshot, every: (every * 10).rounded() / 10)))
        // One that is not taking what it is sent gets no more until it has caught up.
        for link in watchers where link.unsent < 2 { link.send(line) }
        readingsSent += 1
        log("reading \(readingsSent) sent to \(watchers.count), \(line.count) bytes")
    }

    // MARK: Watching the others

    /// A Macs page has come on screen. `activity` says whether its window can be seen.
    func pageAppeared(_ token: UUID, activity: ViewActivity?) {
        if pages[token] == nil { known = nil }
        pages[token] = Page(activity: activity)
        follow(activity)
        reconcile()
    }

    func pageDisappeared(_ token: UUID) {
        pages[token] = nil
        reconcile()
    }

    /// A window that is closed is released without its views being told, so the page cannot be relied on to say
    /// it has gone. The window's own flag can: when it changes, pages on hidden windows are struck off.
    private func follow(_ activity: ViewActivity?) {
        guard let activity else { return }
        withObservationTracking {
            _ = activity.active
        } onChange: { [weak self, weak activity] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                if self.pages.values.contains(where: { $0.activity === activity }) { self.follow(activity) }
            }
        }
    }

    /// Looks for the others exactly while the feature is on and a page that shows them can be seen.
    private func reconcile() {
        pages = pages.filter { !$0.value.hidden }
        let wanted = isOn && !pages.isEmpty
        if wanted && !watching { beginWatching() } else if !wanted && watching { endWatching(forget: false) }
    }

    private func beginWatching() {
        watching = true
        let now = Date()
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > config.timing.dropAfter }
        if config.demo {
            let demo = MacsDemo()
            self.demo = demo
            peers = demo.peers(at: now)
        } else if !config.peers.isEmpty {
            for peer in config.peers {
                guard let port = NWEndpoint.Port(rawValue: peer.port) else { continue }
                targets["\(peer.host):\(peer.port)"] = Target(endpoint: .hostPort(host: NWEndpoint.Host(peer.host), port: port))
            }
        } else if !config.offline {
            let browser = MacsBrowser()
            browser.onResults = { [weak self] found in self?.listed(found) }
            browser.onBlocked = { [weak self] blocked in self?.blocked = blocked }
            self.browser = browser
            browser.start()
        }
        // Which app is busiest comes from the process list, which is read every ten seconds on this page and
        // names nobody on its first pass (load is a difference between two). If it has no answer yet, ask once.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let monitor = self?.monitor, self?.watching == true, monitor.latest?.apps.contains(where: { $0.cpu > 0.001 }) != true else { return }
            await monitor.refreshNow(full: true)
        }
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops looking and closes every connection this Mac opened. `forget` also empties the list, for when the
    /// feature goes off or the code changes; otherwise the Macs stay listed, dimmed, for when the page comes back.
    private func endWatching(forget: Bool) {
        clock?.cancel()
        clock = nil
        browser?.stop()
        browser = nil
        for (_, target) in targets { target.link?.onEnd = nil; target.link?.close() }
        targets = [:]
        demo = nil
        for peer in peers {
            peer.link = nil
            if peer.answering { peer.answering = false }
        }
        if forget || config.demo { peers = [] }
        if otherCodes != 0 { otherCodes = 0 }
        newerNearby = false
        watching = false
        count()
    }

    /// What Bonjour has in sight now.
    private func listed(_ found: [String: NWEndpoint]) {
        for (name, endpoint) in found where name != serviceName {
            if targets[name] == nil {
                targets[name] = Target(endpoint: endpoint)
            } else {
                targets[name]?.endpoint = endpoint
                targets[name]?.listed = true
            }
        }
        for name in targets.keys where found[name] == nil {
            // An advertisement that has gone with nothing open to it is forgotten. One with a connection still
            // open stays until that ends: a Mac can go on answering for a moment after it stops advertising.
            if targets[name]?.link == nil { targets[name] = nil } else { targets[name]?.listed = false }
        }
        tick()
    }

    /// Once a second while the page is on screen: try what is not connected, say this Mac is still watching,
    /// and notice who has gone quiet.
    private func tick() {
        guard watching else { return }
        let now = Date(), timing = config.timing
        if pages.values.contains(where: { $0.hidden }) {
            reconcile()
            guard watching else { return }
        }
        if let demo {
            demo.advance(peers, at: now)
        }
        for (key, target) in targets {
            let waited = now.timeIntervalSince(target.lastTry)
            switch target.state {
            case .idle:
                if !target.listed { targets[key] = nil } else if waited >= timing.reconnect { connect(key) }
            case .refused:
                if waited >= timing.refusedRetry { connect(key) }
            case .duplicate(let peer):
                if waited >= timing.reconnect, peers.first(where: { $0.id == peer })?.link == nil { connect(key) }
            case .connecting:
                if waited >= timing.connectTimeout { target.link?.close() }
            case .connected, .own:
                break
            }
        }
        if now.timeIntervalSince(lastHeartbeat) >= timing.heartbeat {
            lastHeartbeat = now
            let line = MacsWire.line(.watching)
            for target in targets.values {
                if case .connected = target.state, let link = target.link, link.unsent < 2 { link.send(line) }
            }
        }
        for peer in peers {
            let silent = now.timeIntervalSince(peer.lastSeen)
            if peer.answering, silent > max(timing.quietFloor, (peer.reading?.every ?? 2) * timing.quietAfterReadings) {
                peer.answering = false
                log("\(peer.hello.name) has sent nothing for \(String(format: "%.1f", silent)) s: not answering")
                // Nothing has come down this connection for too long. A new one is the quickest way to find out
                // whether the Mac is still there.
                peer.link?.close()
            }
            let seen = peer.answering ? "" : Self.seen(silent)
            if peer.seen != seen { peer.seen = seen }
        }
        if peers.contains(where: { !$0.answering && now.timeIntervalSince($0.lastSeen) > timing.dropAfter }) {
            peers.removeAll { !$0.answering && now.timeIntervalSince($0.lastSeen) > timing.dropAfter }
        }
        count()
    }

    /// "last seen 40 s ago", in steps coarse enough that a dimmed card is not redrawn every second.
    static func seen(_ seconds: Double) -> String {
        if seconds < 5 { return "last seen just now" }
        if seconds < 60 { return "last seen \(Int(seconds / 5) * 5) s ago" }
        return "last seen \(Format.duration(seconds)) ago"
    }

    private func connect(_ key: String) {
        guard let target = targets[key], target.link == nil else { return }
        let link = MacsLink(NWConnection(to: target.endpoint, using: MacsTransport.parameters(code: code)))
        targets[key]?.link = link
        targets[key]?.state = .connecting
        targets[key]?.lastTry = Date()
        link.onReady = { [weak self, weak link] in
            guard let self, let link, self.targets[key]?.link === link else { return }
            self.targets[key]?.state = .connected(nil)
            link.send(.hello(self.hello))
            self.count()
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, self.targets[key]?.link === link else { return }
            self.heard(message, from: key, link)
        }
        link.onEnd = { [weak self, weak link] end in
            guard let self, let link, self.targets[key]?.link === link else { return }
            self.targets[key]?.link = nil
            self.targets[key]?.lastTry = Date()
            self.log("\(key): \(end)\(link.lastError.map { " (\($0))" } ?? "")")
            switch self.targets[key]?.state {
            case .own, .duplicate: break
            default: self.targets[key]?.state = end == .refused ? .refused : .idle
            }
            if let peer = self.peers.first(where: { $0.link === link }) {
                peer.link = nil
                if peer.answering { self.log("\(peer.hello.name): the connection ended, not answering") }
                peer.answering = false
                peer.seen = Self.seen(Date().timeIntervalSince(peer.lastSeen))
            }
            self.count()
        }
        link.start()
    }

    private func heard(_ message: MacsWire.Message, from key: String, _ link: MacsLink) {
        switch message {
        case .hello(let hello):
            if hello.id == id {
                // This Mac's own advertisement, reached by an address the name did not give away.
                targets[key]?.state = .own
                link.close()
                return
            }
            if let known = peers.first(where: { $0.id == hello.id }) {
                if let other = known.link, other !== link, !other.ended {
                    targets[key]?.state = .duplicate(hello.id)
                    link.close()
                    return
                }
                known.hello = hello
                known.link = link
            } else {
                let peer = MacPeer(hello: hello)
                peer.link = link
                peers.append(peer)
            }
            targets[key]?.state = .connected(hello.id)
            log("\(key): hello from \(hello.name), \(hello.model), \(hello.chip), \(App.name) \(hello.app)")
        case .reading(let reading):
            peers.first { $0.link === link }?.take(reading)
            log("\(key): reading, processor \(Format.percent(reading.cpu)), \(reading.apps.count) apps, every \(reading.every) s")
            count()
        case .tooNew:
            if !newerNearby { newerNearby = true }
        case .watching, .unknown:
            break
        }
    }

    /// The figures that others read: set only when they change, so nothing is redrawn for a reading that
    /// changes neither.
    private func count() {
        let answering = peers.filter(\.answering).count
        let value = watching && answering > 0 ? "\(answering) \(answering == 1 ? "Mac" : "Macs")" : ""
        if sidebarValue != value { sidebarValue = value }
        let refused = targets.values.filter { $0.state == .refused }.count
        if otherCodes != refused { otherCodes = refused }
    }

    /// The other Macs' figures in words, for Explain.
    func summary() -> String? {
        let lines = peers.compactMap { peer -> String? in
            guard let r = peer.reading else { return nil }
            var parts = [
                "processor \(Format.percent(r.cpu))",
                r.gpu.map { "graphics \(Format.percent($0))" },
                "memory \(Format.bytes(r.memoryUsed)) of \(Format.bytes(r.memoryTotal)), \(r.memoryPressure.title.lowercased()) pressure",
                r.temperature.map { "hottest sensor \(Format.temperature($0))C" },
                r.watts.map { String(format: "drawing %.0f W", $0) },
                "network down \(Format.rate(r.down)) up \(Format.rate(r.up))",
                "disk \(Format.bytes(r.diskFree)) free of \(Format.bytes(r.diskTotal))",
                r.battery.map { "battery \(Format.percent($0.charge))\($0.charging ? " charging" : ($0.plugged ? " plugged in" : " on battery"))" },
                "up \(Format.duration(r.uptime))",
                "state: \(r.severityLevel.title.lowercased())",
            ].compactMap { $0 }
            if !r.apps.isEmpty { parts.append("busiest apps: " + r.apps.map { "\($0.name) \(Format.cpu($0.cpu))" }.joined(separator: ", ")) }
            return "\(peer.hello.name) (\(peer.hello.model), \(peer.hello.chip))\(peer.answering ? "" : ", not answering, \(peer.seen)"): " + parts.joined(separator: "; ")
        }
        return lines.isEmpty ? nil : "The user's other Macs on this network, as each last reported:\n" + lines.joined(separator: "\n")
    }
}
