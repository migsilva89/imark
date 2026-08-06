import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keyed by nothing on purpose: a window's document changes as you follow
    // links, so identity has to be asked for rather than remembered.
    private var controllers: [DocumentWindowController] = []

    private var welcome: WelcomeWindowController?
    private var cascadePoint = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        Menu.install()
        Settings.applyThemeToApp()
        MenuBarItem.shared.sync()
        NSApp.activate(ignoringOtherApps: true)
        // Launch Services delivers documents just after this callback, so give
        // it a beat before deciding the app was opened empty — otherwise the
        // welcome window flashes on every double-click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showWelcomeIfEmpty()
        }
        // Well after launch: an update dialog that beats the document to the
        // screen makes the update feel more important than the reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Updates.checkQuietly()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) { Updates.checkNow() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcomeIfEmpty() }
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showWelcomeIfEmpty()
        return true
    }

    private func showWelcomeIfEmpty() {
        guard controllers.isEmpty else { return }
        if let welcome {
            welcome.showWindow(nil)
            return
        }
        let controller = WelcomeWindowController()
        controller.onOpen = { [weak self] urls in
            for url in urls { self?.open(url) }
        }
        welcome = controller
        controller.showWindow(nil)
    }

    private func dismissWelcome() {
        welcome?.close()
        welcome = nil
    }

    /// Launch Services hands us documents here — Finder double-click, drag onto
    /// the Dock icon, and `open -a Imark file.md` all land in this method.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Windows

    /// `host` asks for the document to land as a tab beside that window rather
    /// than wherever the window server would have put it. Said outright instead
    /// of left to `tabbingMode`, which answers to a system-wide preference we
    /// do not get to see and should not be second-guessing.
    func open(_ url: URL, asTabIn host: NSWindow? = nil) {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        dismissWelcome()

        // Opening the same file twice brings the existing window forward
        // instead of stacking duplicates (F2).
        if let existing = controllers.first(where: { $0.url == key }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = DocumentWindowController(url: key)
        controller.onClose = { [weak self] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)

        // Added to the group before it is shown: ordering it front first makes
        // it a window for an instant, and it keeps that window's shadow and
        // frame after joining.
        if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)

            // Every document window restores the same autosaved frame, so
            // without this a second document lands exactly on top of the first
            // and looks like nothing happened. A window that joined a tab group
            // has no frame of its own to move, so cascading it would fight the
            // tab bar.
            if controllers.count > 1, let window = controller.window, window.tabGroup == nil {
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
    }

    /// Greys out the menu item once Imark already owns .md — offering to do
    /// something that is already done is just noise.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(makeDefaultHandler(_:)) {
            return !MarkdownType.imarkIsDefault
        }
        return true
    }

    @objc func makeDefaultHandler(_ sender: Any?) {
        MarkdownType.makeImarkDefault { ok in
            let alert = NSAlert()
            alert.messageText = ok
                ? "Imark is now the default for .md"
                : "Couldn't change the default app"
            alert.informativeText = ok
                ? "Double-clicking a markdown file in the Finder opens it here."
                : "Use Get Info on a .md file → Open with → Change All."
            alert.alertStyle = ok ? .informational : .warning
            alert.runModal()
        }
    }

    @objc func showShortcuts(_ sender: Any?) { ShortcutsPanel.toggle() }

    @objc func showSettings(_ sender: Any?) { PreferencesWindowController.show() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MarkdownType.contentTypes
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }
}
