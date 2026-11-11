import AppKit
import WebKit
import ImarkRender

/// The document in CodeMirror, for editing in the preview's own type and colours
/// (docs/LIVE-PREVIEW.md). M1: highlighted Markdown source, nothing hidden yet.
///
/// The page runs in its own web view, not the preview's: the preview is shared
/// with Quick Look and owns the comment rail and the selection logic, and this
/// page owns a contenteditable. Built the first time a window starts editing in
/// this style, so a window that only ever reads never pays for a second web
/// content process.
///
/// Swift is the one that knows the document. Every edit the page makes arrives
/// as a `changes` message and is applied to a `LiveMirror`, so `text` and
/// `isDirty` are answered here, synchronously, without asking the page — and the
/// mirror is right from the moment `load` is called, before the page has even
/// finished loading. If the web content process dies, the mirror still has the
/// text and the page is given it again.
final class LiveEditorView: NSView, DocumentEditor {
    var onEdit: (() -> Void)?
    var onSave: (() -> Void)?
    /// ⌘F. The page has no find bar of its own; the app's is in the content
    /// controller, which this view has no reference to.
    var onShowFind: (() -> Void)?
    /// The page's answer to `find` / `findStep`: how many matches, and which
    /// one is current, counted from one (zero when there are none).
    var onFind: ((_ count: Int, _ index: Int) -> Void)?
    /// A line for the status bar.
    var onNotice: ((String) -> Void)?
    /// ⌘-click on a link in the text. The page only says which; where it goes is
    /// the window's to decide, the same as for a link in the preview.
    var onOpenLink: ((Link) -> Void)?

    enum Link: Equatable {
        /// The destination as written in the document: a URL, or a path
        /// relative to it, possibly with a `#heading`.
        case href(String)
        /// The target of `[[target]]` / `[[target|label]]`.
        case wiki(String)
    }

    /// Set by the test harnesses before any editor is built, never by the app:
    /// it makes the page expose `imarkEditor.__spike`, which reaches straight
    /// into CodeMirror and around the mirror protocol.
    static var exposesTestHooks = false

    /// Whether this build carries the page at all. A build without the
    /// renderer's editor files (or a test binary with no Resources beside it)
    /// edits in the source editor instead of showing a blank web view.
    static var isAvailable: Bool {
        Bundle.main.url(forResource: "editor", withExtension: "html") != nil
    }

    static let page = URL(string: "imark://app/editor.html")!

    /// Absolute path of the file being edited. The page resolves a relative image
    /// against its folder, as the preview does (`imark://file/...`); it has no
    /// other way to know where the document lives.
    var documentPath = "" {
        didSet {
            guard documentPath != oldValue, hasDocument, isReady else { return }
            call("window.imarkEditor.setPath(path)", ["path": documentPath])
        }
    }

    /// Internal rather than private so the Live editor's tests can drive the
    /// page the way the spike does.
    let webView: WKWebView
    private let mirror = LiveMirror()
    private let bridge = Bridge()
    private var isReady = false
    private var hasDocument = false
    /// Calls made before the page was ready, in the order they were made. The
    /// document itself is not among them: it is sent from the mirror on every
    /// `ready`, so a page that comes up twice is told it twice.
    private var queued: [(script: String, arguments: [String: Any])] = []
    /// From the page's `history` messages. The menu asks synchronously.
    private var history = (canUndo: false, canRedo: false)

