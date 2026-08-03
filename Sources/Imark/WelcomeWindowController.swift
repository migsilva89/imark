import AppKit
import UniformTypeIdentifiers

/// Shown when Imark is launched without a document. Without this the app opens
/// to no window at all, which reads as a crash rather than as an empty state.
final class WelcomeWindowController: NSWindowController {
    var onOpen: (([URL]) -> Void)?

    /// Holds either the "make me the default" button or the confirmation that
    /// Imark already is, and is rebuilt when that changes.
    private let defaultRow = NSStackView()
    /// The same, for the coding-agent integration. Only built at all when an
    /// agent is on the machine: an offer to set up something you do not have is
    /// a puzzle, not a feature.
    private let agentRow = NSStackView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()

        super.init(window: window)

        let drop = DropView()
        drop.onDrop = { [weak self] urls in self?.onOpen?(urls) }
        window.contentView = drop
        buildContent(in: drop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildContent(in container: NSView) {
        // The real app icon, not a stand-in glyph — this is the one place the
        // user sees Imark with nothing else on screen.
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
        ])

        let title = NSTextField(labelWithString: "Imark")
        title.font = .systemFont(ofSize: 26, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Drop a .md file here")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let openButton = NSButton(title: "Open…", target: self, action: #selector(openPanel))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        defaultRow.orientation = .horizontal
        defaultRow.spacing = 5
        defaultRow.alignment = .centerY
        refreshDefaultRow()

        agentRow.orientation = .horizontal
        agentRow.spacing = 5
        agentRow.alignment = .centerY
        refreshAgentRow()

        let stack = NSStackView(views: [icon, title, subtitle, openButton, defaultRow, agentRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(26, after: subtitle)
        stack.setCustomSpacing(22, after: openButton)
        stack.setCustomSpacing(10, after: defaultRow)

        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    // MARK: - Default handler

    private func refreshDefaultRow() {
        defaultRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !MarkdownType.imarkIsDefault else {
            // Already the default: an offer to do what is already done is just
            // one more thing to read and dismiss.
            let check = NSImageView(
                image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                    ?? NSImage()
            )
            check.contentTintColor = .secondaryLabelColor
            check.symbolConfiguration = .init(pointSize: 11, weight: .regular)

            let label = NSTextField(labelWithString: "Default for .md files")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor

            defaultRow.addArrangedSubview(check)
            defaultRow.addArrangedSubview(label)
            return
        }

        let button = NSButton(
            title: "Make Imark the default for .md",
            target: self,
            action: #selector(makeDefault)
        )
        button.bezelStyle = .rounded
        defaultRow.addArrangedSubview(button)
    }

    // MARK: - Coding agents

    private func refreshAgentRow() {
        agentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let found = AgentSetup.found
        // Nothing to install into, so nothing to say. Somebody who uses no
        // coding agent should not have to work out what this row is for.
        guard !found.isEmpty else {
            agentRow.isHidden = true
            return
        }
        agentRow.isHidden = false
        let names = found.map(\.name).joined(separator: " and ")

        guard !AgentSetup.isInstalled else {
            let check = NSImageView(
                image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                    ?? NSImage()
            )
            check.contentTintColor = .secondaryLabelColor
            check.symbolConfiguration = .init(pointSize: 11, weight: .regular)

            let label = NSTextField(labelWithString: "Set up for \(names)")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor

            // Deleting a handful of files, offered where they were created. An
            // install with no way back is a trap, and hiding the way back in a
            // menu is the same trap with a longer fuse.
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeAgentSetup))
            remove.bezelStyle = .inline
            remove.controlSize = .small
            remove.font = .systemFont(ofSize: 11)

            agentRow.addArrangedSubview(check)
            agentRow.addArrangedSubview(label)
            agentRow.addArrangedSubview(remove)
            return
        }

        let button = NSButton(
            title: "Set up for \(names)",
            target: self,
            action: #selector(installAgentSetup)
        )
        button.bezelStyle = .rounded
        button.toolTip = "Adds a skill so your agent can open documents here for review"
        agentRow.addArrangedSubview(button)
    }

    /// Says what it will write before it writes it, path by path. This is the
    /// one thing Imark does outside its own files and somebody's documents, and
    /// it lands in folders other programs own.
    @objc private func installAgentSetup() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = AgentSetup.plannedFiles
            .map { $0.path.replacingOccurrences(of: home, with: "~") }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Set Imark up for your coding agents?"
        alert.informativeText = [
            "This writes:",
            "",
            paths,
            "",
            "Your agent can then open a document here for you to comment on, and "
                + "read your notes back out of the file. Nothing else is touched, "
                + "and Remove deletes exactly these.",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try AgentSetup.install()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Imark couldn't set that up."
            failure.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            failure.runModal()
        }
        refreshAgentRow()
    }

    @objc private func removeAgentSetup() {
        try? AgentSetup.uninstall()
        refreshAgentRow()
    }

    @objc private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MarkdownType.contentTypes
        guard panel.runModal() == .OK else { return }
        onOpen?(panel.urls)
    }

    @objc private func makeDefault() {
        MarkdownType.makeImarkDefault { [weak self] _ in
            // Ask the system rather than trusting the result: if it refused,
            // the row correctly stays a button.
            self?.refreshDefaultRow()
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // The user may have changed the handler in the Finder since last time.
        refreshDefaultRow()
        refreshAgentRow()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Drop target

    private final class DropView: NSView {
        var onDrop: (([URL]) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            urls(from: sender).isEmpty ? [] : .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let found = urls(from: sender)
            guard !found.isEmpty else { return false }
            onDrop?(found)
            return true
        }

        private func urls(from sender: NSDraggingInfo) -> [URL] {
            let objects = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            return objects.filter(MarkdownType.matches)
        }
    }
}
