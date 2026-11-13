import Foundation

/// What one pass should read.
struct CollectOptions {
    /// Counters only: processor, memory and network totals. The process list (24 ms) and the
    /// connection details are carried over from the last full pass. This is what live menu bar items run on
    /// while no panel or window is open.
    var light = false
    /// In a light pass, also re-read the die temperatures and fan speeds.
    var thermal = true
    /// In a light pass, also re-read the graphics load (a tenth of a millisecond), for when the window is open
    /// on a page that needs nothing a full pass reads but still shows that figure in its sidebar.
    var graphics = false
    /// Per-app network traffic, read at most this often (seconds). It costs a helper process per reading,
    /// so it is nil unless something on screen shows it.
    var networkApps: Double?
    /// Round trips to the router and the internet, measured by echo. Only while the Network area is on screen.
    var networkLatency = false
    /// Which apps are listening for connections. A helper process per reading, so only while the Network page shows it.
    var networkPorts = false
    /// Ports, cables and connected devices: a walk through the hardware registry, a few tens of milliseconds.
    var usb = false
}

/// Owns every sampler. Not thread-safe: SystemMonitor calls `collect()` from one background task at a time.
final class Collectors {
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let processes = ProcessSampler()
    private let thermal = ThermalSampler()
    private let gpu = GPUSampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()
    private let power = PowerSampler()
    private let usb = USBSampler()
    private var last: Snapshot?

    /// Debug: the power channels as last read.
    var powerChannels: [(name: String, watts: Double)] { power.channelWatts }

    func collect(_ options: CollectOptions = CollectOptions()) -> Snapshot {
        if options.light, var snapshot = last {
            snapshot.timestamp = Date()
            // Only what a menu bar item can show. Graphics load and disk activity ask IOKit, which costs more
            // than everything else here together; they keep their value from the last full pass.
            snapshot.cpu = cpu.sample()
            snapshot.memory = memory.sample()
            snapshot.network = network.sample(detail: false)
            snapshot.power = power.sample(light: true)
            if options.thermal { snapshot.thermal = thermal.sampleLight() }
            if options.graphics, let stats = gpu.sample().stats { snapshot.gpu = stats }
            if options.usb { snapshot.usb = usb.sample() }
            snapshot.system.uptime = ProcessInfo.processInfo.systemUptime
            last = snapshot
            return snapshot
        }
        let memoryStats = memory.sample()
        let graphics = gpu.sample(apps: true)
        let (apps, procs) = processes.sample(gpu: graphics.shares)
        let snapshot = Snapshot(
            timestamp: Date(),
            cpu: cpu.sample(),
            memory: memoryStats,
            thermal: thermal.sample(),
            gpu: graphics.stats,
            disk: disk.sample(),
            network: network.sample(detail: true, apps: options.networkApps, latency: options.networkLatency, ports: options.networkPorts, groups: apps),
            power: power.sample(),
            apps: apps,
            processes: procs,
            system: SystemInfoProvider.current(memoryTotal: memoryStats.total),
            usb: options.usb ? usb.sample() : last?.usb
        )
        // Debug: DOTMETER_APPS_DEMO=1 puts made-up apps in place of the real ones (see `AppsDemo`).
        let shown = AppsDemo.on ? AppsDemo.apply(snapshot) : snapshot
        last = shown
        return shown
    }
}
