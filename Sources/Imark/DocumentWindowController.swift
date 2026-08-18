import AppKit
import ImarkRender

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL
    var onClose: (() -> Void)?

    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    let content = ContentViewController()
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
    private var undoStack = UndoStack()
    /// Set while the composer is editing a note rather than writing a new one.
    private var editingNote: ClosedRange<Int>?
    /// Whether the window is showing the file as text instead of as a page. A
    /// window opens reading, always: this is not remembered between documents or
    /// launches, because reading is what the app is for.
    private(set) var editMode = false
    private let commentsList = CommentsList()
    private let askPanel = AskPanel()
    private var notes: [NoteSummary] = []
    private(set) var noteCount = 0
    /// Set while the composer is open for a note about the document rather than
    /// about anything in it. There is no selection behind such a note, so the
    /// save path has nothing else to tell them apart by.
    /// Reachable from Support/test-undo.swift, which drives a whole comment
    /// through this controller rather than through the popover and the WebView.
    /// A file note is the one kind that needs no selection, which makes it the
    /// cheapest way to put a real change on the undo stack from a test.
    var composingFileNote = false
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
        // The document runs the full height of the window and slides under the
        // toolbar, which carries its own blur. A solid strip cuts a reading
        // window in two; a blurred one says there is more page up there.
        window.titlebarAppearsTransparent = true
        // Obeys "prefer tabs when opening documents", which is somebody's
        // stated preference and not ours to override. It only governs windows
        // the system groups on its own: ⌘-clicking a file in the sidebar asks
        // for its tab outright, and that still works at every setting. What
        // this gives up is Finder double-clicks tabbing for people who left
        // the preference on its default of full screen only.
        window.tabbingMode = .automatic
        // Every document window joins the same group. Without an identifier
        // macOS groups by class name, which happens to work here and would stop
        // working the moment a second kind of window wanted tabs.
        window.tabbingIdentifier = "ImarkDocument"

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

        // A popover belongs to the document under it. Switching tabs hides the
        // window but leaves the popover floating over whatever is now on top,
        // still editing a note in a file you can no longer see. Occlusion is
        // the right signal: a popover taking key status does not change it,
        // while a tab going to the back does.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        // Settings belong to the app, not to a window. Applying them where they
        // were changed left every other open document on the old value until it
        // happened to re-render.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: Settings.changed,
            object: nil
        )

        buildToolbar()

        content.onMessage = { [weak self] in self?.handle($0) }
        content.editor.onEdit = { [weak self] in self?.editorChanged() }
        content.editor.onSave = { [weak self] in self?.saveDocument(nil) }
        content.onFindClosed = { [weak self] in
            self?.window?.makeFirstResponder(self?.content.renderer)
        }
        selectionPopover.onSaveComment = { [weak self] body, colour in
            self?.saveComment(body, colour: colour)
        }
        content.onShowComments = { [weak self] anchor in
            guard let self else { return }
            self.commentsList.show(self.notes, from: anchor)
        }
        commentsList.onSelect = { [weak self] index in
            self?.content.renderer.revealNote(index)
        }

        sidebar.onSelectHeading = { [weak self] id in self?.content.renderer.scrollTo(anchor: id) }
        sidebar.onSelectFile = { [weak self] url in self?.show(url, pushingHistory: true) }
        sidebar.onOpenFileInTab = { [weak self] url in
            guard let window = self?.window else { return }
            (NSApp.delegate as? AppDelegate)?.open(url, asTabIn: window)
        }

        applySettings()
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

    func show(_ target: URL, pushingHistory: Bool) {
        // Another document in the same window means this one is being put down.
        guard mayLeaveDocument() else { return }
        // It goes down reading: an editor left open on a file you are no longer
        // looking at is a buffer waiting to be written over the wrong thing. The
        // question about unsaved text was asked on the line above, so this only
        // has to put the mode back.
        if editMode {
            editMode = false
            applyEditMode()
        }
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
                // Following the file is the reason this app exists, and also the
                // one thing that could erase what somebody typed. With unsaved text
                // in the editor it stands still and says so in the status bar; the
                // save will refuse on its own when it comes.
                guard !self.content.editor.isDirty else {
                    return self.content.flashChangedOnDisk()
                }
                self.load()
                self.content.flashReloaded()
            case .vanished:
                self.showVanished()
            }
        }
    }

    private func load() {
        // Asked again from disk: a different document, or the same one after an
        // edit, may have stopped being a review — and the toolbar is built from
        // the answer.
        Review.forget()
        buildToolbar()
        // The toolbar is rebuilt on every load, which resets the pencil to its
        // off face while the window is still in editing mode.
        refreshEditButton()

        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            content.renderer.render(
                markdown: "# Can't read this file\n\n`\(url.path)`\n\nIt exists, but it isn't UTF-8 text.",
                path: url.path
            )
            return
        }
        var text = source

        if text.utf8.count > Self.sizeLimit {
            let prefix = String(decoding: Array(text.utf8.prefix(Self.sizeLimit)), as: UTF8.self)
            text = prefix + "\n\n---\n\n> **Truncated.** Above 5 MB Imark shows only the beginning."
        }

        stamp = Comments.Stamp(of: url)
        // The editor follows the file as well, and gets the file itself rather than
        // the copy truncated above for rendering. Without this the buffer kept the
        // text from whenever editing began while `stamp` moved on with the reload,
        // so the next save passed the staleness check and wrote a stale document
        // over somebody else's edit.
        //
        // Only when there is nothing unsaved: the caller checked that before
        // reloading at all, and this is the second lock on the same door.
        if editMode, !content.editor.isDirty { content.editor.load(source) }
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
            // No text means the `+` in the margin, not a selection. Straight to
            // writing: Translate and Search need words, and offering them over
            // a whole paragraph would be three choices where there is one.
            if found.text.isEmpty {
                selectionPopover.compose(
                    existing: "", colour: Settings.noteColour,
                    at: found.rect, in: content.renderer
                )
            } else {
                selectionPopover.show(text: found.text, at: found.rect, in: content.renderer)
            }

        case .selectionCleared:
            selection = nil
            selectionPopover.dismiss()

        case .noteCommand(let command):
            perform(command)

        case .comments(let found, let reviewing):
            notes = found
            noteCount = found.count
            reviewingComments = reviewing
            content.setStatus(comments: found.count)
            // The renderer is the one that knows whether review mode survived
            // this render, and switching documents changes whether there is
            // anything to review at all.
            refreshCommentsButton()
            if found.isEmpty { commentsList.dismiss() }

        case .ready, .rendered, .find:
            break
        }
    }

    /// Starts a note about the document rather than about anything in it.
    func beginFileNote() {
        selection = nil
        editingNote = nil
        composingFileNote = true
        content.renderer.clearSelection()
        let view = content.renderer
        // A thin strip across the top of the page: there is nothing to point at,
        // and a popover in the middle of the text would look like it belonged to
        // whatever it happened to cover.
        let rect = NSRect(x: view.bounds.midX - 40, y: view.bounds.maxY - 12, width: 80, height: 1)
        selectionPopover.compose(existing: "", colour: Settings.noteColour, at: rect, in: view)
    }

    /// Writes the note into the file, immediately after the block the selection
    /// came from. This is the first thing Imark does that changes a document, so
    /// it goes through an atomic replace and refuses to write over a file that
    /// moved underneath it.
    func saveComment(_ body: String, colour: NoteColour) {
        if let range = editingNote {
            return updateComment(body, colour: colour, at: range)
        }
        let fileNote = composingFileNote
        composingFileNote = false
        guard fileNote || selection?.block != nil else {
            selectionPopover.reportCommentFailure("Couldn't tell where that selection came from")
            return
        }
        do {
            snapshot("Comment")
            let index = try Comments.insert(
                quote: fileNote ? "" : (selection?.text ?? ""),
                body: body,
                colour: colour,
                after: selection?.block?.end ?? 0,
                occurrence: selection?.occurrence ?? 1,
                by: Settings.authorName,
                on: Date(),
                scope: fileNote ? .file : .block,
                into: url,
                expecting: stamp
            )
            lastWrite = Date()
            sealSnapshot()
            selectionPopover.dismiss()
            content.renderer.clearSelection()
            load()
            // After the re-render, not before: the note does not exist in the
            // DOM until the document has been rebuilt from the new file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.content.renderer.revealNote(index)
            }
        } catch {
            undoStack.discardLast()
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
            selectionPopover.compose(
                existing: command.text,
                colour: NoteColour(attribute: command.colour),
                at: command.rect,
                in: content.renderer
            )

        case .delete:
            do {
                snapshot("Delete Comment")
                try Comments.remove(lines: command.lines, from: url, expecting: stamp)
                finishWrite()
            } catch {
                undoStack.discardLast()
                report(error, doing: "delete that comment")
            }
        }
    }

    private func updateComment(_ body: String, colour: NoteColour, at range: ClosedRange<Int>) {
        editingNote = nil
        do {
            snapshot("Edit Comment")
            try Comments.update(lines: range, body: body, colour: colour, in: url, expecting: stamp)
            selectionPopover.dismiss()
            finishWrite()
        } catch {
            undoStack.discardLast()
            selectionPopover.reportCommentFailure(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't save the comment"
            )
        }
    }

    // MARK: - Editing the document

    /// ⌘E, and the menu item that carries the tick.
    @objc func toggleEditMode(_ sender: Any?) {
        setEditMode(!editMode)
    }

    /// The switch in the toolbar: reading on the left, the pencil on the right.
    @objc func chooseMode(_ sender: NSSegmentedControl) {
        setEditMode(sender.selectedSegment == 1)
    }

    /// Entering editing reads the file again — the page may have been rendered
    /// from a copy that is minutes old. Leaving it asks first if there is
    /// anything unsaved, because the way back is a re-render and the buffer would
    /// go with it.
    private func setEditMode(_ on: Bool) {
        // Clicking the segment that is already lit used to re-enter the mode, which
        // re-read the file and loaded it over whatever was typed, without asking.
        guard on != editMode else { return }
        if on {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return report(Comments.Failure.unreadable, doing: "edit this file")
            }
            stamp = Comments.Stamp(of: url)
            content.editor.load(text)
        } else {
            // The same question the window asks on the way out, and the segment
            // has already moved under the pointer — putting it back is what makes
            // staying mean staying.
            guard mayLeaveDocument() else { return refreshEditButton() }
        }

        editMode = on
        selectionPopover.dismiss()
        commentsList.dismiss()
        applyEditMode()
        if !on { load() }
    }

    /// Puts the mode on screen: which of the two views is showing, which row of
    /// buttons is in the toolbar, and the marks that say whether anything is
    /// unsaved. Separate from `setEditMode` because putting the editor down on
    /// the way to another document has to do all of this and none of the asking.
    private func applyEditMode() {
        content.showEditor(editMode)
        // The row changes with the mode: Save and Revert have nothing to do with
        // reading, and Comments has nothing to do with a file open as text.
        buildToolbar()
        refreshEditButton()
        refreshEditedDot()
    }

    /// Called on every keystroke: the only thing it does is keep the window's
    /// close button, the toolbar and the menu telling the same story.
    private func editorChanged() {
        refreshEditedDot()
        refreshSaveButtons()
    }

    /// The system's own mark for a document with unsaved changes — a dot in the
    /// close button. Free, and where people already look for it.
    private func refreshEditedDot() {
        window?.isDocumentEdited = editMode && content.editor.isDirty
    }

    @objc func saveDocument(_ sender: Any?) {
        _ = saveDocument()
    }

    /// Writes the buffer over the file. Returns whether it landed, so the places
    /// that save on the way out can stop when it did not.
    @discardableResult
    private func saveDocument() -> Bool {
        guard editMode, content.editor.isDirty else { return true }
        // Read before snapshotting. The snapshot is what ⌘Z restores, and a file
        // that cannot be read snapshots as an empty string — so a save on a
        // vanished file, followed by ⌘Z, emptied the document.
        guard (try? String(contentsOf: url, encoding: .utf8)) != nil else {
            report(Comments.Failure.fileChanged, doing: "save this file")
            return false
        }
        do {
            snapshot("Edit")
            try Comments.save(content.editor.text, to: url, expecting: stamp)
            content.editor.markSaved()
            lastWrite = Date()
            sealSnapshot()
            stamp = Comments.Stamp(of: url)
            refreshEditedDot()
            refreshSaveButtons()
            return true
        } catch {
            undoStack.discardLast()
            report(error, doing: "save this file")
            return false
        }
    }

    /// Throws the buffer away and reads the file again. Asks first: this is the
    /// one command in the app whose whole job is to lose what you typed.
    @objc func revertDocument(_ sender: Any?) {
        guard editMode, content.editor.isDirty else { return }
        let alert = NSAlert()
        alert.messageText = "Throw away your changes?"
        alert.informativeText = "The file on disk goes back into the editor. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Throw Away")
        alert.addButton(withTitle: "Keep Editing")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return report(Comments.Failure.unreadable, doing: "read this file again")
        }
        stamp = Comments.Stamp(of: url)
        content.editor.load(text)
        refreshEditedDot()
        refreshSaveButtons()
    }

    /// The Ask button, and every entry in its menu. A menu item carries the id of
    /// the assistant it names; the button itself carries none and means "the one
    /// you used last".
    @objc func askAssistant(_ sender: Any?) {
        let chosen = (sender as? NSMenuItem)?.representedObject as? String
        guard let cli = chosen.flatMap(Assistants.cli(id:)) ?? Assistants.preferred else {
            let alert = NSAlert()
            alert.messageText = "No assistant found on this Mac"
            alert.informativeText = "Imark runs a command-line assistant you already have: "
                + Assistants.builtinLabels.joined(separator: ", ")
                + ". It uses whichever login that CLI already has, so there is no key to enter here."
            alert.alertStyle = .informational
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        Settings.preferredAssistant = cli.id
        guard let window else { return }
        askPanel.show(for: url, using: cli, in: window)
    }

    enum UnsavedAnswer { case save, discard, cancel }

    /// One question, asked wherever unsaved text is about to be lost: leaving
    /// editing, opening another document, closing the window.
    func askAboutUnsaved() -> UnsavedAnswer {
        let alert = NSAlert()
        alert.messageText = "Save your changes to \(url.lastPathComponent)?"
        alert.informativeText = "You have edits that are not in the file yet."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Whether it is safe to leave this document behind. Answers the same
    /// question for the window closing, for another file being opened in it, and
    /// for the switch going back to reading.
    /// Throws the buffer away and puts the file back in it, without asking — the
    /// asking already happened. Without this, "Don't Save" left the editor dirty
    /// forever, and the watcher's dirty guard then kept live reload switched off
    /// for the rest of the window's life.
    private func discardBuffer() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        stamp = Comments.Stamp(of: url)
        content.editor.load(text)
        refreshEditedDot()
        refreshSaveButtons()
    }

    func mayLeaveDocument() -> Bool {
        guard editMode, content.editor.isDirty else { return true }
        switch askAboutUnsaved() {
        case .save: return saveDocument()
        case .discard: discardBuffer(); return true
        case .cancel: return false
        }
    }

    private func snapshot(_ what: String) {
        undoStack.push(
            text: (try? String(contentsOf: url, encoding: .utf8)) ?? "",
            what: what,
            url: url,
            stamp: nil
        )
    }

    /// Called once a change has landed: the entry now knows what the file looks
    /// like with the change in it, which is what makes an outside edit
    /// afterwards detectable.
    private func sealSnapshot() {
        undoStack.stampLast(Comments.Stamp(of: url))
    }

    private func finishWrite() {
        lastWrite = Date()
        sealSnapshot()
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
        // While the file is open as text, ⌘Z means the typing. The app's own undo
        // puts whole documents back, which here would throw away everything since
        // the last save and leave the buffer showing text no longer in the file.
        if editMode {
            guard content.editor.canUndo else { return NSSound.beep() }
            return content.editor.undo()
        }
        guard !undoStack.isEmpty else { return NSSound.beep() }
        do {
            // The stack knows which file each snapshot belongs to. This window
            // may well be showing a different one by now.
            try undoStack.undoLast()
            lastWrite = Date()
            load()
        } catch {
            report(error, doing: "undo that")
        }
    }

    /// ⇧⌘Z. Only ever the editor's: a comment that was taken back is written
    /// again from its own card, not from the menu.
    @objc func redoTyping(_ sender: Any?) {
        guard editMode, content.editor.canRedo else { return NSSound.beep() }
        content.editor.redo()
    }

    // MARK: - Actions

    @objc func reloadDocument(_ sender: Any?) { load() }

    @objc func goBack(_ sender: Any?) {
        // Asked before the stacks are touched: `show` can be called off by the
        // unsaved-text question, and an entry taken off for a move that never
        // happened is a step of history nobody can get back to.
        guard mayLeaveDocument() else { return }
        guard let previous = back.popLast() else { return NSSound.beep() }
        forward.append(url)
        show(previous, pushingHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard mayLeaveDocument() else { return }
        guard let next = forward.popLast() else { return NSSound.beep() }
        back.append(url)
        show(next, pushingHistory: false)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
        Settings.sidebarCollapsed = sidebarItem.isCollapsed
    }

    /// Gives the tab bar its + button and ⌘T. Without it macOS shows tabs but
    /// no way to open another one, which reads as a broken tab bar.
    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openDocument(sender)
    }

    /// Whatever is selected goes into the search field. Selecting a phrase and
    /// pressing ⌘F only ever meant one thing, and typing it again was the app
    /// ignoring what you had already told it.
    @objc func performFind(_ sender: Any?) {
        selectionPopover.dismiss()
        // The editor has the system's own find bar, with its match counter and
        // its Replace field. Ours is for the page.
        if editMode { return content.editor.showFind() }
        content.showFind(with: selection?.text)
    }

    @objc func toggleAllComments(_ sender: Any?) {
        guard noteCount > 0 else { return NSSound.beep() }
        reviewingComments.toggle()
        content.renderer.setReviewingComments(reviewingComments)
        refreshCommentsButton()
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
            if editMode {
                item.title = "Undo Typing"
                return content.editor.canUndo
            }
            item.title = undoStack.last.map { "Undo \($0.what)" } ?? "Undo"
            return !undoStack.isEmpty
        case #selector(toggleEditMode(_:)):
            item.state = editMode ? .on : .off
            return true
        case #selector(redoTyping(_:)):
            return editMode && content.editor.canRedo
        case #selector(saveDocument(_:)), #selector(revertDocument(_:)):
            // Both are about text that is not in the file yet, and there is none
            // of that while the window is reading.
            return editMode && content.editor.isDirty
        case #selector(toggleAllComments(_:)):
            item.state = reviewingComments ? .on : .off
            return noteCount > 0
        case #selector(chooseWidth(_:)):
            item.state = (item.representedObject as? String) == Settings.width.rawValue ? .on : .off
            return true
        case #selector(toggleFrontMatter(_:)):
            item.state = Settings.showsFrontMatter ? .on : .off
            return true
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

    /// Shows or hides the card the front matter is drawn in. The document is not
    /// rendered again: the page only stops drawing the card, so the file, its
    /// line numbers and every note anchored in it stay exactly as they were.
    @objc func toggleFrontMatter(_ sender: Any?) {
        Settings.showsFrontMatter.toggle()
    }

    /// System → Light → Dark → System. The button announces the change, every
    /// window hears it, and each one moves its own glyph.
    @objc func cycleTheme(_ sender: Any?) {
        Settings.theme = Settings.theme.next
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

    @objc private func settingsChanged() { applySettings() }

    /// Everything the page takes from the settings, in one place, so a window
    /// opened now and a window opened an hour ago cannot disagree.
    private func applySettings() {
        content.renderer.palettes = (
            light: Settings.palette.face(dark: false),
            dark: Settings.palette.face(dark: true)
        )
        content.renderer.applyTheme()
        content.renderer.setTextScale(Settings.textScale)
        content.renderer.setWidth(Settings.width.rawValue)
        content.renderer.setFrontMatter(Settings.showsFrontMatter)
        refreshThemeButton()
    }

    @objc private func visibilityChanged() {
        guard let window, !window.occlusionState.contains(.visible) else { return }
        selectionPopover.dismiss()
        commentsList.dismiss()
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        watcher = nil
        onClose?()
    }
}
