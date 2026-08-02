import AppKit
import AVFoundation
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
    var onCopyMarkdown: (() -> Void)?
    var onFind: ((String) -> Void)?
    var onSaveComment: ((String) -> Void)?

    private let popover = NSPopover()
    private let speech = AVSpeechSynthesizer()
    private let target = Target()
    private var text = ""

    private let container = NSView()
    private lazy var actionsView = buildActions()
    private let composer = NSTextView()
    private let message = NSTextField(labelWithString: "")
    private var speakButton: NSButton?

    /// Where the selection is, kept so Look Up can point its panel at the words
    /// rather than at wherever the mouse happens to be.
    private weak var host: NSView?
    private var hostRect = NSRect.zero

    init() {
        popover.behavior = .transient
        popover.animates = false   // it tracks a selection; easing reads as lag

        target.owner = self
        speech.delegate = target

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
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        isComposing = false
        popover.behavior = .transient
        updateSpeakButton()
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

    /// The whole point of the rebuild: say what happened, then get out of the
    /// way. Copy used to succeed in complete silence.
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
        let actions: [(symbol: String, tip: String, action: Selector)] = [
            ("bubble.left", "Comment", #selector(Target.comment)),
            ("doc.on.doc", "Copy Markdown", #selector(Target.copyMarkdown)),
            ("magnifyingglass", "Find in document", #selector(Target.find)),
            ("book", "Look Up", #selector(Target.lookUp)),
            ("character.book.closed", "Translate", #selector(Target.translate)),
            ("speaker.wave.2", "Speak", #selector(Target.speak)),
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
        speakButton = buttons[5]

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        return stack
    }

    /// The buttons target a small forwarding object rather than the popover
    /// itself, so the button targets hold nothing strongly. One per popover —
    /// a shared one would mean two document windows fighting over it.
    fileprivate final class Target: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: SelectionPopover?

        @objc func comment() {
            owner?.beginComposing()
        }
        @objc func copyMarkdown() {
            owner?.onCopyMarkdown?()
            owner?.confirm("Copied")
        }
        @objc func find() {
            owner.map { $0.onFind?($0.text) }
            owner?.dismiss()
        }
        @objc func lookUp() {
            owner?.lookUpSelection()
        }
        @objc func translate() {
            owner?.translateSelection()
        }
        @objc func speak() {
            owner?.speakSelection()
        }
        @objc func searchWeb() {
            owner?.search()
        }
        @objc func saveComment() { owner?.commitComment() }
        @objc func cancelComment() { owner?.dismiss() }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            owner?.updateSpeakButton()
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            owner?.updateSpeakButton()
        }
    }

    // MARK: - Look up, translate, speak, search

    /// `showDefinition` is the panel ⌃⌘D opens everywhere in macOS. The Services
    /// route launched Dictionary.app instead — a whole other application coming
    /// up behind the window, which from here looked like nothing happening.
    private func lookUpSelection() {
        guard let view = host else { return confirm("Can't look that up") }
        let word = text
        let point = NSPoint(x: hostRect.minX, y: hostRect.minY)
        dismiss()
        view.showDefinition(for: NSAttributedString(string: word), at: point)
    }

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

    private func speakSelection() {
        // Pressing it again stops, rather than stacking a second voice on top.
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            updateSpeakButton()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        speech.speak(utterance)
        updateSpeakButton()
    }

    /// Speaking is the one action with no visual result at all, so the button
    /// itself carries the state.
    fileprivate func updateSpeakButton() {
        let symbol = speech.isSpeaking ? "stop.circle" : "speaker.wave.2"
        speakButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        speakButton?.toolTip = speech.isSpeaking ? "Stop speaking" : "Speak"
    }

    private func search() {
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // The service uses whatever search engine the user actually chose;
        // only fall back to a hardcoded one if it is unavailable.
        let board = NSPasteboard(name: .init("pt.miguelsilva.imark.selection"))
        board.clearContents()
        board.setString(text, forType: .string)
        if !NSPerformService("Search With %WebSearchProvider@", board),
           let url = URL(string: "https://duckduckgo.com/?q=\(query)") {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }

    // MARK: - Composing a comment

    private func beginComposing() {
        isComposing = true
        // A click elsewhere must not silently bin what is being typed.
        popover.behavior = .applicationDefined

        let quoted = NSTextField(labelWithString: "“\(text.prefix(80))\(text.count > 80 ? "…" : "")”")
        quoted.font = .systemFont(ofSize: 11)
        quoted.textColor = .secondaryLabelColor
        quoted.lineBreakMode = .byTruncatingTail
        quoted.preferredMaxLayoutWidth = 280

        composer.string = ""
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

        let hint = NSTextField(labelWithString: "⌘↵ to save · esc to cancel")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        // Deliberately not the default button: a Return key equivalent is
        // consumed by the window before the text view ever sees it, and a
        // composer where Return saves instead of starting a line is useless.
        let save = NSButton(title: "Comment", target: target, action: #selector(Target.saveComment))
        save.bezelStyle = .rounded
        save.controlSize = .small

        let cancel = NSButton(title: "Cancel", target: target, action: #selector(Target.cancelComment))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [hint, spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [quoted, scroll, buttons])
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
        }
    }

    private func commitComment() {
        let body = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return NSSound.beep() }
        isComposing = false
        popover.behavior = .transient
        onSaveComment?(body)
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
            // Return inserts a line; ⌘↵ saves. Modifiers are not reported here.
            guard NSEvent.modifierFlags.contains(.command) else { return false }
            saveComment()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelComment()
            return true
        default:
            return false
        }
    }
}

