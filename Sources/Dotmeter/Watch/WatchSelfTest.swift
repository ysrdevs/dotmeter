import CoreAudio
import Foundation

extension DebugTools {
    /// `--self-test watch`: the report headers, the week rule, repeats counted as one, nothing counted twice, and
    /// the rules for a use of the microphone, all on made-up reports in a folder of its own and a timeline file
    /// of its own. Then one real look at Core Audio and CoreMediaIO, which prints counts and no names.
    @MainActor
    static func watchSelfTest(models: AppModels) async {
        var checks = 0, failed = 0
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if !passed { failed += 1 }
            let extra = detail()
            print("\(passed ? "ok" : "FAILED") \(name)\(extra.isEmpty ? "" : " (\(extra))")")
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("dotmeter-watch-\(getpid())", isDirectory: true)
        let folder = root.appendingPathComponent("reports", isDirectory: true).path
        try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        setenv("DOTMETER_TIMELINE_PATH", root.appendingPathComponent("timeline.json").path, 1)

        // MARK: Report headers

        let now = Date()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        var serial = 0
        func header(_ app: String, bundle: String?, type: String = "309", ago: TimeInterval, extra: String = "") -> String {
            serial += 1
            let id = String(format: "00000000-0000-4000-8000-%012d", serial)
            return "{\"app_name\":\"\(app)\",\"timestamp\":\"\(stamp.string(from: now.addingTimeInterval(-ago)))\",\"bug_type\":\"\(type)\",\(bundle.map { "\"bundleID\":\"\($0)\"," } ?? "")\(extra)\"incident_id\":\"\(id)\",\"name\":\"\(app)\"}"
        }
        func write(_ name: String, _ first: String, body: String = "{\"exception\":{\"type\":\"EXC_BAD_ACCESS\"},\"threads\":[]}\n") {
            try? (first + "\n" + body).write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
        }
        let hour = 3600.0
        write("Sketchpad-1.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 3 * hour))
        write("Sketchpad-2.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 3 * hour - 600))
        write("Sketchpad-3.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 3 * hour - 1200))
        write("Sketchpad-4.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 3 * hour - 1800))
        write("Sketchpad-5.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 3 * hour - 4200))
        write("Ledger Helper-1.ips", header("Ledger Helper", bundle: "com.example.ledger.helper", ago: 3 * hour - 900))
        write("Ledger-hang.ips", header("Ledger", bundle: "com.example.ledger", type: "228", ago: 2 * hour))
        write("ExcUserFault_Ledger.ips", header("Ledger", bundle: "com.example.ledger", ago: hour, extra: "\"is_simulated\":1,"))
        write("builder-tool.ips", header("builder-tool", bundle: nil, ago: hour))
        write("Sketchpad-old.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 8 * 86_400))
        write("Sketchpad-ancient.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 30 * 86_400))
        try? manager.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: folder + "/Sketchpad-ancient.ips")
        write("Broken.ips", "this is not a header", body: header("Broken", bundle: "com.example.broken", ago: hour) + "\n")
        write(".Sketchpad-partial.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 60))
        write("notes.txt", header("Notes", bundle: "com.example.notes", ago: hour))
        write("Ledger.cpu_resource.diag", "Date/Time:        2026-01-01 10:00:00.000 -0500")

        let crash = CrashReport.read(folder + "/Sketchpad-1.ips")
        check("a crash report's header is decoded", crash?.app == "Sketchpad" && crash?.bundleID == "com.example.sketchpad" && crash?.bugType == "309" && crash?.isCrash == true)
        check("its time is the crash's own, to the second", crash.map { abs($0.time.timeIntervalSince(now.addingTimeInterval(-3 * hour))) < 1 } ?? false)
        check("its identifier is the report's incident", crash?.id.hasPrefix("00000000-0000-4000-8000-") == true)
        let hang = CrashReport.read(folder + "/Ledger-hang.ips")
        check("a report of another kind (a hang) is decoded and is not a crash", hang?.app == "Ledger" && hang?.isCrash == false)
        check("a fault the process lived through is not a crash", CrashReport.read(folder + "/ExcUserFault_Ledger.ips")?.isCrash == false)
        check("a first line that is not a header gives nothing", CrashReport.read(folder + "/Broken.ips") == nil)
        check("a number for the kind reads like a string", CrashReport.decode(header: Data("{\"bug_type\":309,\"timestamp\":\"2026-11-23 08:04:48.00 -0500\",\"name\":\"X\"}".utf8), fileName: "x.ips")?.isCrash == true)
        check("a header with no time gives nothing", CrashReport.decode(header: Data("{\"bug_type\":\"309\",\"app_name\":\"X\"}".utf8), fileName: "x.ips") == nil)
        check("a report with no identifier goes by its file name", CrashReport.decode(header: Data("{\"bug_type\":\"309\",\"timestamp\":\"2026-11-23 08:04:48 -0500\",\"app_name\":\"X\"}".utf8), fileName: "x.ips")?.id == "x.ips")

        let since = now.addingTimeInterval(-CrashLog.keep)
        let first = CrashReport.pass(folders: [folder, root.appendingPathComponent("missing").path], skipping: [], since: since, now: now)
        check("the folder gives the reports of the last seven days", first.reports.count == 9, "\(first.reports.count) reports")
        check("files that are not reports are not opened", !first.done.contains { $0.hasSuffix(".txt") || $0.hasSuffix(".diag") || $0.contains("/.") })
        check("a report older than a week is left out", !first.reports.contains { $0.time < since } && first.done.contains { $0.hasSuffix("Sketchpad-old.ips") })
        check("an old file is passed over unread", first.done.contains { $0.hasSuffix("Sketchpad-ancient.ips") })
        check("a broken file just written is tried again", first.again.contains { $0.hasSuffix("Broken.ips") })
        let missing = CrashReport.pass(folders: [root.appendingPathComponent("missing").path], skipping: [], since: since, now: now)
        check("a folder that is not there is passed over", missing.reports.isEmpty && missing.done.isEmpty && missing.again.isEmpty)

        // MARK: Events from reports

        let store = TimelineStore()
        // Who a report is about, without asking macOS which apps are installed: the helper belongs to its app.
        let cast: (CrashReport) -> ActivityUser? = { report in
            guard let bundle = report.bundleID else { return nil }
            let name = bundle.contains("ledger") ? "Ledger" : report.app
            return ActivityUser(key: bundle, name: name, bundlePath: nil)
        }
        let later = TimelineEvent(kind: .offline, start: now.addingTimeInterval(-60), end: now, summary: "made up")
        store.begin(later)
        let log = CrashLog(store: store, resolve: cast)
        let begun = log.take(first.reports, now: now)
        let crashes = store.events.filter { $0.kind == .crash }
        let sketch = crashes.filter { $0.apps.first?.name == "Sketchpad" }
        check("four crashes inside an hour are one event", sketch.first?.count == 4 && sketch.first?.summary == "Sketchpad crashed 4 times", sketch.first?.summary ?? "none")
        check("it runs from the first crash to the last", sketch.first.map { abs($0.start.timeIntervalSince(now.addingTimeInterval(-3 * hour))) < 1 && abs($0.duration - 1800) < 1 } ?? false)
        check("a crash more than an hour after the first is a new event", sketch.count == 2 && sketch.last?.count == nil && sketch.last?.summary == "Sketchpad crashed")
        check("a helper's crash is its app's", crashes.contains { $0.summary == "Ledger crashed" })
        check("the hang, the fault and the tool with no identifier made no event", crashes.count == 3 && begun.count == 3, "\(crashes.count) events")
        check("a crash event is over the moment it happened", crashes.allSatisfy { $0.end != nil })
        check("events stay in the order they began", zip(store.events, store.events.dropFirst()).allSatisfy { $0.start <= $1.start } && store.events.last?.id == later.id)

        let second = CrashReport.pass(folders: [folder], skipping: [], since: since, now: now)
        let again = log.take(second.reports, now: now)
        check("a second pass over the folder adds nothing", again.isEmpty && store.events.filter { $0.kind == .crash }.count == 3 && store.events.first { $0.count == 4 } != nil)
        check("a pass that skips what it has read opens nothing", CrashReport.pass(folders: [folder], skipping: Set(first.done + first.again), since: since, now: now).reports.isEmpty)

        store.saveNow()
        let reopened = TimelineStore()
        let relaunch = CrashLog(store: reopened, resolve: cast).take(second.reports, now: now)
        check("nor does the next launch", relaunch.isEmpty && reopened.events.filter { $0.kind == .crash }.count == 3, "\(reopened.crashReports.count) reports remembered")
        if let forgotten = reopened.events.first(where: { $0.count == 4 }) { reopened.remove(forgotten.id) }
        check("a forgotten event does not come back", CrashLog(store: reopened, resolve: cast).take(second.reports, now: now).isEmpty && reopened.events.filter { $0.kind == .crash }.count == 2)

        write("Sketchpad-6.ips", header("Sketchpad", bundle: "com.example.sketchpad", ago: 3 * hour - 4500))
        let third = CrashReport.pass(folders: [folder], skipping: Set(first.done), since: since, now: now)
        let news = log.take(third.reports, now: now)
        check("a new report joins the event its app has within the hour", news.isEmpty && store.events.contains { $0.summary == "Sketchpad crashed 2 times" })
        write("Easel-1.ips", header("Easel", bundle: "com.example.easel", ago: 5))
        let fourth = log.take(CrashReport.pass(folders: [folder], skipping: Set(first.done + third.done), since: since, now: now).reports, now: now)
        check("a new app's crash is a new event, to be announced", fourth.count == 1 && fourth.first?.summary == "Easel crashed")

        check("a report with no bundle identifier is not about an app", CrashLog.app(CrashReport(id: "a", app: "builder-tool", bundleID: nil, time: now, bugType: "309", simulated: false)) == nil)
        check("a piece of the system that is no app is left out", CrashLog.app(CrashReport(id: "b", app: "somethingd", bundleID: "com.apple.dotmeter.selftest.nothing", time: now, bugType: "309", simulated: false)) == nil)
        check("an app macOS does not know goes by the report's name", CrashLog.app(CrashReport(id: "c", app: "Sketchpad", bundleID: "com.example.dotmeter.selftest.sketchpad", time: now, bugType: "309", simulated: false))?.name == "Sketchpad")

        // MARK: Uses of the microphone, from a source that says what it is told to

        let uses = TimelineStore()
        let mic = UseLog(kind: .microphone, store: uses)
        var announced = 0
        mic.began = { _ in announced += 1 }
        let chat = ActivityUser(key: "/Applications/Chatter.app", name: "Chatter", bundlePath: "/Applications/Chatter.app")
        let memo = ActivityUser(key: "/Applications/Memo.app", name: "Memo", bundlePath: "/Applications/Memo.app")
        let t0 = now.addingTimeInterval(-7200)
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
        func events() -> [TimelineEvent] { uses.events.filter { $0.kind == .microphone } }

        let wake = mic.update([chat], at: at(0))
        check("a use is not written down the moment it starts", events().isEmpty && mic.current.isEmpty && wake == at(UseLog.minimum))
        mic.update([chat], at: at(2))
        check("after two seconds it is an event, begun when the use began", events().count == 1 && events().first?.start == at(0) && events().first?.end == nil && announced == 1)
        check("it names the app while it goes on", events().first?.summary == "Chatter is using the microphone" && mic.current == [chat] && events().first?.apps.first?.name == "Chatter")
        mic.update([], at: at(1860))
        check("it ends when the app stops", events().first?.end == at(1860) && events().first?.summary == "Chatter used the microphone for 31 minutes", events().first?.summary ?? "")
        mic.update([chat], at: at(1863))
        check("starting again within a few seconds carries the same event on", events().count == 1 && events().first?.end == nil && announced == 1)
        mic.update([], at: at(1900))
        check("and its end moves", events().count == 1 && events().first?.end == at(1900))
        mic.update([chat], at: at(1910))
        mic.update([chat], at: at(1913))
        mic.update([], at: at(1920))
        check("starting again later is a second event", events().count == 2 && events().last?.start == at(1910) && events().last?.summary == "Chatter used the microphone for 10 seconds" && announced == 2)
        mic.update([memo], at: at(2000))
        mic.update([], at: at(2001))
        mic.update([], at: at(2010))
        check("a use shorter than two seconds is dropped", events().count == 2 && announced == 2)
        mic.update([memo], at: at(2100))
        mic.update([memo, chat], at: at(2101))
        mic.update([memo, chat], at: at(2104))
        check("two apps at once are two events", events().count == 4 && Set(mic.current) == [memo, chat])
        mic.update([memo], at: at(2200))
        check("one stopping leaves the other going", events().filter { $0.end == nil }.count == 1 && mic.current == [memo])
        mic.update([], at: at(2300))

        let camera = UseLog(kind: .camera, store: uses)
        let lens = ActivityUser(key: "camera", name: nil, bundlePath: nil)
        camera.update([lens], at: at(3000))
        camera.update([lens], at: at(3003))
        camera.update([], at: at(3720))
        let shot = uses.events.last { $0.kind == .camera }
        check("the camera names no app", shot?.summary == "The camera was on for 12 minutes" && shot?.apps.isEmpty == true, shot?.summary ?? "none")
        let unnamed = UseLog(kind: .microphone, store: uses)
        let anyone = ActivityUser(key: "microphone", name: nil, bundlePath: nil)
        unnamed.update([anyone], at: at(4000))
        unnamed.update([anyone], at: at(4002))
        unnamed.update([], at: at(4000 + 2 * 3600 + 300))
        check("where macOS does not say who, neither does the event", events().last?.summary == "The microphone was in use for 2 hours 5 minutes" && events().last?.apps.isEmpty == true, events().last?.summary ?? "none")

        var open = TimelineEvent(kind: .microphone, start: at(0), end: at(95), summary: "Chatter is using the microphone")
        open.apps = [.init(name: "Chatter", bundlePath: nil, cpu: 0)]
        check("an event cut off by quitting is put in the past", ActivityWords.settled(open) == "Chatter used the microphone for 2 minutes" && ActivityWords.settled(later) == nil)
        check("spans read as words", ActivityWords.span(0.4) == "1 second" && ActivityWords.span(89) == "89 seconds" && ActivityWords.span(3600) == "1 hour" && ActivityWords.span(60 * 61) == "1 hour 1 minute")

        // MARK: Which app a process is

        check("a helper inside an app is that app", ActivityApps.user(path: "/Applications/Dotmeter Selftest Chatter.app/Contents/Frameworks/Chatter Helper.app/Contents/MacOS/Chatter Helper", bundleID: nil)?.name == "Dotmeter Selftest Chatter")
        check("a piece of the system that listens is left out", ActivityApps.user(path: "/usr/libexec/corespeechd", bundleID: nil) == nil && ActivityApps.user(path: "/System/Library/PrivateFrameworks/X.framework/xd", bundleID: "com.apple.xd") == nil)
        check("the one that carries FaceTime's calls is FaceTime", ActivityApps.user(path: "/usr/libexec/avconferenced", bundleID: nil)?.name == "FaceTime")
        check("a command-line tool goes by its own name", ActivityApps.user(path: "/opt/tools/bin/recorder", bundleID: nil)?.key == "proc:recorder")

        // MARK: Which devices are microphones

        let builtIn: AudioObjectID = 1, loopback: AudioObjectID = 2, speakers: AudioObjectID = 3, group: AudioObjectID = 4, taps: AudioObjectID = 5, mixed: AudioObjectID = 6
        let sound: (AudioObjectID) -> SoundDevice? = { device in
            switch device {
            case builtIn: return SoundDevice(transport: kAudioDeviceTransportTypeBuiltIn, hasInput: true)
            case loopback: return SoundDevice(transport: kAudioDeviceTransportTypeVirtual, hasInput: true)
            case speakers: return SoundDevice(transport: kAudioDeviceTransportTypeUSB, hasInput: false)
            case group: return SoundDevice(transport: kAudioDeviceTransportTypeAggregate, hasInput: true, parts: [speakers, builtIn])
            case taps: return SoundDevice(transport: kAudioDeviceTransportTypeAggregate, hasInput: true, parts: [])
            case mixed: return SoundDevice(transport: kAudioDeviceTransportTypeAggregate, hasInput: true, parts: [loopback, speakers])
            default: return nil
            }
        }
        check("a real input is a microphone, a made-up one that hands on the Mac's sound is not", SoundDevice.isMicrophone(builtIn, describe: sound) && !SoundDevice.isMicrophone(loopback, describe: sound) && !SoundDevice.isMicrophone(speakers, describe: sound))
        check("a group is one if it holds one", SoundDevice.isMicrophone(group, describe: sound) && !SoundDevice.isMicrophone(taps, describe: sound) && !SoundDevice.isMicrophone(mixed, describe: sound))
        check("a device that cannot be described counts", SoundDevice.isMicrophone(99, describe: sound))

        // MARK: This Mac, now

        let source = MicrophoneSource()
        var began = DispatchTime.now().uptimeNanoseconds
        var reading = source.read(everything: true)
        let micFirst = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        began = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { reading = source.read(everything: true) }
        let micTime = Double(DispatchTime.now().uptimeNanoseconds - began) / 20e6
        began = DispatchTime.now().uptimeNanoseconds
        var worth = false
        for _ in 0..<20 { worth = source.worthAsking() }
        let restTime = Double(DispatchTime.now().uptimeNanoseconds - began) / 20e6
        let apps = Set(reading.processes.compactMap { ActivityApps.user(pid: $0.pid, bundleID: $0.bundleID)?.key }).count
        print(String(format: "live: microphone read by %@, %d asked in %.2f ms (the first time %.2f ms): %d recording, %d of them apps", source.byProcess ? "process" : "device", reading.asked, micTime, micFirst, reading.processes.count, apps))
        print(String(format: "live: the slow check at rest: %.3f ms, a device that can record is %@", restTime, worth ? "running" : "not running"))
        let sounds = MicrophoneSource.deviceCounts()
        print("live: \(sounds.all) sound devices, \(sounds.recording) that can record")
        let devices = MicrophoneSource(forceDevices: true).read(everything: true)
        print("live: the way of older systems: \(devices.asked) input-only devices, microphone \(devices.inUse ? "in use" : "free")")
        began = DispatchTime.now().uptimeNanoseconds
        let lenses = CameraSource()
        var cameras = lenses.read()
        let cameraFirst = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        began = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { cameras = lenses.read() }
        print(String(format: "live: %d cameras read in %.2f ms (the first time %.2f ms): camera %@", cameras.devices, Double(DispatchTime.now().uptimeNanoseconds - began) / 20e6, cameraFirst, cameras.running ? "on" : "off"))
        check("the live read came back", reading.asked >= 0 && cameras.devices >= 0)

        print("watch: \(checks) checks, \(failed) failed")
    }
}
