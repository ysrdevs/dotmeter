import AppKit
import SwiftUI

/// A small button for anything that cannot be undone: the first click arms it and changes what it says,
/// the second does it.
struct PXConfirmButton: View {
    var title: String
    var armedTitle: String
    var symbol: String?
    var armed: Bool
    var busy = false
    var height: CGFloat = 24
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5.5) {
                if busy {
                    PXSpinner(size: 10.5)
                } else if let symbol, !armed {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                }
                Text(armed ? armedTitle : title)
                    .font(PX.font(11.5, .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(armed ? Color(hex: 0xFF8A80) : (hovering ? PX.text : PX.soft))
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(armed ? PX.red.color(0.20) : (hovering ? PX.buttonHover : PX.button)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PXPressStyle())
        .disabled(busy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: armed)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// What can be done to an app, shown inside its opened row: quit it, force it, or find it.
struct AppActionRow: View {
    var app: AppUsage
    @Environment(QuitModel.self) private var control

    var body: some View {
        HStack(spacing: 7) {
            if !ProcessControl.canQuit(app) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(PX.tertiary)
                Text("Part of macOS, so it cannot be quit from here.")
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.tertiary)
            } else if let pending = control.pending[app.id] {
                PXSpinner(size: 11.5)
                Text(pending.force ? "Ending \(app.name)" : "Asking \(app.name) to quit")
                    .font(PX.font(11.5))
                    .foregroundStyle(PX.secondary)
            } else {
                PXConfirmButton(title: "Quit", armedTitle: "Confirm quit", symbol: "xmark", armed: control.isArmed(app.id, force: false)) {
                    control.request(app, force: false)
                }
                PXConfirmButton(title: "Force Quit", armedTitle: "Confirm force quit", symbol: "bolt.fill", armed: control.isArmed(app.id, force: true)) {
                    control.request(app, force: true)
                }
            }
            if let path = app.bundlePath ?? app.children.first?.path {
                PXButton(title: "Show in Finder", symbol: "folder", style: .ghost, height: 24) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }
}

/// Why a quit did not happen, shown above the table it was asked from until it is dismissed.
struct QuitNoticeLine: View {
    @Environment(QuitModel.self) private var control

    var body: some View {
        if let notice = control.notice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PX.orange.color())
                Text(notice)
                    .font(PX.font(12))
                    .foregroundStyle(PX.soft)
                    .lineLimit(2)
                Spacer(minLength: 8)
                PXButton(title: "", symbol: "xmark", style: .ghost, height: 22, action: control.dismissNotice)
            }
            .padding(.horizontal, PX.inset)
            .padding(.vertical, 8)
            .background(PX.orange.color(0.07))
            .transition(.opacity)
        }
    }
}

// MARK: - Explain

/// Asks Claude about the one area it sits on. On a page it adapts to the page's light or dark background;
/// on a panel it is a ghost button like its neighbours.
struct ExplainButton: View {
    var section: AppSection
    var onCard = false
    /// What only this area knows, added to the question: the selected day, the list of login items.
    var extra: () -> String? = { nil }

    @Environment(Explainer.self) private var explainer
    @Environment(SystemMonitor.self) private var monitor
    @State private var hovering = false

    var body: some View {
        let streaming = explainer.isStreaming(section.rawValue)
        if onCard {
            PXButton(title: "Explain", symbol: "sparkles", style: .ghost, enabled: !streaming && monitor.snapshot != nil, height: 28, action: ask)
                .help("Ask \(AIProvider.current.assistant) to explain \(section.title.lowercased()) as it is right now")
        } else {
            Button(action: ask) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppSection.claude.rgb.color())
                    Text(streaming ? "Explaining" : "Explain")
                        .font(PX.font(12, .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.11 : 0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(PXPressStyle())
            .disabled(streaming || monitor.snapshot == nil)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .help("Ask \(AIProvider.current.assistant) to explain \(section.title.lowercased()) as it is right now")
        }
    }

    private func ask() {
        guard let snapshot = monitor.snapshot else { return }
        explainer.explain(section, snapshot: snapshot, history: monitor.history, extra: extra())
    }
}

/// Claude's answer for one area, where it was asked. Nothing is shown until Explain has been pressed.
struct ExplainCard: View {
    var section: AppSection
    /// What was asked about, when it is narrower than the area: one event, say.
    var key: String?
    var heading: String?
    /// Card on a page, or a block inside a menu bar panel.
    var width: CGFloat?
    var inset: CGFloat = PX.inset
    var extra: () -> String? = { nil }

