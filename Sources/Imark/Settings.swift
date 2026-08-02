import AppKit

/// Everything the app remembers between launches. Deliberately tiny — no
/// database, no config file, just defaults.
enum Settings {
    private static let store = UserDefaults.standard

    enum Theme: String, CaseIterable {
        case system, light, dark

        var label: String {
            switch self {
            case .system: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    enum Width: String, CaseIterable {
        case narrow, normal, wide, full

        var label: String {
            switch self {
            case .narrow: return "Narrow"
            case .normal: return "Normal"
            case .wide: return "Wide"
            case .full: return "Full width"
            }
        }
    }

    static let textScaleRange = 12.0...24.0
    static let defaultTextScale = 16.0

    static var textScale: Double {
        get {
            let stored = store.double(forKey: "textScale")
            return stored == 0 ? defaultTextScale : stored
        }
        set { store.set(newValue.clamped(to: textScaleRange), forKey: "textScale") }
    }

    static var width: Width {
        get { Width(rawValue: store.string(forKey: "width") ?? "") ?? .normal }
        set { store.set(newValue.rawValue, forKey: "width") }
    }

    static var theme: Theme {
        get { Theme(rawValue: store.string(forKey: "theme") ?? "") ?? .system }
        set { store.set(newValue.rawValue, forKey: "theme") }
    }

    /// Path of the last editor used from "Open in", so the toolbar button can
    /// go straight there instead of guessing every time.
    static var preferredEditor: URL? {
        get { store.string(forKey: "preferredEditor").map(URL.init(fileURLWithPath:)) }
        set { store.set(newValue?.path, forKey: "preferredEditor") }
    }

    static var sidebarCollapsed: Bool {
        get { store.bool(forKey: "sidebarCollapsed") }
        set { store.set(newValue, forKey: "sidebarCollapsed") }
    }

    static func applyThemeToApp() {
        NSApp.appearance = theme.appearance
    }
}

extension NSColor {
    /// The violet from the design tokens. It exists twice — here and as
    /// `--accent` in the stylesheet — because the document is a web view and
    /// the chrome around it is AppKit. docs/DESIGN.md holds the table both
    /// copies answer to.
    static let imarkAccent = NSColor(name: "imarkAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.545, green: 0.482, blue: 0.910, alpha: 1)   // #8b7be8
            : NSColor(srgbRed: 0.478, green: 0.420, blue: 0.847, alpha: 1)   // #7a6bd8
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
