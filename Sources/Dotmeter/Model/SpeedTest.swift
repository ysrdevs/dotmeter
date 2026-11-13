import CDotmeter
import Foundation
import Observation

/// One run of Apple's `networkQuality`, the tool behind Network Quality in System Settings. It downloads and
/// uploads against Apple's servers for about fifteen seconds and moves a few hundred megabytes on a fast line,
/// so it only ever runs when asked.
struct SpeedResult: Codable, Identifiable {
    var id = UUID()
    var date: Date
    /// Bits per second.
    var down: Double
    var up: Double
    /// Round trips per minute under load: Apple's measure of how well the line holds up when it is busy.
    var responsiveness: Double?
    /// Idle round trip in milliseconds.
    var baseRTT: Double?
    var interface: String?

    var responsivenessTitle: String? {
        guard let responsiveness else { return nil }
        return responsiveness >= 1000 ? "High" : (responsiveness >= 200 ? "Medium" : "Low")
    }
}

@MainActor
@Observable
final class SpeedTestModel {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    /// 0...1 through the expected fifteen seconds.
    private(set) var progress = 0.0
    /// What the line is carrying this moment, in bytes per second, read from the interfaces while the test runs.
    private(set) var liveDown = 0.0
    private(set) var liveUp = 0.0
    /// Four readings a second since the test began: (down, up) in bytes per second.
    private(set) var trace: [(down: Double, up: Double)] = []
    private(set) var results: [SpeedResult] = []

    @ObservationIgnored var store: TimelineStore?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private static let tool = "/usr/bin/networkQuality"
    private static let expected = 15.5
    /// Debug: DOTMETER_SPEED_DEMO=1 plays a made-up run without touching the network.
    private static let demo = ProcessInfo.processInfo.environment["DOTMETER_SPEED_DEMO"] == "1"

    var isRunning: Bool { state == .running }
    var latest: SpeedResult? { results.last }

    func load(_ saved: [SpeedResult]) { results = saved }

    func run() {
        guard !isRunning else { return }
        state = .running
        progress = 0
        trace = []
        liveDown = 0
        liveUp = 0
        let started = Date()

        ticker = Task { [weak self] in
            var before = Self.demo ? (0, 0) : Self.counters()
            var beforeTime = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isRunning else { return }
                let elapsed = Date().timeIntervalSince(started)
                self.progress = min(elapsed / Self.expected, 0.98)
                if Self.demo {
                    let ramp = min(elapsed / 2.5, 1)
                    self.liveDown = 61e6 * ramp * (0.9 + 0.1 * sin(elapsed * 2.3))
                    self.liveUp = 9.4e6 * ramp * (0.88 + 0.12 * sin(elapsed * 3.1 + 1))
                } else {
                    let now = Self.counters()
                    let nowTime = DispatchTime.now().uptimeNanoseconds
                    let seconds = Double(nowTime &- beforeTime) / 1e9
                    if seconds > 0 {
                        self.liveDown = Double(NetworkSampler.advance(from: before.0, to: now.0, atMost: 2e9)) / seconds
                        self.liveUp = Double(NetworkSampler.advance(from: before.1, to: now.1, atMost: 2e9)) / seconds
                    }
                    before = now
                    beforeTime = nowTime
                }
                self.trace.append((self.liveDown, self.liveUp))
            }
        }

        if Self.demo {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.environment["DOTMETER_SPEED_DEMO_HOLD"] == "1" ? 600 : 6))
                self?.finish(.done(SpeedResult(date: Date(), down: 486e6, up: 74.8e6, responsiveness: 1240, baseRTT: 14.2, interface: "en1")))
            }
            return
        }

        guard FileManager.default.isExecutableFile(atPath: Self.tool) else {
            finish(.failed("This version of macOS does not include the networkQuality tool."))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tool)
        process.arguments = ["-c"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        self.process = process
        Task.detached(priority: .userInitiated) { [weak self] in
            var outcome: Outcome
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                outcome = Self.parse(data).map { .done($0) } ?? .failed(process.terminationStatus == 15 ? "Stopped." : "The test did not finish. Check the connection and try again.")
            } catch {
                outcome = .failed("The test could not start: \(error.localizedDescription)")
            }
            let final = outcome
            await MainActor.run { [weak self] in self?.finish(final) }
        }
    }

    func stop() {
        process?.terminate()
        if Self.demo { finish(.failed("Stopped.")) }
    }

    private enum Outcome: Sendable {
        case done(SpeedResult)
        case failed(String)
    }

    private func finish(_ outcome: Outcome) {
        ticker?.cancel()
        ticker = nil
        process = nil
        progress = 1
        switch outcome {
        case .done(let result):
            results.append(result)
            if results.count > 30 { results.removeFirst(results.count - 30) }
            store?.speedTests = results
            state = .idle
        case .failed(let message):
            state = message == "Stopped." ? .idle : .failed(message)
        }
    }

    nonisolated private static func parse(_ data: Data) -> SpeedResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (object["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (object["ul_throughput"] as? NSNumber)?.doubleValue, down > 0 || up > 0 else { return nil }
        return SpeedResult(
            date: Date(), down: down, up: up,
            responsiveness: (object["responsiveness"] as? NSNumber)?.doubleValue,
            baseRTT: (object["base_rtt"] as? NSNumber)?.doubleValue,
            interface: object["interface_name"] as? String
        )
    }

    /// Bytes received and sent so far over the physical links.
    nonisolated private static func counters() -> (UInt64, UInt64) {
        var raw = [dotmeter_interface_t](repeating: dotmeter_interface_t(), count: 160)
        let count = max(0, Int(dotmeter_interfaces(&raw, Int32(raw.count))))
        var received: UInt64 = 0, sent: UInt64 = 0
        for i in 0..<count {
            let name = withUnsafeBytes(of: raw[i].name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            received &+= raw[i].ibytes
            sent &+= raw[i].obytes
        }
        return (received, sent)
    }
}