    @Environment(Explainer.self) private var explainer
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let key = key ?? section.rawValue
        if let entry = explainer.entry(for: key) {
            let content = VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppSection.claude.rgb.color())
                    Text(heading ?? "\(AIProvider.current.assistant) on \(section == .dashboard ? "this Mac" : section.title.lowercased())")
                        .font(PX.font(13, .medium))
                        .tracking(PX.tracking(13))
                        .foregroundStyle(PX.text)
                    if entry.streaming {
                        PXSpinner(size: 11.5).padding(.leading, 2)
                    } else {
                        Text(settings.modelTitle)
                            .font(PX.font(11.5))
                            .foregroundStyle(PX.tertiary)
                    }
                    Spacer(minLength: 8)
                    if !entry.streaming, self.key == nil {
                        PXButton(title: "Again", symbol: "arrow.clockwise", style: .ghost, height: 24) {
                            guard let snapshot = monitor.snapshot else { return }
                            explainer.explain(section, snapshot: snapshot, history: monitor.history, extra: extra())
                        }
                    }
                    PXButton(title: "", symbol: "xmark", style: .ghost, height: 24) { explainer.dismiss(key) }
                        .padding(.leading, -4)
                }
                .frame(height: 24)
                if let failure = entry.failure {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(PX.orange.color())
                        Text(failure).font(PX.font(12.5)).foregroundStyle(PX.soft).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                } else {
                    MarkdownText(text: entry.text, streaming: entry.streaming)
                        .font(PX.font(width == nil ? 12.5 : 13))
                        .foregroundStyle(PX.label)
                        .lineSpacing(3)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, inset)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.colorScheme, .dark)

            if let width {
                content
                    .frame(width: width, alignment: .leading)
                    .pxCard()
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    content.background(AppSection.claude.rgb.color(0.05))
                    PXDivider()
                }
            }
        }
    }
}

// MARK: - A short list of apps

/// A fixed-height card listing the top few apps by some measure, with a strip of cells and two figures each.
struct TopAppsPanel: View {
    struct Row: Identifiable {
        var id: String
        var name: String
        var bundlePath: String?
        var fraction: Double
        var rgb: RGB
        var primary: String
        var secondary: String?
    }

    var title: String
    var caption: String?
    var rows: [Row]
    var empty: String
    var columns: (String, String?) = ("", nil)

    var body: some View {
        PXPanel(title: title, caption: caption, width: PX.cardWidth) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("App").frame(maxWidth: .infinity, alignment: .leading)
                    Text(columns.0).frame(width: 92, alignment: .trailing)
                    if let second = columns.1 { Text(second).frame(width: 92, alignment: .trailing) }
                }
                .font(PX.font(10.5, .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PX.tertiary)
                .padding(.horizontal, PX.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                PXDivider()
                VStack(spacing: 1) {
                    if rows.isEmpty {
                        Text(empty)
                            .font(PX.font(12))
                            .foregroundStyle(PX.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                    }
                    ForEach(rows.prefix(8)) { row in
                        HStack(spacing: 0) {
                            Image(nsImage: IconCache.icon(forBundlePath: row.bundlePath))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                            Text(row.name)
                                .font(PX.font(12, .medium))
                                .foregroundStyle(PX.label)
                                .lineLimit(1)
                                .padding(.leading, 9)
                            Spacer(minLength: 10)
                            MiniMatrixBar(fraction: row.fraction, rgb: row.rgb)
                                .frame(width: 96)
                                .padding(.trailing, 6)
                            Text(row.primary)
                                .foregroundStyle(PX.label)
                                .frame(width: 92, alignment: .trailing)
                            if let secondary = row.secondary {
                                Text(secondary)
                                    .foregroundStyle(PX.secondary)
                                    .frame(width: 92, alignment: .trailing)
                            }
                        }
                        .font(PX.font(12))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 342.75)
    }
}
