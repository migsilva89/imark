import AppKit

/// Asks, at most twice ever, for a star on GitHub. Stars are how people find
/// Imark, and the only way to get them is to ask — but a reader that nags is a
/// worse reader, so the rules are narrow:
///
/// - Somebody updating from an earlier version already knows the app, so they
///   can be asked in the first session after the update.
/// - Somebody new is asked only once Imark has earned it: ten documents opened
///   and three days since the first launch.
/// - "Not now" asks once more, thirty days later. "Star on GitHub" never asks
///   again. Two asks is the ceiling either way.
///
/// The card only ever appears over a document that has been open for a few
/// seconds, never over the welcome window and never as a modal.
enum StarPrompt {
    static let repository = URL(string: "https://github.com/migsilva89/imark")!

    private static let store = UserDefaults.standard
    private static let maxAsks = 2
    private static let documentsBeforeFirstAsk = 10
    private static let daysBeforeFirstAsk = 3.0
    private static let daysBetweenAsks = 30.0
    /// Long enough that the document has been read a little first; the card
    /// arriving with the window would read as part of opening the file.
    private static let delay: TimeInterval = 8

    private enum Key {
        static let firstSeen = "starPromptFirstSeen"
        static let updatedFromEarlier = "starPromptUpdatedFromEarlier"
        static let documentsOpened = "starPromptDocumentsOpened"
        static let asks = "starPromptAsks"
        static let lastAsked = "starPromptLastAsked"
        static let finished = "starPromptFinished"
    }

    private static var shownThisLaunch = false

    /// Must run before anything else writes a default this launch: an earlier
    /// version is recognised by the preferences it left behind, and the first
    /// window frame or update check would leave some of its own.
    static func noteLaunch() {
        guard store.object(forKey: Key.firstSeen) == nil else { return }
        let id = Bundle.main.bundleIdentifier ?? ""
        let earlier = !(store.persistentDomain(forName: id) ?? [:]).isEmpty
        store.set(Date(), forKey: Key.firstSeen)
        store.set(earlier, forKey: Key.updatedFromEarlier)
    }

    /// Called for every document window that opens. `pane` is where the card
    /// goes if this turns out to be the moment.
    static func documentOpened(in pane: NSView) {
        store.set(store.integer(forKey: Key.documentsOpened) + 1, forKey: Key.documentsOpened)
        guard isDue else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak pane] in
            guard let pane, let window = pane.window, window.isVisible, isDue else { return }
            if window.isKeyWindow {
                show(in: pane)
                return
            }
            // A window behind other apps would spend the ask on a card nobody
            // sees. Wait for the person to come back to it instead.
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak pane] _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                guard let pane else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak pane] in
                    guard let pane, pane.window?.isKeyWindow == true, isDue else { return }
                    show(in: pane)
                }
            }
        }
    }

    private static var isDue: Bool {
        guard !shownThisLaunch, !store.bool(forKey: Key.finished) else { return false }
        let asks = store.integer(forKey: Key.asks)
        guard asks < maxAsks else { return false }
        let now = Date()

        if asks == 0 {
            if store.bool(forKey: Key.updatedFromEarlier) { return true }
            let firstSeen = store.object(forKey: Key.firstSeen) as? Date ?? now
            return store.integer(forKey: Key.documentsOpened) >= documentsBeforeFirstAsk
                && now.timeIntervalSince(firstSeen) >= daysBeforeFirstAsk * 86_400
        }
        let lastAsked = store.object(forKey: Key.lastAsked) as? Date ?? now
        return now.timeIntervalSince(lastAsked) >= daysBetweenAsks * 86_400
    }

    private static func show(in pane: NSView) {
        shownThisLaunch = true
        // Counted when shown rather than when answered: closing the window
        // without choosing is an answer too, and must not mean "ask again".
        store.set(store.integer(forKey: Key.asks) + 1, forKey: Key.asks)
        store.set(Date(), forKey: Key.lastAsked)

        let card = StarCard()
        card.onAnswer = { starred in
            if starred {
                store.set(true, forKey: Key.finished)
                NSWorkspace.shared.open(repository)
            }
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: pane.safeAreaLayoutGuide.topAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14),
            card.widthAnchor.constraint(equalToConstant: 340),
        ])
        card.appear()
    }
}

/// The card itself: icon, one question, one sentence, two buttons.
private final class StarCard: NSVisualEffectView {
    var onAnswer: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "Enjoying Imark?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "A star on GitHub helps more people find Imark.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        let later = NSButton(title: "Not now", target: self, action: #selector(notNow))
        later.bezelStyle = .rounded
        later.isBordered = false
        later.contentTintColor = .secondaryLabelColor

        let star = NSButton(title: "Star on GitHub", target: self, action: #selector(starIt))
        star.bezelStyle = .rounded
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        star.imagePosition = .imageLeading
        star.contentTintColor = .systemYellow

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 10

        let buttons = NSStackView(views: [NSView(), later, star])
        buttons.spacing = 8

        let stack = NSStackView(views: [top, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Separator colours are dynamic; a CGColor taken once is not.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func appear() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 1
        }
    }

    @objc private func notNow() { dismiss(starred: false) }
    @objc private func starIt() { dismiss(starred: true) }

    private func dismiss(starred: Bool) {
        onAnswer?(starred)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }
}
