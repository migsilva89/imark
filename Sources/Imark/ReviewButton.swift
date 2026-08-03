import AppKit

/// The two buttons that finish a review. One of them is filled, and it is the
/// only filled button in the app — everything else in that row changes how you
/// are looking at the document, and these two end it for somebody who is
/// waiting.
///
/// Drawn rather than asked for: `bezelColor` on a standard button is ignored
/// under the toolbar material on macOS 26, which left Approve and Send Back
/// looking like the same button with different words.
final class ReviewButton: NSButton {
    private let filled: Bool

    init(title: String, symbol: String, filled: Bool, target: AnyObject, action: Selector) {
        self.filled = filled
        super.init(frame: .zero)

        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        bezelStyle = .texturedRounded
        // Neither one is bordered. The filled button draws its own pill, and the
        // other is plain text: two pills side by side were the same size and the
        // same shape, and the one you must not press by accident looked exactly
        // like the one you meant.
        isBordered = false
        self.target = target
        self.action = action

        if filled {
            wantsLayer = true
            layer?.cornerCurve = .continuous
            layer?.cornerRadius = 12
            contentTintColor = .white
        } else {
            contentTintColor = .secondaryLabelColor
        }
        self.title = title

        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// White on the accent, kept in `title`'s place so `title = …` later still
    /// works — the button changes its own wording once a decision is taken.
    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: filled ? NSColor.white : .secondaryLabelColor,
                .font: NSFont.systemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: filled ? .semibold : .regular
                ),
            ])
        }
    }

    /// The accent is a dynamic colour and a CGColor is not; switching the theme
    /// would otherwise leave yesterday's purple behind.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard filled else { return }
        layer?.backgroundColor = (isEnabled ? NSColor.imarkAccent : .disabledControlTextColor).cgColor
    }

    /// A borderless button hugs its text. The fill needs room around the words
    /// or it reads as a highlight rather than a button.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if filled { size.width += 22 }
        size.height = 24
        return size
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
