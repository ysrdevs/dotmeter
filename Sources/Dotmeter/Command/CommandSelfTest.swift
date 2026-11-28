import Foundation

extension DebugTools {
    /// `Dotmeter --self-test command`: the words, the JSON, every reading both ways, the AI server fed line by line,
    /// the recorded week read from a file of the test's own, and that no address gets out unasked. It reads this
    /// Mac and touches nothing: no network, no clipboard, and no file but the ones it makes in a temporary folder.
    static func commandSelfTest(models: AppModels) async {
        var checks = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            checks += 1
            if !ok { failed += 1 }
            print(ok ? "ok  \(name)" : "FAILED \(name)\(String(describing: got).isEmpty ? "" : " (got \(got))")")
        }
        func parsed(_ text: String?) -> [String: Any]? {
            guard let text, let data = text.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        // MARK: Words

        let handled = [["status"], ["cpu", "--json"], ["mcp"], ["help"], ["--help"], ["-h"], ["bogus"], ["Status"], [""]]
        check("a word is a command, a mistyped one included", handled.allSatisfy(Command.handles), handled.filter { !Command.handles($0) })
        let passed: [[String]] = [[], ["--open"], ["--self-test", "command"], ["--dump"], ["-psn_0_12345"], ["--usb", "--json"]]
        check("the app's own flags are left to the app", passed.allSatisfy { !Command.handles($0) }, passed.filter(Command.handles))

        func request(_ arguments: [String]) -> Command.Request? {
            if case .request(let request) = Command.parse(arguments) { return request }
            return nil
        }
        func mistake(_ arguments: [String]) -> Bool {
            if case .mistake = Command.parse(arguments) { return true }
            return false
        }
        let typed = ["status", "cpu", "graphics", "memory", "thermals", "network", "power", "storage", "apps", "usb", "timeline"]
        check("every reading has its word", zip(typed, Command.Reading.allCases).allSatisfy { request([$0])?.word == .reading($1) })
        check("cpu and processor are the same reading", request(["cpu"])?.word == .reading(.processor) && request(["processor"])?.word == .reading(.processor))
        check("help and mcp", request(["help"])?.word == .help && request(["--help"])?.word == .help && request(["mcp"])?.word == .mcp)
        check("unknown words are refused", mistake(["bogus"]) && mistake(["Status"]) && mistake([""]) && mistake([]))
        let ranked = request(["apps", "--by", "memory", "--top", "5"])?.options
        check("apps --by memory --top 5", ranked?.by == .memory && ranked?.top == 5 && ranked?.json == false, ranked as Any)
        let joined = request(["apps", "--by=gpu", "--top=3", "--json"])?.options
        check("the same with equals signs, and --json", joined?.by == .gpu && joined?.top == 3 && joined?.json == true, joined as Any)
        check("timeline --hours 24", request(["timeline", "--hours", "24"])?.options.hours == 24 && request(["timeline"])?.options.hours == nil)
        check("network --addresses", request(["network", "--addresses"])?.options.addresses == true && request(["network"])?.options.addresses == false)
        let wrong = [["apps", "--by", "speed"], ["apps", "--top", "0"], ["apps", "--top", "101"], ["apps", "--top"], ["apps", "--top", "many"], ["cpu", "--top", "3"], ["status", "--by", "cpu"], ["timeline", "--hours", "999"], ["cpu", "--hours", "2"], ["status", "--open"], ["status", "extra"], ["mcp", "--json"]]
        check("wrong options are refused, each of \(wrong.count)", wrong.allSatisfy(mistake), wrong.filter { !mistake($0) })
        check("the usage names every word", (typed + ["mcp", "help", "--json", "--addresses", "--by", "--top", "--hours"]).allSatisfy { Command.usage.contains($0) })

        // MARK: JSON

        let sample = JSON.record(["zeta": .int(1), "alpha": JSON.fraction(0.1), "missing": JSON.text(nil), "third": JSON.fraction(1.0 / 3), "odd": .number(.nan, places: 2), "text": .string("a \"quoted\"\nline\t\u{1}"), "list": .array([.int(1), .number(2.50, places: 2)]), "empty": .array([]), "none": .null])
        check("keys keep their order and a missing value leaves no key", sample.keys == ["zeta", "alpha", "third", "odd", "text", "list", "empty", "none"], sample.keys)
        check("figures are written to the digits that mean something", sample.compact.contains("\"alpha\":0.1,") && sample.compact.contains("\"third\":0.3333,") && sample.compact.contains("\"odd\":null") && sample.compact.contains("[1,2.5]"), sample.compact)
        check("one line when compact, and still JSON either way", !sample.compact.contains("\n") && parsed(sample.compact)?["text"] as? String == "a \"quoted\"\nline\t\u{1}" && (parsed(sample.pretty)?["list"] as? [Any])?.count == 2, sample.compact)
        check("whole figures, and no zeros or minus signs that say nothing", JSON.digits(1234.5, places: 0) == "1235" && JSON.digits(-0.00001, places: 2) == "0" && JSON.digits(52.0, places: 2) == "52" && JSON.digits(0.126, places: 2) == "0.13", JSON.digits(1234.5, places: 0))

        // MARK: Readings

        let reader = MeterReader()
        let started = Date()
        let network = reader.read(network: true).network
        check("a first reading waits for a difference", Date().timeIntervalSince(started) >= MeterReader.window - 0.05, Date().timeIntervalSince(started))

        // Everything about this Mac that must not get out unasked. Never printed: only counted.
        var secrets = Set<String>()
        for item in network.interfaces {
            secrets.formUnion(item.ipv4)
            secrets.formUnion(item.ipv6)
            if let local = item.linkLocal6 { secrets.insert(local) }
            if let mac = item.mac { secrets.insert(mac) }
        }
        if let router = network.router { secrets.insert(router) }
        secrets.formUnion(network.dns)
        secrets.formUnion(network.searchDomains)
        if let name = network.wifi?.ssid { secrets.insert(name) }
        secrets = secrets.filter { $0.count >= 6 }
        func leaks(_ text: String) -> Int { secrets.filter { text.contains($0) }.count }
        let addressShaped = try? NSRegularExpression(pattern: "\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b|\\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\\b")
        func shaped(_ text: String) -> Int { addressShaped?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0 }

        var outputs: [String] = []
        let options = Command.Options()
        /// The keys a description names: the plain words in its brackets.
        func named(_ description: String) -> [String] {
            guard let open = description.firstIndex(of: "("), let close = description.firstIndex(of: ")"), open < close else { return [] }
            return description[description.index(after: open)..<close].components(separatedBy: ", ").filter { $0.range(of: "^[a-z_]+$", options: .regularExpression) != nil }
        }
        for tool in MeterServer.tools {
            let gathered = Command.Gathered(tool.reading, reader: reader)
            let json = gathered.json(options)
            let text = gathered.text(options)
            outputs += [json.compact, json.pretty, text]
            let object = parsed(json.compact)
            let allowed = Set(tool.promises + tool.sometimes)
            let missing = tool.promises.filter { object?[$0] == nil }
            let stray = json.keys.filter { !allowed.contains($0) }
            check("\(tool.name): JSON with every key it always has, and none it does not list", object != nil && parsed(json.pretty) != nil && missing.isEmpty && stray.isEmpty, "missing \(missing), unlisted \(stray)")
            let loose = named(tool.description).filter { !allowed.contains($0) }
            check("\(tool.name): its description names only keys it returns", !named(tool.description).isEmpty && loose.isEmpty, loose)
            check("\(tool.name): text, short and without stray spaces", !text.isEmpty && text.count < 6000 && !text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasSuffix(" ") }, text.count)
        }
        let snapshot = reader.read()
        func number(_ json: JSON, _ key: String) -> Double? {
            switch json[key] {
            case .int(let value)?: return Double(value)
            case .number(let value, _)?: return value
            default: return nil
            }
        }
        let processor = Report.processor(snapshot)
        check("processor: shares from 0 to 1, one figure a core", (number(processor, "load").map { (0...1).contains($0) } ?? false) && processor["per_core"]?.items.count == snapshot.cpu.perCore.count && snapshot.cpu.perCore.count > 0, processor.compact.prefix(120))
        let memory = Report.memory(snapshot)
        check("memory: bytes, used within the total", (number(memory, "used_bytes") ?? 0) > 1e9 && (number(memory, "used_bytes") ?? 0) <= (number(memory, "total_bytes") ?? 0) && number(memory, "total_bytes") == Double(snapshot.memory.total))
        let storage = Report.storage(VolumeSpace.read())
        check("storage: used and free add up to the disk", abs((number(storage, "used_bytes") ?? 0) + (number(storage, "free_bytes") ?? 0) - (number(storage, "total_bytes") ?? -1)) < 1 && (number(storage, "total_bytes") ?? 0) > 1e9, storage.compact)
        let apps = Report.apps(snapshot, by: .memory, top: 3)
        let sizes = apps["apps"]?.items.compactMap { number($0, "memory_bytes") } ?? []
        check("apps: the top three by memory, largest first", sizes.count == min(3, snapshot.apps.count) && sizes == sizes.sorted(by: >) && !sizes.isEmpty, sizes)
        check("apps: every app has its figures", apps["apps"]?.items.allSatisfy { Set(["name", "cpu_cores", "memory_bytes", "watts", "gpu", "processes"]).isSubset(of: $0.keys) } == true)
        let thermals = Report.thermals(snapshot)
        check("thermals: sensors by group, not one by one", (thermals["sensors"]?.items.count ?? 99) <= 16 && thermals["fans"]?.items.count == snapshot.thermal.fans.count, thermals["sensors"]?.items.count as Any)

