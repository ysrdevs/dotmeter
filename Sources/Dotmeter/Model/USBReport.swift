import Foundation

/// The whole USB picture as plain text and as JSON, for the command line and for Claude.
enum USBReport {
    private struct PortReport: Codable {
        var port: USBPort
        var diagnosis: PortDiagnosis
    }

    private struct Whole: Codable {
        var ports: [PortReport]
        var routers: [ThunderboltRouter]
        var charger: ChargerInfo?
    }

    static func json(_ stats: USBStats) -> String {
        let whole = Whole(ports: stats.ports.map { PortReport(port: $0, diagnosis: USBDiagnostics.diagnose($0, charger: stats.charger)) }, routers: stats.routers, charger: stats.charger)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(whole)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func text(_ stats: USBStats) -> String {
        var out: [String] = []
        for port in stats.ports {
            let diagnosis = USBDiagnostics.diagnose(port, charger: stats.charger)
            out.append(stats.title(port) + (port.connected ? " · " + (port.activeNames.isEmpty ? "something attached, no data" : port.activeNames.joined(separator: ", ")) : " · nothing connected"))
            guard port.connected else { continue }
            for verdict in diagnosis.all {
                out.append("  \(verdict.tone == .caution ? "!" : (verdict.tone == .good ? "✓" : "·")) \(verdict.title)")
                out.append("      \(verdict.detail)")
            }
            if let negotiated = diagnosis.negotiated {
                var line = "  Running: \(Format.linkSpeed(negotiated))" + (diagnosis.negotiatedName.map { " \($0)" } ?? "")
                if let lane = port.thunderbolt?.lane, let each = ThunderboltLane.perLane(lane.speedCode) { line += ", \(lane.widthName) of \(Format.linkSpeed(each)) (\(lane.generationName))" }
                out.append(line)
            }
            for part in diagnosis.parts {
                out.append("    \(part.limiting ? "▸" : " ") \(part.name): \(part.text)" + (part.note.map { " (\($0))" } ?? ""))
            }
            if let partner = port.partner {
                var line = "  Far end: " + (port.thunderbolt?.deviceName ?? port.devices.first?.name ?? "answered over Power Delivery")
                line += " · \(partner.kindTitle) · \(USBVendors.label(partner.vendorID)) product \(String(format: "0x%04X", partner.productID))"
                out.append(line)
            }
            if let cable = port.cable {
                var facts = [cable.constructionText, "\(cable.speedText) (\(cable.speedName))"]
                if let amps = cable.amps, let watts = cable.watts { facts.append("\(String(format: "%g", amps)) A, up to \(watts) W") }
                if let length = cable.lengthText { facts.append(length) }
                if let plug = cable.plugText { facts.append(plug) }
                facts.append("chip by \(USBVendors.label(cable.identity.vendorID))")
                if cable.identity.xid != 0 { facts.append("certificate \(cable.identity.xid)") }
                out.append("  Cable: " + facts.joined(separator: " · "))
            } else if port.kind == .usbC {
                out.append("  Cable: no marker answered")
            }
            if let link = port.thunderbolt, !link.tunnelsProvisioned.isEmpty {
                out.append("  Tunnels set up: " + link.tunnelsProvisioned.joined(separator: ", "))
            }
            if let source = port.powerSource {
                out.append("  Charger offers: " + source.options.map { "\(Format.volts($0.millivolts)) \(Format.amps($0.milliamps))" + ($0.active ? " (in force)" : "") }.joined(separator: " · "))
            }
            for screen in port.displays where screen.active {
                var facts = [screen.name ?? "Screen"]
                if let signal = screen.signalText { facts.append(signal) }
                if let link = screen.linkText { facts.append(link) }
                if let branch = screen.branch { facts.append("through \(branch)") }
                if let output = screen.output { facts.append("last hop \(output)") }
                out.append("  Screen: " + facts.joined(separator: " · "))
            }
            func walk(_ device: USBDevice, _ depth: Int) {
                var facts = [device.name, device.role, Format.linkSpeed(device.bitsPerSecond), device.versionText]
                if let vendor = device.vendorName { facts.insert(vendor, at: 1) }
                if let milliamps = device.milliamps { facts.append("\(milliamps) mA") }
                if device.tunneled { facts.append("tunnelled") }
                out.append(String(repeating: "  ", count: depth + 1) + "└ " + facts.joined(separator: " · "))
                device.children.forEach { walk($0, depth + 1) }
            }
            port.devices.forEach { walk($0, 0) }
            if let health = port.health {
                out.append("  Counters: \(health.connects) connects, \(health.linkErrors) link errors, \(health.linkFailures) USB 3 link failures, \(health.enumerationFailures + health.addressFailures) failed starts, \(health.overcurrent) over-current" + (port.plugEvents.map { ", \($0) plug events" } ?? ""))
            }
        }
        let devices = stats.routers.filter { !$0.isHost }
        if !devices.isEmpty {
            out.append("")
            out.append("Thunderbolt")
            for router in devices {
                let parent = stats.routers.first { $0.uid == router.parentUID }
                out.append("  \(router.name)" + (router.vendor.map { " (\($0))" } ?? "") + " · behind " + (parent.map { $0.isHost ? "USB-C \($0.socket.map(String.init) ?? "?")" : $0.name } ?? "the Mac"))
                let riding = router.tunnels.map(\.kind.title)
                if !riding.isEmpty { out.append("    carrying: " + riding.joined(separator: ", ")) }
            }
        }
        if let charger = stats.charger {
            out.append("")
            out.append("Charger: " + [charger.name, charger.watts.map { "\($0) W" }].compactMap { $0 }.joined(separator: " · "))
            if !charger.options.isEmpty { out.append("  Offers: " + charger.options.map { "\(Format.volts($0.millivolts)) \(Format.amps($0.milliamps))" + ($0.active ? " (in force)" : "") }.joined(separator: " · ")) }
        }
        return out.joined(separator: "\n")
    }
}
