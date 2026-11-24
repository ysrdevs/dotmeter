import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var renderPath: String?
    var autoOpen = false
    var analyzeMode = false
    /// `--self-test quit|speed|events`: checks that need the app's run loop.
    var selfTest: String?

    private var statusController: StatusController?
    private let models = AppModels()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = models.monitor
        monitor.start()

        if analyzeMode {
            Task { @MainActor in
                await DebugTools.analyze(monitor: monitor)
                NSApp.terminate(nil)
            }
            return
        }

        if let selfTest {
            Task { @MainActor in
                await DebugTools.selfTest(selfTest, models: models)
                fflush(stdout)
                exit(0)
            }
            return
        }

        if let renderPath {
            Task { @MainActor in
                await DebugTools.render(models: models, to: renderPath)
                NSApp.terminate(nil)
            }
            return
        }

        AlertCenter.shared.attach(to: monitor, store: models.timeline)
        saveOnSignal()
        let controller = StatusController(models: models)
        statusController = controller

        // Keys saved under the app's earlier name come over once. macOS asks before it hands over an item another
        // app saved, so this waits off the main thread for the answer.
        Task.detached(priority: .utility) {
            if Migration.carryOverKeys() { await MainActor.run { AppSettings.shared.refreshKeys() } }
        }

        // A copy opened for a capture or a measurement does not ask about updates, unless it was given a feed to ask.
        if !autoOpen || UpdateFeed.override != nil { models.updates.start() }

        if autoOpen {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                controller.debugRun()
            }
        } else if !Self.launchedAtLogin {
            // Opened by hand: show the window. Started at login: stay in the menu bar.
            controller.openMainWindow(nil)
        }
    }

    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.openMainWindow(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The timeline is written every five minutes; this catches the last few.
    func applicationWillTerminate(_ notification: Notification) {
        if !analyzeMode, renderPath == nil, selfTest == nil {
            models.timeline.saveNow()
            models.cables.saveNow()
        }
    }

    /// `kill` and a rebuild end the app with a signal, which skips the method above; catch it and save first.
    func saveOnSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.models.timeline.saveNow()
                self?.models.cables.saveNow()
            }
            exit(0)
        }
        source.resume()
        signalSource = source
    }

    private var signalSource: DispatchSourceSignal?
}
