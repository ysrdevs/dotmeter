import Foundation
import Network

extension DebugTools {
    /// `--self-test macs`: the code, the key, the messages, and two ends talking over 127.0.0.1 in this one
    /// process. Nothing is advertised or browsed, so macOS has nothing to ask about, and nothing is saved.
    @MainActor
    static func macsSelfTest(models: AppModels) async {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok    " : "FAILED") \(what)")
            if ok { passed += 1 } else { failed += 1 }
            fflush(stdout)
        }
        /// Lets the main queue run until `done` says so, and says how long that took (nil when it never did).
        func wait(_ seconds: Double, _ done: () -> Bool) async -> Double? {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if done() { return Date().timeIntervalSince(start) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done() ? seconds : nil
        }
        func ms(_ seconds: Double?) -> String { seconds.map { "\(Int($0 * 1000)) ms" } ?? "never" }

        let defaults = UserDefaults.standard
        let savedBefore = ["macsOn", "macsCode", "macsID"].map { defaults.object(forKey: $0).map { "\($0)" } ?? "unset" }

        // MARK: The code
        let lookAlikes = Set("0O1IL2Z5S8B")
        let codes = (0..<400).map { _ in MacsCode.make() }
        let alphabet = Set(MacsCode.alphabet)
        check(alphabet.count == MacsCode.alphabet.count && alphabet.isDisjoint(with: lookAlikes), "the code alphabet is \(MacsCode.alphabet.count) characters, none repeated, none a look-alike (\(String(MacsCode.alphabet)))")
        check(codes.allSatisfy { code in
            let groups = code.split(separator: "-", omittingEmptySubsequences: false)
            return code.count == 14 && groups.count == 3 && groups.allSatisfy { $0.count == 4 && $0.allSatisfy(alphabet.contains) }
        }, "400 codes are each three groups of four from that alphabet, such as \(codes[0])")
        check(Set(codes).count == codes.count, "no two of the 400 are the same")
        check(MacsCode.normalized("kq4m 7txa-9hwe") == "KQ4M-7TXA-9HWE" && MacsCode.normalized("KQ4M7TXA9HWE") == "KQ4M-7TXA-9HWE", "a typed code is forgiven its case, spaces and dashes")
        check(MacsCode.normalized("KQ4M-7TXA-9HW") == nil && MacsCode.normalized("KQ4M-7TXA-9HW0") == nil && MacsCode.normalized("") == nil, "a short code, and one with a character no code has, are turned away")

        // MARK: The key
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        // Worked out apart from the app, by RFC 5869 over HMAC-SHA256: key ACDEFGHJKMNP, salt and label as in `MacsCode.key`.
        let expected = "9d4cb14bf6ccaa8ff420f62fcd1db2273afc43954da209e39066cdd0b5507e35"
        check(hex(MacsCode.key(for: "ACDE-FGHJ-KMNP")) == expected, "the key for ACDE-FGHJ-KMNP is the one worked out by hand (\(expected.prefix(16))…)")
        check(MacsCode.key(for: "acdefghjkmnp") == MacsCode.key(for: "ACDE-FGHJ-KMNP"), "however the code is written, the key is the same")
        check(MacsCode.key(for: "ACDE-FGHJ-KMNQ") != MacsCode.key(for: "ACDE-FGHJ-KMNP") && MacsCode.key(for: "ACDE-FGHJ-KMNQ").count == 32, "another code gives another 32-byte key")

        // MARK: The messages
        let hello = MacHello(id: "0123456789abcdef", name: "Test \"Studio\" / büro\n2", model: "Mac Studio", chip: "Apple M3 Ultra", app: "2.2")
        let full = MacReading(
            time: 1_795_000_000.25, every: 2, cpu: 0.4321, gpu: 0.125, memoryUsed: 151_732_604_928, memoryTotal: 549_755_813_888, pressure: "warning",
            temperature: 71.5, fans: [1012, 1009], fanLevel: 0.004, watts: 36.4, down: 23_400_000, up: 2_050_000,
            diskFree: 612_000_000_000, diskTotal: 1_995_218_165_760, battery: .init(charge: 0.62, charging: true, plugged: true, minutes: 48),
            uptime: 283_412, severity: Severity.elevated.rawValue,
            apps: [.init(name: "Xcode", cpu: 2.14), .init(name: "Safari", cpu: 0.58), .init(name: "Music", cpu: 0.09)]
        )
        let line = MacsWire.line(.reading(full))
        check(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil, "a reading is one line of \(line.count) bytes")
        check(MacsWire.message(from: line.dropLast()) == .reading(full), "a reading written and read back has every field as it was")
        let helloLine = MacsWire.line(.hello(hello))
        check(helloLine.dropLast().firstIndex(of: 0x0A) == nil && MacsWire.message(from: helloLine.dropLast()) == .hello(hello), "so has a hello, with quotes, a slash and a line break in the name")
        check(MacsWire.message(from: MacsWire.line(.watching).dropLast()) == .watching, "and the note that a Mac is still watching")

        let newer = #"{"v":7,"type":"reading","sentBy":{"build":4410},"reading":{"time":1795000000.25,"every":2,"cpu":0.4321,"gpu":0.125,"neural":0.3,"memoryUsed":151732604928,"memoryTotal":549755813888,"pressure":"warning","temperature":71.5,"fans":[1012,1009],"fanLevel":0.004,"watts":36.4,"down":23400000,"up":2050000,"diskFree":612000000000,"diskTotal":1995218165760,"battery":{"charge":0.62,"charging":true,"plugged":true,"minutes":48,"health":0.91},"uptime":283412,"severity":1,"lid":"open","apps":[{"name":"Xcode","cpu":2.14,"gpu":0.2},{"name":"Safari","cpu":0.58},{"name":"Music","cpu":0.09}]}}"#
        check(MacsWire.message(from: Data(newer.utf8)) == .reading(full), "a reading from protocol version 7, with fields this version has never heard of, is read all the same")
        check(MacsWire.message(from: Data(#"{"v":7,"type":"clipboard","text":"x"}"#.utf8)) == .unknown("clipboard"), "a kind of message this version does not know is skipped")
        check(MacsWire.message(from: Data(#"{"v":7,"needs":3,"type":"reading"}"#.utf8)) == .tooNew(needs: 3), "one that says it needs a newer reader is reported as that")
        let lean = #"{"v":1,"type":"reading","reading":{"time":1,"every":2,"cpu":0.1,"memoryUsed":1,"memoryTotal":2,"pressure":"normal","fans":[],"down":0,"up":0,"diskFree":1,"diskTotal":2,"uptime":60,"severity":0,"apps":[]}}"#
        if case .reading(let read)? = MacsWire.message(from: Data(lean.utf8)) {
            check(read.gpu == nil && read.temperature == nil && read.watts == nil && read.battery == nil && read.fanLevel == nil, "a Mac that reports no graphics, heat, power or battery is read with those left empty")
        } else {
            check(false, "a Mac that reports no graphics, heat, power or battery is read with those left empty")
        }
        check(MacsWire.message(from: Data("GET / HTTP/1.1".utf8)) == nil, "a line that is not a message is nothing")

        var buffer = MacsLineBuffer()
        let two = MacsWire.line(.hello(hello)) + MacsWire.line(.reading(full))
        var lines = buffer.append(two.prefix(37))
        lines += buffer.append(two.dropFirst(37).prefix(500))
        lines += buffer.append(two.dropFirst(537))
        check(lines.count == 2 && MacsWire.message(from: lines[0]) == .hello(hello) && MacsWire.message(from: lines.last ?? Data()) == .reading(full), "two messages that arrive cut in three pieces come out as two messages")
        var flood = MacsLineBuffer()
        _ = flood.append(Data(repeating: 0x41, count: MacsWire.lineLimit + 1))
        check(flood.overflowed, "a line past \(MacsWire.lineLimit / 1024) KB is refused")

        // What a reading takes from this Mac.
        // Load is a difference between two readings, so the first one names no busy app.
        _ = await wait(4) { models.monitor.latest != nil }
        try? await Task.sleep(for: .seconds(1.2))
        await models.monitor.refreshNow(full: true)
        if let snapshot = models.monitor.latest {
            let reading = MacReading(snapshot: snapshot, every: 2)
            let top = snapshot.apps.sorted { $0.cpu > $1.cpu }.prefix(3).filter { $0.cpu > 0.001 }.map(\.name)
            check(reading.memoryTotal == snapshot.memory.total && reading.diskTotal == snapshot.disk.total && reading.cpu == snapshot.cpu.total && reading.severity == Severity.from(snapshot).rawValue,
                  "a reading of this Mac carries its own figures (memory \(Format.bytes(reading.memoryTotal)), \(reading.fans.count) fans, \(reading.battery == nil ? "no battery" : "a battery"))")
            check(reading.apps.map(\.name) == top.map { String($0.prefix(60)) } && reading.apps.count <= 3, "and its \(reading.apps.count) busiest apps, busiest first, and no other process")
            let text = String(decoding: MacsWire.line(.reading(reading)), as: UTF8.self)
            let addresses = snapshot.network.interfaces.flatMap { $0.ipv4 + $0.ipv6 + [$0.mac, $0.linkLocal6].compactMap { $0 } } + [snapshot.network.router].compactMap { $0 }
            check(!addresses.contains { !$0.isEmpty && text.contains($0) }, "none of this Mac's \(addresses.count) addresses is in it")
        } else {
            check(false, "the monitor gave a reading to test with")
        }

        // MARK: Two ends over 127.0.0.1
        let right = "ACDE-FGHJ-KMNP", wrong = "ACDE-FGHJ-KMNQ"
        var served: [MacsLink] = []
        var servedReady = 0
        var listenerState = MacsListener.State.starting
        guard let listener = MacsListener(code: right, place: .loopback(0)) else {
            check(false, "a listener on 127.0.0.1 could be made")
            print("\(failed) of \(passed + failed) FAILED")
            return
        }
        listener.onState = { listenerState = $0 }
        listener.onLink = { link in
            served.append(link)
            link.onReady = { servedReady += 1 }
            link.start()
        }
        listener.start()
        var port: UInt16 = 0
        _ = await wait(3) {
            if case .ready(let got) = listenerState { port = got }
            return port != 0
        }
        check(port != 0, "a listener is up on 127.0.0.1 port \(port), advertising nothing")
        guard port != 0, let loopback = NWEndpoint.Port(rawValue: port) else {
            print("\(failed) of \(passed + failed) FAILED")
            return
        }
        func dial(_ code: String, to port: NWEndpoint.Port? = nil) -> MacsLink {
            MacsLink(NWConnection(host: "127.0.0.1", port: port ?? loopback, using: MacsTransport.parameters(code: code)))
        }

        // The right code.
        let client = dial(right)
        var clientReady = false, clientEnd: MacsLink.End?
        var heard: [MacsWire.Message] = []
        client.onReady = { clientReady = true }
        client.onMessage = { heard.append($0) }
        client.onEnd = { clientEnd = $0 }
        client.start()
        let opened = await wait(4) { clientReady && servedReady == 1 }
        check(opened != nil, "with the same code on both ends the handshake completes (\(ms(opened)), TLS suite 0x\(String(client.suite ?? 0, radix: 16).uppercased()))")
        check(client.suite == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256), "and it is the pre-shared key suite, so the key is what opened it")
        served.first?.send(.hello(hello))
        served.first?.send(.reading(full))
        let arrived = await wait(3) { heard.count >= 2 }
        check(arrived != nil && heard.first == .hello(hello), "the hello arrives as it was sent")
        check(heard.count >= 2 && heard[1] == .reading(full), "a reading sent down it arrives with every field intact")

        // The wrong code, and no code at all.
        let stranger = dial(wrong)
        var strangerReady = false, strangerEnd: MacsLink.End?, strangerHeard = 0
        stranger.onReady = { strangerReady = true }
        stranger.onMessage = { _ in strangerHeard += 1 }
        stranger.onEnd = { strangerEnd = $0 }
        stranger.start()
        let turnedAway = await wait(5) { strangerEnd != nil }
        try? await Task.sleep(for: .milliseconds(300))
        check(turnedAway != nil && !strangerReady && strangerEnd == .refused, "with another code the handshake fails (\(ms(turnedAway)), \(stranger.lastError ?? "no error given")) and is taken as a refusal")
        check(servedReady == 1 && strangerHeard == 0, "the listener never counted it as connected, and it was told nothing")

        let plain = NWConnection(host: "127.0.0.1", port: loopback, using: .tcp)
        var plainBytes = Data(), plainOver = false
        plain.stateUpdateHandler = { state in
            if case .ready = state {
                plain.send(content: MacsWire.line(.hello(hello)), completion: .contentProcessed { _ in })
                plain.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                    MainActor.assumeIsolated {
                        if let data { plainBytes.append(data) }
                        if complete || error != nil { plainOver = true }
                    }
                }
            }
        }
        plain.start(queue: .main)
        _ = await wait(3) { plainOver }
        plain.cancel()
        check(servedReady == 1 && MacsWire.message(from: plainBytes) == nil && !plainBytes.contains(UInt8(ascii: "{")), "a connection with no key at all gets \(plainBytes.count) bytes of refusal and no reading")

        // One end goes away.
        served.first?.close()
        let noticed = await wait(4) { clientEnd != nil }
        check(noticed != nil && clientEnd == .closed, "when the other end goes away it is noticed in \(ms(noticed))")

        // MARK: Two whole models
        let timing = MacsTiming(heartbeat: 1, watcherTimeout: 4, quietAfterReadings: 2.5, quietFloor: 2, reconnect: 1, refusedRetry: 30, connectTimeout: 4, dropAfter: 7)
        func model(on: Bool = true, code: String = right, listen: Bool, at fixed: UInt16 = 0, peers: [UInt16] = [], name: String, demo: Bool = false) -> MacsModel {
            var config = MacsConfig()
            config.on = on
            config.code = code
            config.loopback = listen ? fixed : nil
            config.peers = peers.map { ("127.0.0.1", $0) }
            config.demo = demo
            config.name = name
            config.trial = true
            if !demo { config.timing = timing }
            let made = MacsModel(config: config)
            made.start(models: models)
            return made
        }

        let shown = model(listen: true, name: "Shown Mac")
        _ = await wait(3) { shown.listeningPort != nil }
        let shownPort = shown.listeningPort ?? 0
        check(shownPort != 0 && shown.watcherCount == 0, "a Mac that is switched on listens (127.0.0.1 port \(shownPort)) and sends nothing while nobody is connected")
        let before = shown.readingsSent
        try? await Task.sleep(for: .seconds(1.2))
        check(shown.readingsSent == before, "no reading goes out with nobody watching")

        let watcher = model(listen: false, peers: [shownPort], name: "Watching Mac")
        check(watcher.peers.isEmpty && !watcher.watching, "a Mac whose Macs page is not on screen connects to nobody")
        let page = UUID()
        watcher.pageAppeared(page, activity: nil)
        let found = await wait(5) { watcher.peers.first?.reading != nil }
        let peer = watcher.peers.first
        check(found != nil && watcher.peers.count == 1 && peer?.hello.name == "Shown Mac" && peer?.answering == true, "with the page on screen the other Mac is listed, by its name, \(ms(found)) later")
        check(peer?.hello.model == SystemInfoProvider.modelName && peer?.hello.chip == SystemInfoProvider.chip, "with its model and chip (\(peer?.hello.model ?? "?"), \(peer?.hello.chip ?? "?"))")
        check(peer?.reading?.memoryTotal == models.monitor.latest?.memory.total && peer?.reading?.diskTotal == models.monitor.latest?.disk.total, "and a reading that is this Mac's own")
        check(watcher.sidebarValue == "1 Mac" && shown.watcherCount == 1, "the sidebar says \"\(watcher.sidebarValue)\", and the Mac being read knows it has one watcher")
        let sentAtStart = shown.readingsSent
        let firstTime = peer?.reading?.time
        try? await Task.sleep(for: .seconds(9))
        let sent = shown.readingsSent - sentAtStart
        check(sent >= 3 && peer?.reading?.time != firstTime && peer?.answering == true, "while it is watched the readings keep the live pace: \(sent) in 9 s (the idle pace would be one)")

        // This Mac's own advertisement, and a Mac with another code.
        let twin = MacsModel(config: {
            var config = MacsConfig()
            config.on = true
            config.code = right
            config.peers = [("127.0.0.1", shownPort)]
            config.id = shown.hello.id
            config.trial = true
            config.timing = timing
            return config
        }())
        twin.start(models: models)
        twin.pageAppeared(UUID(), activity: nil)
        let outsider = model(code: wrong, listen: false, peers: [shownPort], name: "Outsider")
        outsider.pageAppeared(UUID(), activity: nil)
        _ = await wait(4) { outsider.otherCodes == 1 }
        try? await Task.sleep(for: .seconds(1))
        check(twin.peers.isEmpty && twin.sidebarValue.isEmpty, "a Mac that reaches its own listener does not list itself")
        check(outsider.otherCodes == 1 && outsider.peers.isEmpty && shown.watcherCount == 1, "a Mac with another code lists nobody, says one Mac here has another code, and is not counted as a watcher")
        twin.setOn(false)
        outsider.setOn(false)

        // A page on a window that is hidden or closed.
        let window = ViewActivity(active: true)
        let hiddenPage = UUID()
        let second = model(listen: false, peers: [shownPort], name: "Second Watcher")
        second.pageAppeared(hiddenPage, activity: window)
        _ = await wait(4) { shown.watcherCount == 2 }
        let both = shown.watcherCount
        window.active = false
        let letGo = await wait(4) { !second.watching && shown.watcherCount == 1 }
        check(both == 2 && letGo != nil, "when the page's window is hidden or closed, without the page saying so, the connection is closed (\(ms(letGo)))")
        window.active = true
        try? await Task.sleep(for: .milliseconds(600))
        check(!second.watching, "and a window shown again does not bring back a page that has gone")
        second.setOn(false)

        // A watcher that goes silent without closing.
        let mute = dial(right, to: NWEndpoint.Port(rawValue: shownPort))
        var muteReady = false, muteEnd: MacsLink.End?
        mute.onReady = { muteReady = true }
        mute.onEnd = { muteEnd = $0 }
        mute.start()
        _ = await wait(3) { muteReady && shown.watcherCount == 2 }
        let dropped = await wait(10) { muteEnd != nil }
        check(muteReady && dropped != nil && shown.watcherCount == 1, "a watcher that says nothing for \(Int(timing.watcherTimeout)) s is let go (\(ms(dropped))), so a Mac that fell asleep watching does not keep this one working")

        // The Mac being watched goes silent without closing, then goes away.
        var quietLinks: [MacsLink] = []
        let quietListener = MacsListener(code: right, place: .loopback(0))
        var quietPort: UInt16 = 0
        quietListener?.onState = { if case .ready(let got) = $0 { quietPort = got } }
        quietListener?.onLink = { link in
            quietLinks.append(link)
            link.onReady = {
                link.send(.hello(MacHello(id: "quiet-mac", name: "Quiet Mac", model: "Mac mini", chip: "Apple M4", app: "2.2")))
                var one = full
                one.every = 1
                link.send(.reading(one))
            }
            link.start()
        }
        quietListener?.start()
        _ = await wait(3) { quietPort != 0 }
        let third = model(listen: false, peers: [quietPort], name: "Third Watcher")
        third.pageAppeared(UUID(), activity: nil)
        let listed = await wait(4) { third.peers.first?.answering == true }
        let silence = await wait(8) { third.peers.first?.answering == false }
        check(listed != nil && silence != nil && third.peers.count == 1, "a Mac that stops sending without closing is marked as not answering \(ms(silence)) after its last reading, and stays listed")
        check(third.sidebarValue.isEmpty && third.peers.first?.seen.hasPrefix("last seen") == true, "it leaves the sidebar's count and says \"\(third.peers.first?.seen ?? "")\"")
        quietListener?.stop()
        for link in quietLinks { link.close() }
        let gone = await wait(12) { third.peers.isEmpty }
        check(gone != nil, "and after \(Int(timing.dropAfter)) s without an answer (shortened for this test) it drops off the list")
        third.setOn(false)

        // Switched off at the far end.
        shown.setOn(false)
        let wentQuiet = await wait(4) { watcher.peers.first?.answering == false }
        check(wentQuiet != nil && watcher.sidebarValue.isEmpty && shown.watcherCount == 0 && shown.listeningPort == nil, "when the other Mac switches the feature off, this one notices in \(ms(wentQuiet)) and the other stops listening")
        let afterOff = shown.readingsSent
        try? await Task.sleep(for: .seconds(2.5))
        check(shown.readingsSent == afterOff, "and sends nothing more")
        watcher.pageDisappeared(page)
        check(!watcher.watching, "a page that leaves the screen stops the looking")
        watcher.setOn(false)

        // A new code, and a code typed in.
        listener.stop()
        client.close()
        try? await Task.sleep(for: .milliseconds(300))
        let keyed = model(listen: true, at: port, name: "Keyed Mac")
        let typist = model(listen: false, peers: [port], name: "Typist")
        typist.pageAppeared(UUID(), activity: nil)
        let paired = await wait(5) { typist.peers.first?.answering == true }
        keyed.newCode()
        let fresh = keyed.code
        let shutOut = await wait(6) { typist.otherCodes == 1 && typist.peers.first?.answering == false }
        check(paired != nil && fresh != right && MacsCode.normalized(fresh) == fresh && shutOut != nil, "a new code on one Mac shuts out a Mac still holding the old one (\(ms(shutOut)))")
        let refusedCode = typist.useCode("not a code")
        check(!refusedCode && typist.code == right, "something typed that cannot be a code is turned away and changes nothing")
        let taken = typist.useCode(fresh.lowercased().replacingOccurrences(of: "-", with: " "))
        let back = await wait(6) { typist.peers.first?.answering == true && typist.otherCodes == 0 }
        check(taken && typist.code == fresh && back != nil, "typing the new code into the other Mac, in lower case with spaces, brings them back together (\(ms(back)))")
        keyed.setOn(false)
        typist.setOn(false)

        // Off, and the demo.
        let off = model(on: false, listen: true, peers: [port], name: "Off")
        off.pageAppeared(UUID(), activity: nil)
        try? await Task.sleep(for: .milliseconds(700))
        check(off.listeningPort == nil && !off.watching && off.peers.isEmpty, "switched off, a Mac neither listens nor looks, page open or not")
        let demo = model(listen: false, name: "Demo", demo: true)
        demo.pageAppeared(UUID(), activity: nil)
        try? await Task.sleep(for: .milliseconds(300))
        check(demo.peers.count == 3 && demo.peers.filter { !$0.answering }.count == 1 && demo.sidebarValue == "2 Macs" && demo.code == MacsDemo.code && demo.listeningPort == nil && MacsCode.normalized(MacsDemo.code) == MacsDemo.code,
              "the demo lists \(demo.peers.map(\.hello.name).joined(separator: ", ")), one of them gone quiet, under a made-up code, and listens to nothing")
        demo.setOn(false)

        let savedAfter = ["macsOn", "macsCode", "macsID"].map { defaults.object(forKey: $0).map { "\($0)" } ?? "unset" }
        check(savedBefore == savedAfter, "nothing the app remembers was changed by any of this")
        print(failed == 0 ? "all \(passed) checks pass" : "\(failed) of \(passed + failed) FAILED")
    }
}
