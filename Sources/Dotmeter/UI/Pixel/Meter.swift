import AppKit
import SwiftUI

enum MeterIcon {
    case symbol(String)
    case image(NSImage)
    case swatch
}

/// One legend entry, and (when `inBar` is set) one bar segment.
struct MeterItem: Identifiable {
    var id: String
    var name: String
    var icon: MeterIcon
    var rgb: RGB
    /// Share of the bar, in the same unit as `MeterModel.capacity`.
    var amount: Double
    /// Number shown in the legend; it counts toward new values.
    var number: Double
    var format: (Double) -> String
    var detail: String
    var inBar = true
    var inLegend = true
}

enum MeterStatus: Equatable {
    case plain(String)
    /// "Calculating" + a monospaced path.
    case activity(String, String)
    /// Green check, a bold part and a quiet part.
    case success(String, String)
    /// Something did not happen, and why.
    case warning(String)

    var key: String {
        switch self {
        case .plain(let s): return "p:" + s
        case .activity(let a, _): return "a:" + a
        case .success(let a, let b): return "s:" + a + b
        case .warning(let s): return "w:" + s
        }
    }
}

struct MeterAction {
    var title: String
    var symbol: String?
    var spinning = false
    var enabled = true
    var destructive = false
    /// Resting rotation of the symbol, in degrees.
    var symbolRotation: Double = 0
    var action: () -> Void
}

enum MeterFooter {
    case searching(String)
    case suggestion(icon: MeterIcon, rgb: RGB, text: String, action: MeterAction?)
    case success(String)

    var key: String {
        switch self {
        case .searching(let s): return "w:" + s
        case .suggestion(_, _, let text, let action): return "g:" + text + (action?.title ?? "")
        case .success(let s): return "s:" + s
        }
    }
}

struct MeterModel {
    var number: Double
    var numberFormat: (Double) -> String
    var caption: String
    var status: MeterStatus
    var items: [MeterItem]
    var capacity: Double
    var mode: MatrixMode = .rest
    var footer: MeterFooter
    var trailing: MeterAction?
    /// Numbers count toward new values only while something is in progress; routine refreshes just update.
    var animatesNumbers = false

    var segments: [MatrixSegment] {
        items.filter(\.inBar).map { MatrixSegment(id: $0.id, rgb: $0.rgb, value: $0.amount) }
    }
}

// MARK: - Pieces

struct MeterIconView: View {
    var icon: MeterIcon
    var rgb: RGB
    var size: CGFloat = 14

    private static let cutout: Set<String> = ["cursorarrow.square.fill"]

