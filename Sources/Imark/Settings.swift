import AppKit

/// Everything the app remembers between launches. Deliberately tiny — no
/// database, no config file, just defaults.
enum Settings {
    private static let store = UserDefaults.standard

    /// Fired whenever anything here changes. Before this, changing the text size
    /// or the column width only reached the window you were in — invisible while
    /// documents were one window each, and obvious the moment tabs arrived.
    static let changed = Notification.Name("ImarkSettingsChanged")

    private static func announce() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

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

        var symbol: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        /// What the one toolbar button moves to. Three states on one button
        /// means the order has to be the obvious one, and it is the order they
        /// are written in.
        var next: Theme {
            let all = Theme.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    /// A document palette, in both of its faces. One list rather than a light
    /// slot and a dark slot: picking a theme should be one decision, and a theme
    /// that only exists on one side of the system switch is half a theme.
    ///
    /// The colours live in the stylesheet as `[data-theme='…']` blocks, which is
    /// where every other colour in the document already lives. Adding a theme is
    /// two blocks of CSS and a case here, and nothing else.
    enum Palette: String, CaseIterable {
        case classic, warm, cool, forest, contrast

        var label: String {
            switch self {
            case .classic: return "Classic"
            case .warm: return "Warm"
            case .cool: return "Cool"
            case .forest: return "Forest"
            case .contrast: return "High Contrast"
            }
        }

        /// The name the page answers to. The chrome is AppKit and only knows
        /// aqua and darkAqua, so the system switch still decides which face
        /// shows — the palette only decides what each face looks like.
        func face(dark: Bool) -> String { "\(rawValue)-\(dark ? "dark" : "light")" }
    }

    /// Where "Search the web" goes. It is a URL with the phrase in it, so the
    /// list costs nothing and the app stops having an opinion about somebody
    /// else's searching.
    enum SearchEngine: String, CaseIterable {
        case google, duckduckgo, bing, kagi

        var label: String {
            switch self {
            case .google: return "Google"
            case .duckduckgo: return "DuckDuckGo"
            case .bing: return "Bing"
            case .kagi: return "Kagi"
            }
        }

        func url(searching phrase: String) -> URL? {
            let query = phrase.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            switch self {
            case .google: return URL(string: "https://www.google.com/search?q=\(query)")
            case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(query)")
            case .bing: return URL(string: "https://www.bing.com/search?q=\(query)")
            case .kagi: return URL(string: "https://kagi.com/search?q=\(query)")
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
        set {
            store.set(newValue.clamped(to: textScaleRange), forKey: "textScale")
            announce()
        }
    }

    static var width: Width {
        get { Width(rawValue: store.string(forKey: "width") ?? "") ?? .normal }
        set { store.set(newValue.rawValue, forKey: "width"); announce() }
    }

    static var theme: Theme {
        get { Theme(rawValue: store.string(forKey: "theme") ?? "") ?? .system }
        set { store.set(newValue.rawValue, forKey: "theme"); announce() }
    }

    /// The palette, in both faces. A Mac going dark at sunset still takes the
    /// app with it: the system switch decides *when*, this decides *what*.
    static var palette: Palette {
        get { Palette(rawValue: store.string(forKey: "palette") ?? "") ?? .classic }
        set { store.set(newValue.rawValue, forKey: "palette"); announce() }
    }

    /// The name that signs your notes. It used to be `NSFullUserName()` with no
    /// way round it — the one value this app writes into somebody else's file,
    /// and the one thing there was no way to correct.
    static var authorName: String {
        get {
            let stored = store.string(forKey: "authorName") ?? ""
            return stored.isEmpty ? NSFullUserName() : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Emptied on purpose means "use the account name again", not "sign
            // nothing" — a note with no author reads as anonymous rather than
            // as yours.
            store.set(trimmed, forKey: "authorName")
            announce()
        }
    }

    static var noteColour: NoteColour {
        get { NoteColour(attribute: store.string(forKey: "noteColour")) }
        set { store.set(newValue.attribute, forKey: "noteColour"); announce() }
    }

    /// Off by default. The menu bar is the most contested strip of space on the
    /// machine, and a document reader has no standing claim to it.
    static var showInMenuBar: Bool {
        get { store.bool(forKey: "showInMenuBar") }
        set { store.set(newValue, forKey: "showInMenuBar"); announce() }
    }

    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: store.string(forKey: "searchEngine") ?? "") ?? .google }
        set { store.set(newValue.rawValue, forKey: "searchEngine"); announce() }
    }

    /// Path of the last editor used from "Open in", so the toolbar button can
    /// go straight there instead of guessing every time.
    static var preferredEditor: URL? {
        get { store.string(forKey: "preferredEditor").map(URL.init(fileURLWithPath:)) }
        set { store.set(newValue?.path, forKey: "preferredEditor"); announce() }
    }

    static var sidebarCollapsed: Bool {
        get { store.bool(forKey: "sidebarCollapsed") }
        set { store.set(newValue, forKey: "sidebarCollapsed") }
    }

    static func applyThemeToApp() {
        NSApp.appearance = theme.appearance
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
