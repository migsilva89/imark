import AppKit
import ImarkRender
import NaturalLanguage
import Translation

/// The row of actions that appears over a selection, and the panels it turns
/// into — a comment composer, a translation, a one-line confirmation.
///
/// Built once and reused for all of them: giving the composer a window of its
/// own would mean two widgets to keep in step, and every action needs to show
/// that it happened. An action that succeeds in silence is indistinguishable
/// from a button that does nothing.
final class SelectionPopover {
    var onSaveComment: ((String, NoteColour) -> Void)?

    private let popover = NSPopover()
    private let target = Target()
    private var text = ""

    private let container = NSView()
    private lazy var actionsView = buildActions()
    private let composer = NSTextView()
    private let message = NSTextField(labelWithString: "")

    /// Where the selection is, so the composer can open over the note it edits.
    private weak var host: NSView?
    private var hostRect = NSRect.zero
    /// What the note being edited is anchored to, for the header of the composer.
    var quotedText = ""
    private var picked = NoteColour.standard
    private var swatches: [Swatch] = []

    init() {
        popover.behavior = .transient
        popover.animates = false   // it tracks a selection; easing reads as lag

        target.owner = self

        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        show(panel: actionsView)
    }

    // MARK: - Presenting

    func show(text: String, at rect: NSRect, in view: NSView) {
        // Never replace a composer that has something typed in it: a stray
        // selection change would throw away a half-written note.
        if isComposing { return }
        self.text = text
        host = view
        hostRect = rect

        guard !text.isEmpty else { return dismiss() }
        guard let anchor = anchor(for: rect, in: view) else { return dismiss() }

        if !popover.isShown { show(panel: actionsView) }
        if popover.isShown {
            popover.positioningRect = anchor
        } else {
            popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        }
    }

    /// A positioning rect outside the view's bounds is silently refused by
    /// AppKit — which is why selecting something and scrolling it off screen
    /// used to produce no popover at all. Clamp to what is visible, and give up
    /// only when none of the selection is.
    private func anchor(for rect: NSRect, in view: NSView) -> NSRect? {
        let clamped = rect.insetBy(dx: 0, dy: -2).intersection(view.bounds)
        guard !clamped.isNull, clamped.height > 1 else { return nil }
        return clamped
    }

    func dismiss() {
        if popover.isShown { popover.performClose(nil) }
        isComposing = false
        popover.behavior = .transient
        show(panel: actionsView)
    }

    private var isComposing = false

    private func show(panel: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        popover.contentSize = panel.fittingSize
    }