    var body: some View {
        switch icon {
        case .symbol(let name):
            if Self.cutout.contains(name) {
                // Filled badge with a dark glyph cut into it, like the reference's Apps icon.
                Image(systemName: name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(PX.card, rgb.color())
                    .frame(width: size, height: size)
            } else {
                Image(systemName: name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .font(.system(size: size, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(rgb.color())
                    .frame(width: size, height: size)
            }
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .swatch:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(rgb.color())
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
        }
    }
}

struct MeterHeadline: View {
    var number: Double
    var format: (Double) -> String
    var caption: String
    var size: CGFloat = 22.5
    var captionSize: CGFloat = 12.5
    var animated = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6.5) {
            CountingText(value: number, format: format)
                .font(PX.font(size, .medium))
                    .tracking(PX.tracking(size))
                .tracking(PX.tracking(size))
                .foregroundStyle(PX.text)
                .animation(animated ? CountingText.animation : nil, value: number)
            Text(caption)
                .font(PX.font(captionSize))
                .tracking(PX.tracking(captionSize))
                .foregroundStyle(PX.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct MeterStatusLine: View {
    var status: MeterStatus
    var hovered: MeterItem?
    var size: CGFloat = 12

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .id(hovered.map { "h:" + $0.id } ?? status.key)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: hovered?.id)
        .animation(.easeOut(duration: 0.22), value: status.key)
        .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        if let item = hovered {
            HStack(spacing: 0) {
                MeterIconView(icon: item.icon, rgb: item.rgb, size: size + 1)
                Text(item.name)
                    .font(PX.font(size, .medium))
                    .tracking(PX.tracking(size))
                    .foregroundStyle(PX.text)
                    .padding(.leading, 6.5)
                Text(item.format(item.number))
                    .font(PX.font(size))
                    .tracking(PX.tracking(size))
                    .monospacedDigit()
                    .foregroundStyle(PX.secondary)
                    .padding(.leading, 5.5)
                Text(item.detail)
                    .font(PX.font(size))
                    .tracking(PX.tracking(size))
                    .foregroundStyle(PX.tertiary)
                    .padding(.leading, 9.5)
                    .truncationMode(.tail)
            }
        } else {
            switch status {
            case .plain(let text):
                Text(text)
                    .font(PX.font(size))
                    .tracking(PX.tracking(size))
                    .monospacedDigit()
                    .foregroundStyle(PX.secondary)
            case .activity(let label, let path):
                HStack(spacing: 8) {
                    Text(label)
                        .font(PX.font(size))
                    .tracking(PX.tracking(size))
                        .foregroundStyle(PX.soft)
                        .fixedSize()
                    Text(path)
                        .font(PX.mono(size - 1.5))
                        .foregroundStyle(PX.tertiary)
                        .truncationMode(.middle)
                }
            case .warning(let text):
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size - 2))
                        .foregroundStyle(PX.orange.color())
                    Text(text)
                        .font(PX.font(size))
                        .foregroundStyle(PX.soft)
                        .truncationMode(.tail)
                }
            case .success(let strong, let quiet):
                HStack(spacing: 0) {
                    PXCheck(size: size - 1.5)
                    Text(strong)
                        .font(PX.font(size, .medium))
                    .tracking(PX.tracking(size))
                        .foregroundStyle(PX.text)
                        .padding(.leading, 7)
                    Text(quiet)
                        .font(PX.font(size))
                    .tracking(PX.tracking(size))
                        .monospacedDigit()
                        .foregroundStyle(PX.secondary)
                        .padding(.leading, 5)
                }
            }
        }
    }
}

struct MeterLegend: View {
    var items: [MeterItem]
    @Binding var hovered: String?
    var columns = 3
    var rowHeight: CGFloat = 26
    var columnGap: CGFloat = 3.25
    var rowGap: CGFloat = 1.5
    var size: CGFloat = 12
    var animated = false
    /// The item currently chosen by clicking, if the card supports that.
    var selected: String?
    var onSelect: ((String) -> Void)?

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(spacing: rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: columnGap) {
                    ForEach(row) { item in
                        cell(item)
                    }
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).frame(height: rowHeight)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ item: MeterItem) -> some View {
        let isHovered = hovered == item.id
        let dimmed = hovered != nil && !isHovered
        return HStack(spacing: 0) {
            MeterIconView(icon: item.icon, rgb: item.rgb, size: size + 2)
                .padding(.leading, 8)
            Text(item.name)
                .font(PX.font(size))
                    .tracking(PX.tracking(size))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 7.5)
            Spacer(minLength: 6)
            CountingText(value: item.number, format: item.format)
                .font(PX.font(size))
                    .tracking(PX.tracking(size))
                .foregroundStyle(PX.secondary)
                .lineLimit(1)
                .fixedSize()
                .animation(animated ? CountingText.animation : nil, value: item.number)
                .padding(.trailing, 11.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(isHovered ? PX.rowHover : (selected == item.id ? PX.rowHover.opacity(0.62) : .clear)))
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .onTapGesture { onSelect?(item.id) }
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.16), value: selected)
    }
}

struct MeterFooterView: View {
    var footer: MeterFooter
    var size: CGFloat = 12
    var leading: CGFloat = 22.5
    var trailing: CGFloat = 18

    var body: some View {
        ZStack {
            content
                .id(footer.key)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.22), value: footer.key)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            switch footer {
            case .searching(let text):
                PXSpinner(size: 13)
                Text(text)
                    .font(PX.font(size))
                    .tracking(PX.tracking(size))
                    .foregroundStyle(PX.secondary)
                    .padding(.leading, 8.5)
                Spacer(minLength: 8)
            case .suggestion(let icon, let rgb, let text, let action):
                MeterIconView(icon: icon, rgb: rgb, size: 13)
                Text(text)
                    .font(PX.font(size))
                    .tracking(PX.tracking(size))
                    .foregroundStyle(PX.label)
                    .lineLimit(2)
                    .padding(.leading, 8.5)
                Spacer(minLength: 10)
                if let action {
                    PXButton(
                        title: action.title,
                        symbol: action.symbol,
                        spinning: action.spinning,
                        enabled: action.enabled,
                        tint: action.destructive ? Color(hex: 0xFF8A80) : nil,
                        action: action.action
                    )
                }
            case .success(let text):
                PXCheck(size: size - 1)
                    .frame(width: 13, height: 13)
                Text(text)
                    .font(PX.font(size))
                    .tracking(PX.tracking(size))
                    .foregroundStyle(PX.label)
                    .padding(.leading, 8.5)
                Spacer(minLength: 8)
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
    }
}

// MARK: - Full card (the reference layout, 583 x 342.75)

