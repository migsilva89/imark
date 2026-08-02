import AppKit
import ImarkRender

/// The right-hand pane: find bar on top, document in the middle, status bar
/// underneath. Owns the renderer and forwards its messages upward.
final class ContentViewController: NSViewController {
    let renderer = RendererView(frame: .zero)

    var onMessage: ((RendererMessage) -> Void)?
    var onFindClosed: (() -> Void)?

    private let findBar = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let counter = NSTextField(labelWithString: "")
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private var findHeight: NSLayoutConstraint!
    private var folder = ""
    private var flashWork: DispatchWorkItem?

    override func loadView() {
        view = NSView()

        buildFindBar()
        let status = buildStatusBar()

        for subview in [findBar, renderer, status] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Pinned below the toolbar, not behind it: the window title used to
            // sit on top of the search field, and the document text slid under
            // the toolbar whenever the sidebar was toggled.
            findBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            findHeight,

            renderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderer.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            renderer.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])

        renderer.onMessage = { [weak self] message in
            if case .find(let count, let index) = message {
                self?.updateCounter(count: count, index: index)
            }
            self?.onMessage?(message)
        }
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
            bar.addSubview(label)
        }
        statusRight.alignment = .right
        bar.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.topAnchor),

            statusLeft.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            statusLeft.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            statusRight.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            statusRight.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusRight.leadingAnchor.constraint(
                greaterThanOrEqualTo: statusLeft.trailingAnchor, constant: 16
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
        let line = NSMutableAttributedString(
            string: "\(formatted) words · \(minutes) min read",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        if comments > 0 {
            line.append(NSAttributedString(
                string: "  ·  " + (comments == 1 ? "1 comment" : "\(comments) comments"),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.imarkAccent,
                ]
            ))
        }
        statusLeft.attributedStringValue = line
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
