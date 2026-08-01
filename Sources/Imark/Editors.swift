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

    static func open(_ file: URL, with editor: URL) {
        NSWorkspace.shared.open(
            [file],
            withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
