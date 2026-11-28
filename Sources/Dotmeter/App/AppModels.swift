import SwiftUI

/// Everything the views share, made once.
@MainActor
final class AppModels {
    let monitor = SystemMonitor()
    let analysis = AnalysisSession()
    let storage = StorageModel()
    let quit = QuitModel()
    let explainer = Explainer()
    let timeline = TimelineStore()
    let speed = SpeedTestModel()
    let loginItems = LoginItemsModel()
    let cables = CableStore()
    let uninstallHelper = UninstallHelper()
    let publicAddress = PublicAddress()
    let updates = UpdateModel()
    let runners = RunnersModel()
    let macs = MacsModel()
    let watch = ActivityWatch()

    init() {
        analysis.storageSummary = { [weak storage] in storage?.claudeSummary }
        explainer.storageSummary = { [weak storage] in storage?.claudeSummary }
        explainer.timelineSummary = { [weak timeline] in timeline?.weekSummary() }
        storage.helper = uninstallHelper
        speed.store = timeline
        speed.load(timeline.speedTests)
        monitor.addObserver { [weak quit] snapshot in quit?.reconcile(with: snapshot.apps) }
        // The disk is read on every tick; the storage figures, in the menu bar and everywhere else, follow it.
        monitor.addObserver { [weak storage] snapshot in
            if snapshot.disk.total > 0 { storage?.follow(free: snapshot.disk.free) }
        }
        // A followed cable's record builds whether or not the USB area is open: the ports are read when something
        // is plugged in or pulled out, and once a minute besides, for as long as any cable is being followed.
        // A connection that comes up slower than it could is written to the Timeline, so the ports are read when
        // something is plugged in, with a slow clock behind that in case the registry says nothing.
        monitor.setUSBBackground("timeline", every: 120)
        monitor.setUSBBackground("following", every: cables.cables.isEmpty ? nil : 60)
        cables.followingChanged = { [weak monitor] following in monitor?.setUSBBackground("following", every: following ? 60 : nil) }
        monitor.addObserver { [weak cables] snapshot in
            if let usb = snapshot.usb { cables?.record(usb, at: snapshot.timestamp) }
        }
    }
}

extension View {
    func dotmeterModels(_ models: AppModels) -> some View {
        environment(models.monitor)
            .environment(models.analysis)
            .environment(models.storage)
            .environment(models.quit)
            .environment(models.explainer)
            .environment(models.timeline)
            .environment(models.speed)
            .environment(models.cables)
            .environment(models.uninstallHelper)
            .environment(models.publicAddress)
            .environment(models.updates)
            .environment(models.runners)
            .environment(models.macs)
            .environment(models.loginItems)
            .environment(AppSettings.shared)
    }
}
