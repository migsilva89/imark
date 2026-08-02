import AppKit
import WebKit

/// Messages the JS bundle posts back through `webkit.messageHandlers.imark`.
public enum RendererMessage {
    case ready
    case rendered
    case toc([TocEntry])
    case active(String)
    case meta(words: Int, minutes: Int)
    case find(count: Int, index: Int)
    case wikilinks([String])
    case openWiki(String)
    case openLocal(String)
    case openExternal(URL)
    case selection(Selection)
    case selectionCleared
    case comments(count: Int, reviewing: Bool)
}

/// A live selection in the document, and where it came from in the file.
public struct Selection {
    public struct Lines: Equatable {
        public let start: Int
        public let end: Int
    }

    public let text: String
    /// In the renderer view's own coordinates, ready to anchor a popover to.
    public let rect: NSRect
    /// The tightest block that knows its lines — where a quote should be found.
    public let inline: Lines?
    /// The top-level block it belongs to — where a comment gets written.
    public let block: Lines?
    /// Which occurrence of this text inside the block it is, counting from one.
    /// Two notes on the same word would otherwise both anchor to the first.
    public let occurrence: Int
}

public struct TocEntry: Identifiable, Equatable {
    public let id: String
    public let level: Int
    public let title: String
}

public final class RendererView: NSView {
    private let webView: WKWebView
    private var isReady = false
    private var pending: (markdown: String, path: String)?

    public var onMessage: ((RendererMessage) -> Void)?

    private let bridge = Bridge()
    private var previewMode = false
    private var railSide: String?

    public override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // WKWebView copies its configuration on init, so the message handler
        // has to be installed before the web view exists.
        config.userContentController.add(bridge, name: "imark")

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

        webView.load(URLRequest(url: URL(string: "imark://app/index.html")!))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Driving the page

    public func render(markdown: String, path: String) {
        guard isReady else {
            pending = (markdown, path)
            return
        }
        call("window.imark.render", [
            "markdown": markdown,
            "path": path,
            "theme": isDarkMode ? "dark" : "light",
            // Carried in the payload rather than sent separately: a standalone
            // call lands before the page is ready and is silently dropped.
            "preview": previewMode,
            "rail": railSide ?? "",
        ])
    }

    public func applyTheme() {
        call("window.imark.setTheme", isDarkMode ? "dark" : "light")
    }

    public func scrollTo(anchor: String) {
        call("window.imark.scrollToAnchor", anchor)
    }

    public func markMissingWikiLinks(_ targets: [String]) {
        call("window.imark.markMissing", targets)
    }

    public func setTextScale(_ points: Double) {
        call("window.imark.setTextScale", points)
    }

    public func setWidth(_ name: String) {
        call("window.imark.setWidth", name)
    }

    /// Quick Look shows the same document in a much smaller panel: tighter
    /// margins, no copy buttons, nothing clickable.
    public func setPreviewMode() {
        previewMode = true
        setRail("left")
        call("window.imark.setPreview", true)
    }

    /// Which edge the outline rail hugs: `left` in the preview panel, `right`
    /// in a window where the sidebar already owns the left edge, nil for none.
    public func setRail(_ side: String?) {
        railSide = side
        call("window.imark.setRail", side ?? "")
    }

    public func find(_ query: String) {
        call("window.imark.find", query)
    }

    public func findStep(_ delta: Int) {
        call("window.imark.findStep", delta)
    }

    public func clearSelection() {
        webView.evaluateJavaScript("window.imark.clearSelection()")
    }

    /// Opens every note at once, for reading a document somebody commented on
    /// rather than hunting the dots one by one.
    public func setReviewingComments(_ on: Bool) {
        call("window.imark.setReviewing", on)
    }

    /// Moves to the next (+1) or previous (-1) note, wrapping around.
    public func stepNote(_ delta: Int) {
        call("window.imark.stepNote", delta)
    }

    /// Scrolls to a note and opens it — a comment that changes the file without
    /// visibly appearing is the same bug as a button that does nothing.
    public func revealNote(_ index: Int) {
        call("window.imark.revealNote", index)
    }