struct MeterCard: View {
    var model: MeterModel
    /// 583 is the reference card. Wider cards keep every measurement and simply fit more legend columns.
    var width: CGFloat = PX.cardWidth
    /// Clicking a legend row or a segment chooses it, so a table below can follow.
    var selected: String?
    var onSelect: ((String) -> Void)?
    /// Debug: DOTMETER_DEBUG_HOVER=<item id> starts with that legend item hovered, for design captures.
    @State private var hovered: String? = ProcessInfo.processInfo.environment["DOTMETER_DEBUG_HOVER"]

    var body: some View {
        let hoveredItem = model.items.first { $0.id == hovered }
        VStack(alignment: .leading, spacing: 0) {
            MeterHeadline(number: model.number, format: model.numberFormat, caption: model.caption, animated: model.animatesNumbers)
                .frame(height: 27.5, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    if let trailing = model.trailing {
                        PXButton(title: trailing.title, symbol: trailing.symbol, style: .ghost, spinning: trailing.spinning, enabled: trailing.enabled, height: 28, symbolRotation: trailing.symbolRotation, action: trailing.action)
                            .offset(x: 6.5, y: 0.5)
                    }
                }
                .padding(.top, 20)
                .padding(.horizontal, PX.inset)

            MeterStatusLine(status: model.status, hovered: hoveredItem)
                .frame(height: 15)
                .padding(.top, 5.5)
                .padding(.horizontal, PX.inset)

            MatrixBar(segments: model.segments, capacity: model.capacity, highlight: hovered, mode: model.mode, onHover: { id in
                if hovered != id { hovered = id }
            }, onTap: { id in
                onSelect?(id)
            })
            .padding(.top, 20.25)
            .padding(.leading, PX.inset)
            .padding(.trailing, 21)

            MeterLegend(items: model.items.filter(\.inLegend), hovered: $hovered, columns: max(3, Int((width - 32 + 3.25) / 185)), animated: model.animatesNumbers, selected: selected, onSelect: onSelect)
                .padding(.top, 18.75)
                .padding(.horizontal, 16)

            if width == PX.cardWidth {
                Spacer(minLength: 0)
            } else {
                Color.clear.frame(height: 15.75)
            }
            PXDivider()
            MeterFooterView(footer: model.footer)
                .frame(height: 57)
        }
        .frame(width: width, height: width == PX.cardWidth ? 342.75 : nil, alignment: .top)
        .pxCard()
    }
}

// MARK: - Compact section (menu bar panel)

/// Names the area a compact section belongs to, and leads to it.
struct MeterTag {
    var title: String
    var symbol: String
    var rgb: RGB
    var action: () -> Void
}

private struct MeterTagButton: View {
    var tag: MeterTag
    @State private var hovering = false

    var body: some View {
        Button(action: tag.action) {
            HStack(spacing: 5.5) {
                Image(systemName: tag.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(tag.rgb.color(hovering ? 1 : 0.85))
                Text(tag.title)
                    .font(PX.font(11.5))
                    .foregroundStyle(hovering ? PX.text : PX.ghostText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(PX.tertiary)
            }
            .padding(.leading, 7)
            .padding(.trailing, 6)
            .frame(height: 23)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(hovering ? PX.ghostHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PXPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct MeterSection: View {
    var model: MeterModel
    var maxItems = 4
    var tag: MeterTag?
    /// A shorter bar and no status line, for when many areas share one short panel.
    var tight = false
    @State private var hovered: String?

    var body: some View {
        let legend = Array(model.items.filter(\.inLegend).prefix(maxItems))
        let hoveredItem = model.items.first { $0.id == hovered }
        VStack(alignment: .leading, spacing: 0) {
            MeterHeadline(number: model.number, format: model.numberFormat, caption: model.caption, size: tight ? 16.5 : 19, captionSize: tight ? 11.5 : 12)
                .frame(height: tight ? 20 : 23, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    if let tag { MeterTagButton(tag: tag).offset(x: 7, y: tight ? -2.5 : -1.5) }
                }
            if !tight || hoveredItem != nil {
                MeterStatusLine(status: model.status, hovered: hoveredItem, size: 11.5)
                    .frame(height: 14)
                    .padding(.top, 4)
            }
            MatrixBar(segments: model.segments, capacity: model.capacity, highlight: hovered, mode: model.mode, rows: tight ? 6 : PX.compactRows) { id in
                if hovered != id { hovered = id }
            }
            .padding(.top, tight ? 8 : 12)
            if !legend.isEmpty {
                MeterLegend(items: legend, hovered: $hovered, columns: 2, rowHeight: 24, columnGap: 4, rowGap: 1, size: 11.5)
                    .padding(.top, 9)
                    .padding(.horizontal, -8)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, tight ? 11 : 15)
        .padding(.bottom, legend.isEmpty ? (tight ? 12 : 16) : 10)
    }
}
