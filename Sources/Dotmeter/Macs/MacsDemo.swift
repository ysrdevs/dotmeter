import Foundation

/// Made-up Macs (`DOTMETER_MACS_DEMO=1`), for screenshots and design review. Nothing touches the network: no
/// listener, no browsing, and the code shown is not a code anyone uses.
@MainActor
final class MacsDemo {
    static let code = "KQ4M-7TXA-9HWE"
    /// What this Mac is called in a demo, in place of its real name.
    static let thisMac = "Studio"

    private struct Cast {
        var hello: MacHello
        var reading: MacReading
        /// Seconds since it last answered, for the one that has gone quiet.
        var quietFor: Double?
        /// How far its figures wander, 0...1.
        var sway: Double
    }

    private let cast: [Cast]

    init() {
        let gb: UInt64 = 1_073_741_824
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        cast = [
            Cast(
                hello: MacHello(id: "demo-macbook", name: "MacBook Pro", model: "MacBook Pro", chip: "Apple M4 Pro", app: version),
                reading: MacReading(
                    time: 0, every: 2, cpu: 0.41, gpu: 0.23, memoryUsed: 19 * gb + gb / 4, memoryTotal: 24 * gb, pressure: "warning",
                    temperature: 78, fans: [2380, 2412], fanLevel: 0.31, watts: 34, down: 4.2e6, up: 3.1e5,
                    diskFree: 212 * gb, diskTotal: 494 * gb, battery: .init(charge: 0.64, charging: false, plugged: false, minutes: 192),
                    uptime: 2 * 86_400 + 7 * 3600, severity: Severity.elevated.rawValue,
                    apps: [.init(name: "Xcode", cpu: 2.14), .init(name: "Safari", cpu: 0.58), .init(name: "Music", cpu: 0.09)]
                ),
                quietFor: nil, sway: 1
            ),
            Cast(
                hello: MacHello(id: "demo-mini", name: "Mac mini", model: "Mac mini", chip: "Apple M4", app: version),
                reading: MacReading(
                    time: 0, every: 2, cpu: 0.06, gpu: 0.03, memoryUsed: 9 * gb + gb / 8, memoryTotal: 16 * gb, pressure: "normal",
                    temperature: 44, fans: [1000], fanLevel: 0, watts: 7, down: 1.8e5, up: 2.4e6,
                    diskFree: 96 * gb, diskTotal: 245 * gb, battery: nil,
                    uptime: 41 * 86_400 + 3 * 3600, severity: Severity.nominal.rawValue,
                    apps: [.init(name: "Time Machine", cpu: 0.22), .init(name: "Photos", cpu: 0.08), .init(name: "Spotlight", cpu: 0.04)]
                ),
                quietFor: nil, sway: 0.5
            ),
            Cast(
                hello: MacHello(id: "demo-imac", name: "iMac", model: "iMac", chip: "Apple M3", app: version),
                reading: MacReading(
                    time: 0, every: 2, cpu: 0.12, gpu: 0.09, memoryUsed: 11 * gb, memoryTotal: 16 * gb, pressure: "normal",
                    temperature: 52, fans: [1210], fanLevel: 0.04, watts: 46, down: 6.0e4, up: 2.0e4,
                    diskFree: 318 * gb, diskTotal: 494 * gb, battery: nil,
                    uptime: 5 * 86_400 + 11 * 3600, severity: Severity.nominal.rawValue,
                    apps: [.init(name: "Safari", cpu: 0.31), .init(name: "Mail", cpu: 0.06), .init(name: "Photos", cpu: 0.03)]
                ),
                quietFor: 140, sway: 0
            ),
        ]
    }

    func peers(at now: Date) -> [MacPeer] {
        cast.map { member in
            let peer = MacPeer(hello: member.hello, lastSeen: now.addingTimeInterval(-(member.quietFor ?? 0)))
            peer.reading = reading(member, at: now)
            peer.answering = member.quietFor == nil
            peer.peakWatts = member.reading.watts.map { $0 * 1.6 } ?? 0
            peer.peakRate = (member.reading.down + member.reading.up) * 2.2
            return peer
        }
    }

    /// Every two seconds the made-up Macs that are answering send a new reading.
    func advance(_ peers: [MacPeer], at now: Date) {
        for (member, peer) in zip(cast, peers) {
            if let quiet = member.quietFor {
                // The quiet one stays a couple of minutes quiet however long the demo runs.
                if now.timeIntervalSince(peer.lastSeen) > quiet + 30 { peer.lastSeen = now.addingTimeInterval(-quiet) }
            } else if now.timeIntervalSince(peer.lastSeen) >= 2 {
                peer.take(reading(member, at: now), at: now)
            }
        }
    }

    private func reading(_ member: Cast, at now: Date) -> MacReading {
        var r = member.reading
        r.time = now.timeIntervalSince1970
        guard member.sway > 0 else { return r }
        let t = now.timeIntervalSinceReferenceDate
        let swell = sin(t / 11) * cos(t / 4.7) * member.sway
        r.cpu = min(max(r.cpu * (1 + 0.25 * swell), 0.01), 1)
        r.gpu = r.gpu.map { min(max($0 * (1 + 0.3 * swell), 0.01), 1) }
        r.temperature = r.temperature.map { $0 + 3 * swell }
        r.watts = r.watts.map { $0 * (1 + 0.2 * swell) }
        r.down *= 1 + 0.4 * swell
        r.up *= 1 + 0.3 * swell
        if !r.apps.isEmpty { r.apps[0].cpu *= 1 + 0.25 * swell }
        r.uptime += now.timeIntervalSince(started)
        return r
    }

    private let started = Date()
}
