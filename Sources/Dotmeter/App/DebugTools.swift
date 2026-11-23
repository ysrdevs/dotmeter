import AppKit
import DotmeterShared
import CDotmeter
import SwiftUI

/// `Dotmeter --dump` prints every reading to stdout; `Dotmeter --render out.png` renders the panel to PNGs (light + dark) for design review.
enum DebugTools {
    static func dump() {
        let collectors = Collectors()
        var options = CollectOptions()
        options.networkApps = 1
        _ = collectors.collect(options)
        // Per-app network rates need two readings a few seconds apart.
        let wait = CommandLine.arguments.contains("--net") ? 2.6 : 1.0
        Thread.sleep(forTimeInterval: wait)
        let s = collectors.collect(options)

        print("\(s.system.modelName) (\(s.system.modelIdentifier)) · \(s.system.chip) · \(Format.bytes(s.system.memoryTotal)) · \(s.system.osVersion)")
        print("CPU \(Format.percent(s.cpu.total)) (user \(Format.percent(s.cpu.user)), sys \(Format.percent(s.cpu.system))) · P\(s.cpu.performanceCores) E\(s.cpu.efficiencyCores) · load \(s.cpu.loadAverage)")
        print("Cores: " + s.cpu.perCore.map { String(Int($0 * 100)) }.joined(separator: " "))
        print("Memory used \(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total)) · app \(Format.bytes(s.memory.app)) wired \(Format.bytes(s.memory.wired)) compressed \(Format.bytes(s.memory.compressed)) · swap \(Format.bytes(s.memory.swapUsed)) · pressure \(s.memory.pressure.rawValue)")
        print("Thermal state \(s.thermal.state.rawValue) · speed limit \(s.thermal.cpuSpeedLimit.map(String.init) ?? "n/a")")
        for fan in s.thermal.fans { print("Fan \(fan.index): \(Int(fan.rpm)) rpm (\(Int(fan.minRPM))–\(Int(fan.maxRPM)), target \(fan.target.map { String(Int($0)) } ?? "-")) \(Format.percent(fan.percent))") }
        print("Hottest: \(s.thermal.hottest.map { "\($0.key) \(Format.temperature($0.celsius)) [\($0.group)]" } ?? "none") · CPU \(s.thermal.cpuTemperature.map(Format.temperature) ?? "-") · GPU \(s.thermal.gpuTemperature.map(Format.temperature) ?? "-")")
        print("Sensors (\(s.thermal.sensors.count)):")
        for sensor in s.thermal.sensors { print(String(format: "  %@  %5.1f°  %@", sensor.key, sensor.celsius, sensor.group)) }
        if let gpu = s.gpu {
            print("GPU \(gpu.model ?? "?") · \(gpu.cores ?? 0) cores · \(Format.percent(gpu.utilization)) renderer \(gpu.rendererUtilization.map(Format.percent) ?? "-") tiler \(gpu.tilerUtilization.map(Format.percent) ?? "-") · memory in use \(gpu.memoryInUse.map(Format.bytes) ?? "-") of \(gpu.memoryAllocated.map(Format.bytes) ?? "-") set aside")
            for app in s.apps.sorted(by: { $0.gpu > $1.gpu }).prefix(5) where app.gpu > 0.0005 { print(String(format: "  gpu %5.1f%%  %@", app.gpu * 100, app.name)) }
        }
        func watts(_ value: Double?) -> String { value.map { String(format: "%.1f W", $0) } ?? "-" }
        print("Power system \(watts(s.power.system)) · cpu \(watts(s.power.cpu)) gpu \(watts(s.power.gpu)) neural \(watts(s.power.neural)) memory \(watts(s.power.memory)) rest \(watts(s.power.rest)) · adapter \(watts(s.power.adapter)) · battery \(s.power.battery == nil ? "none" : "present")")
        let everyChannel = ProcessInfo.processInfo.environment["DOTMETER_LOG_POWER"] == "1"
        print("  channels: " + collectors.powerChannels.filter { everyChannel || $0.watts > 0.005 }.map { String(format: "%@ %.2f", $0.name, $0.watts) }.joined(separator: ", "))
        for app in s.apps.sorted(by: { $0.power > $1.power }).prefix(5) where app.power > 0.01 { print(String(format: "  power %5.2f W  %@", app.power, app.name)) }
        for app in s.apps.sorted(by: { $0.disk > $1.disk }).prefix(4) where app.disk > 1 { print("  disk ↓\(Format.rate(app.diskRead)) ↑\(Format.rate(app.diskWrite))  \(app.name)") }
        if let smc = SMC() {
            let keys = smc.allKeys().filter { $0.hasPrefix("P") }
            let readings = keys.compactMap { key -> String? in
                guard let value = smc.readDouble(key), value > 0.2, value < 2000 else { return nil }
                return String(format: "%@ %.1f", key, value)
            }
            print("  SMC power keys reading over 0.2: " + readings.joined(separator: ", "))
        }
        print("Disk free \(Format.bytes(s.disk.free)) · read \(Format.rate(s.disk.readBytesPerSecond)) write \(Format.rate(s.disk.writeBytesPerSecond))")
        print("Network down \(Format.rate(s.network.inBytesPerSecond)) up \(Format.rate(s.network.outBytesPerSecond)) · \(Format.data(s.network.inBytes)) in, \(Format.data(s.network.outBytes)) out \(s.network.countingLabel)")
        print("  primary \(s.network.primary ?? "none") · router \(s.network.router ?? "-") · dns \(s.network.dns.joined(separator: ", ")) · search \(s.network.searchDomains.joined(separator: ", ")) · \(s.network.configMethod ?? "-")")
        if let wifi = s.network.wifi {
            print("  Wi-Fi \(wifi.interface): name \(wifi.ssid == nil ? "withheld" : "visible") · signal \(wifi.rssi.map { "\($0) dBm" } ?? "not reported") (\(wifi.qualityTitle ?? "-")), noise \(wifi.noise) · ch \(wifi.channel) \(wifi.band) \(wifi.width ?? "") · \(wifi.standard) · \(Int(wifi.transmitRate)) Mb/s · \(wifi.security) · \(wifi.country ?? "-")")
        } else {
            print("  Wi-Fi: not joined")
        }
        for i in s.network.interfaces {
            let link = i.linkSpeed.map { Format.linkSpeed($0) } ?? "-"
            print("  \(i.isActive ? "●" : "○") \(i.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(i.title.padding(toLength: 24, withPad: " ", startingAt: 0)) \(i.kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(i.address ?? "-") mask \(i.netmask ?? "-") v6 \(i.ipv6.count) mtu \(i.mtu) link \(link) ↓\(Format.rate(i.inRate)) ↑\(Format.rate(i.outRate)) total \(Format.data(i.inBytes))/\(Format.data(i.outBytes))")
        }
        if s.network.appsMeasured {
            print("  per app (\(s.network.apps.count) with open connections):")
            for app in s.network.apps.prefix(10) {
                print(String(format: "    ↓%10@ ↑%10@  %9@  %2d  %@", Format.rate(app.inRate), Format.rate(app.outRate), Format.data(app.bytes), app.processes.count, app.name))
            }
        } else {
            print("  per app: not measured (run with --dump --net)")
        }
        if let kernel = s.processes.first(where: { $0.pid == 0 }) { print("kernel_task: \(Format.cpu(kernel.cpu)) · \(Format.bytes(kernel.memory))") } else { print("kernel_task: NOT VISIBLE") }
        print("Top apps (\(s.apps.count) groups, \(s.processes.count) processes):")
        for app in s.apps.prefix(15) {
            print(String(format: "  %6@  %9@  %3d  %@", Format.cpu(app.cpu), Format.bytes(app.memory), app.processCount, app.name))
            for child in app.children.prefix(3) where app.processCount > 1 { print("           ↳ \(child.name) \(Format.cpu(child.cpu))") }
        }

        if let smc = SMC() {
            let keys = smc.allKeys()
            print("SMC keys: \(keys.count)")
            for key in keys where key.hasPrefix("T") || key.hasPrefix("F") {
                guard let info = smc.info(for: key) else { continue }
                let value = smc.readDouble(key).map { String(format: "%.2f", $0) } ?? "?"
                print("  \(key) [\(info.type)] \(value)")
            }
        }
    }

