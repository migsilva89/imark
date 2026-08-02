import AppKit

/// An optional icon in the system menu bar, off by default.
///
/// Off by default because the menu bar is the most contested strip of space on
/// the machine and a document reader has no standing claim to it. What it earns
/// its place with is the recent list: opening the file you had yesterday
/// without first finding the app that had it.
@MainActor
final class MenuBarItem {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?

    private init() {}

    /// Called at launch and on every settings change, so the icon appears and
    /// disappears with the switch rather than at the next launch.
    func sync() {
        Settings.showInMenuBar ? install() : remove()
    }

    private func install() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Imark")
        // Template, so it inverts with the menu bar instead of staying dark on
        // a dark bar.
        status.button?.image?.isTemplate = true
        status.menu = buildMenu()
        item = status
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// Rebuilt each time it opens: the recent list changes underneath it, and a
    /// menu that lies about what you opened last is worse than no menu.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = Rebuilder.shared
        return menu
    }

    fileprivate static func fill(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = menu.addItem(
            withTitle: "Open…",
            action: #selector(AppDelegate.openDocument(_:)),
            keyEquivalent: ""
        )
        open.target = NSApp.delegate

        let recents = NSDocumentController.shared.recentDocumentURLs
            .map { $0.standardizedFileURL }
            .filter { MarkdownType.matches($0) && FileManager.default.fileExists(atPath: $0.path) }
            .prefix(8)

        if !recents.isEmpty {
            menu.addItem(.separator())
            let header = menu.addItem(withTitle: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            for url in recents {
                let entry = menu.addItem(
                    withTitle: url.deletingPathExtension().lastPathComponent,
                    action: #selector(Rebuilder.openRecent(_:)),
                    keyEquivalent: ""
                )
                entry.representedObject = url
                entry.target = Rebuilder.shared
                entry.toolTip = url.path
            }
        }

        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ""
        )
        settings.target = NSApp.delegate

        let quit = menu.addItem(
            withTitle: "Quit Imark",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quit.target = NSApp
    }
}

/// Split out because a menu delegate has to be an NSObject, and because the
/// recent entries need somewhere to send their action.
private final class Rebuilder: NSObject, NSMenuDelegate {
    static let shared = Rebuilder()

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { MenuBarItem.fill(menu) }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.open(url)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
