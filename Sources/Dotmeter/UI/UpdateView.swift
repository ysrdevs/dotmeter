import SwiftUI

/// The update window: what is new in the version that is out, and the one button that installs it.
struct UpdateView: View {
    var close: () -> Void
    @Environment(UpdateModel.self) private var updates

    static let width: CGFloat = 460
    static let background = Color(hex: 0x141517)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PX.inset)
                .padding(.top, 6)
                .padding(.bottom, 18)
            if showsNotes, let notes = updates.release?.notes, !notes.isEmpty {
                PXDivider()
                ScrollView {
                    MarkdownText(text: notes)
                        .foregroundStyle(PX.soft)
                        .padding(.horizontal, PX.inset)
                        .padding(.vertical, 16)
                }
                .frame(maxHeight: 250)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                PXDivider()
                status
                    .padding(.horizontal, PX.inset)
                    .padding(.vertical, 14)
            }
            PXDivider()
            buttons
                .padding(.horizontal, PX.inset - 6)
                .padding(.vertical, 13)
        }
        .frame(width: Self.width)
        .background(Self.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PX.font(17, .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(PX.text)
                Text(caption)
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        if let release = updates.release, updates.waiting { return "\(App.name) \(release.version) is available" }
        switch updates.phase {
        case .current: return "\(App.name) is up to date"
        case .failed: return "The check did not go through"
        default: return "Checking for updates"
        }
    }

    private var caption: String {
        let mine = AppVersion.running.description
        if let release = updates.release, updates.waiting {
            return "You have \(mine)" + (release.size.map { " · \(Format.bytes(UInt64(max(0, $0)))) to download" } ?? "")
        }
        switch updates.phase {
        case .current: return "Version \(mine) is the newest."
        case .failed(let why): return why
        default: return "Asking GitHub which version is the newest."
        }
    }

    private var showsNotes: Bool {
        switch updates.phase {
        case .available, .downloading, .verifying, .failed: return updates.waiting
        default: return false
        }
    }

    /// The line between the notes and the buttons: how the download is going, or what went wrong.
    private var status: AnyView? {
        guard updates.waiting else { return nil }
        switch updates.phase {
        case .downloading(let fraction):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Downloading").foregroundStyle(PX.label)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(PX.secondary)
                }
                .font(PX.font(12))
                MiniMatrixBar(fraction: fraction, rgb: PX.greenRGB, rows: 2)
            })
        case .verifying:
            return AnyView(working("Checking it is signed by \(App.possessive) developer and by Apple"))
        case .restarting:
            return AnyView(working("Starting the new version"))
        case .failed(let why):
            return AnyView(Text(why)
                .font(PX.font(12))
                .foregroundStyle(PX.red.color())
                .fixedSize(horizontal: false, vertical: true))
        case .byHand(let why):
            return AnyView(Text("\(App.name) cannot replace itself here: \(why). The new version is downloaded and checked. Open its disk image and drag \(App.name) onto Applications.")
                .font(PX.font(12))
                .foregroundStyle(PX.soft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true))
        default:
            return nil
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 9) {
            PXSpinner(size: 13)
            Text(text).font(PX.font(12)).foregroundStyle(PX.label)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch updates.phase {
            case .available:
                PXButton(title: "Skip this version", style: .ghost) { updates.skip(); close() }
                Spacer()
                PXButton(title: "Later", style: .ghost, action: close)
                PXButton(title: "Install and relaunch", symbol: "arrow.down.circle.fill") { updates.install() }
                    .keyboardShortcut(.defaultAction)
            case .downloading, .verifying:
                Spacer()
                PXButton(title: "Cancel", style: .ghost) { updates.cancel() }
            case .restarting:
                Spacer()
                PXButton(title: "Install and relaunch", symbol: "arrow.down.circle.fill", enabled: false) {}
            case .byHand:
                Spacer()
                PXButton(title: "Close", style: .ghost, action: close)
                PXButton(title: "Open the disk image", symbol: "externaldrive.fill") { updates.openImage() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                if updates.waiting {
                    PXButton(title: "Open the download page", style: .ghost) { updates.openPage() }
                    Spacer()
                    PXButton(title: "Close", style: .ghost, action: close)
                    PXButton(title: "Try again", symbol: "arrow.clockwise") { updates.install() }
                } else {
                    Spacer()
                    PXButton(title: "Close", style: .ghost, action: close)
                    PXButton(title: "Try again", symbol: "arrow.clockwise") { updates.check() }
                }
            case .current:
                Spacer()
                PXButton(title: "OK", action: close)
                    .keyboardShortcut(.defaultAction)
            case .idle, .checking:
                HStack(spacing: 9) {
                    PXSpinner(size: 13)
                    Text("One moment").font(PX.font(12)).foregroundStyle(PX.secondary)
                }
                .padding(.leading, 6)
                Spacer()
                PXButton(title: "Close", style: .ghost, action: close)
            }
        }
        .frame(height: 29)
    }
}

/// The line at the foot of the sidebar that says a new version is waiting.
struct UpdateNotice: View {
    @Environment(UpdateModel.self) private var updates
    @State private var hovering = false

    var body: some View {
        if let release = updates.release, updates.waiting {
            Button { updates.present(false) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PX.green)
                        .frame(width: 18)
                    Text("Update")
                        .font(PX.font(13, .medium))
                        .tracking(PX.tracking(13))
                        .foregroundStyle(PX.text)
                    Spacer(minLength: 6)
                    Text(release.version)
                        .font(PX.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(PX.secondary)
                }
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(RoundedRectangle(cornerRadius: 7.5, style: .continuous).fill(hovering ? PX.rowHover : PX.ghostHover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("\(App.name) \(release.version) is available")
        }
    }
}
