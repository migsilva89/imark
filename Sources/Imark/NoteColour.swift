import AppKit

/// The colours a note can be marked with.
///
/// A closed set, and named rather than free-form. The value is written into
/// somebody's document and read back out of it, so it has to stay legible in
/// plain text and it must never be able to reach the stylesheet — anything
/// unrecognised comes back as `.standard`. The same five live in `style.css`
/// as `--note-*`; the table in docs/DESIGN.md is what both answer to.
enum NoteColour: String, CaseIterable {
    case standard
    case amber
    case green
    case blue
    case red

    /// What goes in the file. The default writes nothing at all: a `color=`
    /// on every note would be noise in a document that mostly has one colour.
    var attribute: String? { self == .standard ? nil : rawValue }

    init(attribute: String?) {
        self = attribute.flatMap(NoteColour.init(rawValue:)) ?? .standard
    }

    var label: String {
        self == .standard ? "Default" : rawValue.capitalized
    }

    var colour: NSColor {
        switch self {
        case .standard: .imarkAccent
        case .amber: .imark(light: 0xB9_770E, dark: 0xE0_A458)
        case .green: .imark(light: 0x2F_8F4E, dark: 0x5F_BF82)
        case .blue: .imark(light: 0x2B_6CB0, dark: 0x6B_A3E8)
        case .red: .imark(light: 0xC0_392B, dark: 0xE0_7A6F)
        }
    }
}

extension NSColor {
    /// The violet from the design tokens. It lives here rather than in Settings
    /// because it is the default note colour before it is anything else, and
    /// because the five of them have to be read side by side to stay a palette.
    /// It exists twice — here and as `--accent` in the stylesheet — since the
    /// document is a web view and the chrome around it is not.
    static let imarkAccent = NSColor.imark(light: 0x7A_6BD8, dark: 0x8B_7BE8)

    /// Two hex values, picked by the appearance in effect when the colour is
    /// drawn rather than when it is created — otherwise every one of these
    /// would be stuck on whatever theme was active at launch.
    static func imark(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// A circle you can pick. NSButton has no colour-well style that looks right at
/// this size, and a colour picker is far more machinery than five choices need.
final class Swatch: NSControl {
    let colour: NoteColour
    var isPicked = false { didSet { needsDisplay = true } }

    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(_ colour: NoteColour, target: AnyObject, action: Selector) {
        self.colour = colour
        super.init(frame: .zero)
        self.target = target
        self.action = action
        toolTip = colour.label
        setAccessibilityLabel(colour.label)
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        let fill = bounds.insetBy(dx: 4, dy: 4)
        colour.colour.setFill()
        NSBezierPath(ovalIn: fill).fill()

        // A ring outside the dot rather than a tick inside it: at 12pt across
        // there is no room for a mark that reads as anything.
        guard isPicked || hovered else { return }
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = isPicked ? 2 : 1
        (isPicked ? colour.colour : NSColor.tertiaryLabelColor).setStroke()
        ring.stroke()
    }
}
