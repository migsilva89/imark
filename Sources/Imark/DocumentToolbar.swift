import AppKit

private extension NSToolbarItem.Identifier {
    static let find = NSToolbarItem.Identifier("find")
    static let text = NSToolbarItem.Identifier("text")
    static let export = NSToolbarItem.Identifier("export")
    static let openIn = NSToolbarItem.Identifier("openIn")
    static let theme = NSToolbarItem.Identifier("theme")
    static let comments = NSToolbarItem.Identifier("comments")
    static let shortcuts = NSToolbarItem.Identifier("shortcuts")
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
         // Shortcuts leads its own group, with a gap after it: it is the one
         // button that explains the others, and sitting next to Share made it
         // look like part of exporting.
         .shortcuts, .space,
         .find, .comments, .text, .theme, .export, .openIn]
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

        case .text:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: nil)
            item.label = "Text"
            item.menu = textMenu()
            return item

        case .theme:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = themeControl()
            item.label = "Appearance"
            item.toolTip = "Appearance"
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

        default:
            return nil
        }
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

    private func textMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bigger", action: #selector(increaseText(_:)), keyEquivalent: "+")
        menu.addItem(withTitle: "Smaller", action: #selector(decreaseText(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: #selector(resetText(_:)), keyEquivalent: "0")
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Column width", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for width in Settings.Width.allCases {
            let item = NSMenuItem(title: width.label, action: #selector(chooseWidth(_:)), keyEquivalent: "")
            item.representedObject = width.rawValue
            item.state = Settings.width == width ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    private func editorsMenu() -> NSMenu {
        let menu = NSMenu()
        let editors = Editors.installed(for: url)
        guard !editors.isEmpty else {
            let empty = NSMenuItem(title: "No editors found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for editor in editors {
            let item = NSMenuItem(title: editor.name, action: #selector(openInEditor(_:)), keyEquivalent: "")
            item.representedObject = editor.url
            item.image = icon(for: editor.url)
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func icon(for app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Three-way appearance switch, because a radio list of menu items is a
    /// clumsy way to flip between light and dark.
    private func themeControl() -> NSSegmentedControl {
        let symbols = ["circle.lefthalf.filled", "sun.max", "moon"]
        let control = NSSegmentedControl(
            images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() },
            trackingMode: .selectOne,
            target: self,
            action: #selector(themeChanged(_:))
        )
        control.segmentStyle = .texturedRounded
        for (index, theme) in Settings.Theme.allCases.enumerated() {
            control.setToolTip(theme.label, forSegment: index)
            control.setWidth(34, forSegment: index)
        }
        control.selectedSegment = Settings.Theme.allCases.firstIndex(of: Settings.theme) ?? 0
        return control
    }
}
