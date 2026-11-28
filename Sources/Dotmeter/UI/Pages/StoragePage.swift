import SwiftUI

struct StoragePage: View {
    @Environment(StorageModel.self) private var storage
    @Environment(SystemMonitor.self) private var monitor
    @State private var category = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_CATEGORY"] ?? "apps"
    /// What is typed into the Apps list's search. Debug: DOTMETER_DEBUG_APP_QUERY=<text> starts with it filled in.
    @State private var appQuery = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_APP_QUERY"] ?? ""

    var body: some View {
        PageScaffold(title: "Storage", subtitle: subtitle, section: .storage) { gridWidth, columns in
            PagePair(columns: columns) {
                // Clicking a category in the legend or the bar switches the table below.
                MeterCard(model: storage.meter, selected: category) { id in
                    if StorageCategoryInfo.all.contains(where: { $0.id == id }) { category = id }
                }
            } second: {
                VolumePanel()
            }
            if let blocked = storage.blocked { StorageBlockedCard(failure: blocked, width: gridWidth) }
            if let snapshot = monitor.snapshot {
                PagePair(columns: columns) {
                    DiskActivityPanel(history: monitor.history, snapshot: snapshot)
                } second: {
                    TopAppsPanel.disk(snapshot)
                }
            }
            if let drive = monitor.snapshot?.drive { DriveHealthPanel(drive: drive, width: gridWidth) }
            LargestItemsPanel(category: $category, query: $appQuery, width: gridWidth)
                .id("largest")
        }
        // An app dropped anywhere on the page is found in the list below, and its row asks at once.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in accept(url) }
            }
            return true
        }
        // Debug: DOTMETER_DEBUG_DROP=<path to an app> acts as if that app had just been dropped on the page.
        .task {
            if let path = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_DROP"] {
                try? await Task.sleep(for: .seconds(1.5))
                accept(URL(fileURLWithPath: path))
            }
        }
    }

    private func accept(_ url: URL) {
        guard let item = storage.offerDropped(url) else { return }
        category = "apps"
        appQuery = ""
        _ = item
        PageScroll.shared.go(to: "largest")
    }

    private var subtitle: String {
        let volume = storage.volume
        let name = volume.name.isEmpty ? "Startup disk" : volume.name
        return volume.format.isEmpty ? name : "\(name) · \(volume.format)"
    }
}

/// A removal macOS refused for a reason the user can lift, with the way to lift it.
struct StorageBlockedCard: View {
    var failure: RemovalFailure
    var width: CGFloat
    @Environment(StorageModel.self) private var storage

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PX.orange.color())
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text("macOS needs your OK before \(App.name) can remove this")
                    .font(PX.font(13, .medium))
                    .foregroundStyle(PX.label)
                Text(failure.message + " Something an installer put there belongs to the system, so \(App.name) asks the Finder to move it, the same as dragging it to the Trash, and macOS lets one app direct another only with your consent. In Privacy & Security, under Automation, turn on Finder for \(App.name), then press the button again. The Finder will ask for an administrator's password itself.")
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PXButton(title: "Open Automation settings", symbol: "gearshape", height: 27) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                    }
                    if let path = failure.path {
                        PXButton(title: "Show in Finder", symbol: "folder", style: .ghost, height: 27) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 8)
            PXButton(title: "", symbol: "xmark", style: .ghost, height: 24, action: storage.dismissBlocked)
        }
        .padding(.horizontal, PX.inset - 4)
        .padding(.vertical, 16)
        .frame(width: width, alignment: .leading)
        .background(PX.orange.color(0.06))
        .pxCard()
    }
}

