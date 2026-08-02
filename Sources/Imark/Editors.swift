import AppKit

/// Finds the text editors actually installed on this machine, so "Open in…"
/// offers Cursor or VS Code by name instead of whatever Launch Services happens
/// to consider the default handler.
enum Editors {
    struct Editor {
        let name: String
        let url: URL
    }

    /// Ordered by how likely they are to be the one you want. Anything not on
    /// the list still shows up through the Launch Services sweep below.
    private static let known: [(id: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text"),
        ("dev.zed.Zed", "Zed"),
        ("com.panic.Nova", "Nova"),
        ("com.barebones.bbedit", "BBEdit"),
        ("com.macromates.TextMate", "TextMate"),
        ("md.obsidian", "Obsidian"),
        ("abnerworks.Typora", "Typora"),
        ("pro.writer.mac", "iA Writer"),
    ]

    /// The list with no document in hand, for the preferences — which are about
    /// markdown in general rather than about the file you happen to have open.
    /// The path is a stand-in: Launch Services answers on the extension, and
    /// never goes looking for the file.
    static var installed: [Editor] { installed(for: URL(fileURLWithPath: "/Imark.md")) }

    static func installed(for url: URL) -> [Editor] {
        var found: [Editor] = []
        var seen = Set<URL>()

        for entry in known {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id),
                  !seen.contains(app) else { continue }
            seen.insert(app)
            found.append(Editor(name: entry.name, url: app))
        }

        // Then whatever else claims .md, minus ourselves — opening in Imark
        // from inside Imark would just bounce the file back here.
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url)
        where app != Bundle.main.bundleURL && !seen.contains(app) {
            seen.insert(app)
            found.append(Editor(name: app.deletingPathExtension().lastPathComponent, url: app))
        }

        return found
    }

    /// The one the toolbar button goes to: whatever was picked last, as long as
    /// it is still installed; otherwise the highest-ranked one found.
    static func preferred(from editors: [Editor]) -> URL? {
        if let stored = Settings.preferredEditor,
           editors.contains(where: { $0.url == stored }) {
            return stored
        }
        return editors.first?.url
    }

    static func open(_ file: URL, with editor: URL) {
        Settings.preferredEditor = editor
        NSWorkspace.shared.open(
            [file],
            withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
