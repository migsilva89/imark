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

    /// Assistants, listed after the editors. They are here by hand because they
    /// do not claim markdown, so the Launch Services sweep never finds them —
    /// Claude declares `public.data`, which takes anything, and the rest are
    /// listed on the same expectation. An assistant that turns out not to accept
    /// a text file will say so itself, which beats us guessing on its behalf.
    private static let assistants: [(id: String, name: String)] = [
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.openai.chat", "ChatGPT"),
        // The app shipping as ChatGPT.app carries this identifier on at least
        // some installs, so both are listed and whichever exists is found.
        ("com.openai.codex", "ChatGPT"),
        ("ai.perplexity.mac", "Perplexity"),
    ]

    /// The list with no document in hand, for the preferences — which are about
    /// markdown in general rather than about whatever file you have open.
    ///
    /// Asked by content type, not with a stand-in path. A URL that does not
    /// exist comes back with nothing at all: Launch Services does go looking for
    /// the file, and the preferences were quietly showing only the hand-written
    /// list until this was measured.
    static var installed: [Editor] {
        build(handlers: MarkdownType.contentTypes.flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) })
    }

    static func installed(for url: URL) -> [Editor] {
        build(handlers: NSWorkspace.shared.urlsForApplications(toOpen: url))
    }

    private static func build(handlers: [URL]) -> [Editor] {
        var found: [Editor] = []
        var seen = Set<URL>()

        func add(_ name: String, _ app: URL) {
            guard !seen.contains(app), app != Bundle.main.bundleURL else { return }
            seen.insert(app)
            found.append(Editor(name: name, url: app))
        }

        for entry in known + assistants {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id) else { continue }
            add(entry.name, app)
        }

        // Then whatever else claims markdown, minus ourselves — opening in Imark
        // from inside Imark would just bounce the file back here.
        for app in handlers { add(app.deletingPathExtension().lastPathComponent, app) }

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
