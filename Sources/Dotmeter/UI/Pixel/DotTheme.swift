import SwiftUI

/// What colour the dots are lit in.
///
/// "Color" gives every kind of thing its own colour, as the app always has. The others light everything in one
/// colour, in several strengths so the parts of a bar can still be told apart; red stays red in all of them,
/// because it is the one colour that means something is wrong.
enum DotTheme: String, CaseIterable, Identifiable {
    case color, amber, green, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: return "Color"
        case .amber: return "Amber"
        case .green: return "Green"
        case .white: return "White"
        }
    }

    /// One colour for each kind of thing the app draws. The names are the ones the full-colour theme gives them.
    struct Tones: Equatable {
        var blue, green, pink, purple, cyan, yellow, gray, orange, red, lime, teal, indigo: RGB
    }

    /// The colour a one-colour theme is built from. Nil for the full-colour one.
    var base: RGB? {
        switch self {
        case .color: return nil
        case .amber: return RGB(0xFFA826)
        case .green: return RGB(0x3FDC6E)
        case .white: return RGB(0xC2C7CF)
        }
    }

    var tones: Tones {
        guard let base else {
            return Tones(
                blue: RGB(0x4C8FE8), green: RGB(0x4FCB74), pink: RGB(0xE2569C), purple: RGB(0x9268E3), cyan: RGB(0x36C2DA),
                yellow: RGB(0xE9C63F), gray: RGB(0xA8AEB8), orange: RGB(0xE7813A), red: RGB(0xDE4646), lime: RGB(0xA3D34F),
                teal: RGB(0x35C9A5), indigo: RGB(0x6F7DF2)
            )
        }
        // Above zero a tone is lifted toward white, below it sunk toward black.
        func tone(_ lift: Double) -> RGB {
            lift >= 0 ? base.mixed(with: .white, lift) : base.mixed(with: RGB(0x000000), -lift)
        }
        return Tones(
            blue: tone(0), green: tone(0.30), pink: tone(-0.28), purple: tone(-0.44), cyan: tone(0.55),
            yellow: tone(0.16), gray: base.mixed(with: RGB(0x9A9DA3), 0.72), orange: tone(-0.12), red: RGB(0xE5484D), lime: tone(0.42),
            teal: tone(0.22), indigo: tone(-0.36)
        )
    }

    /// The theme in use. Setting it changes the colours everything reads from then on; what is already on screen
    /// is drawn again by whoever follows `AppSettings.theme` (see `followsTheme`).
    /// Debug: DOTMETER_THEME=amber chooses one for a run without saving it.
    static var current: DotTheme = {
        DotTheme(rawValue: ProcessInfo.processInfo.environment["DOTMETER_THEME"] ?? UserDefaults.standard.string(forKey: "theme") ?? "") ?? .color
    }() {
        didSet { PX.tones = current.tones }
    }
}

private struct ThemeFollower: ViewModifier {
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        // Colours are worked out as views and meters are built, so a new theme builds them again.
        content.id(settings.theme)
    }
}

extension View {
    /// Rebuilds this view from nothing when the theme changes. For the roots of the window, the panel and the wall;
    /// not for Settings, where the choice is made and the form should stay where it is.
    func followsTheme() -> some View { modifier(ThemeFollower()) }
}