/// The disk itself: capacity, what is free now, what macOS could free, and how trustworthy the scan is.
struct VolumePanel: View {
    @Environment(StorageModel.self) private var storage
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let volume = storage.volume
        let used = max(0, volume.capacity - volume.free)
        PXPanel(title: "Disk", caption: scanned, width: PX.cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                // Used, reclaimable and free as one strip.
                VolumeStrip(used: max(0, used - volume.purgeable), reclaimable: volume.purgeable, free: volume.free)
                    .padding(.top, 15)
                    .padding(.horizontal, PX.inset)
                HStack(spacing: 14) {
                    key(PX.blue, "In use")
                    key(PX.yellow, "Reclaimable")
                    key(PX.gray, "Free")
                    Spacer()
                }
                .padding(.top, 9)
                .padding(.horizontal, PX.inset)

                VStack(spacing: 0) {
                    PXStatRow(label: "Capacity", value: StorageModel.gb(volume.capacity))
                    PXStatRow(label: "Used", value: StorageModel.gb(used), detail: "includes what macOS can reclaim")
                    PXStatRow(label: "Free now", value: StorageModel.gb(volume.free))
                    PXStatRow(label: "Reclaimable by macOS", value: StorageModel.gb(volume.purgeable), detail: "snapshots and purgeable caches")
                    PXStatRow(label: "Shared between files", value: storage.phase == .unscanned ? "—" : StorageModel.gb(storage.sharedSkipped), detail: "clones and hard links, counted once")
                    if let snapshot = monitor.snapshot {
                        // What the drives are doing and have done: requests and how long each takes, the totals
                        // since the Mac started with any errors, and how warm the drive is.
                        PXStatRow(label: "Requests", value: Detail.requests(snapshot.disk), detail: Detail.requestTime(snapshot.disk))
                        PXStatRow(label: "Since startup", value: "\(Format.data(snapshot.disk.bytesRead)) read · \(Format.data(snapshot.disk.bytesWritten)) written", detail: Detail.diskErrors(snapshot.disk))
                        if let heat = Detail.temperature(of: "Storage", in: snapshot.thermal) {
                            PXStatRow(label: "Drive temperature", value: Format.temperature(heat))
                        }
                    }
                }
                .padding(.horizontal, PX.inset)
                .padding(.top, 10)

                Spacer(minLength: 0)
                PXDivider()
                HStack(spacing: 8.5) {
                    if storage.denied {
                        MeterIconView(icon: .symbol("lock.fill"), rgb: PX.gray, size: 13)
                        Text("Photos and Trash are private without Full Disk Access.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.label)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        PXButton(title: "Open Settings", action: storage.openFullDiskAccess)
                    } else if storage.fitFactor < 0.995 {
                        MeterIconView(icon: .symbol("info.circle.fill"), rgb: PX.gray, size: 13)
                        Text("Folder sizes were scaled \(Int(((1 - storage.fitFactor) * 100).rounded()))% to fit the disk.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.label)
                        Spacer(minLength: 8)
                    } else if storage.phase == .unscanned || storage.phase == .scanning {
                        MeterIconView(icon: .symbol("magnifyingglass"), rgb: PX.gray, size: 13)
                        Text(storage.phase == .scanning ? "Measuring every folder. Shared storage is counted once." : "Scan to break this down by folder.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.label)
                        Spacer(minLength: 8)
                    } else {
                        PXCheck(size: 11).frame(width: 13, height: 13)
                        Text("Every category adds up to what the disk reports.")
                            .font(PX.font(12))
                            .foregroundStyle(PX.label)
                        Spacer(minLength: 8)
                    }
                }
                .padding(.leading, 22.5)
                .padding(.trailing, 18)
                .frame(height: 57)
            }
        }
        .frame(height: 342.75)
    }

    private var scanned: String {
        guard storage.phase != .unscanned, let date = storage.scannedAt else { return "not scanned yet" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return "scanned just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "scanned " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private func key(_ rgb: RGB, _ title: String) -> some View {
        HStack(spacing: 5.5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(rgb.color()).frame(width: 7, height: 7)
            Text(title).font(PX.font(11.5)).foregroundStyle(PX.secondary)
        }
    }
}

struct VolumeStrip: View {
    var used: Double
    var reclaimable: Double
    var free: Double

    private static let rows = 5

    private struct Spec: Hashable {
        var cols: Int
        var usedCols: Int
        var reclaimCols: Int
    }

    var body: some View {
        BitmapPicture(spec: spec, draw: Self.draw)
            .frame(height: CGFloat(Self.rows) * PX.pitch)
    }

    private func spec(_ size: CGSize) -> Spec {
        let cols = max(1, Int((size.width / PX.pitch).rounded(.down)))
        let total = max(used + reclaimable + free, 1)
        return Spec(
            cols: cols,
            usedCols: Int((used / total * Double(cols)).rounded()),
            reclaimCols: max(reclaimable > 0 ? 1 : 0, Int((reclaimable / total * Double(cols)).rounded()))
        )
    }

    private static func draw(_ pen: BitmapPen, _ size: CGSize, _ spec: Spec) {
        let p = PX.pitch
        var a: [CGRect] = [], b: [CGRect] = [], c: [CGRect] = []
        let side = p - 1.15
        for col in 0..<spec.cols {
            for r in 0..<rows {
                let cx = (CGFloat(col) + 0.5) * p, cy = (CGFloat(r) + 0.5) * p
                if col < spec.usedCols {
                    a.append(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
                } else if col < spec.usedCols + spec.reclaimCols {
                    b.append(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
                } else {
                    c.append(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
                }
            }
        }
        pen.fill(a, PX.blue, 0.9)
        pen.fill(b, PX.yellow, 0.9)
        pen.fill(c, .white, 0.16)
    }
}

/// The biggest things inside one category, with a way to see each in Finder.
struct LargestItemsPanel: View {
    @Environment(StorageModel.self) private var storage
    @Binding var category: String
    /// The Apps list's search: with something typed (or an app dropped on the page), the list is every
    /// installed app that matches instead of the largest ones the scan kept.
    @Binding var query: String
    var width: CGFloat
    @FocusState private var searching: Bool

    private var finding: Bool { category == "apps" && (!query.trimmingCharacters(in: .whitespaces).isEmpty || storage.droppedApp != nil) }

    var body: some View {
        let categories = StorageCategoryInfo.all
        let info = StorageCategoryInfo.info(category)
        let found = finding ? storage.findApps(query) : []
        let items = finding ? Array(found.prefix(14)) : Array(storage.items(in: category).filter { $0.bytes > 0 }.prefix(14))
        let top = max(items.map(\.bytes).max() ?? 1, 1)
        PXPanel(title: finding ? "Apps" : "Largest items", caption: finding ? findCaption(found.count) : caption(info), width: width) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(categories) { item in
                                PXPill(title: item.name, symbol: item.symbols.first, rgb: item.rgb, selected: item.id == category) {
                                    category = item.id
                                }
                            }
                        }
                        .padding(.leading, 14)
                    }
                    if category == "apps" { searchField }
                }
                .padding(.top, 12)
                .padding(.bottom, 9)
                PXDivider()

                if items.isEmpty {
                    Text(finding ? "No installed app has \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D} in its name." : emptyText)
                        .font(PX.font(12))
                        .foregroundStyle(PX.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PX.inset)
                        .padding(.vertical, 22)
                } else {
                    VStack(spacing: 1) {
                        ForEach(Self.keyed(items), id: \.key) { entry in
                            let item = entry.item
                            let busy = !item.path.isEmpty && storage.busyItem == item.path
                            LargestItemRow(
                                item: item, fraction: item.bytes / top, rgb: info.rgb, wide: width > 700,
                                canReveal: !storage.isDemo && !item.path.isEmpty,
                                action: storage.action(for: item, in: category),
                                armed: storage.armedItem == item.path,
                                plan: storage.armedItem == item.path ? storage.armedPlan : nil,
                                // An app can be removed before any scan has run; everything else needs one.
                                enabled: storage.phase == .ready || (finding && storage.phase == .unscanned),
                                busy: busy ? LargestItemRow.Busy(action: storage.busyAction, progress: storage.busyProgress, waiting: storage.awaitingPermission) : nil,
                                reveal: { storage.reveal(item) },
                                perform: { storage.requestItemAction(item, in: category) },
                                cancel: { busy ? storage.cancelPermissionWait() : storage.disarmItem() }
                            )
                            // The finished row goes quickly so the rows closing up do not slide over it.
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.09))))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Only a removal animates: the finished row fades and the ones below close up.
                    .animation(.easeOut(duration: 0.26), value: storage.removals)
                }
            }
        }
        // Apps the scan did not keep have no size yet: measure the ones on show, in the background.
        .task(id: finding ? items.map(\.path).joined(separator: "|") : "") {
            if finding { storage.measureApps(items) }
        }
        .onChange(of: category) { _, _ in
            if category != "apps" { storage.forgetDropped() }
        }
    }

    /// Finds any installed app, not only the largest the scan kept. Dropping an app on the page fills it in.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(searching || !query.isEmpty ? PX.soft : PX.tertiary)
            TextField("", text: $query, prompt: Text("Find any app, or drop one here").foregroundStyle(PX.tertiary))
                .textFieldStyle(.plain)
                .font(PX.font(12))
                .foregroundStyle(PX.text)
                .focused($searching)
                // A window gives its first text field the keyboard as it opens. Nobody asked to type here yet.
                .onAppear { DispatchQueue.main.async { searching = false } }
                .onSubmit { searching = false }
                .onChange(of: query) { _, _ in storage.forgetDropped() }
            if !query.isEmpty || storage.droppedApp != nil {
                Button {
                    query = ""
                    storage.forgetDropped()
                    storage.disarmItem()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PX.tertiary)
                }
                .buttonStyle(.plain)
                .help("Back to the largest apps")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width > 700 ? 250 : 190, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PX.button))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(searching ? PX.blue.color(0.6) : Color.clear, lineWidth: 1))
        .padding(.trailing, 14)
    }

    private func findCaption(_ count: Int) -> String {
        if storage.droppedApp != nil, query.isEmpty { return "the app you dropped" }
        return "\(count) installed \(count == 1 ? "app matches" : "apps match") · uninstall deletes an app and what it left behind"
    }

    /// Rows keyed by path so one can leave the list without the others being rebuilt.
    private static func keyed(_ items: [StorageChild]) -> [(key: String, item: StorageChild)] {
        var seen = Set<String>()
        return items.enumerated().map { index, item in
            var key = item.path.isEmpty ? item.name : item.path
            if !seen.insert(key).inserted { key += "#\(index)" }
            return (key, item)
        }
    }

    private func caption(_ info: StorageCategoryInfo) -> String {
        if storage.phase == .unscanned { return "scan first" }
        switch info.id {
        case "caches": return "caches · clear any one of them"
        case "apps": return "apps · uninstall deletes an app and what it left behind"
        case "trash": return "trash · delete items one at a time"
        case "system": return "system data · look, don't touch"
        default: return "\(info.name.lowercased()) · anything here can be moved to the Trash"
        }
    }

    private var emptyText: String {
        if storage.phase == .unscanned { return "Nothing measured yet. Run a scan from the card above." }
        if storage.phase == .scanning { return "Measuring…" }
        if category == "trash" || category == "photos" { return "Nothing readable here. Photos and Trash need Full Disk Access." }
        return "Nothing sizeable here."
    }
}

