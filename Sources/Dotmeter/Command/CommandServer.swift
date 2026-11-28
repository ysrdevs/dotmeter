import Foundation

/// Lets an AI app read this Mac's meters. Started as `Dotmeter mcp`, the program speaks the Model Context Protocol
/// on its standard input and output: JSON-RPC 2.0, one message to a line. Every tool reads and none changes
/// anything, and no tool ever gives an address or a network's name.
///
/// The protocol changed shape in its 2026-07-28 revision: there is no handshake any more, and every request says
/// which version it speaks. Apps written before that open with `initialize`. This answers both, as the
/// specification allows a server to: a request that names its version in `_meta` is answered the new way, and one
/// that follows an `initialize` the old way.
final class MeterServer {
    /// Revisions without a handshake, newest first.
    static let modern = ["2026-07-28"]
    /// Revisions that open with `initialize`, newest first.
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private static let versionKey = "io.modelcontextprotocol/protocolVersion"
    private static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    private static let serverKey = "io.modelcontextprotocol/serverInfo"

    static let instructions = "Live readings of this Mac from \(App.name): processor, graphics, memory, heat and fans, network, power, storage, apps, ports, and a recorded week of history. Start with status. Every tool only reads. Units are in the key names (bytes, watts, celsius); loads and shares are fractions from 0 to 1, and an app's cpu_cores is in cores, so it can pass 1."

