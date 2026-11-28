import SwiftUI

/// What is noted in the Timeline without being a reading of the machine: an app using the microphone or the
/// camera, and an app that crashed.
///
/// Nothing here polls. Core Audio and CoreMediaIO say when a process starts or stops recording and when a
/// camera comes on, and the file system says when macOS has written a crash report. A look every ten seconds
/// stands behind the first two, in case a change was never announced.
@MainActor
@Observable
final class ActivityWatch {
    /// The apps using the microphone right now, by name. nil when nothing is; empty when something is and
    /// macOS does not say what.
    private(set) var microphone: [String]?
    private(set) var cameraOn = false

    @ObservationIgnored private var started = false
    @ObservationIgnored private var microphoneSource: MicrophoneSource?
    @ObservationIgnored private var cameraSource: CameraSource?
    @ObservationIgnored private var microphoneLog: UseLog?
    @ObservationIgnored private var cameraLog: UseLog?
    @ObservationIgnored private var crashLog: CrashLog?
    @ObservationIgnored private var crashFolders: CrashFolders?
    @ObservationIgnored private var slowCheck: DispatchSourceTimer?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var wake: Date?
    @ObservationIgnored private var looks = 0

    private static let environment = ProcessInfo.processInfo.environment
    /// Debug: DOTMETER_LOG_WATCH=1 prints every change the watch sees and every look it takes.
    static let logs = environment["DOTMETER_LOG_WATCH"] == "1"
    /// How often the microphone and the camera are looked at whether or not anything was announced.
    static let slowInterval = 10

    static func log(_ text: @autoclosure () -> String) {
        guard logs else { return }
        print("WATCH " + text())
        fflush(stdout)
    }

    /// At launch. Watches for as long as the app runs.
    func start(models: AppModels) {
        guard !started else { return }
        started = true
        let environment = Self.environment
        // Debug: DOTMETER_WATCH_DEMO=mic|camera|both pretends something is in use and watches nothing.
        // DOTMETER_WATCH_DEMO_APP names the app that is pretended to be recording.
        if let demo = environment["DOTMETER_WATCH_DEMO"] {
            if demo == "mic" || demo == "both" { microphone = [environment["DOTMETER_WATCH_DEMO_APP"] ?? "FaceTime"] }
            if demo == "camera" || demo == "both" { cameraOn = true }
            return
        }
        // Debug: DOTMETER_WATCH=off. A run on made-up data is left alone too, so nothing real shows up in it.
        guard environment["DOTMETER_WATCH"] != "off", !TimelineStore.demo, !AppsDemo.on else {
            Self.log("off")
            return
        }
        let store = models.timeline
        for event in store.events {
            if let summary = ActivityWords.settled(event) { store.update(event.id) { $0.summary = summary } }
        }

        // Debug: DOTMETER_WATCH_MIC=devices asks the input devices, as on a system older than 14.2.
        let microphoneSource = MicrophoneSource(forceDevices: environment["DOTMETER_WATCH_MIC"] == "devices")
        let cameraSource = CameraSource()
        let microphoneLog = UseLog(kind: .microphone, store: store), cameraLog = UseLog(kind: .camera, store: store)
        microphoneLog.began = { AlertCenter.shared.announce($0) }
        cameraLog.began = { AlertCenter.shared.announce($0) }
        microphoneSource.changed = { [weak self] in self?.lookSoon() }
        cameraSource.changed = { [weak self] in self?.lookSoon() }
        microphoneSource.start()
        cameraSource.start()
        self.microphoneSource = microphoneSource
        self.cameraSource = cameraSource
        self.microphoneLog = microphoneLog
        self.cameraLog = cameraLog
        look()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(Self.slowInterval), repeating: .seconds(Self.slowInterval), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.look(slow: true) } }
        timer.resume()
        slowCheck = timer

        // Debug: DOTMETER_CRASH_FOLDER reads reports from that folder instead of the real ones.
        let crashLog = CrashLog(store: store)
        let folders = CrashFolders(folders: environment["DOTMETER_CRASH_FOLDER"].map { [$0] } ?? CrashFolders.standard)
        folders.found = { reports, atLaunch in
            let now = Date()
            let begun = crashLog.take(reports, now: now)
            if !begun.isEmpty { Self.log("crashes: \(begun.count) new \(begun.count == 1 ? "event" : "events")\(atLaunch ? " from before launch" : "")") }
            // What happened while the app was not running is written down and not announced.
            guard !atLaunch else { return }
            for event in begun where now.timeIntervalSince(event.start) < 600 { AlertCenter.shared.announce(event) }
        }
        folders.start()
        self.crashLog = crashLog
        crashFolders = folders
        Self.log("on: microphone by \(microphoneSource.byProcess ? "process" : "device"), \(folders.watching) of \(folders.count) report folders watched")
    }

    /// Several things change at once when a call starts: one look after they have all been announced.
    private func lookSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.look()
            }
        }
    }

    /// `slow` is the look every ten seconds, which trusts nothing it was told: every process is asked again,
    /// unless no device that can record is running at all.
    private func look(slow: Bool = false) {
        guard let microphoneSource, let cameraSource, let microphoneLog, let cameraLog else { return }
        let now = Date()
        looks += 1

        let reading = microphoneSource.read(everything: slow && microphoneSource.worthAsking())
        var users = reading.processes.compactMap { ActivityApps.user(pid: $0.pid, bundleID: $0.bundleID) }
        if !microphoneSource.byProcess, reading.inUse { users = [ActivityUser(key: "microphone", name: nil, bundlePath: nil)] }
        let first = microphoneLog.update(users, at: now)
        let recording = microphoneLog.current
        let names = recording.isEmpty ? nil : recording.compactMap(\.name)
        if microphone != names {
            microphone = names
            Self.log("microphone: \(names.map { $0.isEmpty ? "in use" : $0.joined(separator: ", ") } ?? "free")")
        }

        let camera = cameraSource.read()
        let second = cameraLog.update(camera.running ? [ActivityUser(key: "camera", name: nil, bundlePath: nil)] : [], at: now)
        let on = !cameraLog.current.isEmpty
        if cameraOn != on {
            cameraOn = on
            Self.log("camera: \(on ? "on" : "off")")
        }
        if Self.logs, looks % 6 == 1 || reading.asked > 0 {
            Self.log("look \(looks): \(reading.asked) of \(reading.known) asked, \(reading.processes.count) recording, \(camera.devices) cameras, announced \(microphoneSource.fired) + \(cameraSource.fired) times")
        }

        // A use that has just begun is written down once it has lasted: come back at that moment.
        guard let next = [first, second].compactMap({ $0 }).min(), wake.map({ next < $0 }) ?? true else { return }
        wake = next
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next.timeIntervalSince(now) + 0.05)) { [weak self] in
            MainActor.assumeIsolated {
                self?.wake = nil
                self?.look()
            }
        }
    }
}

