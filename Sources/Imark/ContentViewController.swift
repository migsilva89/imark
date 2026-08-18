import AppKit
import ImarkRender

/// The right-hand pane: find bar on top, document in the middle, status bar
/// underneath. Owns the renderer and forwards its messages upward.
final class ContentViewController: NSViewController {
    let renderer = RendererView(frame: .zero)
    /// The same document as text. Built with the pane rather than on demand so
    /// the switch between reading and editing is instant and keeps its scroll.
    let editor = MarkdownEditorView(frame: .zero)

    var onMessage: ((RendererMessage) -> Void)?
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
        for subview in [renderer, editor, header, findBar, status] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        editor.isHidden = true

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

            // The editor starts below the toolbar rather than under it: prose
            // sliding under a blur reads as more page above, but a line of source
            // disappearing behind glass just looks like a clipped line.
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
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

    /// Which of the two is on screen. Both are always built; only one is shown,
    /// so neither has to be rebuilt to come back.
    func showEditor(_ on: Bool) {
        editor.isHidden = !on
        renderer.isHidden = on
        if on { editor.focus() } else { renderer.focus() }
    }

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

        searchField.placeholderString = "Find in document"
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
        let done = NSButton(title: "Done", target: self, action: #selector(closeFind))
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
            renderer.find(searchField.stringValue)
        }
    }

    @objc func closeFind() {
        findHeight.constant = 0
        findBar.isHidden = true
        renderer.findClear()
        counter.stringValue = ""
        onFindClosed?()
    }

    @objc private func searchChanged() {
        renderer.find(searchField.stringValue)
    }

    @objc func findNext() { renderer.findStep(1) }

    @objc func findPrevious() { renderer.findStep(-1) }

    private func updateCounter(count: Int, index: Int) {
        counter.stringValue = count == 0
            ? (searchField.stringValue.isEmpty ? "" : "no results")
            : "\(index) of \(count)"
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
        statusLeft.stringValue = "\(formatted) words · \(minutes) min read"

        commentsButton.isHidden = comments == 0
        guard comments > 0 else { return }
        commentsButton.attributedTitle = NSAttributedString(
            string: comments == 1 ? "1 comment" : "\(comments) comments",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.imarkAccent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.imarkAccent.withAlphaComponent(0.4),
            ]
        )
        commentsButton.toolTip = "Show every comment"
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
        statusRight.stringValue = "Updated just now"
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
final class LinkButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
