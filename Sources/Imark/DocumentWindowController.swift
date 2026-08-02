import AppKit
import ImarkRender

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL
    var onClose: (() -> Void)?

    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let content = ContentViewController()
    private var sidebarItem: NSSplitViewItem!

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

        case .ready, .rendered, .find:
            break
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
