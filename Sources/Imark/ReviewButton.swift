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
    /// What a standard toolbar item stands at. These sit in the same row as the
    /// system's own group and any difference reads as one of them being wrong.
    private static let height: CGFloat = 28

    private let filled: Bool
    private let tint: NSColor

    init(
        title: String,
        symbol: String,
        filled: Bool,
        tint: NSColor,
        target: AnyObject,
        action: Selector
    ) {
        self.filled = filled
        self.tint = tint
        super.init(frame: .zero)

        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        bezelStyle = .texturedRounded
        // Both pills are drawn below rather than asked for: the system bezel is
        // restyled by the toolbar material and would not take the colour.
        isBordered = false
        self.target = target
        self.action = action

        // Both get the same pill. The filled one takes the colour inside, the
        // other only around the edge — enough to read as a button without
        // competing with the one that ends the review in the other direction.
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // Half the height: a capsule, like everything else in that row.
        layer?.cornerRadius = Self.height / 2
        if filled {
            contentTintColor = .white
        } else {
            contentTintColor = tint
            layer?.borderWidth = 1
        }
        self.title = title

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// White on the accent, kept in `title`'s place so `title = …` later still
    /// works — the button changes its own wording once a decision is taken.
    override var title: String {
        didSet {
            // Once decided the pair stops being a choice, and a red word on a
            // question nobody is being asked any more reads as an error.
            let colour: NSColor = filled ? .white : (isEnabled ? tint : .secondaryLabelColor)
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: colour,
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
        let colour = isEnabled ? tint : NSColor.disabledControlTextColor
        if filled {
            layer?.backgroundColor = colour.cgColor
        } else {
            // Lighter than the words it surrounds: a full-strength outline in
            // the same red reads as a warning around the button rather than
            // the edge of one.
            layer?.borderColor = colour.withAlphaComponent(0.45).cgColor
        }
    }

    /// A borderless button hugs its text. The fill needs room around the words
    /// or it reads as a highlight rather than a button.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 22
        size.height = Self.height
        return size
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
