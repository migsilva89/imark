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
             .commentFile, .comments, .theme, .find, .export, .openIn]
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

    func refreshThemeButton() {
        let item = window?.toolbar?.items.first { $0.itemIdentifier == .theme }
        (item?.view as? ThemeButton)?.show(Settings.theme)
    }

    /// Greyed out on a document with nothing to show. A button that only ever
    /// beeps is worse than one that admits there is nothing behind it.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .comments ? noteCount > 0 : true
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
            return reviewButton(identifier, title: "Request Changes",
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
            button.title = filled ? "Approved" : "Changes Requested"
        }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = title
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
            alert.messageText = "Request changes with no notes?"
            alert.informativeText = "You haven't commented on anything. "
                + "The agent will be told to revise without being told what to change."
            alert.addButton(withTitle: "Request Changes Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            return finishReview(.requestChanges)
        }
        finishReview(.requestChanges)
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
