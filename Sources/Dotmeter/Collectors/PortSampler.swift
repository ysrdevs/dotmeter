import Foundation

/// Which programs are waiting for connections, from `nettop`, the tool behind Activity Monitor's Network tab
/// and the one the per-app traffic already comes from. It names the process behind every listening TCP socket
/// without needing an administrator, the system's own included, which reading each process's sockets directly
/// cannot do. (`netstat` would be the obvious tool, and from a shell it is; run by an app, macOS hands it an
/// empty table.) Nothing is sent anywhere and no port is probed: this is what the kernel already knows.
final class PortSampler {
    struct Reading: Equatable {
        var port: Int
        var pid: Int32
        var process: String
        /// Bound to every address, or to one of this Mac's addresses on a network: other devices can reach it.
        var exposed: Bool
    }

    private static let tool = "/usr/bin/nettop"
    /// One sample, every TCP socket under its process, as CSV, numeric.
    private static let arguments = ["-L", "1", "-n", "-x", "-m", "tcp"]
    private static let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    private var readings: [Reading] = []
    private var sampledAt = Date.distantPast
    private var firewall: Bool?
    private var firewallAt = Date.distantPast
    private(set) var available = true
    private var failures = 0

    /// The listeners, read again if the last reading is older than `seconds`. Nil until one has worked.
    func sample(every seconds: Double) -> [Reading]? {
        let now = Date()
        if now.timeIntervalSince(sampledAt) >= seconds - 0.2 {
            if let text = Self.run(Self.tool, Self.arguments) {
                readings = Self.parse(text)
                sampledAt = now
                failures = 0
                available = true
            } else {
                failures += 1
                if failures >= 3 { available = false }
            }
        }
        return sampledAt == .distantPast ? nil : readings
    }

    /// Whether the macOS firewall is on, asked of its own tool at most once a minute. Nil if it would not say.
    func firewallOn() -> Bool? {
        let now = Date()
        if now.timeIntervalSince(firewallAt) >= 60 {
            firewallAt = now
            firewall = Self.run(Self.firewallTool, ["--getglobalstate"]).flatMap(Self.parseFirewall)
        }
        return firewall
    }

    static func parseFirewall(_ text: String) -> Bool? {
        guard let range = text.range(of: "State = ") else { return nil }
        return text[range.upperBound...].first.flatMap { $0.wholeNumberValue }.map { $0 != 0 }
    }

    /// One entry per process and port: the IPv4 and IPv6 sockets of one listener are the same thing to a person.
    ///
    /// The tool prints a row for each process ("launchd.1") followed by a row for each of its sockets
    /// ("tcp4 *:22<->*:*" with its state). IPv4 writes the port after a colon, IPv6 after a dot.
    static func parse(_ text: String) -> [Reading] {
        var found: [String: Reading] = [:]
        var owner: (name: String, pid: Int32)?
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { continue }
            let what = fields[1]
            let v4 = what.hasPrefix("tcp4 "), v6 = what.hasPrefix("tcp6 ")
            guard v4 || v6 else {
                // A process row: its name, a dot, its number. The name itself may hold dots.
                if let dot = what.lastIndex(of: "."), let pid = Int32(what[what.index(after: dot)...]) {
                    owner = (String(what[..<dot]), pid)
                } else {
                    owner = nil
                }
                continue
            }
            guard fields[3] == "Listen", let owner, let arrow = what.range(of: "<->") else { continue }
            let local = what[what.index(what.startIndex, offsetBy: 5)..<arrow.lowerBound]
            guard let mark = local.lastIndex(of: v4 ? ":" : "."), let port = Int(local[local.index(after: mark)...]), port > 0 else { continue }
            let exposed = !isLoopback(String(local[..<mark])) && fields[2] != "lo0"
            let key = "\(owner.pid):\(port)"
            if var existing = found[key] {
                existing.exposed = existing.exposed || exposed
                found[key] = existing
            } else {
                found[key] = Reading(port: port, pid: owner.pid, process: owner.name, exposed: exposed)
            }
        }
        return found.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Loopback and link-local-on-loopback addresses answer only to this Mac.
    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address == "localhost" || address.hasSuffix("%lo0")
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // It answers in well under a second. If it ever hangs, it must not take the whole sampler with it.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// What usually answers on a port, for the ones people recognise. A hint, not a finding: any program can listen
/// anywhere.
enum KnownPorts {
    static let names: [Int: String] = [
        22: "SSH · Remote Login", 25: "Mail", 53: "DNS", 80: "Web", 88: "Kerberos", 111: "RPC", 139: "Windows sharing", 443: "Web (TLS)",
        445: "SMB · File Sharing", 548: "AFP · File Sharing", 587: "Mail", 631: "Printing", 2049: "NFS", 3283: "Remote Management",
        3306: "MySQL", 3689: "Music sharing", 5000: "AirPlay", 5432: "PostgreSQL", 5900: "Screen Sharing", 6379: "Redis", 7000: "AirPlay",
        8080: "Web", 8888: "Web", 9000: "Web", 11434: "Ollama", 27017: "MongoDB", 1883: "MQTT", 5353: "Bonjour",
    ]

    static func name(_ port: Int) -> String? { names[port] }
}
