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
        // Written straight away, and said a moment later. An agent could be
        // reading the skill at any time, so the files are not left stale while a
        // timer runs; the sentence about it can wait for the window.
        refreshAgentFiles()
        // Well after launch: an update dialog that beats the document to the
        // screen makes the update feel more important than the reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Updates.checkQuietly()
        }
    }

    // MARK: - Agent files

    /// The agent files are copies that live in other programs' folders, and a
    /// copy goes stale. Imark does not install itself, so the first launch of a
    /// new version is the first moment new code runs and the only place the
    /// refresh can happen. See AgentSetup.refresh for what it will and will not
    /// overwrite.
    private func refreshAgentFiles() {
        guard Settings.agentFilesVersion != Updates.current else { return }
        // Nothing of ours out there to bring forward. Left unrecorded on
        // purpose, so the day somebody does set up, the next launch checks.
        guard AgentSetup.hasInstalledFiles else { return }
        guard let report = try? AgentSetup.refresh() else { return }
        Settings.agentFilesVersion = Updates.current
        // Copies replaced by newer copies of the same thing is the whole point
        // of the refresh, and nobody asked for a dialog about it. The one case
        // worth a sentence is a file left alone, because that one leaves the
        // person with something only they can decide.
        guard !report.kept.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.reportKeptAgentFiles(report)
        }
    }

    /// The files somebody edited themselves, said once: their copy stays, and it
    /// is now a version behind the app that reads it. Not phrased as a failure —
    /// nothing failed, and keeping their work was the right thing to do — but
    /// they are the only ones who can decide what to do about the difference.
    private func reportKeptAgentFiles(_ report: AgentSetup.Refresh) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func list(_ files: [URL]) -> String {
            files
                .map { $0.path.replacingOccurrences(of: home, with: "~") }
                .joined(separator: "\n")
        }

        // One file or several changes every clause in these sentences, so both
        // are written out whole rather than stitched together from fragments.
        // Stitched, the singular came out as "These has changes of your own in
        // it", which is what reading it on screen showed.
        let one = report.kept.count == 1
        var lines = [
            one
                ? "Imark \(Updates.current) has newer instructions for your coding agents. This "
                    + "file has changes of your own in it, so Imark left it exactly as it was:"
                : "Imark \(Updates.current) has newer instructions for your coding agents. These "
                    + "files have changes of your own in them, so Imark left them exactly as "
                    + "they were:",
            "",
            list(report.kept),
            "",
            one
                ? "Your agent goes on reading your version, so it is following the older "
                    + "instructions. Imark's own copy is inside the app, in "
                    + "Contents/Resources/agent, if you want to bring your changes across."
                : "Your agent goes on reading your versions, so it is following the older "
                    + "instructions. Imark's own copies are inside the app, in "
                    + "Contents/Resources/agent, if you want to bring your changes across.",
        ]
        if !report.updated.isEmpty {
            lines += [
                "",
                report.updated.count == 1
                    ? "The other file was still Imark's own, untouched, so it was brought up to date."
                    : "The other files were still Imark's own, untouched, so they were brought "
                        + "up to date.",
            ]
        }

        let alert = NSAlert()
        alert.messageText = report.kept.count == 1
            ? "One agent file was left as you had it"
            : "\(report.kept.count) agent files were left as you had them"
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
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

    /// ⌘Q does not go through `windowShouldClose`, so without this a window with
    /// unsaved text in the editor was thrown away silently — the one path out of
    /// the app that never asked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers {
            controller.window?.makeKeyAndOrderFront(nil)
            guard controller.mayLeaveDocument() else { return .terminateCancel }
        }
        return .terminateNow
    }

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
    /// something that is already done is just noise. Same for the command,
    /// which says where it went the first time and has nothing to add after.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(makeDefaultHandler(_:)) {
            return !MarkdownType.imarkIsDefault
        }
        if item.action == #selector(installCommandLineTool(_:)) {
            return !CommandLineTool.isInstalled
        }
        return true
    }

    /// Puts `imark` on the PATH, after saying exactly which file it is about to
    /// write and where. It writes outside Imark's own container, which is
    /// something to ask about rather than announce afterwards.
    @objc func installCommandLineTool(_ sender: Any?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = CommandLineTool.destination.path
        let shown = target.replacingOccurrences(of: home, with: "~")
        let directory = CommandLineTool.destination.deletingLastPathComponent().path
            .replacingOccurrences(of: home, with: "~")

        let alert = NSAlert()
        alert.messageText = "Install the imark command?"
        alert.informativeText = [
            "This links:",
            "",
            shown,
            "",
            "`imark notes.md` then opens a document in the copy of Imark you are "
                + "already running, and brings it forward if it is open. Deleting "
                + "that one link undoes it.",
            CommandLineTool.mayNeedPathSetup
                ? "\nIf your terminal cannot find it, add \(directory) to PATH "
                    + "and open a new terminal."
                : "",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try CommandLineTool.install()
            let done = NSAlert()
            done.messageText = "The imark command is installed."
            done.informativeText = CommandLineTool.mayNeedPathSetup
                ? "Try `imark notes.md` in a terminal. If it cannot find the command, "
                    + "add \(directory) to PATH and open a new terminal."
                : "Try `imark notes.md` in a terminal."
            done.runModal()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Imark couldn't install the command."
            failure.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            failure.runModal()
        }
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