    private var theme = Settings.Palette.classic.face(dark: false)
    private var textScale = Settings.defaultTextScale
    private var width = Settings.Width.normal.rawValue
    private var language = "en"
    private var frontMatter = Settings.showsFrontMatter

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if Self.exposesTestHooks {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.__imarkEditorHooks = true;",
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        // Installed before the web view exists: WKWebView copies its
        // configuration on init.
        config.userContentController.add(bridge, name: "imarkEditor")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false

        super.init(frame: frameRect)

        bridge.owner = self
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applySettings()
        webView.load(URLRequest(url: Self.page))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "imarkEditor")
    }

    // MARK: - DocumentEditor

    var text: String { mirror.text }
    var savedText: String { mirror.savedText }
    var isDirty: Bool { mirror.isDirty }
    var textIsCurrent: Bool { !mirror.isAwaitingResync }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Only for a file the mirror can write back byte for byte. The content
    /// controller asks `LiveMirror.lineSeparator(of:)` first and sends anything
    /// else to the source editor; getting here with mixed breaks is a bug in that
    /// gate, and stopping is better than saving a file with its breaks rewritten.
    func load(_ text: String, saved: String) {
        guard let separator = LiveMirror.lineSeparator(of: text) else {
            preconditionFailure("mixed line breaks belong in the source editor")
        }
        mirror.load(text, lineSeparator: separator, saved: saved)
        hasDocument = true
        // Whatever the last document could undo, this one cannot, and the menu
        // asks before the page has had a chance to say so.
        history = (false, false)
        // Finds and the like were for the document being replaced.
        queued.removeAll()
        sendDocument()
    }

    func markSaved() {
        mirror.markSaved()
        call("window.imarkEditor.markSaved()")
    }

    func focus() {
        window?.makeFirstResponder(webView)
        call("window.imarkEditor.focus()")
    }

    func undo() { call("window.imarkEditor.undo()") }

    func redo() { call("window.imarkEditor.redo()") }

    func showFind() { onShowFind?() }

    // MARK: - Find

    func find(_ query: String) {
        call("window.imarkEditor.find(query)", ["query": query])
    }

    func findStep(_ delta: Int) {
        call("window.imarkEditor.findStep(delta)", ["delta": delta])
    }

    func findClear() {
        call("window.imarkEditor.findClear()")
    }

    // MARK: - Appearance

    /// Theme, text size, width and language, from the same settings the preview
    /// is given them from. Kept here as well as sent, because they travel with
    /// every `load`: a page rebuilt after a crash comes back in them rather than
    /// in the page's defaults.
    func applySettings() {
        theme = Settings.palette.face(dark: isDarkMode)
        textScale = Settings.textScale
        width = Settings.width.rawValue
        language = Bundle.main.preferredLocalizations.first ?? "en"
        // The preview's own switch (View > Front Matter), so the card is as
        // hidden here as it is there.
        frontMatter = Settings.showsFrontMatter
        guard hasDocument, isReady else { return }
        call("window.imarkEditor.setTheme(theme)", ["theme": theme])
        call("window.imarkEditor.setTextScale(scale)", ["scale": textScale])
        call("window.imarkEditor.setWidth(width)", ["width": width])
        call("window.imarkEditor.setLanguage(language)", ["language": language])
        call("window.imarkEditor.setFrontMatter(shown)", ["shown": frontMatter])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySettings()
    }

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Keys

    // ⌘S is deliberately not caught here, unlike in the source editor. Keys
    // reach the page in order but its `changes` come back afterwards, so a save
    // taken from the event in Swift could run before the last few keystrokes
    // had reached the mirror and write the document without them. The page
    // binds ⌘S itself and posts `save` behind the `changes` it already sent,
    // then eats the key so the menu does not save a second time. The menu item
    // clicked with the mouse saves straight from the mirror, which by then has
    // long caught up.

    // MARK: - Talking to the page

    /// The mirror's document, under its current generation. The text keeps the
    /// file's own breaks: with the CRLF facet set, CodeMirror splits only on
    /// `\r\n`, and a `\n`-joined text would arrive as one line.
    private func sendDocument() {
        guard isReady, hasDocument else { return }
        evaluate("window.imarkEditor.load(args)", ["args": [
            "generation": mirror.generation,
            "text": mirror.text,
            "lineSeparator": mirror.lineSeparator,
            "theme": theme,
            "textScale": textScale,
            "width": width,
            "language": language,
            "path": documentPath,
            "frontMatter": frontMatter,
        ] as [String: Any]])
    }

    private func call(_ script: String, _ arguments: [String: Any] = [:]) {
        guard isReady else { return queued.append((script, arguments)) }
        evaluate(script, arguments)
    }

    private func evaluate(_ script: String, _ arguments: [String: Any]) {
        // Arguments rather than a script with the text spliced in: WebKit does the
        // escaping, and a document is exactly the kind of string that breaks
        // hand-made escaping.
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    /// A fresh page, whether it is the first or one that came back after the old
    /// one died. It knows nothing, so it is given everything: the document under
    /// a new generation (anything the dead page had in flight is then stale), and
    /// then whatever was asked of it while it was coming up.
    fileprivate func pageIsReady() {
        isReady = true
        history = (false, false)
        if hasDocument {
            mirror.restart()
            sendDocument()
        }
        let pending = queued
        queued.removeAll()
        for item in pending { evaluate(item.script, item.arguments) }
        onEdit?()
    }

    fileprivate func receive(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        if type == "ready" { return pageIsReady() }

        // Everything else belongs to one document. A message from the one before
        // — switched away from, reverted, reloaded from disk — describes text
        // that is no longer there.
        guard (body["generation"] as? NSNumber)?.intValue == mirror.generation else { return }

        switch type {
        case "changes":
            guard let seq = (body["seq"] as? NSNumber)?.intValue,
                  let length = (body["length"] as? NSNumber)?.intValue,
                  let changes = LiveMirror.changes(from: body["changes"])
            else { return }
            switch mirror.apply(generation: mirror.generation, seq: seq, length: length, changes: changes) {
            case .applied:
                onEdit?()
            case .needsResync:
                evaluate("window.imarkEditor.resync()", [:])
            case .stale, .awaitingResync:
                break
            }

        case "fullText":
            guard let seq = (body["seq"] as? NSNumber)?.intValue,
                  let text = body["text"] as? NSString
            else { return }
            if mirror.applyFullText(generation: mirror.generation, seq: seq, text: text) == .applied {
                onEdit?()
            }

        case "history":
            history = (body["canUndo"] as? Bool ?? false, body["canRedo"] as? Bool ?? false)

        case "save":
            onSave?()

        case "openLink":
            if let wiki = body["wiki"] as? String, !wiki.isEmpty {
                onOpenLink?(.wiki(wiki))
            } else if let href = body["href"] as? String, !href.isEmpty {
                onOpenLink?(.href(href))
            }

        case "find":
            onFind?((body["count"] as? NSNumber)?.intValue ?? 0, (body["index"] as? NSNumber)?.intValue ?? 0)

        default:
            break
        }
    }

    /// Split out so the user content controller, which retains its handlers,
    /// does not retain the view.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: LiveEditorView?

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // Only the editor's own page speaks for the editor. The navigation
            // policy keeps anything else from loading; this is the second lock.
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame,
                  origin.protocol == SchemeHandler.scheme, origin.host == "app",
                  let body = message.body as? [String: Any]
            else { return }
            owner?.receive(body)
        }
    }
}

// MARK: - Navigation

extension LiveEditorView: WKNavigationDelegate {
    /// The web view shows the editor page and nothing else. A document is text in
    /// here, never HTML, but a link the page might one day follow or a drop onto
    /// the view would otherwise replace the page — and whatever loaded would
    /// inherit the bridge.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isEditor = url?.scheme == SchemeHandler.scheme && url?.host == "app"
            && url?.path == Self.page.path
        decisionHandler(isEditor ? .allow : .cancel)
    }

    /// The page is gone and with it CodeMirror's copy of the document. The
    /// mirror's copy is not: the page is loaded again and given it, and what was
    /// unsaved is still unsaved, because what counts as saved never changed.
    /// Undo history went with the process.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        history = (false, false)
        queued.removeAll()
        webView.load(URLRequest(url: Self.page))
        onNotice?(NSLocalizedString("The editor restarted · your text is still here", comment: ""))
        onEdit?()
    }
}