/// The line at the foot of the sidebar that says the microphone or the camera is in use right now, and by what.
/// Nothing when neither is.
struct ActivityNotice: View {
    @Environment(ActivityWatch.self) private var watch
    @State private var hovering = false

    var body: some View {
        let microphone = watch.microphone, camera = watch.cameraOn
        if microphone != nil || camera {
            let kinds: [TimelineEvent.Kind] = (camera ? [.camera] : []) + (microphone != nil ? [.microphone] : [])
            let apps = microphone ?? []
            let name = apps.first.map { apps.count > 1 ? "\($0) +\(apps.count - 1)" : $0 }
            let long = kinds.count == 2 ? "Camera, mic" : (camera ? "Camera" : "Microphone")
            Button { StatusController.shared?.show(.timeline) } label: {
                // The app is the news: the kind is shortened before the name is cut.
                ViewThatFits(in: .horizontal) {
                    row(kinds, title: long, name: name, cut: false)
                    row(kinds, title: kinds.count == 2 ? long : "Mic", name: name, cut: kinds.count == 2)
                    row(kinds, title: kinds.count == 2 ? long : "Mic", name: name, cut: true)
                }
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(RoundedRectangle(cornerRadius: 7.5, style: .continuous).fill(hovering ? PX.rowHover : PX.ghostHover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(Self.sentence(microphone: microphone, camera: camera))
        }
    }

    private func row(_ kinds: [TimelineEvent.Kind], title: String, name: String?, cut: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(kinds, id: \.self) { kind in
                    Circle()
                        .fill(kind.rgb.color())
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 18)
            .padding(.trailing, 9)
            Text(title)
                .font(PX.font(13, .medium))
                .tracking(PX.tracking(13))
                .foregroundStyle(PX.text)
                .fixedSize()
            Spacer(minLength: 8)
            if let name {
                Text(name)
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !cut, vertical: false)
            }
        }
    }

    private static func sentence(microphone: [String]?, camera: Bool) -> String {
        var parts: [String] = []
        if camera { parts.append("The camera is on") }
        if let microphone {
            switch microphone.count {
            case 0: parts.append("The microphone is in use")
            case 1: parts.append("\(microphone[0]) is using the microphone")
            default: parts.append("\(microphone.joined(separator: ", ")) are using the microphone")
            }
        }
        return parts.joined(separator: ". ") + ". Each use is noted in the Timeline."
    }
}
