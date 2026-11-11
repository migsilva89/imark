import AppKit
import ImarkRender

/// The right-hand pane: find bar on top, document in the middle, status bar
/// underneath. Owns the renderer and forwards its messages upward.
final class ContentViewController: NSViewController {
    let renderer = RendererView(frame: .zero)
    /// The same document as text. Built with the pane rather than on demand so
    /// the switch between reading and editing is instant and keeps its scroll.
    /// Also where a file goes that the Live editor cannot write back faithfully.
    let sourceEditor = MarkdownEditorView(frame: .zero)
    /// The document in CodeMirror. Built the first time this window edits in the
    /// Live style, not before: a window that only reads should not cost a second
    /// web content process.
    private(set) var liveEditor: LiveEditorView?
    private var liveIsActive = false
    /// Which style this window is editing in. Taken from the setting each time
    /// editing starts; ⇧⌘E changes it for this window until editing ends.
    private var prefersLive = false
    /// Whether an editor, rather than the page, is on screen.
    private(set) var isEditing = false

    /// Whichever editor holds the document. The window asks this one, and only
    /// this one, whether anything is unsaved.
    var editor: DocumentEditor {
        if liveIsActive, let liveEditor { return liveEditor }
        return sourceEditor
    }

    /// Whether the Live editor is the one holding the document.
    var isLiveActive: Bool { liveIsActive && liveEditor != nil }

    /// Wired once by the window, for both editors — including the one that does
    /// not exist yet.
    var onEditorEdit: (() -> Void)?
    var onEditorSave: (() -> Void)?

    var onMessage: ((RendererMessage) -> Void)?
    /// A link followed from the Live editor.
    var onOpenLink: ((LiveEditorView.Link) -> Void)?
    var onFindClosed: (() -> Void)?
    var onShowComments: ((NSView) -> Void)?

    private let findBar = NSVisualEffectView()
    /// Sits behind the toolbar and blurs whatever scrolls under it. Without it a
    /// transparent titlebar puts buttons straight on top of prose.
    private let header = NSVisualEffectView()
    private var reportedInset: CGFloat = -1
    private let searchField = NSSearchField()
    private let counter = NSTextField(labelWithString: "")
    private let statusLeft = NSTextField(labelWithString: "")
    private let commentsButton = LinkButton(title: "", target: nil, action: nil)
    private let statusRight = NSTextField(labelWithString: "")
    private var findHeight: NSLayoutConstraint!
    private var folder = ""
    private var flashWork: DispatchWorkItem?

