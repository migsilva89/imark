import AppKit

/// The document as text, for the half of the app that writes.
///
/// Ported from Loadout, which had already worked out the two things that make a
/// programmatic `NSTextView` behave: the sizing dance without which the buffer
/// draws nothing, and a gutter that is a plain sibling view rather than an
/// `NSRulerView`. What changed on the way in is the palette — Loadout is dark
/// only and names its colours; Imark has a light face and six themes, so
/// everything here comes from the system's semantic colours and the app's accent,
/// and follows the window when the system switches.
final class MarkdownEditorView: NSView {
    /// Called on every keystroke, so the window can find out it has something
    /// unsaved without asking.
    var onEdit: (() -> Void)?
    /// ⌘S from inside the text view, which owns the keyboard while it has focus.
    var onSave: (() -> Void)?

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let gutter = LineGutter()
    private var boundsObserver: NSObjectProtocol?

    /// The file as it was read. What the gutter's bars are measured against, and
    /// what tells "unsaved" from "saved".
    private var diskText = ""

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    var text: String { textView.string }
    var isDirty: Bool { textView.string != diskText }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 10, height: 12)
        // A document is not prose the system should be correcting: a smart quote
        // in Markdown is a smart quote in the file, and an em dash where somebody
        // typed two hyphens is an edit nobody asked for.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        gutter.textView = textView
        gutter.translatesAutoresizingMaskIntoConstraints = false

        addSubview(gutter)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 46),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The gutter draws the slice of the document that is on screen, so it has
        // to be repainted by scrolling as well as by typing.
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in self?.gutter.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    /// Puts a file in the editor. `text` is both the buffer and the copy on disk:
    /// a freshly opened document has nothing unsaved in it.
    func load(_ text: String) {
        textView.string = text
        diskText = text
        textView.undoManager?.removeAllActions()
        refresh()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
    }

    /// After a save: the buffer has not changed, but the file has caught up with
    /// it, so the bars in the gutter go away.
    func markSaved() {
        diskText = textView.string
        refresh()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// The system's own find bar, from ⌘F — the text view owns it, and the menu
    /// item has no reference to the text view.
    func showFind() {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    /// Re-highlights and repaints. Cheap enough per keystroke at the size Imark
    /// already caps documents to.
    private func refresh() {
        MarkdownHighlighter.apply(to: textView)
        gutter.modifiedLines = Self.modifiedLines(current: textView.string, original: diskText)
        gutter.needsDisplay = true
    }

    /// Which lines differ from the file on disk. A real diff, not a positional
    /// compare: one inserted line would otherwise flag everything below it and
    /// drown the signal the bars exist to give.
    static func modifiedLines(current: String, original: String) -> Set<Int> {
        let now = current.components(separatedBy: "\n")
        let disk = original.components(separatedBy: "\n")
        var changed: Set<Int> = []
        for case let .insert(offset, _, _) in now.difference(from: disk) {
            changed.insert(offset + 1)
        }
        return changed
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The attributes hold resolved colours, so a light/dark switch has to be
        // painted again rather than left to the system.
        refresh()
    }

    /// ⌘S while the caret is in the buffer. The menu carries it too, but a text
    /// view that has focus swallows key equivalents it recognises first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension MarkdownEditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        refresh()
        onEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // The caret's own line number draws brighter than the rest.
        gutter.needsDisplay = true
    }
}

// MARK: - Highlighting

