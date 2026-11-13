import AppKit
import SwiftUI

/// Claude's analysis in the pixel language. Wide on the desktop window, compact in the menu bar panel.
struct ClaudeCard: View {
    enum Layout { case wide, compact }

    var layout: Layout
    var openSettings: () -> Void

    @Environment(SystemMonitor.self) private var monitor
    @Environment(AnalysisSession.self) private var analysis
    @Environment(AppSettings.self) private var settings

    @State private var followUp = ""
    @State private var contentHeight: CGFloat = 40
    @State private var copied = false

    private var inset: CGFloat { layout == .wide ? PX.inset : 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if analysis.turns.isEmpty {
                idle
            } else {
                header
                    .padding(.horizontal, inset)
                    .padding(.top, layout == .wide ? 18 : 14)
                transcript
                    .padding(.horizontal, inset)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                PXDivider()
                followUpRow
            }
        }
        .animation(.easeOut(duration: 0.22), value: analysis.turns.isEmpty)
    }

    // MARK: Idle

    private static let suggestions = [
        "Why are the fans on?",
        "What is using the most memory?",
        "What can I safely delete?",
        "Is anything misbehaving?",
    ]

    @ViewBuilder
    private var idle: some View {
        if !settings.hasAPIKey {
            MeterFooterView(
                footer: .suggestion(
                    icon: .symbol("key.fill"), rgb: PX.yellow, text: "Add your \(settings.provider.company) API key to turn on \(settings.provider.assistant).",
                    action: MeterAction(title: "Open Settings", action: openSettings)
                ),
                leading: inset + 0.5
            )
            .frame(height: 57)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = analysis.state {
                    let keyProblem = message.localizedCaseInsensitiveContains("key")
                    MeterFooterView(
                        footer: .suggestion(
                            icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.orange, text: message,
                            action: keyProblem ? MeterAction(title: "Open Settings", action: openSettings) : nil
                        ),
                        leading: inset + 0.5
                    )
                    .frame(minHeight: 50)
                    PXDivider()
                }
                if layout == .wide { wideAsk } else { compactAsk }
            }
        }
    }

    /// The window's version: a proper question field and a few things worth asking.
    private var wideAsk: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PX.purple.color())
                Text("Ask \(settings.provider.assistant) about this Mac")
                    .font(PX.font(15, .medium))
                    .tracking(PX.tracking(15))
                    .foregroundStyle(PX.text)
                Spacer(minLength: 8)
                Text(settings.modelTitle)
                    .font(PX.font(11))
                    .foregroundStyle(PX.tertiary)
            }
            .padding(.top, 18)

            HStack(spacing: 10) {
                TextField("", text: $followUp, prompt: Text("Ask anything. Why is it loud? What is corespotlightd? Which app should I quit?").foregroundStyle(PX.tertiary))
                    .textFieldStyle(.plain)
                    .font(PX.font(13))
                    .foregroundStyle(PX.text)
                    .onSubmit(send)
                PXButton(title: "Ask", symbol: "arrow.up", style: .filled, enabled: !followUp.trimmingCharacters(in: .whitespaces).isEmpty, height: 26, action: send)
            }
            .padding(.leading, 13)
            .padding(.trailing, 7)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0x202124)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
            .padding(.top, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    PXButton(title: "Full check-up", symbol: "sparkles", style: .filled, height: 26, action: run)
                    ForEach(Self.suggestions, id: \.self) { question in
                        PXButton(title: question, style: .filled, height: 26) {
                            analysis.ask(question, snapshot: monitor.snapshot, history: monitor.history)
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, inset)
    }

    /// The panel's version: one row. Type to ask, or press Check-up for the full read.
    private var compactAsk: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PX.purple.color())
            TextField("", text: $followUp, prompt: Text("Ask \(settings.provider.assistant) about this Mac").foregroundStyle(PX.secondary))
                .textFieldStyle(.plain)
                .font(PX.font(12))
                .foregroundStyle(PX.text)
                .onSubmit(send)
            if followUp.trimmingCharacters(in: .whitespaces).isEmpty {
                PXButton(title: "Check-up", action: run)
            } else {
                PXButton(title: "Ask", symbol: "arrow.up", action: send)
            }
        }
        .padding(.leading, inset + 0.5)
        .padding(.trailing, 14)
        .frame(height: 57)
    }

    // MARK: Result

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PX.purple.color())
            Text("\(settings.provider.assistant)'s read")
                .font(PX.font(layout == .wide ? 15 : 13, .medium))
                .tracking(PX.tracking(13))
                .foregroundStyle(PX.text)
                .fixedSize()
            if let status = analysis.turns.first?.report?.status {
                PXStatusPill(status: status)
            }
            if analysis.isStreaming {
                PXSpinner(size: 12)
            }
            Spacer(minLength: 8)
            if layout == .wide {
                Text(analysis.modelUsed ?? settings.modelTitle)
                    .font(PX.font(11))
                    .foregroundStyle(PX.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // The panel is narrow, so its buttons are icons only.
            let titled = layout == .wide
            PXButton(title: titled ? (copied ? "Copied" : "Copy") : "", symbol: copied ? "checkmark" : "doc.on.doc", style: .ghost, height: 26, action: copy)
                .help("Copy")
            PXButton(title: titled ? "Again" : "", symbol: "arrow.clockwise", style: .ghost, enabled: !analysis.isStreaming, height: 26, action: run)
                .help("Analyze again")
            PXButton(title: titled ? "Clear" : "", symbol: "xmark", style: .ghost, height: 26, action: analysis.reset)
                .help("Clear")
        }
        .padding(.trailing, layout == .wide ? 0 : -6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(analysis.turns) { turn in
                        let streamingThis = analysis.isStreaming && turn.id == analysis.turns.last?.id
                        if let question = turn.question {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(PX.tertiary)
                                Text(question)
                                    .font(PX.font(12, .medium))
                                    .foregroundStyle(PX.soft)
                            }
                            .padding(.top, 2)
                        }
                        if turn.isStructured, let report = turn.report {
                            PXReportView(report: report, apps: analysis.appsAtStart, streaming: streamingThis, wide: layout == .wide)
                        } else if turn.answer.isEmpty || (turn.isStructured && streamingThis) {
                            HStack(spacing: 8) {
                                PXSpinner(size: 12)
                                Text("Reading the snapshot")
                                    .font(PX.font(12))
                                    .foregroundStyle(PX.secondary)
                            }
                        } else {
                            MarkdownText(text: turn.answer, streaming: streamingThis)
                                .foregroundStyle(PX.label)
                        }
                    }
                    if case .failed(let message) = analysis.state {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PX.orange.color())
                            Text(message).foregroundStyle(PX.soft)
                        }
                        .font(PX.font(11.5))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HeightReader(height: $contentHeight))
            }
            .frame(height: min(contentHeight, maxHeight))
            .onChange(of: analysis.turns.last?.answer.count ?? 0) { _, _ in
                // The report fills in from the top and is read from the top; only follow-up answers chase the bottom.
                if analysis.isStreaming, analysis.turns.count > 1 { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var followUpRow: some View {
        HStack(spacing: 10) {
            TextField("", text: $followUp, prompt: Text("Ask anything else").foregroundStyle(PX.tertiary))
                .textFieldStyle(.plain)
                .font(PX.font(12))
                .foregroundStyle(PX.text)
                .onSubmit(send)
                .disabled(analysis.isStreaming)
            if analysis.isStreaming {
                PXButton(title: "Stop", style: .filled, height: 26, action: analysis.stop)
            } else {
                PXButton(title: "Send", symbol: "arrow.up", style: .filled, enabled: !followUp.trimmingCharacters(in: .whitespaces).isEmpty, height: 26, action: send)
            }
        }
        .padding(.leading, inset)
        .padding(.trailing, layout == .wide ? 18 : 14)
        .frame(height: layout == .wide ? 52 : 46)
    }

    private var maxHeight: CGFloat {
        if layout == .wide { return 520 }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(360, max(150, screenHeight - 600))
    }

    // MARK: Actions

    private func run() {
        guard let snapshot = monitor.snapshot else { return }
        analysis.analyze(snapshot: snapshot, history: monitor.history)
    }

    private func send() {
        let question = followUp
        followUp = ""
        analysis.ask(question, snapshot: monitor.snapshot, history: monitor.history)
    }

    private func copy() {
        let text = analysis.turns.map { turn in
            let answer = turn.report?.plainText ?? turn.answer
            return [turn.question.map { "> " + $0 }, answer].compactMap { $0 }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.3)); copied = false }
    }
}