        // MARK: Addresses

        let networkReading = reader.read(network: true)
        let quiet = Report.network(networkReading, addresses: false)
        let open = Report.network(networkReading, addresses: true)
        let quietText = ReportText.network(networkReading, addresses: false), openText = ReportText.network(networkReading, addresses: true)
        outputs += [quiet.compact, quietText]
        check("this Mac has addresses to hide (\(secrets.count) found)", !secrets.isEmpty || !network.online, secrets.count)
        check("no output holds any of them unasked (\(outputs.count) outputs)", outputs.allSatisfy { leaks($0) == 0 }, outputs.map(leaks).reduce(0, +))
        check("nothing shaped like an address either", shaped(quiet.compact) == 0 && shaped(quietText) == 0, shaped(quiet.compact) + shaped(quietText))
        check("no address keys unasked", quiet["router"] == nil && quiet["dns"] == nil && quiet["search_domains"] == nil && quiet["wifi"]?["name"] == nil && quiet["interfaces"]?.items.allSatisfy { $0["ipv4"] == nil && $0["ipv6"] == nil && $0["mac"] == nil } == true)
        let shown = secrets.filter { open.compact.contains($0) }.count, shownText = secrets.filter { openText.contains($0) }.count
        check("--addresses gives them: every one as JSON, the main ones as text", shown == secrets.count && (secrets.isEmpty || shownText > 0), "\(shown) of \(secrets.count), \(shownText) in text")

