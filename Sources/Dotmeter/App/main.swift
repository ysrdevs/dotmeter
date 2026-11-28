import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
// Under its earlier name the app kept its settings and data elsewhere; bring them along before anything reads one.
Migration.carryOver()

// `dotmeter status`, `dotmeter mcp` and the rest: the app's readings from a terminal or for an AI app. No window.
if Command.handles(arguments) { Command.run(arguments) }

if arguments.contains("--dump") {
    DebugTools.dump()
    exit(0)
}
if arguments.contains("--usb") {
    DebugTools.usb(json: arguments.contains("--json"))
    exit(0)
}
if let index = arguments.firstIndex(of: "--watch-test") {
    let rest = Array(arguments[(index + 1)...])
    let name = rest.first { Double($0) == nil }
    MainActor.assumeIsolated { DebugTools.watchTest(name, seconds: rest.compactMap(Double.init).first ?? 15) }
}
if arguments.contains("--ports") {
    DebugTools.ports()
    exit(0)
}
if arguments.contains("--external-ip-test") {
    Task { @MainActor in
        await DebugTools.externalAddressTest()
        exit(0)
    }
    dispatchMain()
}
if arguments.contains("--update-check") {
    // What GitHub says the newest version is, and whether this copy would offer it. Asks; installs nothing.
    Task { @MainActor in
        do {
            if let release = try await UpdateFeed.latest() {
                let newer = AppVersion(release.version).map { $0 > AppVersion.running } ?? false
                print("newest \(release.version) · this copy \(AppVersion.running) · \(newer ? "would be offered" : "nothing to offer")")
                print("image \(release.image.absoluteString) · \(release.size ?? 0) bytes")
                print("notes:\n\(release.notes)")
            } else {
                print("nothing has been published")
            }
        } catch {
            print("failed: \(error.localizedDescription)")
        }
        exit(0)
    }
    dispatchMain()
}
if arguments.contains("--helper-off") {
    Task { @MainActor in
        await DebugTools.helperOff()
        exit(0)
    }
    dispatchMain()
}
if arguments.contains("--helper-state") {
    Task { @MainActor in
        await DebugTools.helperState()
        exit(0)
    }
    dispatchMain()
}
if arguments.contains("--helper-test") {
    // The uninstall helper end to end, on throwaway items. Run it from the installed app through LaunchServices,
    // so that macOS sees Dotmeter asking: open -n -W --stdout out.txt /Applications/Dotmeter.app --args --helper-test
    Task { @MainActor in
        await DebugTools.helperTest()
        exit(0)
    }
    dispatchMain()
}
if arguments.contains("--net-test") {
    DebugTools.netTest()
    exit(0)
}
if arguments.contains("--ping-test") {
    DebugTools.pingTest()
    exit(0)
}
if arguments.contains("--agent-test") {
    DebugTools.agentTest()
    exit(0)
}
if arguments.contains("--bench") {
    DebugTools.bench()
    exit(0)
}
if arguments.contains("--bench-contents") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        DebugTools.benchContents()
    }
    exit(0)
}
if arguments.contains("--bench-processes") {
    DebugTools.benchProcesses()
    exit(0)
}
if arguments.contains("--bench-draw") {
    DebugTools.benchDraw()
    exit(0)
}
if let index = arguments.firstIndex(of: "--scan-test"), index + 1 < arguments.count {
    DebugTools.scanTest(arguments[index + 1])
    exit(0)
}
if let index = arguments.firstIndex(of: "--remove-test"), index + 2 < arguments.count {
    // The main queue has to keep running: the system's own move to the Trash is asked for on it and answers on it.
    Task.detached {
        await DebugTools.removeTest(arguments[index + 1], mode: arguments[index + 2])
        exit(0)
    }
    dispatchMain()
}
if let index = arguments.firstIndex(of: "--scan-report"), index + 1 < arguments.count {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await DebugTools.scanReport(to: arguments[index + 1])
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if let index = arguments.firstIndex(of: "--clear-test"), index + 1 < arguments.count {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await DebugTools.clearTest(arguments[index + 1])
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if let index = arguments.firstIndex(of: "--render-card"), index + 1 < arguments.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        DebugTools.renderCard(to: arguments[index + 1], state: index + 2 < arguments.count ? arguments[index + 2] : "rest")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
        delegate.renderPath = arguments[index + 1]
    }
    delegate.autoOpen = arguments.contains("--open")
    delegate.analyzeMode = arguments.contains("--analyze")
    if let index = arguments.firstIndex(of: "--self-test"), index + 1 < arguments.count {
        delegate.selfTest = arguments[index + 1]
    }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