struct LargestItemRow: View {
    var item: StorageChild
    var fraction: Double
    var rgb: RGB
    var wide: Bool
    var canReveal: Bool
    var action: StorageModel.ItemAction
    var armed: Bool
    /// For an app waiting to be confirmed: what would go with it. Nil until that is known.
    var plan: UninstallPlan? = nil
    var enabled: Bool
    /// Set while this row is the one being removed.
    var busy: Busy?
    var reveal: () -> Void
    var perform: () -> Void
    /// Backs out of a confirmation, or of waiting for permission.
    var cancel: () -> Void = {}
    @State private var hovering = false

    struct Busy: Equatable {
        var action: StorageModel.ItemAction
        var progress: Double
        /// macOS is waiting for the user to allow the removal.
        var waiting = false
        /// Clearing, deleting and uninstalling go piece by piece and can say how far along they are; a move to the Trash cannot.
        var measured: Bool { action.permanent || action == .uninstall }
        var finished: Bool { progress >= 1 }
    }

    /// An app's row turns into the question itself: what goes, and the two answers.
    private var asking: Bool { armed && action == .uninstall && busy == nil }
    private var waiting: Bool { busy?.waiting == true }
    private static let warm = Color(hex: 0xFF8A80)

    var body: some View {
        HStack(spacing: 0) {
            Text(item.name)
                .font(PX.font(12, .medium))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: wide ? 290 : 170, alignment: .leading)
            if asking || waiting {
                // What the click will do, or what macOS is waiting for, in place of the folder, bar and size.
                HStack(spacing: 7) {
                    if waiting || plan == nil { PXSpinner(size: 11) }
                    Text(explanation)
                        .font(PX.font(12))
                        .foregroundStyle(waiting ? PX.yellow.color() : Self.warm.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .help(detail)
            } else {
                if wide {
                    Text(item.path.isEmpty ? "not itemized" : DiskStorageBackend.abbreviate((item.path as NSString).deletingLastPathComponent))
                        .font(PX.mono(10.5))
                        .foregroundStyle(PX.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                } else {
                    Spacer(minLength: 8)
                }
                Group {
                    if let busy {
                        DrainingMatrixBar(fraction: fraction, progress: busy.measured || busy.finished ? busy.progress : nil, rgb: rgb)
                    } else {
                        MiniMatrixBar(fraction: fraction, rgb: rgb)
                    }
                }
                .frame(width: wide ? 220 : 70)
                .padding(.horizontal, 10)
                // The size counts down with the squares. An app that was found by name may not be measured yet.
                Text(sizeText)
                    .font(PX.font(12))
                    .monospacedDigit()
                    .foregroundStyle(busy == nil ? PX.secondary : PX.soft)
                    .frame(width: 70, alignment: .trailing)
            }

            // The row's own action. It asks twice: the first click turns it into "Confirm".
            // While it runs, the button gives way to the spinner and how far along it is.
            Group {
                if waiting {
                    PXButton(title: "Cancel", style: .ghost, height: 22, action: cancel)
                } else if let busy {
                    HStack(spacing: 6) {
                        if busy.finished {
                            PXCheck(size: 10)
                            Text(busy.action.done)
                                .foregroundStyle(PX.green)
                        } else {
                            PXSpinner(size: 11.5)
                            Text(busy.measured ? "\(busy.action.short) \(Int((busy.progress * 100).rounded(.down)))%" : busy.action.short)
                                .foregroundStyle(PX.soft)
                        }
                    }
                    .font(PX.font(11, .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 8)
                } else if asking {
                    HStack(spacing: 5) {
                        PXButton(title: "Cancel", style: .ghost, height: 22, action: cancel)
                        PXButton(title: "Uninstall", style: .filled, enabled: enabled && plan != nil, tint: Self.warm, height: 22, action: perform)
                    }
                    .fixedSize()
                } else if action != .none {
                    PXButton(
                        title: armed ? (action.permanent ? "Confirm delete" : "Confirm") : action.title,
                        style: armed ? .filled : .ghost,
                        enabled: enabled,
                        tint: armed ? Self.warm : nil,
                        height: 22,
                        action: perform
                    )
                    .opacity(hovering || armed ? 1 : 0.55)
                }
            }
            .frame(minWidth: wide ? 118 : 104, alignment: .trailing)
            .padding(.leading, 6)

            Button(action: reveal) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hovering ? PX.soft : PX.tertiary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canReveal ? 1 : 0.3)
            .disabled(!canReveal)
            .help("Show in Finder")
            .padding(.leading, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(background))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: armed)
        .animation(.easeOut(duration: 0.14), value: busy != nil)
        .animation(.easeOut(duration: 0.14), value: waiting)
    }

    /// The size, counting down while the row is being removed. Megabytes under a tenth of a gigabyte, so a small
    /// app found by name does not read as nothing, and a dash until it has been measured.
    private var sizeText: String {
        guard item.bytes > 0 else { return "—" }
        let left = item.bytes * (busy.map { $0.measured || $0.finished ? 1 - $0.progress : 1 } ?? 1)
        if item.bytes < 1e8 { return left < 1e6 ? "under 1 MB" : "\(Int((left / 1e6).rounded())) MB" }
        return StorageModel.gb(left)
    }

    /// One line in the row: what confirming deletes, or what macOS is waiting for.
    private var explanation: String {
        if waiting { return wide ? "Switch on \(App.name) in the Login Items window that just opened. It carries on by itself." : "Switch on \(App.name) in Login Items" }
        guard let plan else { return wide ? "looking for what it left behind" : "looking" }
        return wide ? plan.summary : plan.shortSummary
    }

    /// The same in full, for the pointer resting on it: every path that would go.
    private var detail: String {
        if waiting { return "The app belongs to the system, so macOS wants your OK once before \(App.name) may remove such things. Switch on \(App.name) under Login Items & Extensions; no uninstall asks again after that." }
        guard let plan else { return "" }
        return (["Deleted for good, not moved to the Trash:"] + plan.items.map { DiskStorageBackend.abbreviate($0.path) }).joined(separator: "\n")
    }

    private var background: Color {
        if waiting { return PX.yellow.color(0.09) }
        if busy != nil { return rgb.color(0.115) }
        if armed { return Color(hex: 0x3A2222) }
        return hovering ? PX.rowHover : .clear
    }
}