        // MARK: The recorded week

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(CommandSetup.serverName)-command-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("timeline.json")
        let now = Date()
        let nowMinute = Int(now.timeIntervalSince1970 / 60)
        // Thirty hours ending two minutes ago: forty watts, a hot quarter of an hour five hours back.
        let minutes = ((nowMinute - 30 * 60)..<(nowMinute - 1)).map { t -> TimelineMinute in
            let hot = (nowMinute - t) >= 300 && (nowMinute - t) < 315
            return TimelineMinute(t: t, cpu: hot ? 0.9 : 0.1, cpuPeak: hot ? 1 : 0.3, gpu: 0.05, memory: 0.4, temp: hot ? 96 : 50, fan: hot ? 2400 : 1000, netIn: 1000, netOut: 100, power: 40, disk: 0)
        }
        var hot = TimelineEvent(kind: .hot, start: now.addingTimeInterval(-315 * 60), end: now.addingTimeInterval(-300 * 60), summary: "Compiler was using 12 cores")
        hot.peakCelsius = 96
        hot.apps = [.init(name: "Compiler", bundlePath: nil, cpu: 12)]
        let old = TimelineEvent(kind: .offline, start: now.addingTimeInterval(-26 * 3600), end: now.addingTimeInterval(-26 * 3600 + 240), summary: "Wi-Fi lost its route")
        let going = TimelineEvent(kind: .app, start: now.addingTimeInterval(-20 * 60), end: nil, summary: "Renderer held 6 cores")
        let unknown = TimelineEvent(kind: .memory, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000), summary: "from a later version")
        struct Written: Encodable {
            var recordingSince: Date
            var minutes: [TimelineMinute]
            var events: [TimelineEvent]
            var speedTests: [SpeedResult]
            var days: [EnergyDay]
        }
        var data = (try? JSONEncoder().encode(Written(recordingSince: now.addingTimeInterval(-30 * 3600), minutes: minutes, events: [old, hot, unknown, going], speedTests: [], days: []))) ?? Data()
        // A kind of event a later version might add: this one must skip it and keep the rest.
        if let text = String(data: data, encoding: .utf8) { data = Data(text.replacingOccurrences(of: "\"kind\":\"memory\"", with: "\"kind\":\"somethingnew\"").utf8) }
        try? data.write(to: file)
        func stamp(_ url: URL) -> (Date?, Int?) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.modificationDate] as? Date, (attributes?[.size] as? NSNumber)?.intValue)
        }
        let before = stamp(file)
        let week = RecordedWeek.load(from: file, demo: false)
        check("the week is read from its file", week.found && week.minutes.count == minutes.count && week.recordingSince != nil, week.minutes.count)
        check("an event of an unknown kind is skipped, the rest kept", week.events.count == 3, week.events.count)
        let whole = week.summary(hours: nil, now: now)
        check("the whole stretch: every minute, two days, 96° at the worst", whole.minutes == minutes.count && whole.days.count >= 2 && whole.hottest == 96 && whole.cpuPeak == 1, "\(whole.minutes) minutes, \(whole.days.count) days")
        check("energy: forty watts for thirty hours", abs(whole.wattHours - 40 * Double(minutes.count) / 60) < 0.5 && abs((whole.averageWatts ?? 0) - 40) < 0.01, whole.wattHours)
        check("events newest first, the open one still going on", whole.eventsTotal == 3 && whole.events.first?.ongoing == true && whole.events.first?.event.kind == .app && whole.events.last?.event.kind == .offline, whole.events.map(\.event.kind.rawValue))
        let recent = week.summary(hours: 2, now: now)
        check("--hours 2: two hours of minutes and only the event inside them", recent.minutes <= 120 && recent.minutes >= 110 && recent.eventsTotal == 1 && recent.hottest == 50, "\(recent.minutes) minutes, \(recent.eventsTotal) events")
        let weekJSON = week.json(hours: 6, now: now)
        check("as JSON: recorded, a summary, days and events", weekJSON["recorded"].map { if case .bool(true) = $0 { return true }; return false } == true && weekJSON["summary"]?["hottest_celsius"] != nil && weekJSON["events"]?.items.count == 2 && weekJSON["events"]?.items.last?["apps"]?.items.count == 1 && parsed(weekJSON.compact) != nil, weekJSON.compact.prefix(160))
        let weekText = ReportText.timeline(week, hours: nil, now: now)
        check("as text: the days, the events and what happened", weekText.contains("Ran hot") && weekText.contains("Compiler was using 12 cores") && weekText.contains("Events (3)") && weekText.contains("In all"), weekText.prefix(200))
        var stale = week
        stale.lastMinute = now.addingTimeInterval(-7200)
        check("an open event in an old file ended with its last minute", stale.summary(hours: nil, now: now).events.first { $0.event.kind == .app }?.ongoing == false)
        let after = stamp(file)
        check("the file was not written: same date, same size", before.0 != nil && before.0 == after.0 && before.1 == after.1 && (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count == 1, "\(String(describing: before)) then \(String(describing: after))")
        let absent = folder.appendingPathComponent("nothing/timeline.json")
        let none = RecordedWeek.load(from: absent, demo: false)
        check("no file: nothing has been recorded, and none is made", !none.found && ReportText.timeline(none, hours: nil).hasPrefix("Nothing has been recorded") && none.json(hours: nil).compact.hasPrefix("{\"recorded\":false") && !FileManager.default.fileExists(atPath: absent.path) && !FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().path))
        try? Data("not json at all".utf8).write(to: folder.appendingPathComponent("broken.json"))
        check("a file that is not a timeline reads as nothing recorded", !RecordedWeek.load(from: folder.appendingPathComponent("broken.json"), demo: false).found)

        // MARK: The AI server

        let server = MeterServer(reader: reader)
        server.week = { week }
        var answers: [String] = []
        func ask(_ line: String) -> [String: Any]? {
            guard let answer = server.handle(line) else { return nil }
            answers.append(answer)
            return parsed(answer)
        }
        func result(_ line: String) -> [String: Any]? { ask(line)?["result"] as? [String: Any] }
        func code(_ line: String) -> Int? { ((ask(line)?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue }
        func call(_ name: String, _ arguments: String = "{}", meta: String = "") -> [String: Any]? {
            result("{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":\(arguments)\(meta)}}")
        }
        func text(_ result: [String: Any]?) -> String? { ((result?["content"] as? [[String: Any]])?.first?["text"]) as? String }
        func isError(_ result: [String: Any]?) -> Bool { (result?["isError"] as? Bool) == true }

        let hello = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"self-test","version":"1"}}}"#)
        check("initialize: the version asked for, tools, a name and instructions", hello?["protocolVersion"] as? String == "2025-06-18" && (hello?["capabilities"] as? [String: Any])?["tools"] != nil && (hello?["serverInfo"] as? [String: Any])?["name"] as? String == CommandSetup.serverName && (hello?["instructions"] as? String)?.isEmpty == false, hello as Any)
        let newer = result(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2031-01-01","capabilities":{}}}"#)
        check("initialize with a version it does not know: its newest with a handshake", newer?["protocolVersion"] as? String == MeterServer.legacy[0], newer?["protocolVersion"] as Any)
        check("notifications get no answer", server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil && server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#) == nil && server.handle(#"{"jsonrpc":"2.0","method":"something/else"}"#) == nil)
        let pong = ask(#"{"jsonrpc":"2.0","id":"p-1","method":"ping"}"#)
        check("ping: an empty result under the same id", (pong?["result"] as? [String: Any])?.isEmpty == true && pong?["id"] as? String == "p-1" && pong?["jsonrpc"] as? String == "2.0", pong as Any)

        let list = result(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)?["tools"] as? [[String: Any]] ?? []
        let names = list.compactMap { $0["name"] as? String }
        check("tools/list: the eleven tools", names == ["status", "processor", "graphics", "memory", "thermals", "network", "power", "storage", "apps", "usb", "timeline"], names)
        check("each tool: a description in one sentence, a schema, and marked read-only", list.allSatisfy { tool in
            let description = tool["description"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any]
            let sentences = description.components(separatedBy: ". ").count
            return description.count > 40 && description.hasSuffix(".") && sentences == 1 && schema?["type"] as? String == "object" && schema?["additionalProperties"] as? Bool == false && (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true && tool["title"] is String
        })
        let appsSchema = (list.first { $0["name"] as? String == "apps" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        let hoursSchema = (list.first { $0["name"] as? String == "timeline" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        check("apps takes by and top, timeline takes hours", ((appsSchema?["by"] as? [String: Any])?["enum"] as? [String]) == ["cpu", "memory", "energy", "gpu"] && (appsSchema?["top"] as? [String: Any])?["type"] as? String == "integer" && (hoursSchema?["hours"] as? [String: Any])?["maximum"] as? Int == 168, appsSchema as Any)

        var toolOutputs: [String] = []
        for tool in MeterServer.tools {
            let answer = call(tool.name)
            let body = text(answer)
            toolOutputs.append(body ?? "")
            let object = parsed(body)
            let missing = tool.promises.filter { object?[$0] == nil }
            check("tools/call \(tool.name): text holding JSON on one line, with the keys promised", !isError(answer) && (answer?["content"] as? [[String: Any]])?.first?["type"] as? String == "text" && object != nil && missing.isEmpty && body?.contains("\n") == false, "missing \(missing)")
        }
        check("no tool gives an address (\(toolOutputs.count) answers)", toolOutputs.allSatisfy { leaks($0) == 0 } && shaped(toolOutputs[5]) == 0, toolOutputs.map(leaks).reduce(0, +))
        check("the network tool cannot be asked for addresses", isError(call("network", #"{"addresses":true}"#)) && leaks(answers.last ?? "") == 0)
        let three = parsed(text(call("apps", #"{"by":"memory","top":3}"#)))
        check("apps with by and top", three?["by"] as? String == "memory" && (three?["apps"] as? [[String: Any]])?.count == min(3, snapshot.apps.count), three?["by"] as Any)
        let day = parsed(text(call("timeline", #"{"hours":2}"#)))
        check("timeline with hours, from the test's own file", day?["hours"] as? Int == 2 && day?["events_total"] as? Int == 1 && day?["recorded"] as? Bool == true, day?["events_total"] as Any)
        let bad = [("apps", #"{"by":"speed"}"#), ("apps", #"{"top":0}"#), ("apps", #"{"top":"3"}"#), ("apps", #"{"top":2.5}"#), ("apps", #"{"top":true}"#), ("apps", #"{"top":1e30}"#), ("apps", #"{"by":7}"#), ("timeline", #"{"hours":1000}"#), ("status", #"{"verbose":true}"#), ("apps", #"{"sort":"cpu"}"#)]
        let refused = bad.map { call($0.0, $0.1) }
        check("bad arguments: an error the model can read, in a result, each of \(bad.count)", refused.allSatisfy { isError($0) && (text($0)?.count ?? 0) > 10 }, refused.filter { !isError($0) }.count)
        check("an unknown tool: error -32602", code(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"reboot","arguments":{}}}"#) == -32602 && (answers.last ?? "").contains("Unknown tool: reboot"))
        check("a call with no name, or arguments that are no object: error -32602", code(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#) == -32602 && code(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"status","arguments":[1]}}"#) == -32602 && code(#"{"jsonrpc":"2.0","id":6,"method":"tools/list","params":[1]}"#) == -32602)
        check("an unknown method: error -32601", code(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#) == -32601 && code(#"{"jsonrpc":"2.0","id":8,"method":"logging/setLevel","params":{"level":"debug"}}"#) == -32601)
        let garbled = ask("{\"jsonrpc\": \"2.0\", \"id\": 9, \"method\": ")
        check("a malformed line: error -32700 with a null id", (garbled?["error"] as? [String: Any])?["code"] as? Int == -32700 && garbled?["id"] is NSNull, garbled as Any)
        check("not a request: error -32600", code("[]") == -32600 && code(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == -32600 && code(#"{"jsonrpc":"2.0","id":10}"#) == -32600 && code(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#) == -32600 && code(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == -32600 && code("7") == -32600)
        check("an answer to nothing, and an empty line: no reply", server.handle(#"{"jsonrpc":"2.0","id":11,"result":{}}"#) == nil && server.handle("") == nil && server.handle("   ") == nil)

        // The revision without a handshake: every request says its version, every result says its kind.
        let meta = #","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"self-test","version":"1"}}"#
        let found = result("{\"jsonrpc\":\"2.0\",\"id\":\"d\",\"method\":\"server/discover\",\"params\":{\(meta.dropFirst())}}")
        check("server/discover: versions, tools, who is answering, how long to keep it", found?["resultType"] as? String == "complete" && (found?["supportedVersions"] as? [String])?.first == "2026-07-28" && (found?["supportedVersions"] as? [String])?.contains("2025-11-25") == true && (found?["capabilities"] as? [String: Any])?["tools"] != nil && ((found?["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String == CommandSetup.serverName && (found?["ttlMs"] as? Int ?? -1) >= 0 && found?["cacheScope"] as? String == "public", found as Any)
        let listed = result("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/list\",\"params\":{\(meta.dropFirst())}}")
        check("tools/list the new way: complete, cacheable, the same tools", listed?["resultType"] as? String == "complete" && listed?["ttlMs"] != nil && listed?["cacheScope"] as? String == "public" && (listed?["tools"] as? [[String: Any]])?.count == 11)
        let called = call("storage", "{}", meta: meta)
        check("tools/call the new way: complete, and who is answering", called?["resultType"] as? String == "complete" && !isError(called) && (called?["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] != nil && parsed(text(called))?["free_bytes"] != nil)
        check("a tool's own error the new way is complete too", call("apps", #"{"by":"speed"}"#, meta: meta)?["resultType"] as? String == "complete")
        let later = ask(#"{"jsonrpc":"2.0","id":13,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#)?["error"] as? [String: Any]
        check("a version it does not speak: error -32022 naming the ones it does", later?["code"] as? Int == -32022 && ((later?["data"] as? [String: Any])?["supported"] as? [String])?.contains("2026-07-28") == true && (later?["data"] as? [String: Any])?["requested"] as? String == "2030-01-01", later as Any)
        check("the new way without capabilities, or discover without a version: error -32602", code(#"{"jsonrpc":"2.0","id":14,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#) == -32602 && code(#"{"jsonrpc":"2.0","id":15,"method":"server/discover"}"#) == -32602)
        check("ping is gone from the new way: error -32601", code("{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"ping\",\"params\":{\(meta.dropFirst())}}") == -32601)
        check("every answer is one line of JSON-RPC 2.0 (\(answers.count) answers)", answers.allSatisfy { !$0.contains("\n") && parsed($0)?["jsonrpc"] as? String == "2.0" && parsed($0)?["id"] != nil && (parsed($0)?["result"] != nil) != (parsed($0)?["error"] != nil) })

        // MARK: Setup

        let plain = "/Applications/\(App.name).app/Contents/MacOS/\(App.name)"
        let awkward = "/Users/someone/My \"Apps\"/$HOME/\(App.name).app/Contents/MacOS/\(App.name)"
        check("in Terminal: the path and status, quoted only where a shell needs it", CommandSetup.terminal(plain) == "\(plain) status" && CommandSetup.terminal(awkward) == "\"/Users/someone/My \\\"Apps\\\"/\\$HOME/\(App.name).app/Contents/MacOS/\(App.name)\" status", CommandSetup.terminal(awkward))
        let setup = parsed(CommandSetup.claude(awkward))
        let entry = (setup?["mcpServers"] as? [String: Any])?[CommandSetup.serverName] as? [String: Any]
        check("setup for Claude: JSON naming this program and mcp", entry?["command"] as? String == awkward && entry?["args"] as? [String] == ["mcp"] && setup?.count == 1, CommandSetup.claude(plain))
        check("setup for Claude Code: one line", CommandSetup.claudeCode(plain) == "claude mcp add \(CommandSetup.serverName) -- \"\(plain)\" mcp" && !CommandSetup.claudeCode(awkward).contains("\n"), CommandSetup.claudeCode(plain))
        check("the path is this copy's own program", Command.demo || (CommandSetup.path == Bundle.main.executablePath && FileManager.default.isExecutableFile(atPath: CommandSetup.path)), CommandSetup.path)

        print("\(checks) checks, \(failed) failed")
    }
}
