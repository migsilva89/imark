import AppKit

/// Asking an assistant about the document you have open — a conversation, not a
/// form.
///
/// What you typed and what came back stack up in one scroll, with the composer at
/// the bottom, so a second question is the obvious thing to do rather than a
/// second visit. Nothing is written to any file: the answer is text you can read,
/// copy, or ignore, and anything that reaches the document is still your own
/// keystroke in the editor.
///
/// The CLIs behind it answer one prompt at a time and remember nothing, so each
/// turn sends the conversation so far along with the new question. That is what
/// makes a follow-up like "and the second one?" mean anything.
final class AskPanel: NSObject {
    private var sheet: NSWindow?
    private let run = AssistantRun()

    private let transcript = NSStackView()
    private let scroll = NSScrollView()
    private let composer = NSTextView()
    private let placeholder = NSTextField(labelWithString: "Ask about this document…")
    private let sendButton = NSButton(title: "Ask", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")

    /// The one line an empty transcript shows, held onto so the first message can
    /// take it away without having to go looking for it.
    private var emptyLine: NSTextField?

    private var cli: Assistants.CLI?
    private var document = URL(fileURLWithPath: "/")
    private var folder = URL(fileURLWithPath: "/")
    private var turns: [(question: String, answer: String)] = []
    private var running = false
    private var ticker: Timer?
    private var startedAt = Date()

    // MARK: - Opening

    func show(for document: URL, using cli: Assistants.CLI, in parent: NSWindow) {
        self.cli = cli
        self.document = document
        folder = document.deletingLastPathComponent()
        turns = []
        // The panel outlives the sheet, so the last conversation was still hanging
        // in the transcript the next time Ask was pressed — under a fresh empty-state
        // line, on a model that had forgotten all of it.
        transcript.views.forEach(transcript.removeView)
        emptyLine = nil

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Ask \(cli.label)"
        panel.contentView = build()
        panel.minSize = NSSize(width: 480, height: 360)
        sheet = panel
        parent.beginSheet(panel)
        panel.makeFirstResponder(composer)
    }

    private func build() -> NSView {
        let container = NSView()
        // The sheet's own ground. A content view with no background leaves the
        // window's material behind it, which is right on screen and invisible when
        // the panel is drawn into an image to be looked at.
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = buildHeader()
        let body = buildTranscript()
        let footer = buildComposer()

        for view in [header, body, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),

            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        // Minimums, not a fixed size. A sheet is laid out at its content view's
        // fitting size, with a priority nothing else can outrank — and nothing in
        // here has a width of its own, because a scroll view has none and a label
        // will compress to a single letter. The first version of this panel shipped
        // 38 points wide and modal, with no way past it to the window underneath.
        //
        // Stated as `>=` so the sheet can still be dragged bigger.
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(greaterThanOrEqualToConstant: 644),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
        ])
        return container
    }

    /// Which assistant, on which file, run how. An app that starts a process on
    /// somebody's machine should be able to name it without being asked.
    private func buildHeader() -> NSView {
        let title = NSTextField(labelWithString: document.lastPathComponent)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(labelWithString:
            "\(cli?.invocationDescription ?? "") in \(folder.lastPathComponent) · writes nothing")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func buildTranscript() -> NSView {
        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 10
        transcript.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        transcript.translatesAutoresizingMaskIntoConstraints = false

        // A flipped clip view, so an empty transcript sits at the top of the well
        // rather than floating in the middle of it.
        let holder = FlippedView()
        // Without this the holder keeps the frame the scroll view gave it — zero by
        // zero — and every constraint against it is quietly ignored, which is how
        // the transcript came out four points wide.
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: holder.topAnchor),
            transcript.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor),
        ])

        scroll.documentView = holder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let well = well(around: scroll, radius: 12)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // The empty state is one line, not an empty box the size of the window.
        let empty = NSTextField(labelWithString:
            "Ask anything about this document. The answer comes back here as text.")
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .tertiaryLabelColor
        transcript.addView(empty, in: .top)
        emptyLine = empty

        return well
    }

    private func buildComposer() -> NSView {
        composer.isRichText = false
        composer.font = .systemFont(ofSize: 12.5)
        composer.textContainerInset = NSSize(width: 8, height: 8)
        composer.drawsBackground = false
        composer.delegate = self
        composer.isVerticallyResizable = true
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        composer.string = ""

        let field = NSScrollView()
        field.documentView = composer
        field.drawsBackground = false
        field.hasVerticalScroller = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 62).isActive = true

        placeholder.font = .systemFont(ofSize: 12.5)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let box = well(around: field, radius: 10)
        box.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
        ])

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        sendButton.target = self
        sendButton.action = #selector(ask)
        // Deliberately not the default button: `\r` as its key equivalent takes
        // plain Return away from the composer, and a question worth asking often has
        // two lines in it. ⌘↩ sends, and the hint beside the button says so.
        sendButton.bezelStyle = .rounded

        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true

        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let hint = NSTextField(labelWithString: "⌘↩ to ask")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [spinner, status, hint, NSView(), close, stopButton, sendButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [box, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    /// The rounded, faintly filled container every part of this panel sits in —
    /// the app's own furniture rather than the line border a raw scroll view draws.
    private func well(around view: NSView, radius: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = radius
        box.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.45).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }

    // MARK: - The conversation

    /// One turn in the transcript. A question is the reader's own words, in the
    /// accent colour; an answer is what the CLI printed, monospaced, because it is
    /// usually Markdown and often quotes lines of the file.
    private func addMessage(_ text: String, from role: Role) {
        if let emptyLine {
            transcript.removeView(emptyLine)
            self.emptyLine = nil
        }

        let who = NSTextField(labelWithString: role.label(cli: cli))
        who.font = .systemFont(ofSize: 10.5, weight: .semibold)
        who.textColor = role == .you ? .imarkAccent : .secondaryLabelColor

        // Copy sits on the name's own line rather than under the answer, where it
        // reads as the first line of whatever comes next.
        let heading = NSStackView(views: [who])
        heading.spacing = 8
        if role == .answer {
            // Carries its own text: every Copy used to reach for `turns.last`, so in
            // a conversation of five answers all five copied the newest one.
            let copy = CopyButton(text: text, target: self, action: #selector(copyAnswer(_:)))
            heading.addView(copy, in: .trailing)
        }

        // Both in the body font. An answer is usually prose about the document, and
        // prose set in a monospaced face reads like a log file.
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .labelColor
        body.isSelectable = true
        body.preferredMaxLayoutWidth = scroll.contentSize.width - 40

        let block = NSStackView(views: [heading, body])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 3

        transcript.addView(block, in: .top)
        NSLayoutConstraint.activate([
            block.widthAnchor.constraint(lessThanOrEqualTo: transcript.widthAnchor, constant: -28),
        ])
        scrollToBottom()
    }

    private enum Role {
        case you, answer

        func label(cli: Assistants.CLI?) -> String {
            switch self {
            case .you: "You"
            case .answer: cli?.label ?? "Assistant"
            }
        }
    }

    /// The hint behind an empty composer. In one place because it has to be right
    /// after typing *and* after a question is sent and the box emptied — the
    /// delegate only hears about the first.
    private func syncPlaceholder() {
        placeholder.isHidden = !composer.string.isEmpty
    }

    private func scrollToBottom() {
        // After layout, or the height it scrolls to is the height before the
        // message was added.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let bottom = max(0, document.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: - Running

    @objc private func ask() {
        guard let cli, !running else { return }
        let question = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return NSSound.beep() }

        composer.string = ""
        syncPlaceholder()
        addMessage(question, from: .you)
        begin()

        let prompt = fullPrompt(for: question)
        let folder = folder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let answer: String
            do {
                let result = try run.run(cli, prompt: prompt, in: folder)
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.timedOut {
                    answer = text.isEmpty
                        ? "\(cli.label) was still going after five minutes, so it was stopped."
                        : text + "\n\n(Stopped after five minutes.)"
                } else if text.isEmpty {
                    answer = "\(cli.label) exited with code \(result.exitCode) and said nothing."
                } else {
                    answer = text
                }
            } catch {
                answer = "Couldn't run \(cli.label): \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.turns.append((question: question, answer: answer))
                self.addMessage(answer, from: .answer)
                self.end()
            }
        }
    }

    /// What actually goes to the CLI: the file it is about, the conversation so
    /// far, then the new question. The reader sees only what they typed.
    private func fullPrompt(for question: String) -> String {
        var parts = [
            "You are helping with the Markdown file \(document.lastPathComponent) in this folder. "
                + "Read it if you need to. Do not edit any file — answer in the reply.",
        ]
        if !turns.isEmpty {
            let history = turns
                .map { "Question: \($0.question)\nYour answer: \($0.answer)" }
                .joined(separator: "\n\n")
            parts.append("The conversation so far:\n\n\(history)")
        }
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// The waiting state, with the seconds counting up. A spinner alone says
    /// something is happening; the count says how long it has been happening,
    /// which is what tells thinking from stuck.
    private func begin() {
        running = true
        startedAt = Date()
        spinner.startAnimation(nil)
        sendButton.isEnabled = false
        stopButton.isHidden = false
        showElapsed()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.showElapsed()
        }
    }

    /// The first label and every tick after it, so "0s" and "12s" are the same
    /// sentence rather than two that have to be kept saying the same thing.
    private func showElapsed() {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        status.stringValue = "\(cli?.label ?? "Working")… \(seconds)s"
    }

    private func end() {
        running = false
        ticker?.invalidate()
        ticker = nil
        spinner.stopAnimation(nil)
        sendButton.isEnabled = true
        stopButton.isHidden = true
        status.stringValue = ""
        sheet?.makeFirstResponder(composer)
    }

    @objc private func stop() {
        guard running else { return }
        run.cancel()
        status.stringValue = "Stopping…"
    }

    @objc private func copyAnswer(_ sender: CopyButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.text, forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { sender.title = "Copy" }
    }

    @objc private func closeSheet() {
        // A CLI left running after its sheet closed is a process nobody can see
        // and nobody asked for.
        run.cancel()
        ticker?.invalidate()
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        self.sheet = nil
    }
}

extension AskPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        syncPlaceholder()
    }

    /// ⌘↩ asks; plain ↩ is a new line, because a question worth asking often has
    /// two of them.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              NSEvent.modifierFlags.contains(.command)
        else { return false }
        ask()
        return true
    }
}

/// A Copy that knows which answer it belongs to.
final class CopyButton: LinkButton {
    let text: String

    init(text: String, target: AnyObject, action: Selector) {
        self.text = text
        super.init(frame: .zero)
        self.title = "Copy"
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 10.5)
        contentTintColor = .imarkAccent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Top-down layout inside a scroll view, so the first message is at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
