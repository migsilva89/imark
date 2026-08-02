import AppKit
import ImarkRender

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL
    var onClose: (() -> Void)?

    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let content = ContentViewController()
    private var sidebarItem: NSSplitViewItem!

    private let selectionPopover = SelectionPopover()
    private var selection: Selection?
    /// The file as it was when we read it, and the moment we last wrote it
    /// ourselves — one guards against clobbering somebody else's edit, the
    /// other stops our own write from being announced as an outside change.
    private var stamp: Comments.Stamp?
    private var lastWrite = Date.distantPast
    /// A snapshot of the whole document before each change, which is what makes
    /// undo work the same for writing, editing and deleting a note. Documents
    /// are capped at 5 MB and the stack at ten, so this stays small.
    private var undoStack: [(text: String, what: String)] = []
    /// Set while the composer is editing a note rather than writing a new one.
    private var editingNote: ClosedRange<Int>?
    private(set) var noteCount = 0
    private(set) var reviewingComments = false

    private var watcher: FileWatcher?
    private var back: [URL] = []
    private var forward: [URL] = []

    /// Documents past this size would lock the web view up; render a prefix and
    /// say so instead of beachballing.
    private static let sizeLimit = 5 * 1_024 * 1_024

    init(url: URL) {
        self.url = url

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed

        super.init(window: window)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 420
        sidebarItem.preferredThicknessFraction = 0.26
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = Settings.sidebarCollapsed

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))

        // Assigning a content view controller resizes the window to the view's
        // fitting size, which for autolayout-only views is nothing. Restore a
        // real size first, then let the autosaved frame win if there is one.
        window.contentViewController = split
        window.minSize = NSSize(width: 680, height: 420)
        window.setContentSize(NSSize(width: 1_140, height: 800))
        window.center()
        window.setFrameAutosaveName("ImarkDocument")
        window.delegate = self

        buildToolbar()

        content.onMessage = { [weak self] in self?.handle($0) }
        content.onFindClosed = { [weak self] in
            self?.window?.makeFirstResponder(self?.content.renderer)
        }
        selectionPopover.onCopyMarkdown = { [weak self] in self?.copySelectedMarkdown() }
        selectionPopover.onFind = { [weak self] text in self?.content.showFind(with: text) }
        selectionPopover.onSaveComment = { [weak self] body in self?.saveComment(body) }

        sidebar.onSelectHeading = { [weak self] id in self?.content.renderer.scrollTo(anchor: id) }
        sidebar.onSelectFile = { [weak self] url in self?.show(url, pushingHistory: true) }

        content.renderer.setTextScale(Settings.textScale)
        content.renderer.setWidth(Settings.width.rawValue)
        // Left, same as the preview panel: the rail lives inside the web view,
        // which already starts to the right of the sidebar, so it never collides
        // with it — and one consistent position beats one clever one.
        content.renderer.setRail("left")

        show(url, pushingHistory: false)

        // Without this nothing holds focus and the arrow keys do nothing until
        // you click into the document first.
        DispatchQueue.main.async { [weak self] in self?.content.renderer.focus() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Loading

    private func show(_ target: URL, pushingHistory: Bool) {
        if pushingHistory {
            back.append(url)
            forward.removeAll()
        }
        url = target
        window?.title = target.lastPathComponent
        window?.representedURL = target
        content.setStatus(path: target)
        // One document's folded sections should not carry over to the next.
        sidebar.resetOutlineState()
        refreshSiblings()
        load()

        watcher = FileWatcher(url: target) { [weak self] event in
            guard let self else { return }
            switch event {
            case .changed:
                // Our own atomic save trips the watcher; announcing it as an
                // outside change would be a lie and would fight the reload we
                // are already doing.
                guard Date().timeIntervalSince(self.lastWrite) > 1.0 else { return }
                self.load()
                self.content.flashReloaded()
            case .vanished:
                self.showVanished()
            }
        }
    }

    private func load() {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            content.renderer.render(
                markdown: "# Can't read this file\n\n`\(url.path)`\n\nIt exists, but it isn't UTF-8 text.",
                path: url.path
            )
            return
        }

        if text.utf8.count > Self.sizeLimit {
            let prefix = String(decoding: Array(text.utf8.prefix(Self.sizeLimit)), as: UTF8.self)
            text = prefix + "\n\n---\n\n> **Truncated.** Above 5 MB Imark shows only the beginning."
        }

        stamp = Comments.Stamp(of: url)
        content.renderer.render(markdown: text, path: url.path)
    }

    private func showVanished() {
        content.renderer.render(
            markdown: "# This file no longer exists\n\n`\(url.path)`",
            path: url.path
        )
    }

    private func refreshSiblings() {
        let folder = url.deletingLastPathComponent()
        let found = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let markdown = found
            .filter(MarkdownType.matches)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // Recently opened markdown from anywhere, minus what is already listed
        // as a neighbour — the sibling list is only useful inside a doc folder.
        let siblings = Set(markdown)
        let recents = NSDocumentController.shared.recentDocumentURLs
            .map { $0.standardizedFileURL }
            .filter { $0 != url && !siblings.contains($0) && MarkdownType.matches($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(5)

        sidebar.update(files: markdown, current: url, recents: Array(recents))
    }

    // MARK: - Messages

    private func handle(_ message: RendererMessage) {
        switch message {
        case .toc(let entries):
            sidebar.update(toc: entries)

        case .active(let id):
            sidebar.setActive(id)

        case .meta(let words, let minutes):
            content.setStatus(words: words, minutes: minutes)

        case .wikilinks(let targets):
            let dead = targets.filter { LinkRouter.resolveWiki($0, from: url) == nil }
            if !dead.isEmpty { content.renderer.markMissingWikiLinks(dead) }

        case .openExternal(let target):
            NSWorkspace.shared.open(target)

        case .openLocal(let path):
            let target = URL(fileURLWithPath: path)
            if MarkdownType.matches(target), FileManager.default.fileExists(atPath: path) {
                show(target, pushingHistory: true)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }

        case .openWiki(let name):
            if let target = LinkRouter.resolveWiki(name, from: url) {
                show(target, pushingHistory: true)
            } else {
                NSSound.beep()
            }

        case .selection(let found):
            selection = found
            selectionPopover.show(text: found.text, at: found.rect, in: content.renderer)

        case .selectionCleared:
            selection = nil
            selectionPopover.dismiss()

        case .noteCommand(let command):
            perform(command)

        case .comments(let count, let reviewing):
            noteCount = count
            reviewingComments = reviewing
            content.setStatus(comments: count)

        case .ready, .rendered, .find:
            break
        }
    }

    /// Copies the source that produced the selection, not the flattened text —
    /// the whole point of the line map. Falls back to the plain text when the
    /// selection is not inside a block we can locate.
    private func copySelectedMarkdown() {
        guard let selection else { return }
        var copied = selection.text

        if let block = selection.block,
           let source = try? String(contentsOf: url, encoding: .utf8) {
            let lines = source.components(separatedBy: .newlines)
            let start = max(0, block.start)
            let end = min(lines.count, block.end)
            if start < end {
                copied = lines[start..<end].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    /// Writes the note into the file, immediately after the block the selection
    /// came from. This is the first thing Imark does that changes a document, so
    /// it goes through an atomic replace and refuses to write over a file that
    /// moved underneath it.
    private func saveComment(_ body: String) {
        if let range = editingNote {
            return updateComment(body, at: range)
        }
        guard let selection, let block = selection.block else {
            selectionPopover.reportCommentFailure("Couldn't tell where that selection came from")
            return
        }
        do {
            snapshot("Comment")
            let index = try Comments.insert(
                quote: selection.text,
                body: body,
                after: block.end,
                occurrence: selection.occurrence,
                by: NSFullUserName(),
                on: Date(),
                into: url,
                expecting: stamp
            )
            lastWrite = Date()
            selectionPopover.dismiss()
            content.renderer.clearSelection()
            load()
            // After the re-render, not before: the note does not exist in the
            // DOM until the document has been rebuilt from the new file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.content.renderer.revealNote(index)
            }
        } catch {
            undoStack.removeLast()
            selectionPopover.reportCommentFailure(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't save the comment"
            )
        }
    }

    /// Edit and delete, asked for from the note's own card.
    private func perform(_ command: NoteCommand) {
        switch command.kind {
        case .edit:
            editingNote = command.lines
            selectionPopover.quotedText = command.quote
            selectionPopover.compose(existing: command.text, at: command.rect, in: content.renderer)

        case .delete:
            do {
                snapshot("Delete Comment")
                try Comments.remove(lines: command.lines, from: url, expecting: stamp)
                finishWrite()
            } catch {
                undoStack.removeLast()
                report(error, doing: "delete that comment")
            }
        }
    }

    private func updateComment(_ body: String, at range: ClosedRange<Int>) {
        editingNote = nil
        do {
            snapshot("Edit Comment")
            try Comments.update(lines: range, body: body, in: url, expecting: stamp)
            selectionPopover.dismiss()
            finishWrite()
        } catch {
            undoStack.removeLast()
            selectionPopover.reportCommentFailure(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't save the comment"
            )
        }
    }

    private func snapshot(_ what: String) {
        undoStack.append((text: (try? String(contentsOf: url, encoding: .utf8)) ?? "", what: what))
        if undoStack.count > 10 { undoStack.removeFirst() }
    }

    private func finishWrite() {
        lastWrite = Date()
        load()
    }

    private func report(_ error: Error, doing what: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't \(what)"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc func undoComment(_ sender: Any?) {
        guard let last = undoStack.popLast() else { return NSSound.beep() }
        do {
            try Comments.restore(last.text, to: url)
            finishWrite()
        } catch {
            report(error, doing: "undo that")
        }
    }

    // MARK: - Actions

    @objc func reloadDocument(_ sender: Any?) { load() }

    @objc func goBack(_ sender: Any?) {
        guard let previous = back.popLast() else { return NSSound.beep() }
        forward.append(url)
        show(previous, pushingHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forward.popLast() else { return NSSound.beep() }
        back.append(url)
        show(next, pushingHistory: false)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
        Settings.sidebarCollapsed = sidebarItem.isCollapsed
    }

    @objc func performFind(_ sender: Any?) { content.showFind() }

    @objc func toggleAllComments(_ sender: Any?) {
        guard noteCount > 0 else { return NSSound.beep() }
        reviewingComments.toggle()
        content.renderer.setReviewingComments(reviewingComments)
    }

    @objc func nextComment(_ sender: Any?) {
        noteCount > 0 ? content.renderer.stepNote(1) : NSSound.beep()
    }

    @objc func previousComment(_ sender: Any?) {
        noteCount > 0 ? content.renderer.stepNote(-1) : NSSound.beep()
    }

    /// Greys the comment commands out in a document with no notes, and ticks
    /// the toggle when review mode is on.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoComment(_:)):
            // Named after what it will actually put back, so the menu never
            // offers a vague "Undo" that might mean something else.
            item.title = undoStack.last.map { "Undo \($0.what)" } ?? "Undo"
            return !undoStack.isEmpty
        case #selector(toggleAllComments(_:)):
            item.state = reviewingComments ? .on : .off
            return noteCount > 0
        case #selector(nextComment(_:)), #selector(previousComment(_:)),
             #selector(exportComments(_:)):
            return noteCount > 0
        default:
            return true
        }
    }

    @objc func findNext(_ sender: Any?) { content.findNext() }

    @objc func findPrevious(_ sender: Any?) { content.findPrevious() }

    @objc func increaseText(_ sender: Any?) { setTextScale(Settings.textScale + 1) }

    @objc func decreaseText(_ sender: Any?) { setTextScale(Settings.textScale - 1) }

    @objc func resetText(_ sender: Any?) { setTextScale(Settings.defaultTextScale) }

    private func setTextScale(_ value: Double) {
        Settings.textScale = value
        content.renderer.setTextScale(Settings.textScale)
    }

    @objc func chooseWidth(_ sender: NSMenuItem) {
        guard let width = Settings.Width(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.width = width
        content.renderer.setWidth(width.rawValue)
    }

    @objc func themeChanged(_ sender: NSSegmentedControl) {
        let cases = Settings.Theme.allCases
        guard cases.indices.contains(sender.selectedSegment) else { return }
        Settings.theme = cases[sender.selectedSegment]
        Settings.applyThemeToApp()
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window else { return }
        let info = NSPrintInfo.shared
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        content.renderer.printOperation(with: info)
            .runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Writes a copy with the notes turned into blockquotes. A copy, not the
    /// document: HTML comments are the right home for a note between two people
    /// who both use Imark, and useless for a review the other person has to read
    /// on GitHub. Converting in place would trade one for the other.
    @objc func exportComments(_ sender: Any?) {
        guard noteCount > 0 else { return NSSound.beep() }
        content.renderer.exportComments { [weak self] text in
            guard let self, let text, let window = self.window else { return NSSound.beep() }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = self.url.deletingPathExtension().lastPathComponent
                + "-comments." + (self.url.pathExtension.isEmpty ? "md" : self.url.pathExtension)
            panel.directoryURL = self.url.deletingLastPathComponent()
            panel.message = "The comments become blockquotes. Your document is not changed."
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let target = panel.url else { return }
                do {
                    try text.write(to: target, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } catch {
                    self.report(error, doing: "export the comments")
                }
            }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInEditor(_ sender: NSMenuItem) {
        guard let editor = sender.representedObject as? URL else { return NSSound.beep() }
        Editors.open(url, with: editor)
        buildToolbar()   // the button now wears the icon of what you just chose
    }

    @objc func openInPreferredEditor(_ sender: Any?) {
        let editors = Editors.installed(for: url)
        guard let editor = Editors.preferred(from: editors) else { return NSSound.beep() }
        Editors.open(url, with: editor)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        watcher = nil
        onClose?()
    }
}
