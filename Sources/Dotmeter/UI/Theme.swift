import AppKit
import SwiftUI

enum Theme {
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let green = Color(nsColor: .systemGreen)
    static let yellow = Color(nsColor: .systemYellow)

    static func color(for severity: Severity) -> Color {
        switch severity {
        case .nominal: return green
        case .elevated: return yellow
        case .high: return orange
        case .critical: return red
        }
    }

    static func nsColor(for severity: Severity) -> NSColor {
        switch severity {
        case .nominal: return .systemGreen
        case .elevated: return .systemYellow
        case .high: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