struct PXStatusPill: View {
    var status: AnalysisReport.Status

    private var rgb: RGB {
        switch status {
        case .normal: return PX.greenRGB
        case .busy: return PX.yellow
        case .hot: return PX.orange
        case .problem: return PX.red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(rgb.color()).frame(width: 5.5, height: 5.5)
            Text(status.title).font(PX.font(10.5, .medium)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(rgb.color())
        .padding(.horizontal, 7.5)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(rgb.color(0.14)))
    }
}

/// Claude's structured report: verdict, what's using it, what to do, thermal note.
struct PXReportView: View {
    var report: AnalysisReport
    var apps: [AppUsage]
    var streaming: Bool
    var wide: Bool
    @Environment(QuitModel.self) private var control
    @Environment(SystemMonitor.self) private var monitor

    /// The running app an action says to quit, if it is still there and can be quit from here.
    private func quitTarget(_ action: AnalysisReport.Action) -> AppUsage? {
        guard !action.quit.isEmpty else { return nil }
        let wanted = action.quit.lowercased()
        return monitor.snapshot?.apps.first { $0.name.lowercased() == wanted && ProcessControl.canQuit($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let verdict = report.verdict {
                Text(verdict)
                    .font(PX.font(wide ? 13 : 12.5))
                    .foregroundStyle(PX.label)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if wide {
                HStack(alignment: .top, spacing: 36) {
                    culprits.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 14) {
                        actions
                        thermal
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                culprits
                actions
                thermal
            }
            if streaming && report.culprits.isEmpty {
                HStack(spacing: 8) {
                    PXSpinner(size: 12)
                    Text("Looking at what's running").font(PX.font(12)).foregroundStyle(PX.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(PX.font(10.5, .medium))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(PX.tertiary)
    }

    @ViewBuilder
    private var culprits: some View {
        if !report.culprits.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                title("What's using it")
                ForEach(report.culprits) { culprit in
                    HStack(alignment: .top, spacing: 9) {
                        Image(nsImage: icon(for: culprit.name))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2.5) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(culprit.name)
                                    .font(PX.font(12, .medium))
                                    .foregroundStyle(PX.text)
                                    .lineLimit(1)
                                if culprit.concern != .none {
                                    let rgb = culprit.concern == .fix ? PX.orange : PX.yellow
                                    Text(culprit.concern == .fix ? "Fix" : "Watch")
                                        .font(PX.font(9.5, .semibold))
                                        .foregroundStyle(rgb.color())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(rgb.color(0.15)))
                                }
                                Spacer(minLength: 6)
                                Text(culprit.usage)
                                    .font(PX.font(12))
                                    .monospacedDigit()
                                    .foregroundStyle(PX.secondary)
                                    .lineLimit(1)
                            }
                            Text(culprit.reason)
                                .font(PX.font(12))
                                .foregroundStyle(PX.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if !culprit.processes.isEmpty {
                                Text(culprit.processes.joined(separator: "  ·  "))
                                    .font(PX.mono(10))
                                    .foregroundStyle(PX.tertiary)
                                    .lineLimit(2)
                                    .padding(.top, 1)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !report.actions.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                title("What to do")
                ForEach(Array(report.actions.enumerated()), id: \.element.id) { index, action in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(PX.soft)
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(PX.button))
                            .padding(.top, 0.5)
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(action.title)
                                .font(PX.font(12, .medium))
                                .foregroundStyle(PX.text)
                            Text(action.detail)
                                .font(PX.font(12))
                                .foregroundStyle(PX.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            // A step that names a running app can be carried out from here, in two clicks.
                            if !streaming, let target = quitTarget(action) {
                                HStack(spacing: 7) {
                                    if control.pending[target.id] != nil {
                                        PXSpinner(size: 11.5)
                                        Text("Asking \(target.name) to quit").font(PX.font(11.5)).foregroundStyle(PX.secondary)
                                    } else {
                                        PXConfirmButton(title: "Quit \(target.name)", armedTitle: "Confirm: quit \(target.name)", symbol: "xmark", armed: control.isArmed(target.id, force: false)) {
                                            control.request(target, force: false)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var thermal: some View {
        if let note = report.thermal {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PX.tertiary)
                Text(note)
                    .font(PX.font(12))
                    .foregroundStyle(PX.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(for name: String) -> NSImage {
        let lowered = name.lowercased()
        if let app = apps.first(where: { $0.name.lowercased() == lowered }) { return IconCache.icon(for: app) }
        if let app = apps.first(where: { lowered.contains($0.name.lowercased()) || $0.name.lowercased().contains(lowered) }) { return IconCache.icon(for: app) }
        return IconCache.generic
    }
}