/// Markdown in colour, applied as attributes so the same buffer stays editable.
///
/// Every colour is a semantic one or the app's accent, which is what makes this
/// work on a light face as well as a dark one: the six themes only ever paint the
/// rendered page, and the editor is text on the system's own background.
enum MarkdownHighlighter {
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let full = NSRange(location: 0, length: source.length)
        let heading = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)

        storage.beginEditing()
        storage.setAttributes([
            .font: MarkdownEditorView.font,
            .foregroundColor: NSColor.textColor,
        ], range: full)

        var inFrontMatter = false
        var closedFrontMatter = false
        var inFence = false
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            defer { location = NSMaxRange(lineRange) }

            // Front matter: only at the very top, and only until it closes.
            if line == "---", !inFence, !closedFrontMatter {
                if !inFrontMatter, lineRange.location == 0 {
                    inFrontMatter = true
                } else if inFrontMatter {
                    inFrontMatter = false
                    closedFrontMatter = true
                }
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.06), range: lineRange)
                continue
            }
            if inFrontMatter {
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.06), range: lineRange)
                if let colon = line.range(of: #"^[\w-]+:"#, options: .regularExpression) {
                    let keyLength = line.distance(from: line.startIndex, to: colon.upperBound) - 1
                    storage.addAttribute(
                        .foregroundColor, value: NSColor.imarkAccent,
                        range: NSRange(location: lineRange.location, length: keyLength)
                    )
                    storage.addAttribute(
                        .foregroundColor, value: NSColor.secondaryLabelColor,
                        range: NSRange(
                            location: lineRange.location + keyLength + 1,
                            length: max(0, lineRange.length - keyLength - 1)
                        )
                    )
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                continue
            }
            if inFence {
                storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: lineRange)
                continue
            }
            // A comment block is a note somebody wrote in the app. Dimmed as a
            // whole, because it is not the document — and it is still editable,
            // because in the editor the file is the file.
            if Comments.isNote(line) || line.trimmingCharacters(in: .whitespaces) == "-->" {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                continue
            }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                storage.addAttribute(
                    .foregroundColor, value: NSColor.tertiaryLabelColor,
                    range: NSRange(location: lineRange.location, length: min(hashes + 1, lineRange.length))
                )
                let rest = NSRange(
                    location: lineRange.location + hashes + 1,
                    length: max(0, lineRange.length - hashes - 1)
                )
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: rest)
                storage.addAttribute(.font, value: heading, range: rest)
                continue
            }
            // List and quote markers, so the shape of a document is readable
            // down the left edge without reading the words.
            if let marker = line.range(of: #"^\s*([-*+>]|\d+\.)\s"#, options: .regularExpression) {
                let length = line.distance(from: line.startIndex, to: marker.upperBound)
                storage.addAttribute(
                    .foregroundColor, value: NSColor.imarkAccent,
                    range: NSRange(location: lineRange.location, length: min(length, lineRange.length))
                )
            }

            // Inline code, chip and backticks together.
            let lineText = source.substring(with: lineRange) as NSString
            var search = 0
            while true {
                let open = lineText.range(of: "`", range: NSRange(location: search, length: lineText.length - search))
                guard open.location != NSNotFound, open.location + 1 < lineText.length else { break }
                let after = open.location + 1
                let close = lineText.range(of: "`", range: NSRange(location: after, length: lineText.length - after))
                guard close.location != NSNotFound else { break }
                let span = NSRange(
                    location: lineRange.location + open.location,
                    length: close.location - open.location + 1
                )
                storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: span)
                storage.addAttribute(
                    .backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.10), range: span
                )
                search = close.location + 1
            }
        }
        storage.endEditing()
    }
}

// MARK: - Gutter

/// Line numbers, and a bar on every line that differs from the file on disk.
///
/// A plain view beside the scroll view rather than an `NSRulerView`: the ruler
/// draws under the text view's own inset and has to be fought for its width, and
/// this needs neither.
final class LineGutter: NSView {
    weak var textView: NSTextView?
    var modifiedLines: Set<Int> = []

    override var isFlipped: Bool { true }

    /// The 1-based line the caret sits on, which draws brighter than the rest.
    private var caretLine: Int {
        guard let textView else { return 0 }
        let source = textView.string as NSString
        let upToCaret = source.substring(to: min(textView.selectedRange().location, source.length))
        return upToCaret.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
    }

    override func draw(_ rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
        else { return }

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        let source = textView.string as NSString
        // View coordinates to container coordinates: without taking the inset off,
        // the visible slice is computed one inset lower than what the eye sees.
        var visible = textView.visibleRect
        visible.origin.y -= textView.textContainerInset.height
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // Counted from the start of the line holding the first visible character:
        // when the top of the viewport lands part-way through a wrapped line,
        // counting to the raw location includes that partial line and every
        // number comes out one too high.
        let firstLineStart = source.lineRange(for: NSRange(location: chars.location, length: 0)).location
        var number = 1
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: firstLineStart),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in number += 1 }

        let current = caretLine
        var location = firstLineStart
        while location < NSMaxRange(chars) {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            lineRect.origin.y += textView.textContainerInset.height
            // Both views are flipped, so the y converts one to one.
            let y = convert(NSPoint(x: 0, y: lineRect.minY), from: textView).y

            if modifiedLines.contains(number) {
                NSColor.imarkAccent.setFill()
                NSRect(x: 0, y: y + 2, width: 2, height: lineRect.height - 4).fill()
            }

            let label = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: number == current ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.width - size.width - 9, y: y + (lineRect.height - size.height) / 2),
                withAttributes: attributes
            )

            number += 1
            location = NSMaxRange(lineRange)
        }
    }
}
