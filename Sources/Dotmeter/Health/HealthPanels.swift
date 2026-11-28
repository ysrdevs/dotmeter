import SwiftUI
import UserNotifications

/// The internal drive's own account of itself: how much of its rated life is used, and the counters behind it.
struct DriveHealthPanel: View {
    var drive: DriveHealth
    var width: CGFloat

    /// The drive's colour while all is well; a warning or a worn-out rating changes it.
    private var tone: RGB {
        if !drive.warnings.isEmpty || drive.used >= 100 { return PX.red }
        return drive.used >= 80 ? PX.yellow : PX.blue
    }

    var body: some View {
        let wide = width > 700
        let rows = stats
        PXPanel(title: "Drive health", caption: drive.model, width: width) {
            Group {
                if wide {
                    // The wear under the left-hand card of the pair above and the counters under the right-hand
                    // one, so the page keeps its two columns.
                    HStack(alignment: .top, spacing: 2 * PX.inset + PageScaffold<EmptyView>.gap) {
                        wear.frame(width: PX.cardWidth - 2 * PX.inset, alignment: .leading)
                        HStack(alignment: .top, spacing: 30) {
                            column(Array(rows.prefix((rows.count + 1) / 2)))
                            column(Array(rows.dropFirst((rows.count + 1) / 2)))
                        }
                    }
                    .padding(.bottom, 14)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        wear
                        PXDivider().padding(.horizontal, -PX.inset).padding(.top, 14)
                        column(rows).padding(.vertical, 7)
                    }
                }
            }
            .padding(.horizontal, PX.inset)
        }
    }

    private var wear: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6.5) {
                Text("\(drive.used)%")
                    .font(PX.font(22.5, .medium))
                    .tracking(PX.tracking(22.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.text)
                Text("of its rated life used")
                    .font(PX.font(12.5))
                    .foregroundStyle(PX.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 16)
            .help("The drive's own estimate of how much of the writing it was built for has been done. It can pass 100%: the rating is cautious, not a cut-off.")
            MiniMatrixBar(fraction: drive.usedFraction, rgb: tone, rows: 5)
                .padding(.top, 14)
            HStack(spacing: 7) {
                if drive.warnings.isEmpty {
                    PXCheck(size: 10.5).frame(width: 13, height: 13)
                    Text("The drive reports no warnings.")
                } else {
                    MeterIconView(icon: .symbol("exclamationmark.triangle.fill"), rgb: PX.orange, size: 12)
                    Text(drive.warnings.joined(separator: " · "))
                }
            }
            .font(PX.font(12))
            .foregroundStyle(PX.label)
            .lineLimit(2)
            .padding(.top, 13)
        }
    }

    private func column(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { PXStatRow(label: $0.label, value: $0.value, detail: $0.detail).help($0.help) }
        }
        .frame(maxWidth: .infinity)
    }

    private struct Row: Identifiable {
        var label: String
        var value: String
        var detail: String?
        var help = ""
        var id: String { label }
    }

    private var stats: [Row] {
        var rows = [
            Row(label: "Written", value: DriveHealth.amount(drive.bytesWritten), detail: "since new"),
            Row(label: "Read", value: DriveHealth.amount(drive.bytesRead), detail: "since new"),
            Row(label: "Powered on", value: "\(Format.count(drive.powerOnHours)) \(drive.powerOnHours == 1 ? "hour" : "hours")", detail: drive.powerOnHours >= 48 ? DriveHealth.span(hours: drive.powerOnHours) : nil),
            Row(label: "Power cycles", value: Format.count(drive.powerCycles)),
            Row(label: "Unsafe shutdowns", value: Format.count(drive.unsafeShutdowns), help: "Times the drive lost power without being told first."),
            Row(label: "Spare", value: "\(drive.spare)%", detail: "warns under \(drive.spareThreshold)%", help: "Blocks kept back to replace ones that wear out. The drive raises a warning when fewer than this are left."),
            Row(label: "Media errors", value: drive.mediaErrors == 0 ? "None" : Format.count(drive.mediaErrors), help: "Data the drive could not read back intact."),
        ]
        if let celsius = drive.celsius { rows.append(Row(label: "Temperature", value: Format.temperature(celsius), detail: "the drive's own sensor")) }
        return rows
    }
}

/// Keyboards, mice and whatever else reports a battery level, one row each. Not shown when nothing does.
struct AccessoriesPanel: View {
    var accessories: [AccessoryBattery]
    var width: CGFloat

    var body: some View {
        let wide = width > 700
        let low = accessories.filter(\.isLow).count
        PXPanel(title: "Accessories", caption: low > 0 ? "battery levels · \(low) low" : "battery levels", width: width) {
            VStack(spacing: 1) {
                ForEach(accessories) { AccessoryRow(device: $0, wide: wide) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct AccessoryRow: View {
    var device: AccessoryBattery
    var wide: Bool
    @State private var hovering = false

    private var tone: RGB {
        if device.percent <= AccessoryWatch.low { return PX.red }
        return device.percent <= 30 ? PX.yellow : PX.greenRGB
    }

    var body: some View {
        HStack(spacing: 0) {
            MeterIconView(icon: .symbol(device.kind.symbol), rgb: PX.gray, size: 13)
                .frame(width: 16)
            Text(device.name)
                .font(PX.font(12, .medium))
                .foregroundStyle(PX.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: wide ? 266 : 150, alignment: .leading)
                .padding(.leading, 8)
            Text([device.transport, device.detail].compactMap { $0 }.joined(separator: " · "))
                .font(PX.font(11.5))
                .foregroundStyle(PX.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            // What needs saying about it, beside the bar: that it is filling up, or that it is nearly out.
            if device.isCharging == true {
                note("charging", symbol: "bolt.fill", color: PX.green)
            } else if device.isLow {
                note("low", symbol: nil, color: PX.red.color())
            }
            MiniMatrixBar(fraction: max(device.fraction, 0.012), rgb: tone)
                .frame(width: wide ? 220 : 110)
                .padding(.horizontal, 10)
            Text("\(device.percent)%")
                .font(PX.font(12))
                .monospacedDigit()
                .foregroundStyle(PX.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(hovering ? PX.rowHover : .clear))
        .onHover { hovering = $0 }
    }

    private func note(_ text: String, symbol: String?, color: Color) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)) }
            Text(text).font(PX.font(11.5))
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

extension AlertCenter {
    /// The knock for an accessory that has run low, one per device. Only the app's own watcher sends it: a test's
    /// watcher and made-up accessories write their events and stay quiet.
    func notifyAccessory(_ device: AccessoryBattery) {
        guard self === AlertCenter.shared, !HealthSampler.demo, Bundle.main.bundleIdentifier != nil, AppSettings.shared.notifies(.accessory) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(device.name) is at \(device.percent)%"
        content.body = "Its battery is running low. \(App.name) lists every accessory's level under Power."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dotmeter.accessory." + device.id, content: content, trigger: nil))
    }
}
