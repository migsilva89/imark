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
        let help = NSMenu(title: "Help")
        help.addItem(
            withTitle: "Keyboard Shortcuts",
            action: #selector(AppDelegate.showShortcuts(_:)),
            keyEquivalent: "/"
        )
        helpItem.submenu = help

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Imark")
        menu.addItem(withTitle: "About Imark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = NSApp.delegate
        menu.addItem(.separator())
        let makeDefault = menu.addItem(
            withTitle: "Make Imark the Default for .md",
            action: #selector(AppDelegate.makeDefaultHandler(_:)),
            keyEquivalent: ""
        )
        makeDefault.target = NSApp.delegate
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "Hide Imark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Imark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(.separator())
        let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Print…", action: #selector(DocumentWindowController.printDocument(_:)), keyEquivalent: "p")
        menu.addItem(
            withTitle: "Export Comments as Text…",
            action: #selector(DocumentWindowController.exportComments(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(DocumentWindowController.undoComment(_:)), keyEquivalent: "z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find…", action: #selector(DocumentWindowController.performFind(_:)), keyEquivalent: "f")
        let next = menu.addItem(withTitle: "Find Next", action: #selector(DocumentWindowController.findNext(_:)), keyEquivalent: "g")
        next.keyEquivalentModifierMask = [.command]
        let previous = menu.addItem(withTitle: "Find Previous", action: #selector(DocumentWindowController.findPrevious(_:)), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Toggle Sidebar", action: #selector(DocumentWindowController.toggleSidebar(_:)), keyEquivalent: "\\")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bigger Text", action: #selector(DocumentWindowController.increaseText(_:)), keyEquivalent: "+")
        menu.addItem(withTitle: "Smaller Text", action: #selector(DocumentWindowController.decreaseText(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: #selector(DocumentWindowController.resetText(_:)), keyEquivalent: "0")

        // The column width used to live only inside the toolbar's AA menu, which
        // means it went with it. The menu bar is where macOS expects every
        // command to be findable, and it is what ⌘/ reads to build its list.
        let widths = NSMenu(title: "Column Width")
        for width in Settings.Width.allCases {
            let item = widths.addItem(
                withTitle: width.label,
                action: #selector(DocumentWindowController.chooseWidth(_:)),
                keyEquivalent: ""
            )
            item.representedObject = width.rawValue
        }
        menu.addItem(withTitle: "Column Width", action: nil, keyEquivalent: "").submenu = widths

        menu.addItem(.separator())
        menu.addItem(withTitle: "Back", action: #selector(DocumentWindowController.goBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: "Forward", action: #selector(DocumentWindowController.goForward(_:)), keyEquivalent: "]")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload", action: #selector(DocumentWindowController.reloadDocument(_:)), keyEquivalent: "r")
        menu.addItem(.separator())

        let allComments = menu.addItem(
            withTitle: "Show All Comments",
            action: #selector(DocumentWindowController.toggleAllComments(_:)),
            keyEquivalent: "c"
        )
        allComments.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Next Comment",
            action: #selector(DocumentWindowController.nextComment(_:)),
            keyEquivalent: "'"
        )
        let previousComment = menu.addItem(
            withTitle: "Previous Comment",
            action: #selector(DocumentWindowController.previousComment(_:)),
            keyEquivalent: "'"
        )
        previousComment.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }
}
