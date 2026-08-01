import AppKit
import UniformTypeIdentifiers

/// Shown when Imark is launched without a document. Without this the app opens
/// to no window at all, which reads as a crash rather than as an empty state.
final class WelcomeWindowController: NSWindowController {
    var onOpen: (([URL]) -> Void)?
    var onClose: (() -> Void)?

    private let hint = NSTextField(labelWithString: "")

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
        let mark = NSTextField(labelWithString: "◗")
        mark.font = .systemFont(ofSize: 56, weight: .medium)
        mark.textColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Imark")
        title.font = .systemFont(ofSize: 26, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Drop a .md file here")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let openButton = NSButton(title: "Open…", target: self, action: #selector(openPanel))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        let defaultButton = NSButton(
            title: "Make Imark the default for .md",
            target: self,
            action: #selector(makeDefault)
        )
        defaultButton.bezelStyle = .rounded

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        let stack = NSStackView(views: [mark, title, subtitle, openButton, defaultButton, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(2, after: mark)
        stack.setCustomSpacing(24, after: subtitle)
        stack.setCustomSpacing(20, after: openButton)

        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
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
        guard let markdown = UTType("net.daringfireball.markdown") else { return }
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: markdown) { [weak self] error in
            DispatchQueue.main.async {
                self?.hint.stringValue = error == nil
                    ? "Done — .md files now open in Imark."
                    : "Couldn't set it. Use Get Info on a .md → Open with → Change All."
            }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
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
