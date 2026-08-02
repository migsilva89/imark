import AppKit

/// The keyboard shortcuts, read out of the menu bar rather than written down.
///
/// A hand-kept list is a list that drifts: the README's already had to be
/// corrected twice. Walking `NSApp.mainMenu` means the panel is wrong only if
/// the menu itself is wrong, in which case the shortcut does not work either.
///
/// It also tells the truth about something a written list cannot. AppKit
/// rewrites key equivalents for the active keyboard layout once the menu is
/// installed, so on a Portuguese keyboard Back and Forward are not ⌘[ and ⌘]
/// at all — the menu holds ⌘Ç and ⌘~, and so does this panel.
final class ShortcutsPanel: NSWindowController {
    private static var shared: ShortcutsPanel?

    static func toggle() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.close()
            return
        }
        let panel = shared ?? ShortcutsPanel()
        shared = panel
        panel.rebuild()
        panel.showWindow(nil)
        panel.window?.center()
        panel.window?.makeKeyAndOrderFront(nil)
    }

    private let stack = NSStackView()

    init() {
        let panel = EscapablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            // No .fullSizeContentView: the first group heading ended up under
            // the title bar.
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard Shortcuts"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        super.init(window: panel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        panel.contentView = scroll
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var seen = Set<String>()

        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            let rows = menu.items.compactMap { item -> NSView? in
                guard let keys = shortcut(for: item), seen.insert(keys + item.title).inserted
                else { return nil }
                return row(keys: keys, title: item.title)
            }
            guard !rows.isEmpty else { continue }
            stack.addArrangedSubview(header(menu.title.isEmpty ? "Imark" : menu.title))
            rows.forEach(stack.addArrangedSubview)
        }

        // Not menu items, so the menu cannot tell us about them. The only two
        // that live purely in the sidebar's key handling.
        stack.addArrangedSubview(header("Outline"))
        stack.addArrangedSubview(row(keys: "↑ ↓", title: "Move through the outline"))
        stack.addArrangedSubview(row(keys: "← →", title: "Fold or unfold a section"))
    }

    /// macOS adds Dictation and Emoji & Symbols to any Edit menu it finds, more
    /// than once and with key equivalents it does not print correctly. They are
    /// the system's, not ours, and listing them here would be listing somebody
    /// else's shortcuts wrong.
    private static let injectedBySystem: Set<String> = [
        "startDictation:", "orderFrontCharacterPalette:",
    ]

    private func shortcut(for item: NSMenuItem) -> String? {
        guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { return nil }
        if let action = item.action, Self.injectedBySystem.contains(NSStringFromSelector(action)) {
            return nil
        }
        return glyphs(for: item)
    }

    private func row(keys: String, title: String) -> NSView {
        let shortcut = NSTextField(labelWithString: keys)
        shortcut.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        shortcut.alignment = .right
        shortcut.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let line = NSStackView(views: [shortcut, label])
        line.orientation = .horizontal
        line.spacing = 14
        line.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        return line
    }

    private func header(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let holder = NSStackView(views: [label])
        holder.orientation = .horizontal
        holder.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 4, right: 0)
        return holder
    }

    /// `keyEquivalent` is the character the menu matches on, which is lowercase
    /// even for a shortcut printed with shift. The glyphs are the ones macOS
    /// prints on the menu itself.
    private func glyphs(for item: NSMenuItem) -> String {
        var out = ""
        let flags = item.keyEquivalentModifierMask
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }

        switch item.keyEquivalent {
        case "\r": out += "↩"
        case "\u{8}", "\u{7F}": out += "⌫"
        case "\u{1B}": out += "⎋"
        case " ": out += "␣"
        default: out += item.keyEquivalent.uppercased()
        }
        return out
    }
}


/// Escape closes it. A panel you can only dismiss by aiming at a red dot is a
/// panel you stop opening.
private final class EscapablePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}
