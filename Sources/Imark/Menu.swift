import AppKit

/// SwiftPM executables get no menu bar for free, so the whole thing is built
/// here. Shortcuts mirror the table in docs/DESIGN.md.
enum Menu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = appMenu()

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        fileItem.submenu = fileMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        editItem.submenu = editMenu()

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        viewItem.submenu = viewMenu()

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let help = NSMenu(title: NSLocalizedString("Help", comment: ""))
        help.addItem(
            withTitle: NSLocalizedString("Keyboard Shortcuts", comment: ""),
            action: #selector(AppDelegate.showShortcuts(_:)),
            keyEquivalent: "/"
        )
        help.addItem(.separator())
        help.addItem(
            withTitle: NSLocalizedString("Buy Me a Coffee…", comment: ""),
            action: #selector(AppDelegate.buyCoffee(_:)),
            keyEquivalent: ""
        )
        helpItem.submenu = help

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: NSLocalizedString("Window", comment: ""))
        window.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: NSLocalizedString("Zoom", comment: ""), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Imark")
        menu.addItem(withTitle: NSLocalizedString("About Imark", comment: ""), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = menu.addItem(
            withTitle: NSLocalizedString("Check for Updates…", comment: ""),
            action: #selector(AppDelegate.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = NSApp.delegate
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: NSLocalizedString("Settings…", comment: ""),
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = NSApp.delegate
        menu.addItem(.separator())
        let makeDefault = menu.addItem(
            withTitle: NSLocalizedString("Make Imark the Default for .md", comment: ""),
            action: #selector(AppDelegate.makeDefaultHandler(_:)),
            keyEquivalent: ""
        )
        makeDefault.target = NSApp.delegate
        let commandLine = menu.addItem(
            withTitle: NSLocalizedString("Install the imark Command…", comment: ""),
            action: #selector(AppDelegate.installCommandLineTool(_:)),
            keyEquivalent: ""
        )
        commandLine.target = NSApp.delegate
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: NSLocalizedString("Hide Imark", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: NSLocalizedString("Quit Imark", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("File", comment: ""))
        menu.addItem(withTitle: NSLocalizedString("Open…", comment: ""), action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Close", comment: ""), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(
            withTitle: NSLocalizedString("Save", comment: ""),
            action: #selector(DocumentWindowController.saveDocument(_:)),
            keyEquivalent: "s"
        )
        menu.addItem(
            withTitle: NSLocalizedString("Revert to Saved", comment: ""),
            action: #selector(DocumentWindowController.revertDocument(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let reveal = menu.addItem(withTitle: NSLocalizedString("Reveal in Finder", comment: ""), action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        // ⌥⌘C because it is the Finder's own key for "Copy as Pathname", so the
        // hand that already knows it there does not have to learn another here.
        let copyPath = menu.addItem(withTitle: NSLocalizedString("Copy Path", comment: ""), action: #selector(DocumentWindowController.copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: NSLocalizedString("Print…", comment: ""), action: #selector(DocumentWindowController.printDocument(_:)), keyEquivalent: "p")
        menu.addItem(
            withTitle: NSLocalizedString("Export Comments as Text…", comment: ""),
            action: #selector(DocumentWindowController.exportComments(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        menu.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: #selector(DocumentWindowController.undoComment(_:)), keyEquivalent: "z")
        let redo = menu.addItem(
            withTitle: NSLocalizedString("Redo", comment: ""),
            action: #selector(DocumentWindowController.redoTyping(_:)),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        // Cut and Paste arrived with the editor: in a reader there was nothing to
        // cut, and ⌘V did nothing at all until the file could be typed in.
        menu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        // A tick rather than two titles: editing is a state the window is in,
        // and the same key puts it back.
        menu.addItem(
            withTitle: NSLocalizedString("Editing Mode", comment: ""),
            action: #selector(DocumentWindowController.toggleEditMode(_:)),
            keyEquivalent: "e"
        )
        menu.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Find…", comment: ""), action: #selector(DocumentWindowController.performFind(_:)), keyEquivalent: "f")
        let next = menu.addItem(withTitle: NSLocalizedString("Find Next", comment: ""), action: #selector(DocumentWindowController.findNext(_:)), keyEquivalent: "g")
        next.keyEquivalentModifierMask = [.command]
        let previous = menu.addItem(withTitle: NSLocalizedString("Find Previous", comment: ""), action: #selector(DocumentWindowController.findPrevious(_:)), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("View", comment: ""))
        menu.addItem(withTitle: NSLocalizedString("Toggle Sidebar", comment: ""), action: #selector(DocumentWindowController.toggleSidebar(_:)), keyEquivalent: "\\")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Bigger Text", comment: ""), action: #selector(DocumentWindowController.increaseText(_:)), keyEquivalent: "+")
        menu.addItem(withTitle: NSLocalizedString("Smaller Text", comment: ""), action: #selector(DocumentWindowController.decreaseText(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: NSLocalizedString("Actual Size", comment: ""), action: #selector(DocumentWindowController.resetText(_:)), keyEquivalent: "0")

        // The column width used to live only inside the toolbar's AA menu, which
        // means it went with it. The menu bar is where macOS expects every
        // command to be findable, and it is what ⌘/ reads to build its list.
        let widths = NSMenu(title: NSLocalizedString("Column Width", comment: ""))
        for width in Settings.Width.allCases {
            let item = widths.addItem(
                withTitle: width.label,
                action: #selector(DocumentWindowController.chooseWidth(_:)),
                keyEquivalent: ""
            )
            item.representedObject = width.rawValue
        }
        menu.addItem(withTitle: NSLocalizedString("Column Width", comment: ""), action: nil, keyEquivalent: "").submenu = widths

        // A tick rather than a title that flips between "Show" and "Hide": the
        // front matter is a thing the document either shows or does not, and a
        // checked item says which without having to be read twice.
        menu.addItem(
            withTitle: NSLocalizedString("Show Front Matter", comment: ""),
            action: #selector(DocumentWindowController.toggleFrontMatter(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(
            withTitle: NSLocalizedString("Back", comment: ""),
            action: #selector(DocumentWindowController.goBackInHistory(_:)),
            keyEquivalent: "["
        )
        menu.addItem(
            withTitle: NSLocalizedString("Forward", comment: ""),
            action: #selector(DocumentWindowController.goForwardInHistory(_:)),
            keyEquivalent: "]"
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Reload", comment: ""), action: #selector(DocumentWindowController.reloadDocument(_:)), keyEquivalent: "r")
        menu.addItem(.separator())

        let allComments = menu.addItem(
            withTitle: NSLocalizedString("Show All Comments", comment: ""),
            action: #selector(DocumentWindowController.toggleAllComments(_:)),
            keyEquivalent: "c"
        )
        allComments.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: NSLocalizedString("Next Comment", comment: ""),
            action: #selector(DocumentWindowController.nextComment(_:)),
            keyEquivalent: "'"
        )
        let previousComment = menu.addItem(
            withTitle: NSLocalizedString("Previous Comment", comment: ""),
            action: #selector(DocumentWindowController.previousComment(_:)),
            keyEquivalent: "'"
        )
        previousComment.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }
}
