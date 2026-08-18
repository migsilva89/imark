import AppKit

private extension NSToolbarItem.Identifier {
    static let find = NSToolbarItem.Identifier("find")
    static let text = NSToolbarItem.Identifier("text")
    static let export = NSToolbarItem.Identifier("export")
    static let openIn = NSToolbarItem.Identifier("openIn")
    static let theme = NSToolbarItem.Identifier("theme")
    static let comments = NSToolbarItem.Identifier("comments")
    static let shortcuts = NSToolbarItem.Identifier("shortcuts")
    static let commentFile = NSToolbarItem.Identifier("commentFile")
    static let editMode = NSToolbarItem.Identifier("editMode")
    static let save = NSToolbarItem.Identifier("save")
    static let revert = NSToolbarItem.Identifier("revert")
    static let ask = NSToolbarItem.Identifier("ask")
    static let reviewSendBack = NSToolbarItem.Identifier("reviewSendBack")
    static let reviewApprove = NSToolbarItem.Identifier("reviewApprove")
}

extension DocumentWindowController: NSToolbarDelegate {
    func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ImarkDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        // The system's own item arrives with a label and no tooltip, so it is the
        // one button in the row that answers nothing when you hover it.
        if let sidebar = toolbar.items.first(where: { $0.itemIdentifier == .toggleSidebar }) {
            sidebar.toolTip = "Show or Hide Sidebar (⌘\\)"
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Actions you take while reading, and the appearance. Two things left:
        // the AA menu, a second copy of View › Bigger/Smaller/Actual Size, which
        // already have ⌘+, ⌘− and ⌘0; and the shortcuts cheat sheet, which is
        // read once or twice ever and was already sitting in Help under ⌘/.
        // Reading the document, then changing how it looks, then taking it
        // somewhere else. Find sits with the appearance rather than leading the
        // row: it is a thing you do to the page in front of you, not a way out
        // of it.
        //
        // A document under review ends the row with the two buttons that finish
        // it. They go last, past the appearance and the way out, because they
        // are the only items here that end something rather than change how you
        // are looking at it — and because a button that closes a loop somebody
        // else is waiting on should not sit next to Find.
        let reading: [NSToolbarItem.Identifier] =
            [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
             .editMode, .commentFile, .comments, .theme, .find, .export, .openIn]

        // Editing keeps the switch and loses everything that is about the page:
        // a theme paints the rendered document, and a comment is written onto a
        // phrase in it. What it gains is the two ways out of a dirty buffer.
        if editMode {
            return [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
                    .editMode, .ask, .find, .revert, .save]
        }
        guard Review.isReview(url) else { return reading }

        // A review keeps only what a reviewer does. Open in and Export are ways
        // of taking a document somewhere else, and this one is a copy that
        // exists to be answered — editing it in Cursor changes nothing anybody
        // will read, and printing it is printing a working file.
        let reviewing = reading.filter { $0 != .export && $0 != .openIn }
        // Once it is decided, only the button that was pressed stays. Hiding the
        // other one leaves its slot behind, and an empty pill in the toolbar
        // looks like something that failed to load.
        if let decision = Review.decision(for: url) {
            return reviewing + [decision == .approve ? .reviewApprove : .reviewSendBack]
        }
        // A gap between them, because the cost of pressing the wrong one is
        // asymmetric: approving by mistake sets work going that nobody checked.
        return reviewing + [.reviewSendBack, .space, .reviewApprove]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Comments is a switch, and a switch has to look switched. A toolbar item
    /// has no on-state of its own, so it says so the way the rest of the system
    /// does: the glyph fills in and takes the accent colour.
    func refreshCommentsButton() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .comments })
        else { return }

        let on = reviewingComments
        let symbol = on ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Comments")
        item.image = on ? image?.withSymbolConfiguration(.init(paletteColors: [.imarkAccent])) : image
        item.toolTip = on ? "Hide All Comments (⇧⌘C)" : "Show All Comments (⇧⌘C)"
    }

    /// Which side of the switch is lit. A tinted glyph says "on" only to somebody
    /// who has seen it off; two segments with one of them lit say which state the
    /// window is in without anything to compare against.
    func refreshEditButton() {
        let item = window?.toolbar?.items.first { $0.itemIdentifier == .editMode }
        (item?.view as? NSSegmentedControl)?.selectedSegment = editMode ? 1 : 0
    }

    func refreshThemeButton() {
        let item = window?.toolbar?.items.first { $0.itemIdentifier == .theme }
        (item?.view as? ThemeButton)?.show(Settings.theme)
    }

    /// Greyed out on a document with nothing to show. A button that only ever
    /// beeps is worse than one that admits there is nothing behind it.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .comments: return noteCount > 0
        // Both are about text that is not in the file yet.
        case .save, .revert: return editMode && content.editor.isDirty
        case .ask: return !Assistants.installed.isEmpty
        default: return true
        }
    }

    /// The toolbar validates on its own schedule, which is a beat behind a
    /// keystroke. Asking it directly is what makes Save light up on the first
    /// character typed rather than a moment later.
    func refreshSaveButtons() {
        window?.toolbar?.validateVisibleItems()
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .find:
            return button(identifier, symbol: "magnifyingglass", label: "Find",
                          tip: "Find in Document (⌘F)",
                          action: #selector(performFind(_:)))

        case .commentFile:
            // Next to Comments, which shows the ones that exist: one names the
            // subject, the other adds to it.
            return button(identifier, symbol: "text.bubble", label: "Comment on Document",
                          tip: "Comment on the whole document",
                          action: #selector(commentOnDocument(_:)))

        case .editMode:
            // First in the row of things you do to the document: it is the only
            // one that changes what the document says.
            //
            // Two segments rather than one pencil that lights up. Reading is
            // where this app lives, so it is a state worth naming on screen
            // instead of being the absence of the other one.
            let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "Reading")!
            let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Editing")!
            let control = NSSegmentedControl(
                images: [eye, pencil],
                trackingMode: .selectOne,
                target: self,
                action: #selector(chooseMode(_:))
            )
            control.segmentStyle = .texturedRounded
            control.selectedSegment = editMode ? 1 : 0
            control.setToolTip("Reading — nothing here changes the file", forSegment: 0)
            control.setToolTip("Editing — click a block to write in it (⇧⌘E)", forSegment: 1)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Mode"
            item.toolTip = "Reading or editing (⇧⌘E)"
            return item

        case .save:
            return button(identifier, symbol: "arrow.down.doc", label: "Save",
                          tip: "Write your changes to the file (⌘S)",
                          action: #selector(saveDocument(_:)))

        case .revert:
            return button(identifier, symbol: "arrow.uturn.backward", label: "Revert",
                          tip: "Throw away your changes and read the file again",
                          action: #selector(revertDocument(_:)))

        case .ask:
            // A split button when there is more than one assistant on the
            // machine: the face runs the one you used last, the chevron picks.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Ask AI")
            item.label = "Ask AI"
            // Spelled out on the button itself, not only in the tooltip. The
            // toolbar is icons everywhere else because everything else is a verb
            // people already know; sparkles alone says nothing about what runs.
            item.title = "Ask AI"
            let installed = Assistants.installed
            item.toolTip = installed.isEmpty
                ? "Install one of \(Assistants.builtinLabels.joined(separator: ", ")) to ask about this document"
                : "Ask an assistant about this document, in a panel that writes nothing"
            item.menu = assistantsMenu()
            item.showsIndicator = installed.count > 1
            if !installed.isEmpty {
                item.target = self
                item.action = #selector(askAssistant(_:))
            }
            return item

        case .comments:
            // "Comments" alone names the subject, not the action, and left
            // people pressing it to find out. The tip says what happens.
            return button(identifier, symbol: "bubble.left.and.bubble.right", label: "Comments",
                          tip: "Show All Comments (⇧⌘C)",
                          action: #selector(toggleAllComments(_:)))

        case .shortcuts:
            // Target left nil so it walks the responder chain to the app
            // delegate: the panel belongs to the app, not to one document.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
            item.label = "Shortcuts"
            item.toolTip = "Keyboard Shortcuts (⌘/)"
            item.action = #selector(AppDelegate.showShortcuts(_:))
            return item

        case .export:
            // The share glyph promises a share sheet and opens the print panel
            // instead. Saying so is the cheap half of the fix; the icon is the
            // other half and belongs with whatever sharing ends up being.
            return button(identifier, symbol: "square.and.arrow.up", label: "Export",
                          tip: "Print or Save as PDF (⌘P)",
                          action: #selector(printDocument(_:)))

        case .theme:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = ThemeButton(target: self, action: #selector(cycleTheme(_:)))
            item.label = "Appearance"
            return item

        case .openIn:
            // A split button: the face opens the editor you used last, the
            // chevron lets you pick another one.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            let editors = Editors.installed(for: url)
            let preferred = Editors.preferred(from: editors)
            item.image = preferred.map(icon(for:))
                ?? NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
            item.label = "Open in"
            item.toolTip = preferred.map { "Open in \($0.lastPathComponent.replacingOccurrences(of: ".app", with: ""))" }
                ?? "Open in editor"
            item.menu = editorsMenu()
            item.showsIndicator = !editors.isEmpty
            if preferred != nil {
                item.target = self
                item.action = #selector(openInPreferredEditor(_:))
            }
            return item

        case .reviewSendBack:
            // The palette's own red, the same one you can paint a note with.
            // Borrowing GitHub's would have put a colour in the window that
            // appears nowhere else in the app.
            // "Send Back", not GitHub's "Request Changes": this is a document,
            // not a diff, and the button is not filing a review — it is handing
            // the document back to whoever wrote it, with your notes on it.
            return reviewButton(identifier, title: "Send Back",
                                symbol: "arrow.uturn.backward",
                                tip: "Send your notes back and hold the work",
                                tint: NoteColour.red.colour,
                                action: #selector(sendReviewBack(_:)))

        case .reviewApprove:
            // The only filled button in the app. It is the one place where a
            // button does something outside this window, and the row would
            // otherwise read as five equal ways of looking at a document.
            return reviewButton(identifier, title: "Approve", symbol: "checkmark",
                                tip: "Approve and let the agent continue",
                                tint: .imarkApprove,
                                action: #selector(approveReview(_:)), filled: true)

        default:
            return nil
        }
    }

    /// One entry per assistant found on the machine, in the order the registry
    /// puts them: the built-ins it recognises first.
    private func assistantsMenu() -> NSMenu {
        let menu = NSMenu()
        for cli in Assistants.installed {
            let item = menu.addItem(
                withTitle: cli.label,
                action: #selector(askAssistant(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = cli.id
            item.toolTip = "Runs \(cli.invocationDescription)"
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No assistant CLI found", action: nil, keyEquivalent: "")
        }
        return menu
    }

    /// Wide enough to carry a word, because these two have to be read rather
    /// than recognised: nobody has seen them before, and getting them the wrong
    /// way round sends work back that was meant to go ahead.
    private func reviewButton(
        _ identifier: NSToolbarItem.Identifier,
        title: String,
        symbol: String,
        tip: String,
        tint: NSColor,
        action: Selector,
        filled: Bool = false
    ) -> NSToolbarItem {
        let button = ReviewButton(title: title, symbol: symbol, filled: filled,
                                  tint: tint, target: self, action: action)

        // Decided already: the pair stops offering a choice that has been made
        // and becomes a record of it, so reopening the file tells you what you
        // said instead of inviting you to say it twice.
        if Review.decision(for: url) != nil {
            button.isEnabled = false
            button.title = filled ? "Approved" : "Sent Back"
        }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = title
        // On the view as well as the item: a view-based toolbar item never shows
        // the item's own tooltip, because the pointer is over the view.
        button.toolTip = tip
        item.toolTip = tip
        return item
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        tip: String? = nil,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = tip ?? label
        item.target = self
        item.action = action
        return item
    }

    private func editorsMenu() -> NSMenu {
        let menu = NSMenu()
        let editors = Editors.installed(for: url)
        if editors.isEmpty {
            let empty = NSMenuItem(title: "No editors found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for editor in editors {
            let item = NSMenuItem(title: editor.name, action: #selector(openInEditor(_:)), keyEquivalent: "")
            item.representedObject = editor.url
            item.image = icon(for: editor.url)
            item.target = self
            menu.addItem(item)
        }

        // Below a rule, because it is the odd one out: every entry above hands
        // the file to something that will show you its contents, and this one
        // shows you where it lives. Same command as ⇧⌘R — this menu is "where
        // else does this file go", and the Finder is an answer to that.
        menu.addItem(.separator())
        let reveal = menu.addItem(
            withTitle: "Reveal in Finder",
            action: #selector(revealInFinder(_:)),
            keyEquivalent: ""
        )
        reveal.image = icon(for: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        reveal.target = self
        return menu
    }

    /// Opens the composer for a note about the document itself. There is no
    /// selection and nothing highlighted, so the popover is anchored to the top
    /// of the page — the note is about all of it.
    @objc func commentOnDocument(_ sender: Any?) {
        beginFileNote()
    }

    // MARK: - Finishing a review

    @objc func approveReview(_ sender: Any?) {
        finishReview(.approve)
    }

    @objc func sendReviewBack(_ sender: Any?) {
        // Sending back an unannotated document tells the agent to try again and
        // nothing about what to change, which is the one outcome nobody wants.
        guard noteCount > 0 else {
            let alert = NSAlert()
            alert.messageText = "Send it back with no notes?"
            alert.informativeText = "You haven't commented on anything. "
                + "The agent will be told to revise without being told what to change."
            alert.addButton(withTitle: "Send Back Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            return finishReview(.requestChanges)
        }
        finishReview(.requestChanges)
    }

    /// Closing the window is not an answer, and somebody is waiting for one.
    ///
    /// A silent close used to leave the agent on the other end blocked on a
    /// window that was no longer on screen — until the wait timed out, four
    /// hours later. So the window asks on the way out, and closing is not one
    /// of the things it offers: you answer, or you go back to reviewing.
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Unsaved text first: it is the one thing here that cannot be got back.
        guard mayLeaveDocument("close this window") else { return false }
        guard Review.isReview(url), Review.decision(for: url) == nil else { return true }

        let alert = NSAlert()
        alert.messageText = "Finish this review?"
        alert.informativeText = "Something is waiting for your answer, and closing "
            + "the window doesn't give it one."
        // First is the default and the one Escape lands on: the safe way out of a
        // dialogue nobody asked for is back to the document.
        alert.addButton(withTitle: "Keep Reviewing")
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Send Back")

        switch alert.runModal() {
        case .alertSecondButtonReturn: finishReview(.approve)
        // Through the button's own action, so sending back with nothing
        // commented still gets the warning it gets from the toolbar.
        case .alertThirdButtonReturn: sendReviewBack(nil)
        default: break
        }
        // Either way this close does not happen: deciding closes the window
        // itself a moment later, once the button has shown what was pressed.
        return false
    }

    private func finishReview(_ decision: Review.Decision) {
        do {
            try Review.decide(decision, notes: noteCount, for: url)
            // The button says what happened before the window goes, so the press
            // is acknowledged rather than just answered by everything vanishing.
            // The state is kept on disk too: reopening the file later shows it.
            buildToolbar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.window?.performClose(nil)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Imark couldn't record that decision."
            alert.runModal()
        }
    }

    private func icon(for app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

}