    /// `Dotmeter --net-test`: the byte-counter arithmetic, on the cases that matter.
    static func netTest() {
        let wifi = 150e6 * 1.5 * 2   // a 1.2 Gb/s link over two seconds, with headroom
        let cases: [(String, UInt64, UInt64, UInt64)] = [
            ("ordinary growth", 1_000_000, 3_500_000, 2_500_000),
            ("wrap at 4 GB (what this Mac's Wi-Fi did)", 4_290_000_000, 30_000_000, 34_967_296),
            ("interface reset from 3 GB", 3_000_000_000, 100, 0),
            ("interface reset from 500 MB", 528_000_000, 0, 0),
            ("a true 64-bit counter going backwards", 9_000_000_000, 10, 0),
        ]
        var failed = 0
        for (name, old, new, expected) in cases {
            let got = NetworkSampler.advance(from: old, to: new, atMost: wifi)
            if got != expected { failed += 1 }
            print("\(got == expected ? "ok  " : "FAIL") \(name): \(old) -> \(new) counts as \(got) (expected \(expected))")
        }
        // The external address is read from the `ip=` line of a plain-text page, and only if it looks like one.
        let pages: [(String, String, String?)] = [
            ("an IPv4 answer", "fl=1\nh=1.1.1.1\nip=203.0.113.42\nts=1.0\n", "203.0.113.42"),
            ("an IPv6 answer", "h=one\nip=2001:db8::7\n", "2001:db8::7"),
            ("no ip line", "fl=1\nh=1.1.1.1\n", nil),
            ("something that is not an address", "ip=<script>alert(1)</script>\n", nil),
            ("an empty answer", "", nil),
        ]
        for (name, page, expected) in pages {
            let got = PublicAddress.parse(page)
            if got != expected { failed += 1 }
            print("\(got == expected ? "ok  " : "FAIL") external address from \(name): \(got ?? "none")")
        }
        // Listening sockets, as nettop prints them: both families of one listener are one entry, a name with
        // dots or a space survives, loopback is not "reachable", and a connection that is not listening is left out.
        let table = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        12:17:16.511582,launchd.1,,,0,0,0,0,0,,,,,,,,,,,,
        12:17:16.332473,tcp6 *.22<->*.*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:16.525295,tcp4 *:22<->*:*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:17.045982,master.377,,,0,0,0,0,0,,,,,,,,,,,,
        12:17:16.525659,tcp6 ::1.587<->*.*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:16.525750,tcp4 127.0.0.1:587<->*:*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:17.045991,node.674,,,0,0,0,0,0,,,,,,,,,,,,
        12:17:16.884328,tcp6 *.3000<->*.*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:17.045995,io.tailscale.ipn.2063,,,0,0,0,0,0,,,,,,,,,,,,
        12:17:16.884400,tcp4 192.0.2.24:8101<->*:*,utun4,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:17.045996,Control Center.788,,,0,0,0,0,0,,,,,,,,,,,,
        12:17:16.884500,tcp6 fe80::1%lo0.5000<->*.*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        12:17:17.045999,Safari.901,,,1200,3400,0,0,0,,,,,,,,,,,,
        12:17:16.883923,tcp4 192.0.2.24:52311<->203.0.113.9:443,en1,Established,1200,3400,0,0,0,12.50 ms,131072,688640,RD,-,cubic,-,-,-,-,ch,
        """
        let listeners = PortSampler.parse(table)
        let summary = listeners.map { "\($0.port):\($0.process):\($0.pid):\($0.exposed ? "net" : "local")" }.joined(separator: " ")
        let wanted = "22:launchd:1:net 587:master:377:local 3000:node:674:net 5000:Control Center:788:local 8101:io.tailscale.ipn:2063:net"
        if summary != wanted { failed += 1 }
        print("\(summary == wanted ? "ok  " : "FAIL") listening sockets parsed: \(summary)")
        let grouped = NetworkSampler.group(listeners, into: [])
        let order = grouped.map(\.name).joined(separator: ", ")
        let wantedOrder = "io.tailscale.ipn, macOS sharing services, node, Control Center, master"
        if order != wantedOrder { failed += 1 }
        print("\(order == wantedOrder ? "ok  " : "FAIL") reachable apps first, then by name: \(order)")
        let states = [("Firewall is disabled. (State = 0)", false), ("Firewall is enabled. (State = 1)", true), ("Firewall is set to block all non-essential incoming connections. (State = 2)", true)]
        for (text, expected) in states {
            let got = PortSampler.parseFirewall(text)
            if got != expected { failed += 1 }
            print("\(got == expected ? "ok  " : "FAIL") firewall \(expected ? "on" : "off") read from its own words")
        }
        print(failed == 0 ? "all \(cases.count + pages.count + 2 + states.count) cases pass" : "\(failed) FAILED")
    }

    /// `Dotmeter --watch-test [class] [seconds]`: prints a line each time the hardware registry reports something of
    /// that class coming or going (by default what the USB watcher listens for), then stops.
    @MainActor
    static func watchTest(_ name: String?, seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)
        let started = Date()
        var events = 0
        let watcher = USBWatcher(classes: name.map { [$0] } ?? USBWatcher.classes) {
            events += 1
            print(String(format: "changed at %.1f s", Date().timeIntervalSince(started)))
        }
        watcher.start()
        print("watching \(name ?? USBWatcher.classes.joined(separator: ", ")) for \(Int(seconds)) s: \(watcher.running ? "armed" : "could not arm")")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print("\(events) \(events == 1 ? "change" : "changes") reported")
            exit(0)
        }
        dispatchMain()
    }

    /// `Dotmeter --ports`: every app listening for connections, as the Network page lists them.
    static func ports() {
        let sampler = PortSampler()
        guard let readings = sampler.sample(every: 0) else {
            print("nettop did not answer")
            return
        }
        let (apps, _) = ProcessSampler().sample()
        let listeners = NetworkSampler.group(readings, into: apps)
        for (title, reachable) in [("Reachable from other devices", true), ("This Mac only", false)] {
            print(title)
            for app in listeners where app.exposed.isEmpty != reachable {
                let ports = reachable ? app.exposed : app.local
                print("  \(app.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(ports.map { "\($0.port)\(KnownPorts.name($0.port).map { " (\($0))" } ?? "")" }.joined(separator: ", "))")
            }
        }
        print("firewall: \(sampler.firewallOn().map { $0 ? "on" : "off" } ?? "did not say") · \(readings.count) listening sockets in \(listeners.count) apps")
    }

    /// `Dotmeter --external-ip-test`: the lookup for real, once. Says what kind of address came back, not the address.
    @MainActor
    static func externalAddressTest() async {
        let lookup = PublicAddress()
        lookup.lookUp(for: "test", force: true)
        for _ in 0..<100 where lookup.state == .looking {
            try? await Task.sleep(for: .milliseconds(100))
        }
        switch lookup.state {
        case .known(let address): print("found \(address.contains(":") ? "an IPv6" : "an IPv4") address, \(address.count) characters")
        default: print("no address: \(lookup.state)")
        }
    }

    /// `Dotmeter --ping-test`: three echoes to the router and three to the internet, as the Network area sends them.
    static func pingTest() {
        let network = NetworkSampler().sample(detail: true)
        var targets: [(String, String)] = []
        if let router = network.router, !router.contains(":") { targets.append(("router", router)) }
        targets.append(("internet", LatencyProbe.internetHost))
        for (name, host) in targets {
            var results: [String] = []
            for sequence in 1...3 {
                var milliseconds = 0.0
                let result = dotmeter_ping(host, 1500, UInt16(sequence), &milliseconds)
                let code = errno
                results.append(result == 0 ? String(format: "%.1f ms", milliseconds) : (result == 1 ? "no answer" : "could not send (\(String(cString: strerror(code))))"))
                Thread.sleep(forTimeInterval: 0.3)
            }
            print("\(name): " + results.joined(separator: ", "))
        }
    }

    /// `Dotmeter --agent-test`: loads a throwaway launch agent from a temporary folder, then removes it the way
    /// the Login Items area does (stop it, move its file to the Trash), and cleans the Trash copy out again.
    static func agentTest() {
        let label = "com.ysr.dotmeter.selftest-agent"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dotmeter-agent-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist = folder.appendingPathComponent(label + ".plist")
        let contents: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0), (try? data.write(to: plist)) != nil else { print("could not write the test agent"); return }
        func launchctl(_ arguments: [String]) -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }
        let boot = launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        Thread.sleep(forTimeInterval: 0.6)
        let before = launchctl(["list"]).1.contains(label)
        print("loaded the test agent: status \(boot.0), listed by launchd: \(before)")
        // Read it back the way the page does, from the folder it is in.
        var item = LaunchItem(path: plist.path, label: label, scope: .user)
        item.program = "/bin/sleep"
        let refused = LoginItemsModel.remove(item, allowAnywhere: false)
        print("outside ~/Library/LaunchAgents the app refuses: \(refused ?? "NOT REFUSED")")
        let (failure, landed) = LoginItemsModel.removeReportingLocation(item, allowAnywhere: true)
        Thread.sleep(forTimeInterval: 0.6)
        let after = launchctl(["list"]).1.contains(label)
        print("remove: \(failure ?? "ok") · still listed by launchd: \(after) · file still in place: \(FileManager.default.fileExists(atPath: plist.path))")
        if let landed {
            let cleaned = (try? FileManager.default.removeItem(at: landed)) != nil
            print(cleaned ? "took the test file out of the Trash again" : "NOTE: the test file is still in the Trash at \(landed.path)")
        }
        // An earlier run of this test could not see where its file landed; take that one out too.
        let stray = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash/" + label + ".plist")
        if (try? FileManager.default.removeItem(at: stray)) != nil { print("took an earlier run's test file out of the Trash") }
        if after { _ = launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        try? FileManager.default.removeItem(at: folder)
    }

    /// `Dotmeter --self-test quit|speed|events`: the checks that need the app's run loop.
    @MainActor
    static func selfTest(_ name: String, models: AppModels) async {
        switch name {
        case "quit":
            // A bare process: one this test starts, so nothing of the user's is touched.
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["600"]
            try? sleeper.run()
            let pid = sleeper.processIdentifier
            let child = ProcessUsage(pid: pid, ppid: getpid(), name: "sleep", path: "/bin/sleep", cpu: 0, memory: 0, parentName: nil)
            let bare = AppUsage(id: "proc:sleep", name: "sleep", bundlePath: nil, pid: pid, cpu: 0, memory: 0, processCount: 1, children: [child])
            print("bare process \(pid): can quit \(ProcessControl.canQuit(bare))")
            models.quit.request(bare, force: false)
            print("  after the first click: armed \(models.quit.isArmed(bare.id, force: false)), still running \(sleeper.isRunning)")
            models.quit.request(bare, force: false)
            try? await Task.sleep(for: .seconds(1))
            print("  after the second click: still running \(sleeper.isRunning), notice \(models.quit.notice ?? "none")")
            let guarded = AppUsage(id: "proc:WindowServer", name: "WindowServer", bundlePath: nil, pid: 400, cpu: 0, memory: 0, processCount: 1, children: [ProcessUsage(pid: 400, ppid: 1, name: "WindowServer", path: nil, cpu: 0, memory: 0, parentName: nil)])
            print("protected process: can quit \(ProcessControl.canQuit(guarded)) · asking anyway says: \(ProcessControl.quit(guarded, force: true) ?? "SENT")")

            // An app: Chess, hidden, and only if it is not already open.
            let chess = URL(fileURLWithPath: "/System/Applications/Chess.app")
            let open = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == chess.path }
            guard !open, FileManager.default.fileExists(atPath: chess.path) else { print("app path: skipped, Chess is \(open ? "already open" : "not installed")"); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            guard let launched = try? await NSWorkspace.shared.openApplication(at: chess, configuration: configuration) else { print("app path: could not start Chess"); return }
            try? await Task.sleep(for: .seconds(2))
            let appChild = ProcessUsage(pid: launched.processIdentifier, ppid: 1, name: "Chess", path: chess.path + "/Contents/MacOS/Chess", cpu: 0, memory: 0, parentName: nil)
            let app = AppUsage(id: chess.path, name: "Chess", bundlePath: chess.path, pid: launched.processIdentifier, cpu: 0, memory: 0, processCount: 1, children: [appChild])
            let failure = ProcessControl.quit(app, force: false)
            try? await Task.sleep(for: .seconds(3))
            print("app (Chess, started hidden for this test): quit request \(failure ?? "sent") · terminated \(launched.isTerminated)")
            if !launched.isTerminated {
                print("  force quit: \(ProcessControl.quit(app, force: true) ?? "sent")")
                try? await Task.sleep(for: .seconds(2))
                print("  terminated \(launched.isTerminated)")
            }
        case "speed":
            print("running a real speed test (about fifteen seconds)")
            models.speed.run()
            var peak = 0.0
            while models.speed.isRunning {
                try? await Task.sleep(for: .milliseconds(500))
                peak = max(peak, models.speed.liveDown)
            }
            if let result = models.speed.latest {
                print("result: down \(Format.linkSpeed(result.down)), up \(Format.linkSpeed(result.up)), responsiveness \(result.responsiveness.map { "\(Int($0)) RPM (\(result.responsivenessTitle ?? ""))" } ?? "-"), idle \(LatencyScale.text(result.baseRTT)) · live trace \(models.speed.trace.count) readings, peak \(Format.linkSpeed(peak * 8)) seen on the interface")
            } else {
                print("no result: \(models.speed.state)")
            }
        case "events":
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotmeter-events-\(getpid()).json")
            setenv("DOTMETER_TIMELINE_PATH", path.path, 1)
            let store = TimelineStore()
            let center = AlertCenter.forTesting(store: store)
            await models.monitor.refreshNow()
            try? await Task.sleep(for: .seconds(1))
            await models.monitor.refreshNow()
            guard var base = models.monitor.latest else { print("no reading"); return }
            base.thermal.state = .nominal
            base.thermal.cpuSpeedLimit = 100
            for index in base.thermal.sensors.indices { base.thermal.sensors[index].celsius = min(base.thermal.sensors[index].celsius, 60) }
            base.thermal.hottest?.celsius = 60
            for index in base.thermal.fans.indices { base.thermal.fans[index].percent = 0.1 }
            base.memory.pressure = .normal
            for index in base.apps.indices { base.apps[index].cpu = min(base.apps[index].cpu, 0.5) }
            base.cpu.total = 0.1
            var clock = Date().addingTimeInterval(-3600)
            func run(_ seconds: Int, _ change: (inout Snapshot) -> Void) {
                for _ in stride(from: 0, to: seconds, by: 2) {
                    var reading = base
                    change(&reading)
                    clock = clock.addingTimeInterval(2)
                    reading.timestamp = clock
                    center.feed(reading)
                }
            }
            run(60) { _ in }
            run(10) { $0.thermal.state = .serious }                      // too brief to count
            run(60) { _ in }
            run(180) { $0.thermal.state = .serious; $0.thermal.hottest?.celsius = 97 }
            run(60) { _ in }
            run(420) { if !$0.apps.isEmpty { $0.apps[0].cpu = 6.2 } }   // seven minutes at six cores
            run(60) { _ in }
            run(40) { $0.network.primary = nil }
            run(60) { _ in }
            run(30) { $0.memory.pressure = .warning }
            run(60) { _ in }
            // A laptop at 12% on battery, then plugged in.
            run(40) { $0.power.battery = BatteryInfo(charge: 0.12, isCharging: false, isPluggedIn: false, minutesRemaining: 31) }
            run(60) { $0.power.battery = BatteryInfo(charge: 0.13, isCharging: true, isPluggedIn: true) }
            store.flushForTesting()
            print("minutes recorded: \(store.minutes.count) · events: \(store.events.count)")
            for event in store.events {
                print("  \(event.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(Int(event.duration)) s · ended \(event.end != nil) · \(event.summary) · peak \(event.peakCelsius.map { "\(Int($0))°" } ?? "-")")
            }
            let expected: [TimelineEvent.Kind] = [.hot, .app, .offline, .memory, .battery]
            print(store.events.map(\.kind) == expected ? "as expected: one of each, and the ten-second blip was ignored" : "UNEXPECTED: wanted \(expected.map(\.rawValue))")
            store.saveNow()
            let reloaded = TimelineStore()
            print("written and read back: \(reloaded.minutes.count) minutes, \(reloaded.events.count) events")
            try? FileManager.default.removeItem(at: path)
        case "energy":
            // The ledger, the period totals and the dollar figures, on a store of its own.
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotmeter-energy-\(getpid()).json")
            setenv("DOTMETER_TIMELINE_PATH", path.path, 1)
            let store = TimelineStore()
            // The monitor is already taking its first reading; wait for it rather than ask for another.
            for _ in 0..<50 where models.monitor.latest == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard var base = models.monitor.latest else { print("no reading"); return }
            base.power.system = 60
            let calendar = Calendar.current
            let noon = calendar.startOfDay(for: Date()).addingTimeInterval(-12 * 3600)
            // Two hours and a minute at 60 W on each of four days: forty days ago, three days ago, yesterday and today.
            // The last one runs up to now, so nothing is fed from the future.
            let starts = [-39, -2, 0].map { noon.addingTimeInterval(Double($0) * 86_400) } + [Date().addingTimeInterval(-121 * 60)]
            for start in starts {
                for minute in 0...120 {
                    var reading = base
                    reading.timestamp = start.addingTimeInterval(Double(minute) * 60)
                    store.record(reading)
                }
            }
            store.flushForTesting()
            let sameMonth = [2, 1].filter { calendar.isDate(noon.addingTimeInterval(-Double($0 - 1) * 86_400), equalTo: Date(), toGranularity: .month) }.count
            let sameYear = calendar.isDate(noon.addingTimeInterval(-39 * 86_400), equalTo: Date(), toGranularity: .year)
            // 121 one-minute readings at 60 W are 121 Wh a day.
            let expected: [(EnergyPeriod, Double)] = [(.today, 121), (.week, 363), (.month, 121 + Double(sameMonth) * 121), (.year, 363 + (sameYear ? 121 : 0)), (.all, 484)]
            var failed = 0
            func check(_ store: TimelineStore, _ note: String) {
                for (period, wanted) in expected {
                    let got = store.energy(period)
                    let ok = abs(got.wattHours - wanted) <= 0.5
                    if !ok { failed += 1 }
                    print("\(ok ? "ok  " : "FAIL") \(note) \(period.title.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%6.1f Wh", got.wattHours)) (expected about \(Int(wanted))) · \(got.bars.count) bars by the \(got.unit) · \(got.daysRecorded) days recorded\(got.projected.map { String(format: " · month at this rate %.0f Wh", $0) } ?? "")")
                }
            }
            check(store, "live    ")
            store.saveNow()
            check(TimelineStore(), "reloaded")
            // A file from before the ledger existed: the same file with the ledger taken out.
            if let data = try? Data(contentsOf: path), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                object["days"] = nil
                try? JSONSerialization.data(withJSONObject: object).write(to: path)
                check(TimelineStore(), "old file")
            }
            let money = [(0.004, "under $0.01"), (0.17, "$0.17"), (12.479, "$12.48"), (1248.3, "$1,248")]
            for (value, wanted) in money {
                let got = Format.dollars(value)
                if got != wanted { failed += 1 }
                print("\(got == wanted ? "ok  " : "FAIL") \(value) is written \(got)")
            }
            print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
            try? FileManager.default.removeItem(at: path)
        case "usb":
            usbSelfTest()
        case "openai":
            openAISelfTest()
        case "dashboard":
            dashboardSelfTest()
        case "storage":
            await storageSelfTest(models: models)
        case "uninstall":
            await uninstallSelfTest()
        default:
            print("unknown self-test: \(name)")
        }
    }

    /// A made-up app for the uninstall tests: a bundle with its own identifier, and files under that identifier in
    /// the Library folders. Returns the app's path and every path it made.
    private static let testID = "com.ysr.dotmeter.removaltest"
    private static let testName = "Dotmeter Removal Test"

    /// `id` gives the app another identifier. With one of Apple's, the folder under the app's plain name is made
    /// too but is not expected to be found (returned in `kept`), and nothing is made under `/Library`.
    private static func makeTestApp(in folder: String, locked: Bool, id: String = testID) -> (app: String, made: [String], kept: [String]) {
        let fm = FileManager.default
        let apple = id.lowercased().hasPrefix("com.apple.")
        let app = folder + "/\(testName).app"
        try? fm.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleName": testName, "CFBundleExecutable": "none", "CFBundlePackageType": "APPL"]
        info.write(toFile: app + "/Contents/Info.plist", atomically: true)
        fm.createFile(atPath: app + "/Contents/MacOS/none", contents: Data("#!/bin/sh\n".utf8))
        let home = Uninstaller.home
        var made = [app]
        var kept: [String] = []
        for folder in ["Library/Application Support/\(id)", "Library/Caches/\(id)", "Library/Saved Application State/\(id).savedState", "Library/Logs/\(testName)"] {
            let path = home + "/" + folder
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            fm.createFile(atPath: path + "/data.bin", contents: Data(repeating: 7, count: 300_000))
            if apple && folder.hasSuffix(testName) { kept.append(path) } else { made.append(path) }
        }
        let settings = home + "/Library/Preferences/\(id).plist"
        (["made": "by the uninstall test"] as NSDictionary).write(toFile: settings, atomically: true)
        made.append(settings)
        if locked {
            // A folder its owner cannot change is refused to a plain delete, as something the system owns would be.
            var sealed = [app + "/Contents/MacOS", app + "/Contents", app]
            if !apple {
                let system = "/Library/Caches/\(id)"
                try? fm.createDirectory(atPath: system, withIntermediateDirectories: true)
                fm.createFile(atPath: system + "/data.bin", contents: Data(repeating: 7, count: 100_000))
                made.append(system)
                sealed.insert(system, at: 0)
            }
            for path in sealed { chmod(path, 0o555) }
        }
        return (app, made, kept)
    }

    /// The rule for what the helper may delete, as text only, and the search for an app's leftovers with plain
    /// deletes on files the test makes itself.
    private static func uninstallSelfTest() async {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got \(got))")")
        }
        let home = Uninstaller.home
        let allowed = [
            "/Applications/Some Maker App.app", home + "/Applications/Some Maker App.app", "/Library/Application Support/com.example.thing",
            "/Library/LaunchDaemons/com.example.thing.plist", "/Library/PrivilegedHelperTools/com.example.thing.helper",
            "/private/var/db/receipts/com.example.thing.bom", home + "/Library/Caches/com.example.thing", home + "/Library/Preferences/com.example.thing.plist",
            // One of Apple's App Store apps is an app like any other; what is part of macOS is refused below.
            "/Applications/iMovie.app", "/Applications/GarageBand.app",
        ]
        for path in allowed { check("may remove \(DiskStorageBackend.abbreviate(path))", RemovalPolicy.refusal(for: path, home: home) == nil, RemovalPolicy.refusal(for: path, home: home) as Any) }
        let refused = [
            "/", "/Applications", "/etc/hosts", "relative/thing", "/Library/Application Support/", "/System/Applications/Chess.app", "/Applications/Safari.app",
            "/Library/Application Support/com.apple.TCC", "/Library/Application Support/Apple", "/Library/Application Support/com.example.thing/inside",
            "/Library/../etc/hosts", "/Applications/Utilities/../../etc", "/usr/local/bin/thing", "/Users/Shared/Some App.app", home + "/Documents/thing",
            home + "/Library/Caches", home + "/Library", home + "/Library/Mail/thing", "/Library/Keychains/System.keychain", "/var/db/receipts/com.example.thing.bom",
            "/Applications/a/b/Deep.app", "/Library/Application Support/ab",
        ]
        for path in refused { check("refuses \(DiskStorageBackend.abbreviate(path))", RemovalPolicy.refusal(for: path, home: home) != nil) }

        // The search, on a made-up app, with one entry that only looks like it belongs.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dotmeter-uninstall-\(getpid())").path
        let fixture = makeTestApp(in: folder, locked: false)
        let decoy = home + "/Library/Application Support/\(testID)x"
        try? FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: decoy)
            try? FileManager.default.removeItem(atPath: folder)
        }
        let plan = await Task.detached { Uninstaller.plan(for: fixture.app) }.value
        let found = Set(plan.items.map(\.path))
        check("named and identified from the bundle", plan.name == testName && plan.bundleID == testID, plan.bundleID as Any)
        check("found the app and all five things it left", found == Set(fixture.made), found.subtracting(fixture.made).union(Set(fixture.made).subtracting(found)).sorted())
        check("the logs folder was found by the app's plain name", plan.items.contains { $0.kind == .logs })
        check("an entry that only starts the same way is left alone", !found.contains(decoy))
        check("everything is measured", plan.items.allSatisfy { ($0.bytes ?? 0) > 0 }, plan.items.map { $0.bytes ?? -1 })
        check("none of it needs the helper", plan.items.allSatisfy { !$0.system })
        let failures = await Uninstaller.delete(plan, helper: { $0.map { _ in "no helper in this test" } }) { _ in }
        check("deleted without the helper", failures.isEmpty, failures)
        check("nothing of it is left", fixture.made.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, fixture.made.filter { FileManager.default.fileExists(atPath: $0) })
        check("the look-alike is still there", FileManager.default.fileExists(atPath: decoy))

        // A second installed copy with the same identifier uses the same files, so only the app would go.
        let twin = makeTestApp(in: folder, locked: false)
        let alone = await Task.detached { Uninstaller.plan(for: twin.app, others: [(id: testID, name: "another copy")]) }.value
        check("with another copy installed, only the app goes", alone.items.map(\.path) == [twin.app] && alone.sharesFiles, alone.items.map(\.path))
        check("and the row says its files stay", alone.summary.contains("files stay"), alone.summary)
        let whole = await Task.detached { Uninstaller.plan(for: twin.app, appBytes: 5e9, others: []) }.value
        check("a size that is already known is not measured again", whole.items.first?.bytes == 5e9, whole.items.first?.bytes as Any)
        check("the row says what goes with it", whole.summary == "deletes the app and 5 things it left behind (1 MB) for good", whole.summary)
        _ = await Uninstaller.delete(whole, helper: { $0.map { _ in "no helper in this test" } }) { _ in }

        // One of Apple's own: matched by its identifier in the user's Library, never by its plain name.
        let appleID = "com.apple.DotmeterRemovalTest"
        let apple = makeTestApp(in: folder, locked: false, id: appleID)
        defer { for path in apple.made + apple.kept { try? FileManager.default.removeItem(atPath: path) } }
        let applePlan = await Task.detached { Uninstaller.plan(for: apple.app, others: []) }.value
        let appleFound = Set(applePlan.items.map(\.path))
        check("an Apple app's own files are found by its identifier", appleFound == Set(apple.made), appleFound.symmetricDifference(apple.made).sorted())
        check("a folder that only has its plain name is left alone", apple.kept.allSatisfy { !appleFound.contains($0) })
        let appleFailures = await Uninstaller.delete(applePlan, helper: { $0.map { _ in "no helper in this test" } }) { _ in }
        check("it uninstalls like any other app", appleFailures.isEmpty && apple.made.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, appleFailures)
        check("and the plain-name folder is still there", apple.kept.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
    }

    /// The storage figures on a made-up disk that fills and empties after it was scanned. Nothing of the
    /// user's is read or saved: the model is told not to remember.
    @MainActor
    private static func storageSelfTest(models: AppModels) async {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got \(got))")")
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 2e7 }
        func item(_ section: AppSection, _ storage: StorageModel) -> [String] {
            MenuBarRenderer.content(for: section, snapshot: Collectors().collect(), history: [], storage: storage).lines
        }
        let disk = MadeUpDisk(capacity: 1000e9, free: 600e9)
        let storage = StorageModel(backend: disk, remembers: false)
        check("before a scan, used is what the disk says", near(storage.usedBytes, 400e9), storage.usedBytes)
        disk.free = 550e9
        storage.follow(free: 550_000_000_000)
        check("and it follows the disk filling up", near(storage.usedBytes, 450e9), storage.usedBytes)
        check("the menu bar says so", item(.storage, storage) == ["U 450 GB", "F 550 GB"], item(.storage, storage))

        storage.scan()
        for _ in 0..<100 where storage.phase != .ready { try? await Task.sleep(for: .milliseconds(50)) }
        func part(_ id: String) -> Double { storage.meter.items.first { $0.id == id }.map { $0.number * 1e9 } ?? -1 }
        check("a scan leaves the folders and the rest as System data", storage.phase == .ready && near(part("apps"), 100e9) && near(part("system"), 300e9), "\(storage.phase) \(part("apps")) \(part("system"))")

        disk.free = 380e9
        storage.follow(free: 380_000_000_000)
        check("after a scan, used still follows the disk filling up", near(storage.usedBytes, 620e9), storage.usedBytes)
        check("the menu bar says so", item(.storage, storage) == ["U 620 GB", "F 380 GB"], item(.storage, storage))
        check("what was added since is System data until the next scan", near(part("system"), 470e9) && near(part("apps"), 100e9), part("system"))
        check("the card agrees", storage.meter.status == .plain("380.0 GB available"), storage.meter.status)

        let before = storage.meter.number
        storage.follow(free: 380_004_000_000)
        check("a few megabytes change nothing", storage.meter.number == before)

        disk.free = 900e9
        storage.follow(free: 900_000_000_000)
        check("emptied below what the folders came to, used is still the disk's", near(storage.usedBytes, 100e9), storage.usedBytes)
        let bar = storage.meter.items.filter { $0.id != "unmeasured" }.reduce(0.0) { $0 + $1.amount }
        check("and the bar does not draw more than is used", near(bar, 100e9), bar)
        check("the menu bar says so", item(.storage, storage) == ["U 100 GB", "F 900 GB"], item(.storage, storage))

        // The real disk, through the app's own wiring: the running monitor reads it and the storage figures follow.
        // The only thing written is a file this test makes in the temporary folder and deletes again; the saved
        // scan is read, never saved.
        func diskUsed() -> Double {
            var fs = statfs()
            guard statfs("/", &fs) == 0 else { return 0 }
            return Double(UInt64(fs.f_blocks) * UInt64(fs.f_bsize)) - Double(UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
        }
        func settles(_ ok: @escaping () -> Bool) async -> Bool {
            for _ in 0..<70 where !ok() { try? await Task.sleep(for: .milliseconds(500)) }
            return ok()
        }
        let real = models.storage
        let agrees = { abs(real.usedBytes - diskUsed()) < 1e8 }
        let atStart = await settles { models.monitor.latest != nil && agrees() }
        let first = real.usedBytes
        check("the real disk: used is what the disk says (\(real.phase))", atStart, "\(StorageModel.gb(real.usedBytes)) against \(StorageModel.gb(diskUsed()))")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dotmeter-storage-test-\(getpid())")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: file) {
            let chunk = Data((0..<8_388_608).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            for _ in 0..<50 { try? handle.write(contentsOf: chunk) }
            try? handle.synchronize()
            try? handle.close()
        }
        let grew = await settles { real.usedBytes - first > 3e8 && agrees() }
        check("it follows 400 MB being written", grew, "\(StorageModel.gb(first)) then \(StorageModel.gb(real.usedBytes)), disk \(StorageModel.gb(diskUsed()))")
        let full = real.usedBytes
        try? FileManager.default.removeItem(at: file)
        let shrank = await settles { full - real.usedBytes > 3e8 && agrees() }
        check("and being deleted again", shrank, "\(StorageModel.gb(full)) then \(StorageModel.gb(real.usedBytes)), disk \(StorageModel.gb(diskUsed()))")
        print(String(format: "     real disk: %.2f GB used at the start, %.2f with the file, %.2f after", first / 1e9, full / 1e9, real.usedBytes / 1e9))
        print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
    }

    /// The Dashboard's card order: what is shown for a saved order, how a card moves, and how the rows fall.
    private static func dashboardSelfTest() {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got \(got))")")
        }
        func names(_ cards: [DashboardCard]) -> String { cards.map(\.rawValue).joined(separator: ",") }
        let desk = DashboardCard.standard(battery: false), laptop = DashboardCard.standard(battery: true)
        check("nothing saved is the usual order", DashboardOrder.resolve(saved: [], available: desk) == desk)
        let saved = ["network", "thermal", "cpu"]
        let resolved = DashboardOrder.resolve(saved: saved, available: desk)
        check("a saved order comes first and loses no card", names(resolved).hasPrefix("network,thermal,cpu") && Set(resolved) == Set(desk) && resolved.count == desk.count, names(resolved))
        check("an unknown or repeated name is dropped", DashboardOrder.resolve(saved: ["cpu", "nonsense", "cpu", "gpu"], available: desk).prefix(2) == [.cpu, .gpu])
        check("a card this Mac lacks is left out", !DashboardOrder.resolve(saved: ["battery", "cpu"], available: desk).contains(.battery))
        let grown = DashboardOrder.resolve(saved: names(desk).split(separator: ",").map(String.init), available: laptop)
        check("a Mac that gains a battery gets its cards after the ones already placed", grown == desk + [.battery, .energyDay], names(grown))
        check("dragged down, a card lands after the one it was dropped on", names(DashboardOrder.moving(.cpu, onto: .memory, in: desk)).hasPrefix("gpu,memory,cpu"), names(DashboardOrder.moving(.cpu, onto: .memory, in: desk)))
        check("dragged up, before it", names(DashboardOrder.moving(.network, onto: .gpu, in: desk)).hasPrefix("cpu,network,gpu"), names(DashboardOrder.moving(.network, onto: .gpu, in: desk)))
        check("to the top, up, down and to the bottom", DashboardOrder.moving(.power, .top, in: desk).first == .power && DashboardOrder.moving(.cpu, .bottom, in: desk).last == .cpu
              && DashboardOrder.moving(.gpu, .up, in: desk).first == .gpu && DashboardOrder.moving(.cpu, .down, in: desk)[1] == .cpu)
        check("moving the first card up changes nothing", DashboardOrder.moving(.cpu, .up, in: desk) == desk)
        let rows = DashboardOrder.rows(desk, columns: 2).map(names)
        check("two to a row, the wide card on its own", rows == ["cpu,gpu", "memory,storage", "thermal,power", "network,throughput", "assistant"], rows)
        let early = DashboardOrder.rows([.cpu, .assistant, .gpu, .memory], columns: 2).map(names)
        check("a wide card never leaves half a row empty above it", early == ["cpu,gpu", "assistant", "memory"], early)
        check("one column is one card a row", DashboardOrder.rows(desk, columns: 1).count == desk.count)
        check("the panel shows the areas only, in the same order", Array(DashboardOrder.resolve(saved: saved, available: desk).filter(\.inPanel).map(\.rawValue).prefix(3)) == ["network", "thermal", "cpu"] && !desk.filter(\.inPanel).contains(.assistant))
        print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
    }

    /// The OpenAI client without OpenAI: the request it would send, and the stream events as the Responses API
    /// writes them, fed to the parser one line at a time.
    private static func openAISelfTest() {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got \(got))")")
        }
        let turns = [ClaudeMessage(role: "user", content: "first"), ClaudeMessage(role: "assistant", content: "answer"), ClaudeMessage(role: "user", content: "second")]
        let body = OpenAIClient.body(model: "gpt-6.1-sol", effort: "low", system: "be brief", messages: turns, format: AnalysisReport.schema)
        check("the model, the system prompt and the effort", body["model"] as? String == "gpt-6.1-sol" && body["instructions"] as? String == "be brief" && (body["reasoning"] as? [String: String])?["effort"] == "low")
        check("the whole conversation, in order", (body["input"] as? [[String: String]])?.map { $0["role"] ?? "" } == ["user", "assistant", "user"])
        check("streamed, and not kept by OpenAI", body["stream"] as? Bool == true && body["store"] as? Bool == false)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        check("the report's schema, in strict mode", format?["type"] as? String == "json_schema" && format?["strict"] as? Bool == true && format?["name"] as? String == "dotmeter_report" && format?["schema"] != nil)
        check("no schema for a plain answer", OpenAIClient.body(model: "m", effort: "low", system: "", messages: turns, format: nil)["text"] == nil)
        check("it can be written as JSON", JSONSerialization.isValidJSONObject(body))
        // Strict mode wants every property required and every object closed. Check the schema says so.
        func strict(_ schema: [String: Any]) -> Bool {
            if schema["type"] as? String == "object" {
                guard let properties = schema["properties"] as? [String: Any], schema["additionalProperties"] as? Bool == false,
                      Set(schema["required"] as? [String] ?? []) == Set(properties.keys) else { return false }
                return properties.values.allSatisfy { ($0 as? [String: Any]).map(strict) ?? false }
            }
            if schema["type"] as? String == "array" { return (schema["items"] as? [String: Any]).map(strict) ?? false }
            return true
        }
        check("the report's schema is one strict mode accepts", strict(AnalysisReport.schema))

        func event(_ line: String) -> Result<OpenAIClient.Event, Error> { Result { try OpenAIClient.event(in: line) } }
        func value(_ line: String) -> OpenAIClient.Event? { try? OpenAIClient.event(in: line) }
        func message(_ line: String) -> String? {
            if case .failure(let error) = event(line) { return error.localizedDescription }
            return nil
        }
        check("text arrives in deltas", value(#"data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello, ","sequence_number":4}"#) == .text("Hello, "))
        check("an event's name line is skipped", value("event: response.output_text.delta") == .nothing && value("") == .nothing)
        check("other events are skipped", value(#"data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#) == .nothing && value(#"data: {"type":"response.reasoning_summary_text.delta","delta":"thinking"}"#) == .nothing)
        check("the end is the completed event", value(#"data: {"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#) == .finished)
        check("a refusal is collected", value(#"data: {"type":"response.refusal.delta","delta":"I can't help with that."}"#) == .refusal("I can't help with that."))
        check("a line that is not JSON is skipped", value("data: [DONE]") == .nothing)
        check("running out of tokens says so", message(#"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)?.contains("cut off") == true)
        check("a filtered answer reads as declined", message(#"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#)?.contains("declined") == true)
        check("a failure carries OpenAI's words", message(#"data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"The model failed to respond."}}}"#) == "The model failed to respond.")
        check("an error event carries its message", message(#"data: {"type":"error","code":"invalid_prompt","message":"Bad input.","param":null}"#) == "Bad input.")

        let quota = OpenAIClient.errorDetail(in: #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","param":null,"code":"credit_balance_exhausted"}}"#)
        check("an error body gives its message and code", quota.message == "You exceeded your current quota." && quota.code == "credit_balance_exhausted", quota)
        check("out of credit is not called a rate limit", OpenAIError.http(429, quota.message ?? "", code: quota.code).localizedDescription.contains("out of credit"))
        let pace = OpenAIClient.errorDetail(in: #"{"error":{"message":"Rate limit reached for requests.","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#)
        check("going too fast is", OpenAIError.http(429, pace.message ?? "", code: pace.code).localizedDescription.hasPrefix("Rate limited"))
        check("a rejected key says where to fix it", OpenAIError.http(401, "Incorrect API key provided.", code: "invalid_api_key").localizedDescription.contains("Settings"))
        check("each provider has its own key and its own models", Set(AIProvider.allCases.map(\.keyAccount)).count == 2 && AIProvider.openai.models.map(\.id) == ["gpt-6.1-sol"] && AIProvider.anthropic.models.count == 3)
        print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
    }

    /// `Dotmeter --helper-state`: what macOS reports about the helper and whether it answers. Changes nothing.
    @MainActor
    static func helperState() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let helper = UninstallHelper()
        print("macOS reports: \(helper.state)")
        let version = await helper.version()
        print("helper answers: \(version.map { "yes, version \($0) (this copy carries \(HelperInfo.version))" } ?? "no")")
    }

    /// `Dotmeter --helper-off`: unregisters the helper, as the switch in Settings does. Only the copy that
    /// registered it can, so this is run from the installed app.
    @MainActor
    static func helperOff() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let helper = UninstallHelper()
        print("before: \(helper.state)")
        await helper.turnOff()
        print("after: \(helper.state)")
    }

    /// `Dotmeter --helper-test`: the helper for real, asked for the way an uninstall asks: it is registered if it is
    /// not, macOS asks the user to allow it if it has not been, and then it removes a locked made-up app with its
    /// files, and a second one that carries an Apple identifier, which a plain delete is refused.
    @MainActor
    static func helperTest() async {
        // Written to a file when launched through LaunchServices, so do not hold lines back.
        setvbuf(stdout, nil, _IONBF, 0)
        let helper = UninstallHelper()
        print("macOS reports: \(helper.state)")

        // Things it must refuse. None of these exist, so a wrong answer could not cost anything either.
        let forbidden = ["/Library/Application Support/com.apple.dotmeter-test-missing", "/etc/dotmeter-test-missing", Uninstaller.home + "/Documents/dotmeter-test-missing", "/Applications/../dotmeter-test-missing.app", "/System/Applications/dotmeter-test-missing.app"]
        let refusals = await helper.remove(forbidden, asking: true)
        print("helper answers, version \(await helper.version().map(String.init) ?? "none") (this copy carries \(HelperInfo.version))")
        guard refusals.contains(where: { $0?.hasPrefix("Refused") == true }) else {
            print("the helper could not be used, so nothing was tested: \(refusals.first.flatMap { $0 } ?? "no answer")")
            return
        }
        print("refused all \(forbidden.count) forbidden paths: \(refusals.allSatisfy { $0?.hasPrefix("Refused") == true })\(refusals.contains { $0?.hasPrefix("Refused") != true } ? " \(refusals)" : "")")

        var passed = refusals.allSatisfy { $0?.hasPrefix("Refused") == true }
        for (label, id) in [("a locked app", testID), ("a locked app with an Apple identifier", "com.apple.DotmeterRemovalTest")] {
            let fixture = makeTestApp(in: "/Applications", locked: true, id: id)
            defer {
                // Whatever is left is unlocked and removed here, by name.
                for path in fixture.made + fixture.kept where FileManager.default.fileExists(atPath: path) {
                    for inner in [path, path + "/Contents", path + "/Contents/MacOS"] { chmod(inner, 0o755) }
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            let app = fixture.app
            let plan = await Task.detached { Uninstaller.plan(for: app, others: []) }.value
            let plainRefused = (try? FileManager.default.removeItem(atPath: fixture.app)) == nil
            let failures = await Uninstaller.delete(plan, helper: { paths in await helper.remove(paths, asking: true) }) { _ in }
            let left = fixture.made.filter { FileManager.default.fileExists(atPath: $0) }
            let ok = failures.isEmpty && left.isEmpty && plainRefused
            passed = passed && ok
            print("\(label): \(plan.items.count) items, plain delete refused: \(plainRefused), failures: \(failures.isEmpty ? "none" : "\(failures)"), left behind: \(left.isEmpty ? "nothing" : left.joined(separator: ", "))")
        }
        print(passed ? "helper test passes" : "helper test FAILED")
    }

    /// The decoders against identity words read from two real cables, the supply decoder against objects built
    /// by the specification's layout, the verdicts against the made-up ports, and the cable record on a file of
    /// its own.
    @MainActor
    private static func usbSelfTest() {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got \(got))")")
        }
        // A 0.8 m Thunderbolt 4 cable and a short cable that leaves its vendor blank, as their plugs answered.
        let dock = PDIdentity(vdos: [0x1C60_0522, 0x0000_0938, 0x0B70_0190, 0x1108_2043], revision: 3, cable: true).flatMap(CableMarker.init)
        check("passive cable recognised", dock?.identity.kind == .passiveCable && dock?.active == false, dock?.identity.kind as Any)
        check("vendor, product and certificate", dock?.identity.vendorID == 0x0522 && dock?.identity.productID == 0x0B70 && dock?.identity.xid == 2360, dock?.identity.fingerprint as Any)
        check("marked USB4 Gen 3, 40 Gb/s", dock?.speedCode == 3 && dock?.linkBitsPerSecond == 40e9, dock?.speedCode as Any)
        check("5 A, 100 W, 20 V", dock?.amps == 5 && dock?.watts == 100 && dock?.maxVolts == 20, dock?.watts as Any)
        check("about a metre, USB-C both ends", dock?.latencyCode == 1 && dock?.plugCode == 2, dock?.latencyCode as Any)
        check("nothing unusual in it", dock?.unusual.isEmpty == true, dock?.unusual as Any)
        let blank = PDIdentity(vdos: [0x1860_0000, 0, 0, 0x0008_2023], revision: 3, cable: true).flatMap(CableMarker.init)
        check("blank vendor flagged, once", blank?.unusual.count == 1 && blank?.amps == 3 && blank?.watts == 60, blank?.unusual as Any)
        let odd = USBDemo.marker(vendor: 0x1234, product: 1, xid: 0, speed: 6, current: 3, latency: 0, extended: true)
        check("reserved speed, current and length, and a mismatched power claim, all flagged", odd?.unusual.count == 4, odd?.unusual.count as Any)
        let epr = USBDemo.marker(vendor: 0x1234, product: 1, xid: 0, speed: 4, current: 2, extended: true, maxVoltage: 3)
        check("extended-range cable is 240 W and 80 Gb/s", epr?.watts == 240 && epr?.linkBitsPerSecond == 80e9 && epr?.unusual.isEmpty == true, epr?.watts as Any)
        let partner = PDIdentity(vdos: [0x4CC0_291A, 0, 0x8397_0072], revision: 3, cable: false)
        check("a dock answers as a hub from Anker", partner?.kind == .hub && partner?.vendorID == 0x291A && partner?.productID == 0x8397 && USBVendors.name(0x291A) == "Anker", partner?.kindTitle as Any)

        let fixed = PowerOption(pdo: 400 << 10 | 500, index: 0)
        check("fixed supply: 20 V, 5 A, 100 W", fixed?.millivolts == 20000 && fixed?.milliamps == 5000 && fixed?.watts == 100, fixed as Any)
        let programmable = PowerOption(pdo: 3 << 30 | 210 << 17 | 33 << 8 | 100, index: 1)
        check("programmable supply: 3.3 to 21 V, 5 A", programmable?.kind == .programmable && programmable?.millivolts == 21000 && programmable?.minMillivolts == 3300 && programmable?.milliamps == 5000, programmable as Any)
        let adjustable = PowerOption(pdo: 3 << 30 | 1 << 28 | 480 << 17 | 150 << 8 | 240, index: 2)
        check("adjustable supply: 15 to 48 V, 240 W", adjustable?.kind == .adjustable && adjustable?.millivolts == 48000 && adjustable?.milliamps == 5000, adjustable as Any)

        func title(_ demo: String, _ port: Int) -> String {
            let stats = USBDemo.stats(demo)
            return USBDiagnostics.diagnose(stats.ports[port], charger: stats.charger).headline?.title ?? "none"
        }
        check("dock on a matching cable: full speed", title("laptop", 0) == "Running at full speed, 40 Gb/s", title("laptop", 0))
        check("same link come up on one slow lane: slower than expected", title("slow", 0) == "Running slower than expected", title("slow", 0))
        check("3 A cable on a 96 W charger: charging limited", title("laptop", 1) == "Cable limits charging to 60 W", title("laptop", 1))
        check("fast drive on a charging cable: the cable limits", title("laptop", 2) == "Cable is limiting data speed", title("laptop", 2))
        let demo = USBDemo.stats("laptop")
        check("path resistance from the sag", demo.charger?.pathMilliohms.map { Int($0.rounded()) } == 142, demo.charger?.pathMilliohms as Any)
        let screens = USBDiagnostics.diagnose(demo.ports[0], charger: nil).screens.map(\.title)
        check("6K at 60 Hz needs compression on four HBR3 lanes", USBDiagnostics.diagnose(demo.ports[0]).screens.first?.detail.contains("compressed") == true, screens)
        check("the second screen is found below its top refresh", screens.last?.contains("below its top refresh") == true, screens)
        check("ports have distinct names", Set(demo.ports.map(\.id)).count == demo.ports.count, demo.ports.map(\.id))

        // The record of a followed cable, in a file of its own.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotmeter-cables-\(getpid()).json")
        setenv("DOTMETER_CABLES_PATH", path.path, 1)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = CableStore()
        if USBSampler.demo == nil, let marker = demo.ports[2].cable {
            store.add(marker, name: "  Drawer cable ")
            let start = Date().addingTimeInterval(-3600)
            store.record(demo, at: start)
            store.record(demo, at: start.addingTimeInterval(60))
            store.record(demo, at: start.addingTimeInterval(1800))
            let saved = store.saved(marker)
            check("named, and found again by its marker", saved?.name == "Drawer cable", saved?.name as Any)
            check("readings a minute apart are one connection, half an hour later another", saved?.sessions.count == 2, saved?.sessions.count as Any)
            check("both noted as trouble", saved?.troubled == 2 && saved?.verdict.caution == true, saved?.verdict.title as Any)
            store.saveNow()
            let reloaded = CableStore()
            check("written and read back", reloaded.cables.first?.sessions.count == 2 && reloaded.cables.first?.id == saved?.id, reloaded.cables.count)
            reloaded.remove(saved?.id ?? "")
            check("removed", CableStore().cables.isEmpty)
        } else {
            print("skipped the cable record: demo ports are on")
        }

        // What the menu bar item, its panel and the alert are built from.
        let slowPorts = USBDemo.stats("slow"), laptopPorts = USBDemo.stats("laptop")
        let overview = USBOverview(slowPorts)
        check("four of six made-up ports are in use", overview.connected.count == 4 && overview.ports.count == 6, "\(overview.connected.count)/\(overview.ports.count)")
        check("three of them run below what their parts could do", overview.slow.map(\.title) == ["USB-C 1", "USB-C 2", "USB-C 3"], overview.slow.map(\.title))
        check("a slow link, a held-back charger and a limiting cable", overview.slow.compactMap { $0.slow?.id } == ["speed", "power", "speed"], overview.slow.compactMap { $0.slow?.id })
        check("each port has a level for its column", overview.ports.map(\.level).allSatisfy { (0...1).contains($0) } && overview.empty.allSatisfy { $0.level == 0 })
        check("the same reading is not worked out twice", USBOverview.of(slowPorts) == USBOverview.of(slowPorts))
        let item = MenuBarRenderer.content(for: .usb, snapshot: { var s = Collectors().collect(); s.usb = slowPorts; return s }(), history: [], storage: StorageModel())
        check("the item reads 4/6 and turns orange", item.lines == ["4/6"] && item.tint != nil, item.lines)

        // The alert: what is already slow at the first reading is not news, a connection that turns up slow later
        // is one event, and it ends when the connection is put right or pulled out.
        let timeline = TimelineStore()
        let center = AlertCenter.forTesting(store: timeline)
        var reading = Collectors().collect()
        let known = timeline.events.count
        reading.usb = laptopPorts
        center.feed(reading)
        check("slow when \(App.name) started is not news", timeline.events.count == known, timeline.events.count - known)
        reading.usb = slowPorts
        reading.timestamp = reading.timestamp.addingTimeInterval(5)
        center.feed(reading)
        let raised = timeline.events.filter { $0.kind == .usb }
        check("a dock that comes up slow is one event", timeline.events.count == known + 1 && raised.count == 1, timeline.events.count - known)
        check("it names the dock, the port and the finding", raised.last?.summary == "Harbor Dock 11 on USB-C 1: Running slower than expected, at 10 Gb/s", raised.last?.summary as Any)
        center.feed(reading)
        check("and is not raised again while it lasts", timeline.events.count == known + 1)
        reading.usb = laptopPorts
        reading.timestamp = reading.timestamp.addingTimeInterval(5)
        center.feed(reading)
        check("it ends when the link is back to full speed", timeline.events.last(where: { $0.kind == .usb })?.end != nil)
        print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
    }

    /// `Dotmeter --usb`: every port, cable, link, device and screen as text; with `--json`, the same as JSON
    /// (the cable's raw certificate number and identity words included).
    static func usb(json: Bool) {
        let started = DispatchTime.now().uptimeNanoseconds, busy = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let stats = USBSampler().sample()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let onCore = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - busy) / 1e6
        if json {
            print(USBReport.json(stats))
        } else {
            print(USBReport.text(stats))
            print(String(format: "\nread in %.1f ms, %.1f ms of it on a core", elapsed, onCore))
        }
    }

    static func bench() {
        let cpu = CPUSampler(), memory = MemorySampler(), processes = ProcessSampler()
        let thermal = ThermalSampler(), gpu = GPUSampler(), disk = DiskSampler(), network = NetworkSampler(), power = PowerSampler()
        // Elapsed time, and how much of it this thread spent on a core: most collectors mostly wait on the
        // kernel or another process, and only the second figure shows up as this app's processor use.
        func time(_ label: String, _ block: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds, busyStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            block()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            let busy = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - busyStart) / 1e6
            print(String(format: "  %-11@ %7.2f ms elapsed, %6.2f ms on a core", label, ms, busy))
        }
        for round in 1...3 {
            print("round \(round)")
            time("cpu") { _ = cpu.sample() }
            time("memory") { _ = memory.sample() }
            time("processes") { _ = processes.sample() }
            time("thermal") { _ = thermal.sample() }
            time("gpu") { _ = gpu.sample() }
            time("disk") { _ = disk.sample() }
            time("network") { _ = network.sample() }
            time("net light") { _ = network.sample(detail: false) }
            time("net apps") { _ = network.sample(detail: true, apps: 0.1) }
            time("therm light") { _ = thermal.sampleLight() }
            time("gpu apps") { _ = gpu.sample(apps: true) }
            time("power") { _ = power.sample() }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// `Dotmeter --bench-processes`: the process pass alone, many times over, for a profiler to look at.
    static func benchProcesses() {
        let processes = ProcessSampler()
        _ = processes.sample()
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var seen = 0
        for _ in 0..<400 { seen = processes.sample().processes.count }
        print(String(format: "%d processes, %.2f ms on a core a pass", seen, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 400 / 1e6))
    }

    /// `Dotmeter --analyze`: run one analysis headlessly and stream the answer to stdout, from whichever provider
    /// is chosen (DOTMETER_PROVIDER=openai chooses for one run). DOTMETER_API_KEY or DOTMETER_OPENAI_API_KEY stands in
    /// for the Keychain.
    @MainActor
    static func analyze(monitor: SystemMonitor) async {
        try? await Task.sleep(for: .seconds(1.5))
        await monitor.refreshNow()
        try? await Task.sleep(for: .seconds(1))
        await monitor.refreshNow()
        // Nothing is on screen in this mode, so the readings are in `latest`, not in what views observe.
        guard let snapshot = monitor.latest else { return }
        let settings = AppSettings.shared
        guard let client = AIClient.current() else {
            print("ERROR: no \(settings.provider.company) API key (Settings, or \(settings.provider.keyOverride) for this run)")
            return
        }
        if let question = ProcessInfo.processInfo.environment["DOTMETER_QUESTION"] {
            // Free-form question, with whatever storage scan is cached.
            let storage = StorageModel().claudeSummary
            let prompt = AnalysisPrompt.questionMessage(question, snapshot: snapshot, history: monitor.latestHistory, storage: storage)
            print("--- question: \(question) (storage summary: \(storage == nil ? "none" : "\(storage!.count) chars")) ---")
            do {
                for try await chunk in client.stream(system: AnalysisPrompt.chatSystem, messages: [ClaudeMessage(role: "user", content: prompt)]) {
                    print(chunk, terminator: "")
                    fflush(stdout)
                }
                print()
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
            return
        }
        let prompt = AnalysisPrompt.initialMessage(snapshot: snapshot, history: monitor.latestHistory)
        print("--- prompt (\(prompt.count) chars, \(settings.provider.company) model \(settings.activeModel), effort \(settings.effort)) ---")
        print(prompt)
        print("--- response (structured) ---")
        do {
            var raw = ""
            let stream = client.stream(system: AnalysisPrompt.system, messages: [ClaudeMessage(role: "user", content: prompt)], format: AnalysisReport.schema)
            for try await chunk in stream {
                raw += chunk
                print(chunk, terminator: "")
                fflush(stdout)
            }
            print()
            if let report = AnalysisReport.parse(raw) {
                print("--- rendered as text ---")
                print(report.plainText)
            } else {
                print("--- could not parse report ---")
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }

    /// `Dotmeter --render-card out.png [state]`: render the storage card alone at 2x for comparison with the reference.
    @MainActor
    static func renderCard(to path: String, state: String) {
        let storage = StorageModel()
        storage.debugSet(state)
        let view = MeterCard(model: storage.meter)
            .padding(.horizontal, 15)
            .padding(.vertical, 13.5)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// `Dotmeter --clear-test <folder>`: run the real delete path on a throwaway folder. Refuses anything outside a temp directory.
    static func clearTest(_ path: String) async {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let tempRoots = ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"]
        guard tempRoots.contains(where: { resolved.hasPrefix($0) }) else {
            print("refusing: \(resolved) is not inside a temp directory")
            return
        }
        let stats = DirectoryWalker.walk(resolved, cancelled: { false }) { _, _ in }
        let children = stats.children.map { StorageChild(name: $0.name, path: resolved + "/" + $0.name, bytes: Double($0.bytes)) }
        print("before: \(children.count) items, \(stats.bytes) bytes")
        let freed = await DiskStorageBackend().clear("caches", children: children) { path, done in print("  removing \(path) (freed so far \(Int(done)))") }
        let after = DirectoryWalker.walk(resolved, cancelled: { false }) { _, _ in }
        print("freed \(Int(freed)) bytes; left behind: \(after.children.map { $0.name })")
    }

    /// `Dotmeter --bench-draw`: CPU time (all threads) and wall time per bar redraw, for different pixel formats.
    /// CoreGraphics fans compositing out over every core; on a many-core Mac that overhead dwarfs the drawing itself.
    static func benchDraw() {
        let demo = DemoStorageBackend.final
        let segments = StorageCategoryInfo.all.map { MatrixSegment(id: $0.id, rgb: $0.rgb, value: demo[$0.id] ?? 0) }
        let size = CGSize(width: 540 + 28, height: MatrixLayerView.barHeight(rows: PX.fullRows) + 68)
        let bar = CGRect(x: 14, y: 54, width: 540, height: MatrixLayerView.barHeight(rows: PX.fullRows))

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }

        func run(_ label: String, _ make: () -> CGContext?) {
            guard let ctx = make() else { print("\(label): could not create context"); return }
            ctx.translateBy(x: 0, y: CGFloat(ctx.height))
            ctx.scaleBy(x: 2, y: -2)
            let engine = MatrixEngine()
            engine.sync(segments, capacity: 512e9, highlight: nil, mode: .rest, animateIn: false)
            engine.settle()
            let n = 300
            let cpu0 = cpuSeconds(), wall0 = CACurrentMediaTime()
            for i in 0..<n {
                ctx.clear(CGRect(origin: .zero, size: size))
                engine.drawBase(ctx, bar: bar, time: 1000 + Double(i) * 0.1, rows: PX.fullRows)
            }
            let cpu = (cpuSeconds() - cpu0) / Double(n) * 1000, wall = (CACurrentMediaTime() - wall0) / Double(n) * 1000
            var buffer: [UInt8] = []
            let cell0 = cpuSeconds()
            for i in 0..<n { engine.fillCells(&buffer, bar: bar, rows: PX.fullRows, time: 1000 + Double(i) * 0.1) }
            let cells = (cpuSeconds() - cell0) / Double(n) * 1000
            print(String(format: "%@  base: wall %.2f ms, cpu %.2f ms   cells bitmap: cpu %.3f ms", label.padding(toLength: 28, withPad: " ", startingAt: 0), wall, cpu, cells))
        }

        let w = Int(size.width * 2), h = Int(size.height * 2)
        run("8-bit sRGB bitmap") {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        run("8-bit Display P3 bitmap") {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        run("16-bit float extended sRGB") {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.extendedSRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        }
    }

    /// `Dotmeter --remove-test <temp path> delete|trash`: run the single-item removal on a throwaway file or folder.
    /// Refuses anything outside a temp directory. In trash mode it cleans the test item back out of the Trash.
    static func removeTest(_ path: String, mode: String) async {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let tempRoots = ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"]
        // One exact name is allowed outside a temp folder: a throwaway app the test's caller puts in Applications,
        // because macOS only guards apps where apps live.
        guard tempRoots.contains(where: { resolved.hasPrefix($0) }) || resolved == "/Applications/Dotmeter Removal Test.app" else {
            print("refusing: \(resolved) is not inside a temp directory")
            return
        }
        let item = StorageChild(name: (resolved as NSString).lastPathComponent, path: resolved, bytes: 0)
        if mode == "trash" {
            // The app's own move, keeping where the item landed so the test leaves nothing behind.
            do {
                let landed = try await DiskStorageBackend.moveToTrash(URL(fileURLWithPath: resolved))
                print("moved to Trash: \(landed?.path ?? "?"); still at original path: \(FileManager.default.fileExists(atPath: resolved))")
                // The Finder does not say where it put the item; it is in the Trash under its own name.
                let inTrash = landed ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent((resolved as NSString).lastPathComponent)
                if landed == nil { print("the Finder moved it") }
                // A locked folder has to be unlocked before it will go.
                _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inTrash.path)
                if (try? FileManager.default.removeItem(at: inTrash)) != nil { print("test item removed from Trash again") } else { print("NOTE: could not remove the test item from the Trash") }
            } catch {
                print("trash failed: \(error)")
                let said = await DiskStorageBackend().remove(item, permanently: false) { _ in }
                print("what the page would say: \(said?.message ?? "ok")\(said?.fix == .finderAccess ? " [offers to open the Automation setting]" : "")")
            }
        } else {
            let seen = ProgressLog()
            let failure = await DiskStorageBackend().remove(item, permanently: true) { seen.add($0) }
            let values = seen.values
            let rising = zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
            print("delete result: \(failure?.message ?? "ok"); still exists: \(FileManager.default.fileExists(atPath: resolved)); progress reported \(values.count) times, rising: \(rising), first \(values.first.map { String(format: "%.3f", $0) } ?? "-"), last \(values.last.map { String(format: "%.3f", $0) } ?? "-")")
        }
        let missing = await DiskStorageBackend().remove(StorageChild(name: "nope", path: resolved + "-does-not-exist", bytes: 0), permanently: true) { _ in }
        print("removing a missing item reports: \(missing?.message ?? "ok (unexpected)")")
    }

    /// `Dotmeter --scan-report <file>`: run the real scan headlessly and write the totals, so the maths can be checked.
    static func scanReport(to path: String) async {
        let backend = DiskStorageBackend()
        let volume = backend.volume()
        let start = Date()
        let result = await backend.scan { _ in }
        let elapsed = Date().timeIntervalSince(start)
        func gb(_ v: Double) -> String { String(format: "%8.1f GB", v / 1e9) }
        var lines = ["\(App.name) scan report"]
        lines.append("volume \(volume.name) (\(volume.format)): capacity \(gb(volume.capacity)), free \(gb(volume.free)), reclaimable \(gb(volume.purgeable))")
        let used = volume.capacity - volume.free
        var measured = 0.0
        for info in StorageCategoryInfo.all where info.id != "system" {
            let value = result.bytes[info.id] ?? 0
            measured += value
            lines.append("  \(info.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(gb(value))   \(result.details[info.id] ?? "")")
        }
        lines.append("measured in folders \(gb(measured))")
        lines.append("used on disk        \(gb(used))")
        lines.append("system data         \(gb(max(0, used - measured)))  (used minus measured)")
        lines.append("  of which found in Library: \(gb(result.libraryBytes))")
        for child in (result.children["system"] ?? []).prefix(8) { lines.append("      \(gb(child.bytes))  \(child.name)") }
        lines.append("shared storage counted once (clones + hard links): \(gb(result.sharedBytesSkipped))")
        lines.append(measured > used ? "RESULT: measured exceeds used by \(gb(measured - used)); categories will be scaled by \(String(format: "%.3f", used / measured))" : "RESULT: measured fits inside used")
        lines.append("some folders unreadable: \(result.denied ? "yes" : "no") · elapsed \(String(format: "%.1f", elapsed)) s")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }

    /// `Dotmeter --scan-test <folder>`: time the directory walker on one folder and print what it found.
    static func scanTest(_ path: String) {
        let start = Date()
        let deduper = ScanDeduper()
        var stats = DirectoryWalker.walk(path, cancelled: { false }) { _, _ in }
        let sharedFiles = stats.shared.count
        DirectoryWalker.resolve(&stats, with: deduper)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "%@: %.2f GB in %d files, %.2fs (%.0f files/s), denied=%@", path, Double(stats.bytes) / 1e9, stats.files, elapsed, Double(stats.files) / max(elapsed, 0.001), stats.denied ? "yes" : "no"))
        print(String(format: "  %d files share storage; %.2f GB counted once instead of repeatedly", sharedFiles, Double(deduper.bytesSkipped) / 1e9))
        for child in stats.children.sorted(by: { $0.bytes > $1.bytes }).prefix(6) {
            print(String(format: "  %8.2f GB  %@", Double(child.bytes) / 1e9, child.name))
        }
        if let file = stats.largestFile { print(String(format: "  largest file: %@ (%.2f GB)", file.name, Double(file.bytes) / 1e9)) }
        print("  photos \(stats.photos) videos \(stats.videos) songs \(stats.songs)")
    }

    /// `Dotmeter --render out.png`: a still render of the menu bar panel. The window scrolls, so capture it live with `--open`.
    @MainActor
    static func render(models: AppModels, to path: String) async {
        let monitor = models.monitor
        // Behave as if a panel were open, so readings are published to the views being rendered.
        monitor.networkAppsEvery = 1
        monitor.panelVisible = true
        try? await Task.sleep(for: .seconds(1.5))
        await monitor.refreshNow()
        try? await Task.sleep(for: .seconds(1))
        await monitor.refreshNow()
        let base = path.hasSuffix(".png") ? String(path.dropLast(4)) : path

        func write(_ view: some View, _ suffix: String) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            let out = base + suffix
            try? png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }

        let panel = PopoverView(openApp: { _ in }, openSettings: {})
            .pxCard()
            .padding(24)
            .background(Color(white: 0.9))
            .dotmeterModels(models)
        write(panel, "-panel.png")

        // The Network area's two tables at the width of a single card, each with a row open.
        if let network = monitor.snapshot?.network {
            let tables = VStack(spacing: 20) {
                InterfacesPanel(network: network, width: PX.cardWidth, open: .constant(network.primary))
                NetworkAppsPanel(network: network, width: PX.cardWidth, expanded: .constant(network.apps.first?.id))
            }
            .padding(24)
            .background(Color(white: 0.9))
            .dotmeterModels(models)
            write(tables, "-network-tables.png")
        }
    }
}

/// Collects progress values from another thread, for the removal test.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A disk for the storage self-test: its free space is whatever the test says, and a scan finds two folders.
private final class MadeUpDisk: StorageBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Double
    private var space: Double
    var free: Double {
        get { lock.withLock { space } }
        set { lock.withLock { space = newValue } }
    }

    init(capacity: Double, free: Double) {
        self.capacity = capacity
        space = free
    }

    var isDemo: Bool { false }
    func volume() -> StorageVolume { StorageVolume(capacity: capacity, free: free, purgeable: 0, name: "Made up", format: "APFS") }
    func scan(update: @escaping @Sendable (StorageScanUpdate) -> Void) async -> StorageScanResult {
        StorageScanResult(bytes: ["apps": 100e9, "documents": 50e9])
    }
    func clear(_ id: String, children: [StorageChild], update: @escaping @Sendable (_ path: String, _ freed: Double) -> Void) async -> Double { 0 }
    func remove(_ item: StorageChild, permanently: Bool, progress: @escaping @Sendable (Double) -> Void) async -> RemovalFailure? { nil }
}

import IOSurface

extension DebugTools {
    /// `Dotmeter --bench-contents`: what it costs this process to hand a new picture to a layer, by pixel format.
    /// A small window is shown for a few seconds so the layers really are committed to the screen.
    @MainActor
    static func benchContents() {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        let layers: [CALayer] = (0..<8).map { index in
            let layer = CALayer()
            layer.frame = CGRect(x: 10 + (index % 4) * 100, y: 10 + (index / 4) * 70, width: 90, height: 60)
            layer.magnificationFilter = .nearest
            view.layer?.addSublayer(layer)
            return layer
        }
        CATransaction.flush()
        let screenSpace = window.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        print("screen colour space: \(screenSpace.name.map { $0 as String } ?? "a profile of its own") · model \(screenSpace.model.rawValue)")
        let rgba = CGImageAlphaInfo.premultipliedLast.rawValue
        let bgra = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        func threadTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

        func run(_ name: String, width: Int, height: Int, make: (Int, Int) -> Any?) {
            // Warm up, then time 400 rounds of eight new pictures and the commit that carries them.
            var total: UInt64 = 0
            for round in 0..<440 {
                let start = threadTime()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (index, layer) in layers.enumerated() { layer.contents = make(round, index) }
                CATransaction.commit()
                CATransaction.flush()
                if round >= 40 { total += threadTime() - start }
            }
            print(String(format: "%-46@ %3dx%-3d  %6.1f µs a picture", name as NSString, width, height, Double(total) / 400 / 8 / 1000))
        }
        func image(_ width: Int, _ height: Int, _ space: CGColorSpace, _ info: UInt32, seed: Int) -> CGImage? {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let v = UInt8(truncatingIfNeeded: (i &* 31 &+ seed &* 7) >> 3)
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!, p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        for (width, height) in [(160, 22), (1200, 240)] {
            run("sRGB, RGBA (as now)", width: width, height: height) { round, index in image(width, height, srgb, rgba, seed: round * 8 + index) }
            run("sRGB, BGRA", width: width, height: height) { round, index in image(width, height, srgb, bgra, seed: round * 8 + index) }
            run("the screen's own space, RGBA", width: width, height: height) { round, index in image(width, height, screenSpace, rgba, seed: round * 8 + index) }
            run("the screen's own space, BGRA", width: width, height: height) { round, index in image(width, height, screenSpace, bgra, seed: round * 8 + index) }
            run("Display P3, BGRA", width: width, height: height) { round, index in image(width, height, p3, bgra, seed: round * 8 + index) }
            // A surface each layer keeps: the bytes are written in place and the layer is told they changed.
            let surfaces: [IOSurface] = layers.map { _ in
                IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x42475241 as UInt32])!
            }
            for (index, layer) in layers.enumerated() { layer.contents = surfaces[index] }
            CATransaction.flush()
            let changed = Selector(("setContentsChanged"))
            print("layers answer to setContentsChanged: \(layers[0].responds(to: changed))")
            var total: UInt64 = 0
            for round in 0..<440 {
                let start = threadTime()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (index, layer) in layers.enumerated() {
                    let surface = surfaces[index]
                    surface.lock(options: [], seed: nil)
                    let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                    let row = surface.bytesPerRow
                    for y in 0..<height {
                        for x in stride(from: 0, to: width * 4, by: 4) {
                            let v = UInt8(truncatingIfNeeded: ((y * width * 4 + x) &* 31 &+ (round * 8 + index) &* 7) >> 3)
                            base[y * row + x] = v; base[y * row + x + 1] = v; base[y * row + x + 2] = v; base[y * row + x + 3] = 255
                        }
                    }
                    surface.unlock(options: [], seed: nil)
                    if layer.responds(to: changed) { layer.perform(changed) }
                }
                CATransaction.commit()
                CATransaction.flush()
                if round >= 40 { total += threadTime() - start }
            }
            print(String(format: "%-46@ %3dx%-3d  %6.1f µs a picture", "a surface written in place" as NSString, width, height, Double(total) / 400 / 8 / 1000))
            // What filling the bytes alone costs, so the rows above can be read net of it.
            var fill: UInt64 = 0
            for round in 0..<400 {
                let start = threadTime()
                for index in 0..<8 { _ = image(width, height, srgb, rgba, seed: round * 8 + index) }
                fill += threadTime() - start
            }
            print(String(format: "%-46@ %3dx%-3d  %6.1f µs a picture", "(making the picture alone, no layer)" as NSString, width, height, Double(fill) / 400 / 8 / 1000))
            // The other way round: leave the pictures in sRGB and make the window an sRGB one.
            let before = window.colorSpace
            window.colorSpace = .sRGB
            CATransaction.flush()
            run("sRGB picture in a window set to sRGB", width: width, height: height) { round, index in image(width, height, srgb, rgba, seed: round * 8 + index) }
            run("screen-space picture in a window set to sRGB", width: width, height: height) { round, index in image(width, height, screenSpace, rgba, seed: round * 8 + index) }
            window.colorSpace = before
            CATransaction.flush()
        }
        window.orderOut(nil)
    }
}
