import AppKit
import ImarkRender

/// Every note in the document, as a list you can scan without scrolling.
///
/// It answers a different question from the ones already on screen. The rail
/// says *where* the notes are, review mode shows them in place, and stepping
/// takes you through one at a time — all of which need the document. This one
/// lets you read six notes at once and pick.
final class CommentsList {
    /// Fixed, because the rows have to know it. A wrapping label inside a
    /// scroll view with no width cannot work out its height, and the popover
    /// came out a few points tall with everything in it invisible.
    private static let width: CGFloat = 320

    var onSelect: ((Int) -> Void)?

    private let popover = NSPopover()
    private let stack = NSStackView()
    private let target = Target()

    init() {
        popover.behavior = .transient
        target.owner = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        let controller = NSViewController()
        controller.view = scroll
        popover.contentViewController = controller
    }

    func show(_ notes: [NoteSummary], from view: NSView) {
        guard !notes.isEmpty else { return NSSound.beep() }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, note) in notes.enumerated() {
            stack.addArrangedSubview(row(for: note, index: index))
        }

        stack.layoutSubtreeIfNeeded()
        // Tall enough to show four or five without scrolling, capped so a
        // document with forty notes does not produce a popover the height of
        // the screen.
        let height = min(max(stack.fittingSize.height, 60), 420)
        popover.contentSize = NSSize(width: Self.width, height: height)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func dismiss() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: - Rows

    private func row(for note: NoteSummary, index: Int) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        if note.orphan {
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        } else {
            dot.layer?.backgroundColor = NoteColour(attribute: note.colour).colour.cgColor
        }
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        // The quote is what the note is about, so it leads. An orphan says so
        // in its place rather than showing a phrase that is no longer there.
        let heading = NSTextField(labelWithString: note.orphan
            ? "Quote no longer in the document"
            : "“\(note.quote)”")
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = note.orphan ? .tertiaryLabelColor : .labelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.maximumNumberOfLines = 1
        heading.preferredMaxLayoutWidth = Self.width - 46

        let body = NSTextField(wrappingLabelWithString: note.text)
        body.font = .systemFont(ofSize: 11.5)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byTruncatingTail
        body.preferredMaxLayoutWidth = Self.width - 46

        let byline = NSTextField(labelWithString: signature(for: note))
        byline.font = .systemFont(ofSize: 10)
        byline.textColor = .tertiaryLabelColor

        let text = NSStackView(views: [heading, body, byline])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let line = NSStackView(views: [dot, text])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

        let button = RowButton(index: index, target: target, action: #selector(Target.pick(_:)))
        button.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        button.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            line.topAnchor.constraint(equalTo: button.topAnchor),
            line.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        return button
    }

    private func signature(for note: NoteSummary) -> String {
        [note.author, note.when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    fileprivate func pick(_ index: Int) {
        dismiss()
        onSelect?(index)
    }

    private final class Target: NSObject {
        weak var owner: CommentsList?
        @objc func pick(_ sender: RowButton) { owner?.pick(sender.index) }
    }
}

/// A whole row that behaves like a button, with a highlight under the pointer —
/// a list you can click but that never looks clickable is a list nobody clicks.
private final class RowButton: NSControl {
    let index: Int
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    init(index: Int, target: AnyObject, action: Selector) {
        self.index = index
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}
