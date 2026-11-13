import Foundation

/// The cards on the Dashboard, by name, so their order can be chosen and remembered.
enum DashboardCard: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, storage, thermal, power, battery, network, throughput, energyDay, assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .thermal: return "Thermals"
        case .power: return "Power"
        case .battery: return "Battery"
        case .network: return "Network"
        case .throughput: return "Throughput"
        case .energyDay: return "Energy today"
        case .assistant: return "Ask \(AIProvider.current.assistant)"
        }
    }

    /// The assistant's card spans the page; the rest are one column wide.
    var isWide: Bool { self == .assistant }
    /// The cards the Dashboard's menu bar panel also shows, as sections.
    var inPanel: Bool { self != .throughput && self != .energyDay && self != .assistant }

    /// The order the Dashboard had before it could be changed. A laptop has two cards more.
    static func standard(battery: Bool) -> [DashboardCard] {
        battery ? [.cpu, .gpu, .memory, .storage, .thermal, .power, .battery, .network, .throughput, .energyDay, .assistant]
                : [.cpu, .gpu, .memory, .storage, .thermal, .power, .network, .throughput, .assistant]
    }
}

/// Working out the order to show: what was saved, minus what this Mac does not have, plus anything new.
enum DashboardOrder {
    /// The saved order, with only the cards this Mac has, then any card the saved order does not mention (one
    /// added in a later version, or the battery's on a Mac that gained one) in its usual order after them.
    /// Nothing saved is the usual order.
    static func resolve(saved: [String], available: [DashboardCard]) -> [DashboardCard] {
        var seen = Set<DashboardCard>()
        let chosen = saved.compactMap(DashboardCard.init(rawValue:)).filter { available.contains($0) && seen.insert($0).inserted }
        return chosen + available.filter { !seen.contains($0) }
    }

    /// `card` taken out and put where `target` is: before it when moving up the page, after it when moving down.
    static func moving(_ card: DashboardCard, onto target: DashboardCard, in order: [DashboardCard]) -> [DashboardCard] {
        guard card != target, let from = order.firstIndex(of: card), let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: from)
        result.insert(card, at: to)
        return result
    }

    enum Step { case top, up, down, bottom }

    static func moving(_ card: DashboardCard, _ step: Step, in order: [DashboardCard]) -> [DashboardCard] {
        guard let from = order.firstIndex(of: card) else { return order }
        let to: Int
        switch step {
        case .top: to = 0
        case .up: to = max(0, from - 1)
        case .down: to = min(order.count - 1, from + 1)
        case .bottom: to = order.count - 1
        }
        guard to != from else { return order }
        var result = order
        result.remove(at: from)
        result.insert(card, at: to)
        return result
    }

    /// Rows of the page: one-column cards side by side, a wide card on a row of its own. A wide card that would
    /// leave half a row empty above it lets the next one-column card go first.
    static func rows(_ order: [DashboardCard], columns: Int) -> [[DashboardCard]] {
        guard columns > 1 else { return order.map { [$0] } }
        var rows: [[DashboardCard]] = []
        var pending: [DashboardCard] = []
        var waiting: [DashboardCard] = []
        for card in order {
            if card.isWide {
                if pending.isEmpty { rows.append([card]) } else { waiting.append(card) }
            } else {
                pending.append(card)
                if pending.count == columns {
                    rows.append(pending)
                    pending = []
                    rows.append(contentsOf: waiting.map { [$0] })
                    waiting = []
                }
            }
        }
        if !pending.isEmpty { rows.append(pending) }
        rows.append(contentsOf: waiting.map { [$0] })
        return rows
    }
}
