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
final class MarkdownEditorView: NSView, DocumentEditor {
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
    var savedText: String { diskText }
    /// Unit by unit. `String !=` treats canonically equivalent text as equal, so
    /// an `é` retyped from `e` + U+0301 as one code point read as nothing unsaved
    /// — ⌘S did nothing and closing the window threw the change away.
    var isDirty: Bool { !(textView.string as NSString).isEqual(to: diskText) }

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

    /// Puts a file in the editor. `saved` is the copy on disk, which is `text`
    /// itself for a freshly opened document and something older for a buffer
    /// handed over from the Live editor with unsaved changes in it.
    func load(_ text: String, saved: String) {
        textView.string = text
        diskText = saved
        textView.undoManager?.removeAllActions()
        refresh()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
    }

    func reload(_ text: String) {
        let place = (top: topLine, caret: caretLine)
        load(text)
        scrollTo(line: place.top, caret: place.caret)
    }

    // MARK: - Lines

    /// The line holding a UTF-16 offset, from zero. Breaks are counted as the
    /// preview and the Live editor count them — `\r\n`, a lone `\r` and `\n` are
    /// one each — and nothing else: `lineRange(for:)` also breaks at U+2028 and
    /// U+0085, which markdown-it and CodeMirror do not, and a Swift `Character`
    /// folds `\r\n` into one that is not a newline.
    static func line(at offset: Int, in source: NSString) -> Int {
        let end = min(max(0, offset), source.length)
        var line = 0
        var i = 0
        while i < end {
            let unit = source.character(at: i)
            if unit == 0x0A {
                line += 1
            } else if unit == 0x0D {
                if i + 1 < source.length, source.character(at: i + 1) == 0x0A {
                    // The `\n` of a `\r\n` is the same break; an offset between
                    // the two is still on the line the `\r` ends.
                    if i + 1 >= end { break }
                    i += 1
                }
                line += 1
            }
            i += 1
        }
        return line
    }

    /// Where a line starts, as a UTF-16 offset; the end of the text past its
    /// last line.
    static func offset(ofLine target: Int, in source: NSString) -> Int {
        guard target > 0 else { return 0 }
        var line = 0
        var i = 0
        while i < source.length {
            let unit = source.character(at: i)
            i += 1
            if unit == 0x0D, i < source.length, source.character(at: i) == 0x0A { i += 1 }
            if unit == 0x0A || unit == 0x0D {
                line += 1
                if line == target { return i }
            }
        }
        return source.length
    }

    var caretLine: Int {
        Self.line(at: textView.selectedRange().location, in: textView.string as NSString)
    }

    var topLine: Int {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        // One point under the top edge, in the container's coordinates.
        let point = NSPoint(x: 0, y: max(0, textView.visibleRect.minY - textView.textContainerInset.height + 1))
        let glyph = layout.glyphIndex(for: point, in: container)
        let index = layout.characterIndexForGlyph(at: glyph)
        return Self.line(at: index, in: textView.string as NSString)
    }

    func scrollTo(line: Int, caret: Int) {
        let source = textView.string as NSString
        textView.setSelectedRange(NSRange(location: Self.offset(ofLine: caret, in: source), length: 0))
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let start = Self.offset(ofLine: line, in: source)
        guard source.length > 0, line > 0 else {
            textView.scroll(.zero)
            gutter.needsDisplay = true
            return
        }
        // Laid out up to the line first: the rect of a line not laid out yet is
        // a guess, and `scrollRangeToVisible` would only bring it into view
        // somewhere, not to the top.
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(source.length, start + 1)))
        let y: CGFloat
        if start >= source.length {
            y = layout.usedRect(for: container).maxY
        } else {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: 0), actualCharacterRange: nil)
            y = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
        }
        // A screen's worth below it laid out too, and the text view as tall as
        // what is laid out: its frame follows the layout manager later, and a
        // scroll before then is clamped to wherever its frame happens to end.
        let visible = textView.visibleRect.height
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: y, width: container.size.width, height: visible), in: container)
        let needed = layout.usedRect(for: container).maxY + 2 * textView.textContainerInset.height
        if textView.frame.height < needed {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: needed))
        }
        // The line's top at the top of the view. The first line keeps the
        // inset above it, which is the `guard` above.
        textView.scroll(NSPoint(x: 0, y: y + textView.textContainerInset.height))
        gutter.needsDisplay = true
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

    /// Typing is undone by the text view's own stack, not by the app's — the app's
    /// undo puts whole documents back, which is not what ⌘Z means while typing.
    var canUndo: Bool { textView.undoManager?.canUndo ?? false }
    var canRedo: Bool { textView.undoManager?.canRedo ?? false }

    func undo() {
        textView.undoManager?.undo()
        refresh()
        onEdit?()
    }

    func redo() {
        textView.undoManager?.redo()
        refresh()
        onEdit?()
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
        // Both of these read the whole buffer, which is fine at the size documents
        // actually are and a stall on a file that is mostly generated. Past the
        // ceiling the text is still editable — it just stops being coloured, which
        // is a cost worth paying to keep typing instant.
        guard textView.string.utf8.count <= Self.highlightLimit else {
            gutter.modifiedLines = []
            gutter.needsDisplay = true
            return
        }
        MarkdownHighlighter.apply(to: textView)
        gutter.modifiedLines = Self.modifiedLines(current: textView.string, original: diskText)
        gutter.needsDisplay = true
    }

    /// Where colouring stops. Half a megabyte of Markdown is about 8,000 lines,
    /// well past anything written by hand.
    private static let highlightLimit = 512 * 1_024

    /// Which lines differ from the file on disk. A real diff, not a positional
    /// compare: one inserted line would otherwise flag everything below it and
    /// drown the signal the bars exist to give.
    static func modifiedLines(current: String, original: String) -> Set<Int> {
        // Opening a file and saving one both land here with the two sides equal,
        // and a diff is the slowest possible way to find that out.
        guard current != original else { return [] }
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
        // Not while hidden: the window asks every view, and with the Live editor
        // on screen this one would save from the mirror ahead of the page.
        if !isHiddenOrHasHiddenAncestor,
           event.modifierFlags.contains(.command),
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
    /// Counted with `lineRange`, the same way the numbers beside it are drawn.
    /// Counting `\n` characters instead looks equivalent and is not: on a file
    /// saved by a Windows editor, Swift reads `\r\n` as one character that is not
    /// a newline, so the caret lit a line further and further off the more line
    /// breaks it had passed.
    private var caretLine: Int {
        guard let textView else { return 0 }
        let source = textView.string as NSString
        return Self.lineNumber(at: textView.selectedRange().location, in: source)
    }

    /// Pulled out of the property so it can be tested on its own: the CRLF case
    /// is the whole reason it is written this way, and it is not reachable through
    /// a text view without one.
    static func lineNumber(at caret: Int, in source: NSString) -> Int {
        let caret = min(max(0, caret), source.length)
        var number = 1
        var location = 0
        while location < caret {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            guard NSMaxRange(line) <= caret, NSMaxRange(line) > location else { break }
            number += 1
            location = NSMaxRange(line)
        }
        return number
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