    public func findClear() {
        webView.evaluateJavaScript("window.imark.findClear()")
    }


    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func call(_ function: String, _ argument: Any) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [argument], options: []),
            let json = String(data: data, encoding: .utf8)
        else { return }
        // The array wrapper keeps JSONSerialization happy with bare strings and
        // gives us correct escaping for free.
        webView.evaluateJavaScript("\(function).apply(null, \(json))")
    }

    // MARK: - Appearance

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    // MARK: - Printing

    public func printOperation(with info: NSPrintInfo) -> NSPrintOperation {
        webView.printOperation(with: info)
    }

    /// Hands keyboard focus to the page so the arrow keys, page up/down, space
    /// and home/end scroll the document straight away.
    public func focus() {
        window?.makeFirstResponder(webView)
    }

    public func reloadPage() {
        webView.load(URLRequest(url: URL(string: "imark://app/index.html")!))
    }

    // MARK: - Bridge

    /// Split out so the content controller does not retain the view.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: RendererView?

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let owner, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                owner.isReady = true
                if let pending = owner.pending {
                    owner.pending = nil
                    owner.render(markdown: pending.markdown, path: pending.path)
                }
                owner.onMessage?(.ready)

            case "rendered":
                owner.onMessage?(.rendered)

            case "toc":
                let raw = body["items"] as? [[String: Any]] ?? []
                let items = raw.compactMap { item -> TocEntry? in
                    guard let id = item["id"] as? String,
                          let level = item["level"] as? Int,
                          let title = item["title"] as? String else { return nil }
                    return TocEntry(id: id, level: level, title: title)
                }
                owner.onMessage?(.toc(items))

            case "active":
                if let id = body["id"] as? String { owner.onMessage?(.active(id)) }

            case "meta":
                owner.onMessage?(.meta(
                    words: body["words"] as? Int ?? 0,
                    minutes: body["minutes"] as? Int ?? 0
                ))

            case "find":
                owner.onMessage?(.find(
                    count: body["count"] as? Int ?? 0,
                    index: body["index"] as? Int ?? 0
                ))

            case "selection":
                guard let text = body["text"] as? String,
                      let raw = body["rect"] as? [String: Any],
                      let x = raw["x"] as? Double, let y = raw["y"] as? Double,
                      let w = raw["width"] as? Double, let h = raw["height"] as? Double
                else { break }

                let lines = { (key: String) -> Selection.Lines? in
                    guard let v = body[key] as? [String: Any],
                          let s = v["start"] as? Int, let e = v["end"] as? Int
                    else { return nil }
                    return Selection.Lines(start: s, end: e)
                }

                // The page measures from the top-left; AppKit views from the
                // bottom-left unless flipped.
                let height = owner.bounds.height
                let rect = NSRect(x: x, y: height - y - h, width: w, height: h)
                owner.onMessage?(.selection(Selection(
                    text: text, rect: rect, inline: lines("inline"), block: lines("block"),
                    occurrence: body["occurrence"] as? Int ?? 1
                )))

            case "selectionCleared":
                owner.onMessage?(.selectionCleared)

            case "comments":
                owner.onMessage?(.comments(
                    count: body["count"] as? Int ?? 0,
                    reviewing: body["reviewing"] as? Bool ?? false
                ))

            case "wikilinks":
                owner.onMessage?(.wikilinks(body["targets"] as? [String] ?? []))

            case "openWiki":
                if let target = body["target"] as? String { owner.onMessage?(.openWiki(target)) }

            case "openLocal":
                if let path = body["path"] as? String { owner.onMessage?(.openLocal(path)) }

            case "openExternal":
                if let raw = body["url"] as? String, let url = URL(string: raw) {
                    owner.onMessage?(.openExternal(url))
                }

            default:
                break
            }
        }
    }
}

// MARK: - Navigation

extension RendererView: WKNavigationDelegate {
    /// If WebKit dies the page goes blank and silent; reloading is the only
    /// useful response, and it beats leaving the user staring at nothing.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadPage()
    }
}