    private static var serverInfo: JSON {
        .record([
            "name": .string(CommandSetup.serverName),
            "title": .string(App.name),
            "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"),
        ])
    }

    // MARK: Tools

    struct Tool {
        var reading: Command.Reading
        var title: String
        /// One sentence for a model deciding whether to call it. It names, in brackets, the keys that come back.
        var description: String
        /// The keys the answer always has.
        var promises: [String]
        /// The keys it has only where the Mac reports the figure. The self-test holds the description and the
        /// answer to these two lists, so neither can drift from what is really returned.
        var sometimes: [String] = []
        var arguments: [(name: String, schema: JSON)] = []

        var name: String { reading.rawValue }
    }

    static let tools: [Tool] = [
        Tool(reading: .status, title: "Status",
             description: "How this Mac is doing right now, in brief (state, processor, graphics, memory, thermals, network, disk, power, storage, ports, top_apps): call it first when asked about the Mac's health, speed, heat or noise.",
             promises: ["time", "mac", "state", "processor", "memory", "thermals", "network", "disk", "power", "storage", "top_apps"],
             sometimes: ["graphics", "ports"]),
        Tool(reading: .processor, title: "Processor",
             description: "Processor load right now, overall and for each core (load, per_core, load_average, celsius, watts, top_apps): call it when the Mac feels slow or an app might be holding the cores.",
             promises: ["time", "load", "user", "system", "cores", "performance_cores", "efficiency_cores", "per_core", "load_average", "top_apps"],
             sometimes: ["performance_load", "efficiency_load", "celsius", "watts", "speed_limit"]),
        Tool(reading: .graphics, title: "Graphics",
             description: "Graphics load and graphics memory right now (available, load, memory_used_bytes, celsius, watts, top_apps): call it for questions about rendering, games, video or models running on this Mac.",
             promises: ["time", "available"],
             sometimes: ["model", "cores", "load", "renderer_load", "tiler_load", "memory_used_bytes", "memory_allocated_bytes", "celsius", "watts", "top_apps"]),
        Tool(reading: .memory, title: "Memory",
             description: "Memory in use, pressure and swap right now (used_bytes, total_bytes, pressure, swap_used_bytes, activity, top_apps): call it when the Mac might be short of memory.",
             promises: ["time", "total_bytes", "used_bytes", "used_fraction", "available_bytes", "app_bytes", "wired_bytes", "compressed_bytes", "cached_bytes", "swap_used_bytes", "swap_total_bytes", "pressure", "activity", "top_apps"]),
        Tool(reading: .thermals, title: "Thermals",
             description: "Temperatures, fan speeds and whether macOS is throttling the processor (state, throttled, hottest_celsius, fans, sensors): call it when the Mac is hot or loud.",
             promises: ["time", "state", "throttled", "fans", "sensors"],
             sometimes: ["speed_limit", "hottest_celsius", "hottest_sensor", "processor_celsius", "graphics_celsius"]),
        Tool(reading: .network, title: "Network",
             description: "Whether the Mac is online, its traffic right now by interface and by app, the Wi-Fi link, and the ports open to other devices (online, download_bytes_per_second, upload_bytes_per_second, interfaces, wifi, apps, listening): call it for a slow or dropped connection; addresses and network names are never included.",
             promises: ["time", "online", "download_bytes_per_second", "upload_bytes_per_second", "interfaces"],
             sometimes: ["primary_interface", "configured_by", "firewall_on", "wifi", "apps", "listening", "listening_local_only"]),
        Tool(reading: .power, title: "Power",
             description: "Watts the Mac is drawing right now, by part and by app, and the battery where there is one (watts, processor_watts, graphics_watts, battery, top_apps): call it for questions about energy use, charging or battery life.",
             promises: ["time", "whole_mac", "top_apps"],
             sometimes: ["watts", "processor_watts", "graphics_watts", "neural_watts", "memory_watts", "rest_watts", "adapter_watts", "battery"]),
        Tool(reading: .storage, title: "Storage",
             description: "Total and free space on the startup disk (total_bytes, used_bytes, free_bytes, reclaimable_bytes, used_fraction): call it when asked how full the disk is.",
             promises: ["time", "volume", "total_bytes", "used_bytes", "free_bytes", "reclaimable_bytes", "used_fraction"]),
        Tool(reading: .apps, title: "Apps",
             description: "The apps using the most processor, memory, energy or graphics right now, each with its cores in use, memory, watts, graphics share and disk traffic (by, apps_running, processes_running, apps): call it to find what is slowing the Mac, draining the battery or filling its memory.",
             promises: ["time", "by", "apps_running", "processes_running", "apps"],
             arguments: [
                ("by", .record(["type": .string("string"), "enum": .array(AppOrder.allCases.map { .string($0.rawValue) }), "description": .string("What to rank the apps by. Usually cpu.")])),
                ("top", .record(["type": .string("integer"), "minimum": .int(Int64(Command.topRange.lowerBound)), "maximum": .int(Int64(Command.topRange.upperBound)), "description": .string("How many apps to return. Usually 10.")])),
             ]),
        Tool(reading: .usb, title: "USB and ports",
             description: "What is plugged into each port, the speed and the cable of each connection, and anything running slower than it could (ports, devices, charger): call it for questions about cables, docks, drives, screens or charging.",
             promises: ["time", "devices", "ports"],
             sometimes: ["charger"]),
        Tool(reading: .timeline, title: "Timeline",
             description: "What \(App.name) recorded over the past week, day by day, with the events in it such as running hot, throttling, a busy app or a dropped connection (recorded, summary, days, events): call it for questions about the past, such as why the Mac was loud last night.",
             promises: ["recorded"],
             sometimes: ["note", "recording_since", "last_recorded", "hours", "from", "to", "summary", "days", "events_total", "event_counts", "events"],
             arguments: [
                ("hours", .record(["type": .string("integer"), "minimum": .int(Int64(Command.hoursRange.lowerBound)), "maximum": .int(Int64(Command.hoursRange.upperBound)), "description": .string("How far back to look, in hours. Left out, the whole recorded week.")])),
             ]),
    ]

    private static func describe(_ tool: Tool) -> JSON {
        var schema: [(key: String, value: JSON)] = [("type", .string("object"))]
        if !tool.arguments.isEmpty { schema.append(("properties", .object(tool.arguments.map { ($0.name, $0.schema) }))) }
        schema.append(("additionalProperties", .bool(false)))
        return .record([
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": .object(schema),
            // The Mac is only read, the same question can be asked again, and nothing outside this Mac is reached.
            "annotations": .record(["readOnlyHint": .bool(true), "destructiveHint": .bool(false), "idempotentHint": .bool(true), "openWorldHint": .bool(false)]),
        ])
    }

    // MARK: Answering

    private let reader: MeterReader
    /// Reads a tool's answer. The self-test puts its own here to answer from a file of its own.
    var week: () -> RecordedWeek = { RecordedWeek.load() }

    init(reader: MeterReader = MeterReader()) {
        self.reader = reader
    }

    private enum Failure: Error {
        /// A JSON-RPC error: the request itself was wrong.
        case rpc(Int, String, JSON?)
        /// The tool was found and called, and what it was given was wrong: said in a result, where the model sees it.
        case tool(String)
    }

    /// One line in, one line out, or none: a notification gets no answer, and neither does an empty line.
    func handle(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return Self.error(id: .null, -32700, "Parse error")
        }
        // Several messages in one line were allowed by one revision only and are not accepted.
        guard let message = parsed as? [String: Any] else { return Self.error(id: .null, -32600, "Invalid Request") }

        var id: JSON?
        if let raw = message["id"] {
            if let string = raw as? String {
                id = .string(string)
            } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9e15 {
                id = .int(number.int64Value)
            } else {
                return Self.error(id: .null, -32600, "Invalid Request: id must be a string or a whole number")
            }
        }
        guard let method = message["method"] as? String else {
            // An answer to something this server never asked needs none.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: id ?? .null, -32600, "Invalid Request")
        }
        // No id: a notification, which is never answered.
        guard let id else { return nil }

        // A request that names its version speaks a revision without a handshake, and is answered that way.
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any]
        let isModern = meta?[Self.versionKey] != nil
        do {
            guard message["params"] == nil || message["params"] is [String: Any] else { throw Failure.rpc(-32602, "Invalid params: params must be an object", nil) }
            if isModern, method != "initialize" {
                let version = meta?[Self.versionKey] as? String ?? ""
                guard Self.modern.contains(version) else {
                    throw Failure.rpc(-32022, "Unsupported protocol version", .record([
                        "supported": .array((Self.modern + Self.legacy).map { .string($0) }),
                        "requested": .string(version),
                    ]))
                }
                guard meta?[Self.capabilitiesKey] is [String: Any] else { throw Failure.rpc(-32602, "Invalid params: _meta is missing \(Self.capabilitiesKey)", nil) }
            }
            let result = try answer(method, params, isModern: isModern)
            return JSON.record(["jsonrpc": .string("2.0"), "id": id, "result": .object(result)]).compact
        } catch Failure.rpc(let code, let text, let data) {
            return Self.error(id: id, code, text, data: data)
        } catch Failure.tool(let text) {
            return JSON.record(["jsonrpc": .string("2.0"), "id": id, "result": .object(Self.content(text, failed: true, isModern: isModern))]).compact
        } catch {
            return Self.error(id: id, -32603, "Internal error")
        }
    }

    private static func error(id: JSON, _ code: Int, _ message: String, data: JSON? = nil) -> String {
        JSON.record(["jsonrpc": .string("2.0"), "id": id, "error": .record(["code": .int(Int64(code)), "message": .string(message), "data": data])]).compact
    }

    /// What a revision without a handshake wants on every result: its kind, and who is answering.
    private static func stamped(_ pairs: [(key: String, value: JSON)], isModern: Bool, cached: Bool = false) -> [(key: String, value: JSON)] {
        guard isModern else { return pairs }
        var out: [(key: String, value: JSON)] = [("resultType", .string("complete"))] + pairs
        // The list of tools is the same for everyone and only changes with the app's version.
        if cached { out += [("ttlMs", .int(3_600_000)), ("cacheScope", .string("public"))] }
        out.append(("_meta", .object([(serverKey, serverInfo)])))
        return out
    }

    private static func content(_ text: String, failed: Bool, isModern: Bool) -> [(key: String, value: JSON)] {
        stamped([("content", .array([.record(["type": .string("text"), "text": .string(text)])])), ("isError", .bool(failed))], isModern: isModern)
    }

    private func answer(_ method: String, _ params: [String: Any], isModern: Bool) throws -> [(key: String, value: JSON)] {
        let capabilities = JSON.record(["tools": .object([])])
        switch method {
        case "initialize":
            // The handshake of the earlier revisions: the version asked for if it is one of them, else the newest.
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.legacy.contains($0) ? $0 : nil } ?? Self.legacy[0]
            return [("protocolVersion", .string(version)), ("capabilities", capabilities), ("serverInfo", Self.serverInfo), ("instructions", .string(Self.instructions))]
        case "server/discover":
            guard isModern else { throw Failure.rpc(-32602, "Invalid params: _meta is missing \(Self.versionKey)", nil) }
            return Self.stamped([
                ("supportedVersions", .array((Self.modern + Self.legacy).map { .string($0) })),
                ("capabilities", capabilities),
                ("instructions", .string(Self.instructions)),
            ], isModern: true, cached: true)
        case "ping":
            // Gone from the revisions without a handshake, where it is a method like any other unknown one.
            guard !isModern else { throw Failure.rpc(-32601, "Method not found: ping", nil) }
            return []
        case "tools/list":
            return Self.stamped([("tools", .array(Self.tools.map(Self.describe)))], isModern: isModern, cached: true)
        case "tools/call":
            guard let name = params["name"] as? String else { throw Failure.rpc(-32602, "Invalid params: name is missing", nil) }
            guard let tool = Self.tools.first(where: { $0.name == name }) else { throw Failure.rpc(-32602, "Unknown tool: \(name)", nil) }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] || params["arguments"] is NSNull else {
                throw Failure.rpc(-32602, "Invalid params: arguments must be an object", nil)
            }
            let options = try Self.options(for: tool, params["arguments"] as? [String: Any] ?? [:])
            return Self.content(read(tool.reading, options).compact, failed: false, isModern: isModern)
        default:
            throw Failure.rpc(-32601, "Method not found: \(method)", nil)
        }
    }

    /// What a tool was given, checked. A mistake here is one the model can put right, so it is told what was wrong.
    private static func options(for tool: Tool, _ given: [String: Any]) throws -> Command.Options {
        var options = Command.Options()
        let known = tool.arguments.map(\.name)
        if let stray = given.keys.sorted().first(where: { !known.contains($0) }) {
            throw Failure.tool(known.isEmpty ? "\(tool.name) takes no arguments, and \"\(stray)\" was given." : "\(tool.name) has no argument called \"\(stray)\". It takes: \(known.joined(separator: ", ")).")
        }
        func whole(_ name: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let value = given[name], !(value is NSNull) else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e9, range.contains(number.intValue) else {
                throw Failure.tool("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return number.intValue
        }
        if tool.reading == .apps {
            if let value = given["by"], !(value is NSNull) {
                guard let text = value as? String, let order = AppOrder(rawValue: text) else {
                    throw Failure.tool("by must be one of: \(AppOrder.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                options.by = order
            }
            if let top = try whole("top", Command.topRange) { options.top = top }
        }
        if tool.reading == .timeline {
            options.hours = try whole("hours", Command.hoursRange)
        }
        return options
    }

    /// A tool's answer: the same JSON the command prints with `--json`, without addresses whatever is asked.
    func read(_ reading: Command.Reading, _ options: Command.Options) -> JSON {
        var safe = options
        safe.addresses = false
        if reading == .timeline { return week().json(hours: safe.hours) }
        return Command.Gathered(reading, reader: reader).json(safe)
    }

    // MARK: Standard input and output

    /// Answers until the input closes, then ends the program.
    static func serve() -> Never {
        // The protocol owns standard output: nothing but its messages may go there. So the real output is put
        // aside for them, and anything else in the program that prints lands on standard error instead.
        let output = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        if isatty(STDIN_FILENO) != 0 {
            Command.say("\(App.name) is waiting for an AI app on standard input (Model Context Protocol). Control-D ends it.")
        }
        let server = MeterServer()
        while let line = readLine(strippingNewline: true) {
            guard let answer = server.handle(line) else { continue }
            var bytes = Array((answer + "\n").utf8)
            while !bytes.isEmpty {
                let written = bytes.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
                if written < 0, errno == EINTR { continue }
                // Nobody is reading any more.
                if written <= 0 { exit(0) }
                bytes.removeFirst(written)
            }
        }
        exit(0)
    }
}