    override func loadView() {
        view = NSView()

        buildFindBar()
        let status = buildStatusBar()

        // Back to front: the document runs the full height and everything else
        // sits over it. The header is what makes that readable — it blurs the
        // text passing underneath so the toolbar has something to stand on.
        for subview in [renderer, sourceEditor, header, findBar, status] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        self.status = status

        sourceEditor.isHidden = true
        sourceEditor.onEdit = { [weak self] in self?.onEditorEdit?() }
        sourceEditor.onSave = { [weak self] in self?.onEditorSave?() }

        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .followsWindowActiveState

        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Still below the toolbar rather than behind it: the window title
            // used to sit on top of the search field. Only the document is
            // meant to pass underneath.
            findBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            findHeight,

            renderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderer.topAnchor.constraint(equalTo: view.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])
        pin(sourceEditor)
    }

    private var status: NSView!

    /// The editor starts below the toolbar rather than under it: prose sliding
    /// under a blur reads as more page above, but a line of source disappearing
    /// behind glass just looks like a clipped line.
    private func pin(_ editor: NSView) {
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: status.topAnchor),
        ])
    }

    /// Tells the page how much of its own top the toolbar is standing on. Read
    /// from the safe area rather than hard-coded: the toolbar is a different
    /// height with and without a window title, and taller again in full screen.
    override func viewDidLayout() {
        super.viewDidLayout()
        let inset = view.safeAreaInsets.top
        guard inset != reportedInset else { return }
        reportedInset = inset
        renderer.setTopInset(inset)

        renderer.onMessage = { [weak self] message in
            if case .find(let count, let index) = message {
                self?.updateCounter(count: count, index: index)
            }
            self?.onMessage?(message)
        }
    }

    /// Which is on screen, the page or the editor. Both stay built; only one is
    /// shown, so neither has to be rebuilt to come back.
    func showEditor(_ on: Bool) {
        let findWasInEditor = findsInEditor
        isEditing = on
        sourceEditor.isHidden = !(on && !isLiveActive)
        liveEditor?.isHidden = !(on && isLiveActive)
        renderer.isHidden = on
        retargetFind(wasInEditor: findWasInEditor)
        if on { editor.focus() } else { renderer.focus() }
    }

    // MARK: - Which editor

    /// Editing starts: the style comes from the setting, and the file goes into
    /// whichever editor can hold it.
    func beginEditing(_ text: String) {
        prefersLive = Settings.editorStyle == .live
        loadEditor(text)
    }

    /// A file, freshly read, into the editor for this window's style — unless
    /// that is Live and the file is one Live cannot write back as it found it.
    func loadEditor(_ text: String) {
        place(text, saved: text)
    }

    /// ⇧⌘E. The buffer moves across as it is, unsaved changes and all, and stays
    /// unsaved: the other editor is told what the file holds as well as what the
    /// buffer does. Undo history does not survive the move.
    func switchEditorStyle() {
        guard isEditing else { return }
        guard editor.textIsCurrent else { return NSSound.beep() }
        let text = editor.text
        let saved = editor.savedText
        let wasLive = isLiveActive
        prefersLive = !wasLive
        // Typing Return in the source editor puts a bare `\n` into a CRLF file,
        // so the gate is asked of the buffer, not of the file it came from.
        guard willBeLive(text) != wasLive else {
            prefersLive = wasLive
            return LiveEditorView.isAvailable ? noteMixedBreaks() : NSSound.beep()
        }
        place(text, saved: saved)
        showEditor(true)
    }

    private func willBeLive(_ text: String) -> Bool {
        prefersLive && LiveEditorView.isAvailable && LiveMirror.lineSeparator(of: text) != nil
    }

    private func place(_ text: String, saved: String) {
        let live = willBeLive(text)
        if prefersLive, LiveEditorView.isAvailable, !live { noteMixedBreaks() }
        let findWasInEditor = findsInEditor
        if live, liveEditor == nil { buildLiveEditor() }
        liveIsActive = live
        editor.load(text, saved: saved)
        if isEditing {
            sourceEditor.isHidden = live
            liveEditor?.isHidden = !live
            retargetFind(wasInEditor: findWasInEditor)
        }
    }

    /// The Live editor writes a file back exactly as it read it, and a file
    /// mixing `\r\n` with lone `\n`, or using a bare `\r`, is one it cannot
    /// (docs/LIVE-PREVIEW.md §6). Such a file is edited as source instead, and
    /// this says why the editor is not the one the setting asked for.
    private func noteMixedBreaks() {
        flash(NSLocalizedString("Mixed line endings · editing as source", comment: ""))
    }

    private func buildLiveEditor() {
        let live = LiveEditorView(frame: .zero)
        live.isHidden = true
        live.translatesAutoresizingMaskIntoConstraints = false
        // Under the header, the find bar and the status bar, like the source
        // editor: added on top, it would cover the find bar it is searched from.
        view.addSubview(live, positioned: .below, relativeTo: header)
        pin(live)
        live.onEdit = { [weak self] in self?.onEditorEdit?() }
        live.onSave = { [weak self] in self?.onEditorSave?() }
        live.onShowFind = { [weak self] in self?.showFind() }
        live.onFind = { [weak self] count, index in self?.updateCounter(count: count, index: index) }
        live.onNotice = { [weak self] message in self?.flash(message) }
        live.onOpenLink = { [weak self] link in self?.onOpenLink?(link) }
        liveEditor = live
    }

    /// The settings the preview takes, for the Live editor too.
    func applyEditorSettings() {
        liveEditor?.applySettings()
    }

    func flashNote(_ message: String) { flash(message) }

    // MARK: - Find

    private func buildFindBar() {
        findBar.material = .headerView
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        // A zero-height NSView still draws its subviews, so the search field
        // leaked out over the toolbar before anyone pressed ⌘F.
        findBar.wantsLayer = true
        findBar.layer?.masksToBounds = true
        findBar.isHidden = true

        searchField.placeholderString = NSLocalizedString("Find in document", comment: "")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self

        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right

        let previous = button(symbol: "chevron.up", action: #selector(findPrevious))
        let next = button(symbol: "chevron.down", action: #selector(findNext))
        let done = NSButton(title: NSLocalizedString("Done", comment: ""), target: self, action: #selector(closeFind))
        done.bezelStyle = .rounded
        done.controlSize = .small

        let stack = NSStackView(views: [searchField, counter, previous, next, done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            counter.widthAnchor.constraint(equalToConstant: 74),
        ])
    }

    private func button(symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.imageScaling = .scaleProportionallyDown
        return button
    }

    func showFind(with text: String? = nil) {
        findBar.isHidden = false
        findHeight.constant = 40
        // Newlines would make the field one long unsearchable line; a selection
        // spanning paragraphs is still a reasonable thing to hand over.
        if let text, !text.isEmpty {
            searchField.stringValue = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        view.window?.makeFirstResponder(searchField)
        // Selected, not just filled: if the guess is wrong, typing replaces it
        // instead of appending to it.
        searchField.currentEditor()?.selectAll(nil)
        if !searchField.stringValue.isEmpty {
            runFind(searchField.stringValue)
        }
    }

    @objc func closeFind() {
        findHeight.constant = 0
        findBar.isHidden = true
        clearFind(inEditor: findsInEditor)
        counter.stringValue = ""
        onFindClosed?()
    }

    @objc private func searchChanged() {
        runFind(searchField.stringValue)
    }

    @objc func findNext() { stepFind(1) }

    @objc func findPrevious() { stepFind(-1) }

    /// The find bar searches whatever is on screen. The source editor has the
    /// system's own find bar and never comes through here; the Live editor has
    /// none, so while it is up the bar is its.
    private var findsInEditor: Bool { isEditing && isLiveActive }

    private func runFind(_ query: String) {
        if findsInEditor { liveEditor?.find(query) } else { renderer.find(query) }
    }

    private func stepFind(_ delta: Int) {
        if findsInEditor { liveEditor?.findStep(delta) } else { renderer.findStep(delta) }
    }

    private func clearFind(inEditor: Bool) {
        if inEditor { liveEditor?.findClear() } else { renderer.findClear() }
    }

    /// The view under the find bar changed while it was open. The old one stops
    /// highlighting and the new one is searched for the same words, so the
    /// counter keeps describing what is on screen.
    private func retargetFind(wasInEditor: Bool) {
        guard !findBar.isHidden, wasInEditor != findsInEditor else { return }
        clearFind(inEditor: wasInEditor)
        counter.stringValue = ""
        if !searchField.stringValue.isEmpty { runFind(searchField.stringValue) }
    }

    private func updateCounter(count: Int, index: Int) {
        counter.stringValue = count == 0
            ? (searchField.stringValue.isEmpty ? "" : NSLocalizedString("no results", comment: ""))
            : String(format: NSLocalizedString("%@ of %@", comment: ""), String(describing: index), String(describing: count))
    }

    // MARK: - Status bar

    private func buildStatusBar() -> NSView {
        let bar = NSView()

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for label in [statusLeft, statusRight] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        statusRight.alignment = .right

        // A button rather than part of the label: the count is the way into the
        // list, and something you can click has to look like it.
        commentsButton.isBordered = false
        commentsButton.target = self
        commentsButton.action = #selector(showComments)
        commentsButton.setContentHuggingPriority(.required, for: .horizontal)
        commentsButton.isHidden = true

        let left = NSStackView(views: [statusLeft, commentsButton])
        left.orientation = .horizontal
        left.spacing = 10
        left.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(left)
        bar.addSubview(statusRight)
        bar.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.topAnchor),

            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            statusRight.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            statusRight.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusRight.leadingAnchor.constraint(
                greaterThanOrEqualTo: left.trailingAnchor, constant: 16
            ),
        ])
        return bar
    }

    private var words = 0
    private var minutes = 0
    private var comments = 0

    func setStatus(words: Int, minutes: Int) {
        self.words = words
        self.minutes = minutes
        refreshStatus()
    }

    func setStatus(comments: Int) {
        self.comments = comments
        refreshStatus()
    }

    /// The comment count carries the accent the notes are marked with, so the
    /// status bar says *there is something to read here* at a glance instead of
    /// hiding it in the same grey as the word count.
    private func refreshStatus() {
        let formatted = words.formatted(.number.grouping(.automatic))
        statusLeft.stringValue = String(format: NSLocalizedString("%@ words · %@ min read", comment: ""), String(describing: formatted), String(describing: minutes))

        commentsButton.isHidden = comments == 0
        guard comments > 0 else { return }
        commentsButton.attributedTitle = NSAttributedString(
            string: comments == 1 ? NSLocalizedString("1 comment", comment: "") : String(format: NSLocalizedString("%@ comments", comment: ""), String(describing: comments)),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.imarkAccent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.imarkAccent.withAlphaComponent(0.4),
            ]
        )
        commentsButton.toolTip = NSLocalizedString("Show every comment", comment: "")
    }

    @objc private func showComments() {
        onShowComments?(commentsButton)
    }


    func setStatus(path: URL) {
        folder = path.deletingLastPathComponent()
            .path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        flashWork?.cancel()
        statusRight.stringValue = folder
    }

    /// Confirmation that the file is genuinely being watched. Without it a
    /// silent re-render is indistinguishable from nothing happening.
    func flashReloaded() {
        flash(NSLocalizedString("Updated just now", comment: ""))
    }

    /// The file moved under an editor with unsaved text in it. Nothing was
    /// reloaded — that would have taken the text with it — so this is the only
    /// warning there is until the save refuses.
    func flashChangedOnDisk() {
        flash(NSLocalizedString("Changed on disk · your text is still here", comment: ""))
    }

    private func flash(_ message: String) {
        statusRight.stringValue = message
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusRight.stringValue = self.folder
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

extension ContentViewController: NSSearchFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift is not reported here, so the modifier is read directly.
            NSEvent.modifierFlags.contains(.shift) ? findPrevious() : findNext()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeFind()
            return true
        default:
            return false
        }
    }
}


/// Underlined and in the accent colour, so it reads as a link — and so it has
/// to behave like one under the pointer too. Used by the status bar's comment
/// count and by the Copy under an answer in the Ask panel.
class LinkButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