    /// Says what happened, then gets out of the way. An action that succeeds in
    /// silence is indistinguishable from a button that does nothing.
    private func confirm(_ note: String, then close: Bool = true) {
        message.stringValue = note
        message.font = .systemFont(ofSize: 13)
        message.alignment = .center
        let panel = NSView()
        panel.addSubview(message)
        message.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            message.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            message.topAnchor.constraint(equalTo: panel.topAnchor, constant: 9),
            message.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -9),
        ])
        show(panel: panel)

        guard close else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, !self.isComposing else { return }
            self.dismiss()
        }
    }

    // MARK: - Actions

    private func buildActions() -> NSView {
        // Three, not seven. Copying and finding are already ⌘C and ⌘F, looking
        // a word up is ⌃⌘D in every app on the system, and reading aloud was a
        // button nobody was going to press. What is left is what only exists
        // here or is genuinely faster from a selection.
        let actions: [(symbol: String, tip: String, action: Selector)] = [
            ("bubble.left", "Comment", #selector(Target.comment)),
            ("character.book.closed", "Translate", #selector(Target.translate)),
            ("globe", "Search the web", #selector(Target.searchWeb)),
        ]

        let buttons = actions.map { spec -> NSButton in
            let image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.tip)
            let button = NSButton(image: image ?? NSImage(), target: target, action: spec.action)
            // Borderless buttons in a popover give no sign at all that they were
            // pressed. A recessed button lights up on hover and on click, which
            // is the difference between "broken" and "working".
            button.bezelStyle = .recessed
            button.isBordered = true
            button.showsBorderOnlyWhileMouseInside = true
            button.toolTip = spec.tip
            button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return button
        }

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        return stack
    }

    /// The buttons target a small forwarding object rather than the popover
    /// itself, so the button targets hold nothing strongly. One per popover —
    /// a shared one would mean two document windows fighting over it.
    fileprivate final class Target: NSObject {
        weak var owner: SelectionPopover?

        @objc func comment() {
            owner?.beginComposing()
        }
        @objc func translate() {
            owner?.translateSelection()
        }
        @objc func searchWeb() {
            owner?.search()
        }
        @objc func saveComment() { owner?.commitComment() }
        @objc func cancelComment() { owner?.dismiss() }
        @objc func pickColour(_ sender: Swatch) { owner?.pick(sender.colour) }

    }

    // MARK: - Translate and search

    /// There is no "Translate" system service — the probe that found this had
    /// the button beeping into the void. The Translation framework does the work
    /// on device, and the result goes in the popover rather than another window.
    private func translateSelection() {
        guard #available(macOS 26.0, *) else {
            return confirm("Translation needs macOS 26 or later")
        }
        let source = text
        confirm("Translating…", then: false)

        Task { @MainActor in
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(source)
            guard let detected = recognizer.dominantLanguage else {
                return confirm("Couldn't tell what language that is")
            }
            do {
                let session = TranslationSession(
                    installedSource: Locale.Language(identifier: detected.rawValue),
                    target: nil
                )
                let response = try await session.translate(source)
                showTranslation(response.targetText)
            } catch {
                // Almost always a language pair that has not been downloaded;
                // saying so beats a generic failure nobody can act on.
                confirm("No offline translation for \(detected.rawValue). Add the language in System Settings › Translation.")
            }
        }
    }

    private func showTranslation(_ translated: String) {
        let label = NSTextField(wrappingLabelWithString: translated)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 260

        let head = NSTextField(labelWithString: "Translation")
        head.font = .systemFont(ofSize: 11, weight: .semibold)
        head.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [head, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        show(panel: stack)
    }

    /// Opens a plain search URL rather than going through the system's search
    /// service. The service hands the query to Safari whatever your default
    /// browser is; a URL goes to whichever browser actually handles http.
    private func search() {
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://duckduckgo.com/?q=\(query)") {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }

    // MARK: - Composing a comment

    /// Opens the composer over an existing note rather than over a selection,
    /// so editing happens where the note is.
    func compose(existing text: String, colour: NoteColour, at rect: NSRect, in view: NSView) {
        picked = colour
        host = view
        hostRect = rect
        self.text = ""
        guard let anchor = anchor(for: rect.insetBy(dx: -60, dy: -8), in: view) else { return }
        if !popover.isShown {
            popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        } else {
            popover.positioningRect = anchor
        }
        beginComposing(prefill: text)
    }

    private func beginComposing(prefill: String = "") {
        isComposing = true
        // A new note starts on the default; an edit keeps whatever it already
        // was, which `compose(existing:colour:…)` has already put in `picked`.
        if prefill.isEmpty { picked = .standard }
        // A click elsewhere must not silently bin what is being typed.
        popover.behavior = .applicationDefined

        let subject = prefill.isEmpty ? text : quotedText
        let quoted = NSTextField(labelWithString: "“\(subject.prefix(80))\(subject.count > 80 ? "…" : "")”")
        quoted.font = .systemFont(ofSize: 11)
        quoted.textColor = .secondaryLabelColor
        quoted.lineBreakMode = .byTruncatingTail
        quoted.preferredMaxLayoutWidth = 280

        composer.string = prefill
        composer.delegate = target
        composer.font = .systemFont(ofSize: 13)
        composer.isRichText = false
        composer.isEditable = true
        composer.textContainerInset = NSSize(width: 4, height: 5)
        composer.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = composer
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 290).isActive = true

        let hint = NSTextField(labelWithString: "↵ save · ⇧↵ line · esc")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        swatches = NoteColour.allCases.map {
            Swatch($0, target: target, action: #selector(Target.pickColour(_:)))
        }
        for swatch in swatches { swatch.isPicked = swatch.colour == picked }

        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let palette = NSStackView(views: swatches + [gap, hint])
        palette.orientation = .horizontal
        palette.spacing = 1
        palette.alignment = .centerY

        // Deliberately not the default button: a Return key equivalent is
        // consumed by the window before the text view ever sees it, and a
        // composer where Return saves instead of starting a line is useless.
        let save = NSButton(title: prefill.isEmpty ? "Comment" : "Save",
                            target: target, action: #selector(Target.saveComment))
        save.bezelStyle = .rounded
        save.controlSize = .small

        let cancel = NSButton(title: "Cancel", target: target, action: #selector(Target.cancelComment))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [quoted, scroll, palette, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        show(panel: stack)

        // A popover only takes key status once it is on screen, and a composer
        // you have to click into before typing is a composer that looks broken.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.container.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.composer)
            // Editing starts with the cursor at the end, not with the note
            // selected — the first keystroke should not wipe it.
            self.composer.setSelectedRange(NSRange(location: self.composer.string.count, length: 0))
        }
    }

    fileprivate func pick(_ colour: NoteColour) {
        picked = colour
        for swatch in swatches { swatch.isPicked = swatch.colour == colour }
    }

    private func commitComment() {
        let body = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return NSSound.beep() }
        isComposing = false
        popover.behavior = .transient
        onSaveComment?(body, picked)
    }

    /// Called by the window controller when the write failed, so the note is
    /// not lost along with the popover.
    func reportCommentFailure(_ reason: String) {
        isComposing = true
        confirm(reason, then: false)
    }

}

// MARK: - Composer keys

extension SelectionPopover.Target: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return saves. A note is usually one sentence, and having to reach
            // for ⌘↵ to finish one was the thing that felt wrong.
            saveComment()
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            // ⇧↵ is how you get a second line when you want one.
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            cancelComment()
            return true
        default:
            return false
        }
    }
}

