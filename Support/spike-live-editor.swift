// M0 spike for the Live editor (docs/LIVE-PREVIEW.md §7): CodeMirror 6 in a real
// WKWebView, behind the app's scheme handler and CSP, mirrored into Swift.
//
//   (cd renderer && npm install && npm run build)
//   mkdir -p /tmp/imark-spike-live
//   swiftc -parse-as-library Sources/Imark/LiveMirror.swift \
//     Sources/ImarkRender/SchemeHandler.swift Support/spike-live-editor.swift \
//     -o /tmp/imark-spike-live/run && /tmp/imark-spike-live/run
//
// It wraps itself in ImarkSpike.app (beside the binary) and launches that, then
// puts a window on screen for a few seconds. If the system will not make the app
// active (macOS 14+ cooperative activation, e.g. while another app is in use),
// key status is forced on the window and ⌘Z is given to the window before the
// menu by hand, as NSApplication would; a note says so. Run it from a frontmost
// Terminal to get the real `NSApp.sendEvent` route. Each item prints OK or FAIL;
// lines starting `note` are measurements, not verdicts.
//
//   (a) CodeMirror's injected styles apply under the page's CSP
//   (b) the Swift mirror equals `state.sliceDoc()` after random edits (LF, CRLF)
//   (c) a message from an older generation is ignored after a reload
//   (d) a real ⌘Z through an Undo menu item undoes exactly one step
//   (e) composition through NSTextInputClient leaves the right text behind

import AppKit
import WebKit

// MARK: - The page's host

/// What LiveEditorView will be in M1, cut down to what the spike needs.
final class EditorHost: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    let mirror = LiveMirror()
    private(set) var isReady = false
    private var pendingLoad: [String: Any]?

    var outcomes: [LiveMirror.Outcome] = []
    var resyncs = 0
    var historyState = (canUndo: false, canRedo: false)
    /// Lose the next `changes` message on purpose, to see the resync heal it.
    var dropNextChange = false

    init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        // Instrumentation, installed before the page's own script runs. User
        // scripts are not subject to the page's CSP. `__imarkEditorHooks` is what
        // makes the page expose `imarkEditor.__spike`; the app never sets it.
        config.userContentController.addUserScript(WKUserScript(source: """
            window.__imarkEditorHooks = true;
            window.__csp = [];
            document.addEventListener('securitypolicyviolation', e =>
              window.__csp.push(e.violatedDirective + ' ' + e.blockedURI));
            window.__events = [];
            document.addEventListener('keydown', e => {
              if (e.metaKey) window.__events.push('keydown:' + e.key);
            }, true);
            document.addEventListener('beforeinput', e => {
              if (e.inputType.startsWith('history')) window.__events.push('beforeinput:' + e.inputType);
            }, true);
            window.__composition = [];
            for (const t of ['compositionstart', 'compositionupdate', 'compositionend'])
              document.addEventListener(t, e => window.__composition.push(t + ':' + e.data), true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        config.userContentController.add(self, name: "imarkEditor")
        webView.load(URLRequest(url: URL(string: "imark://app/editor.html")!))
    }

    // The load in §3.2: the mirror is right at once; the page catches up.
    func load(_ fileText: String) {
        guard let separator = LiveMirror.lineSeparator(of: fileText) else {
            fatalError("mixed line breaks do not go to the Live editor")
        }
        let generation = mirror.load(fileText, lineSeparator: separator)
        outcomes.removeAll()
        let args: [String: Any] = [
            "generation": generation, "text": fileText, "lineSeparator": separator,
        ]
        if isReady { send(args) } else { pendingLoad = args }
    }

    private func send(_ args: [String: Any]) {
        webView.callAsyncJavaScript("window.imarkEditor.load(args)", arguments: ["args": args],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func undo() { webView.evaluateJavaScript("window.imarkEditor.undo()") }
    func redo() { webView.evaluateJavaScript("window.imarkEditor.redo()") }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == SchemeHandler.scheme, origin.host == "app",
              let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        let generation = (body["generation"] as? NSNumber)?.intValue ?? -1

        switch type {
        case "ready":
            isReady = true
            if let args = pendingLoad { pendingLoad = nil; send(args) }
        case "changes":
            if dropNextChange { dropNextChange = false; return }
            guard let seq = (body["seq"] as? NSNumber)?.intValue,
                  let length = (body["length"] as? NSNumber)?.intValue,
                  let changes = LiveMirror.changes(from: body["changes"])
            else { return }
            let outcome = mirror.apply(generation: generation, seq: seq, length: length, changes: changes)
            outcomes.append(outcome)
            if outcome == .needsResync {
                resyncs += 1
                webView.evaluateJavaScript("window.imarkEditor.resync()")
            }
        case "fullText":
            guard let seq = (body["seq"] as? NSNumber)?.intValue, let text = body["text"] as? NSString
            else { return }
            outcomes.append(mirror.applyFullText(generation: generation, seq: seq, text: text))
        case "history":
            guard generation == mirror.generation else { return }
            historyState = (body["canUndo"] as? Bool ?? false, body["canRedo"] as? Bool ?? false)
        default:
            break
        }
    }
}

// MARK: - The window and its menu

/// The menu item has the app's shape: `undoComment:` sent down the responder
/// chain with no target, which the web view does not answer, so it reaches the
/// window — `DocumentWindowController` in the app.
final class SpikeWindow: NSWindow {
    var host: EditorHost?
    var menuUndos = 0
    var menuRedos = 0

    @objc func undoComment(_ sender: Any?) {
        menuUndos += 1
        host?.undo()
    }

    @objc func redoTyping(_ sender: Any?) {
        menuRedos += 1
        host?.redo()
    }

    /// Set when the system would not make the app active (see `focusEditor`).
    /// WebKit's own API tests force key status the same way
    /// (TestWKWebViewHostWindow): the page's focus follows `isKeyWindow` and
    /// the key notifications.
    var forcedKey = false
    override var isKeyWindow: Bool { forcedKey || super.isKeyWindow }
    override var canBecomeKey: Bool { true }
}

/// With the app inactive there is no key window for a nil-targeted menu item to
/// start from, and NSApplication falls back to the app delegate. Forwarding to
/// the window keeps the item's shape (no target, `undoComment:`) the same.
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    weak var window: SpikeWindow?
    var used = 0
    @objc func undoComment(_ sender: Any?) { used += 1; window?.undoComment(sender) }
    @objc func redoTyping(_ sender: Any?) { used += 1; window?.redoTyping(sender) }
}

func buildMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu(title: "Spike")
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: #selector(SpikeWindow.undoComment(_:)), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: #selector(SpikeWindow.redoTyping(_:)), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

// MARK: - The run

@main
enum Spike {
    static var failures = 0
    static var window: SpikeWindow!
    static var host: EditorHost!
    static let delegate = SpikeDelegate()

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)  \(detail())")
        }
    }

    static func note(_ text: String) { print("note \(text)") }

    /// Turns the run loop and hands the app its events: WebKit sends a key the
    /// page did not want back through the application, and a loop that only runs
    /// the run loop would never deliver it.
    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    static func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            spin(0.02)
        }
        return condition()
    }

    /// Runs a script and waits for its value.
    @discardableResult
    static func js(_ script: String) -> Any? {
        var done = false
        var value: Any?
        host.webView.evaluateJavaScript(script) { result, error in
            value = result
            if let error { print("     js error: \(error)  in: \(script.prefix(120))") }
            done = true
        }
        _ = until(10) { done }
        return value
    }

    static func same(_ a: Any?, _ b: String) -> Bool {
        guard let a = a as? NSString else { return false }
        return a.isEqual(to: b)
    }

    static func main() {
        // A process started from a terminal is not allowed to make itself the
        // active app (macOS 14's cooperative activation), and without that its
        // window is never key: no page focus, no real ⌘Z, no input method. So
        // the binary wraps itself in an .app and has LaunchServices start it.
        if Bundle.main.bundleURL.pathExtension != "app" {
            relaunchAsApp()
        }
        setvbuf(stdout, nil, _IOLBF, 0)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = buildMenu()
        app.finishLaunching()

        pureMirror()

        window = SpikeWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        delegate.window = window
        app.delegate = delegate
        host = EditorHost(frame: window.contentView!.bounds)
        window.host = host
        host.webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(host.webView)

        // Loaded before the page is ready: the mirror must already be right.
        host.load("# Spike\n\nhello\n")
        check("mirror is right before the page is ready",
              !host.isReady && host.mirror.text == "# Spike\n\nhello\n" && !host.mirror.isDirty)

        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        _ = until(5) { NSApp.isActive && window.isKeyWindow }
        note("after launch: app active \(NSApp.isActive), key window \(window.isKeyWindow)")

        check("page reports ready", until(10) { host.isReady })
        check("queued load reached the page", until { same(js("window.imarkEditor.__spike.slice()"), "# Spike\n\nhello\n") })

        stylesUnderCSP()
        randomEdits()
        resyncHeals()
        staleGenerations()
        commandZ()
        inputMethod()

        window.close()
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    /// Builds `ImarkSpike.app` beside the binary — the binary itself, and the
    /// renderer's Resources where SchemeHandler looks for them — opens it with
    /// LaunchServices, waits, and passes its output and verdict through.
    static func relaunchAsApp() -> Never {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = repo.appendingPathComponent("Resources")
        let files = (try? fm.contentsOfDirectory(atPath: resources.path)) ?? []
        guard files.contains("editor.html"), files.contains("index.html") else {
            print("FAIL Resources/editor.html missing — run `cd renderer && npm run build` first")
            exit(1)
        }

        let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let dir = executable.deletingLastPathComponent()
        let app = dir.appendingPathComponent("ImarkSpike.app")
        let contents = app.appendingPathComponent("Contents")
        try? fm.removeItem(at: app)
        try! fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try! fm.copyItem(at: executable, to: contents.appendingPathComponent("MacOS/spike"))
        for name in files {
            try! fm.copyItem(at: resources.appendingPathComponent(name),
                             to: contents.appendingPathComponent("Resources/\(name)"))
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": "spike",
            "CFBundleIdentifier": "app.imark.spike-live-editor",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Imark Spike",
            "NSPrincipalClass": "NSApplication",
        ]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let log = dir.appendingPathComponent("spike.log")
        try? fm.removeItem(at: log)
        fm.createFile(atPath: log.path, contents: nil)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-W", "-n", "--stdout", log.path, "--stderr", log.path, app.path]
        try! open.run()
        open.waitUntilExit()

        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print(output, terminator: "")
        exit(output.hasSuffix("all good\n") ? 0 : 1)
    }

    // MARK: - The mirror on its own

    static func pureMirror() {
        print("▸ mirror, without a page")
        check("LF file", LiveMirror.lineSeparator(of: "a\nb\n") == "\n")
        check("CRLF file", LiveMirror.lineSeparator(of: "a\r\nb\r\n") == "\r\n")
        check("no break is LF", LiveMirror.lineSeparator(of: "abc") == "\n")
        check("mixed is refused", LiveMirror.lineSeparator(of: "a\r\nb\n") == nil)
        check("bare CR is refused", LiveMirror.lineSeparator(of: "a\rb") == nil)

        let m = LiveMirror()
        let g = m.load("ab\r\ncd\r\n", lineSeparator: "\r\n")
        check("CRLF loads into CM coordinates", m.mirrorText == "ab\ncd\n" && m.text == "ab\r\ncd\r\n")
        // Two changes in one transaction, both in the old document's coordinates.
        let out = m.apply(generation: g, seq: 1, length: 7, changes: [
            .init(from: 0, to: 1, insert: "X"), .init(from: 3, to: 5, insert: "中\n文"),
        ])
        check("changes apply in descending order", out == .applied && m.mirrorText == "Xb\n中\n文\n", m.mirrorText)
        check("and come out with CRLF", m.text == "Xb\r\n中\r\n文\r\n")
        check("dirty after an edit", m.isDirty)
        check("not waiting on a resync yet", !m.isAwaitingResync)
        check("a gap asks for a resync", m.apply(generation: g, seq: 3, length: 0, changes: []) == .needsResync)
        check("and further changes wait", m.apply(generation: g, seq: 4, length: 0, changes: []) == .awaitingResync)
        check("fullText heals", m.applyFullText(generation: g, seq: 4, text: "ab\ncd\n") == .applied && !m.isDirty)
        check("wrong length asks for a resync",
              m.apply(generation: g, seq: 5, length: 99, changes: [.init(from: 0, to: 0, insert: "z")]) == .needsResync)
        check("old generation is stale", m.apply(generation: g - 1, seq: 1, length: 0, changes: []) == .stale)
        let lone = NSString(characters: [0xD83D], length: 1)
        let m2 = LiveMirror()
        let g2 = m2.load("x", lineSeparator: "\n")
        _ = m2.apply(generation: g2, seq: 1, length: 2, changes: [.init(from: 1, to: 1, insert: lone)])
        check("a lone surrogate survives", (m2.mirrorText as NSString).character(at: 1) == 0xD83D)
        check("canonically equal is still dirty", {
            let m3 = LiveMirror()
            let g3 = m3.load("e\u{301}", lineSeparator: "\n")
            _ = m3.apply(generation: g3, seq: 1, length: 1, changes: [.init(from: 0, to: 2, insert: "é")])
            return m3.isDirty
        }())
    }

    // MARK: - (a)

    static func stylesUnderCSP() {
        print("▸ (a) styles under the CSP")
        let probe = js("""
            (() => {
              const ed = document.querySelector('.cm-editor'), sc = document.querySelector('.cm-scroller');
              const s = getComputedStyle(ed), t = getComputedStyle(sc);
              let evalBlocked = false; try { eval('1') } catch (e) { evalBlocked = true }
              return JSON.stringify({
                display: s.display, direction: s.flexDirection, position: s.position,
                scroller: t.display, align: t.alignItems,
                adopted: document.adoptedStyleSheets.length,
                styleTags: document.querySelectorAll('style').length,
                csp: window.__csp, evalBlocked,
                linked: [...document.styleSheets].some(x => (x.href || '').endsWith('editor.css')),
              });
            })()
            """) as? String ?? "{}"
        note(probe)
        let p = (try? JSONSerialization.jsonObject(with: Data(probe.utf8))) as? [String: Any] ?? [:]
        // None of these are set by editor.css; they come from CodeMirror's base theme.
        check("(a) .cm-editor display:flex column from the base theme",
              p["display"] as? String == "flex" && p["direction"] as? String == "column")
        check("(a) .cm-scroller display:flex, align-items:flex-start",
              p["scroller"] as? String == "flex" && p["align"] as? String == "flex-start")
        check("(a) no CSP violations", (p["csp"] as? [Any])?.isEmpty == true, "\(p["csp"] ?? "")")
        check("(a) the CSP is in force (eval blocked)", p["evalBlocked"] as? Bool == true)
        check("(a) editor.css loaded", p["linked"] as? Bool == true)
    }

    // MARK: - (b)

    static let fuzz = """
        window.__fuzz = (seed, n) => {
          let s = seed >>> 0 || 1;
          const rnd = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296 };
          const pick = a => a[Math.floor(rnd() * a.length)];
          const pieces = ['a', 'Z', ' ', '#', '**', '中', '文字', '漢字かな', '😀', '👨‍👩‍👧', '🇨🇳',
            '\\uD83D', '\\uDE00', 'é', 'e\\u0301', '\\n', '\\r\\n', '\\r', '\\t', 'x\\ny', '\\u2028', '\\uFEFF'];
          const v = imarkEditor.__spike.view;
          for (let i = 0; i < n; i++) {
            const r = rnd();
            if (r < 0.06) { imarkEditor.undo(); continue }
            if (r < 0.09) { imarkEditor.redo(); continue }
            const len = v.state.doc.length;
            const k = 1 + Math.floor(rnd() * 3);
            const pts = [];
            for (let j = 0; j < 2 * k; j++) pts.push(Math.floor(rnd() * (len + 1)));
            pts.sort((a, b) => a - b);
            const changes = [];
            for (let j = 0; j < k; j++) {
              const from = pts[2 * j];
              const to = rnd() < 0.5 ? from : pts[2 * j + 1];
              let insert = '';
              if (rnd() < 0.8) { const m = 1 + Math.floor(rnd() * 3); for (let q = 0; q < m; q++) insert += pick(pieces) }
              changes.push({ from, to, insert });
            }
            v.dispatch({ changes });
          }
          return { seq: imarkEditor.__spike.seq, slice: v.state.sliceDoc(), cm: v.state.doc.toString() };
        };
        0
        """

    static func randomEdits() {
        print("▸ (b) random edits")
        js(fuzz)
        let lf = "# Title\n\nSome *text* with 中文 and 😀.\n\n- one\n- two\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        for (name, doc, filter) in [("LF", lf, true), ("CRLF", crlf, true), ("CRLF, break filter off", crlf, false)] {
            host.load(doc)
            _ = until { same(js("window.imarkEditor.__spike.slice()"), doc) }
            js("window.imarkEditor.__spike.setBreakFilter(\(filter))")
            host.resyncs = 0
            var mismatch: String?
            var batches = 0
            for batch in 0..<30 {
                guard let r = js("window.__fuzz(\(batch * 7919 + 17), 40)") as? [String: Any],
                      let seq = (r["seq"] as? NSNumber)?.intValue,
                      let slice = r["slice"] as? NSString, let cm = r["cm"] as? NSString
                else { mismatch = "no result"; break }
                _ = until { host.mirror.seq >= seq || host.resyncs > 0 }
                batches += 1
                if host.resyncs > 0 { mismatch = "resync needed in batch \(batch)"; break }
                if !(host.mirror.text as NSString).isEqual(to: slice as String) {
                    mismatch = "batch \(batch): text != sliceDoc (\(host.mirror.text.utf16.count) vs \(slice.length))"
                    break
                }
                if !(host.mirror.mirrorText as NSString).isEqual(to: cm as String) {
                    mismatch = "batch \(batch): mirror != doc.toString()"
                    break
                }
            }
            let applied = host.outcomes.filter { $0 == .applied }.count
            if filter {
                check("(b) \(name): mirror == sliceDoc() after \(batches)×40 random edits (\(applied) messages)",
                      mismatch == nil, mismatch ?? "")
            } else {
                // Expected to diverge: shows why the break filter is there.
                note("(b) \(name): \(mismatch ?? "no divergence") — without the filter a lone \\n/\\r stays a literal in-line character")
            }
        }
        js("window.imarkEditor.__spike.setBreakFilter(true)")
    }

    static func resyncHeals() {
        print("▸ resync")
        host.load("abc\n")
        _ = until { same(js("window.imarkEditor.__spike.slice()"), "abc\n") }
        host.resyncs = 0
        host.dropNextChange = true
        js("window.imarkEditor.__spike.view.dispatch({changes: {from: 0, insert: 'lost '}})")
        js("window.imarkEditor.__spike.view.dispatch({changes: {from: 0, insert: 'next '}})")
        let healed = until { host.resyncs == 1 && !host.mirror.isAwaitingResync && host.mirror.text == "next lost abc\n" }
        check("a lost message is healed by resync", healed, "\(host.resyncs) \(host.mirror.text.debugDescription)")
        js("window.imarkEditor.__spike.view.dispatch({changes: {from: 0, insert: '>'}})")
        check("and changes carry on after it", until { host.mirror.text == ">next lost abc\n" }, host.mirror.text.debugDescription)
    }

    // MARK: - (c)

    static func staleGenerations() {
        print("▸ (c) stale generation")
        host.load("first document\n")
        _ = until { same(js("window.imarkEditor.__spike.slice()"), "first document\n") }
        let old = host.mirror.generation

        // An edit in flight while Swift switches documents: Swift has moved on
        // by the time the page's message for the old document arrives.
        host.webView.evaluateJavaScript("window.imarkEditor.__spike.view.dispatch({changes: {from: 0, insert: 'OLD '}})")
        host.load("second document\n")
        _ = until { same(js("window.imarkEditor.__spike.slice()"), "second document\n") }
        spin(0.2)
        check("(c) in-flight change for the old document is dropped",
              host.outcomes.contains(.stale) && host.mirror.text == "second document\n",
              "\(host.outcomes) \(host.mirror.text.debugDescription)")

        // A forged late message with the old generation.
        host.resyncs = 0
        js("webkit.messageHandlers.imarkEditor.postMessage({type: 'changes', generation: \(old), seq: 1, length: 99, changes: [[0, 0, 'X']]}); 0")
        spin(0.2)
        check("(c) late message with the old generation is ignored",
              host.mirror.text == "second document\n" && host.mirror.seq == 0 && host.resyncs == 0)

        js("window.imarkEditor.__spike.view.dispatch({changes: {from: 0, insert: 'new '}})")
        check("(c) the new document's changes start again at seq 1",
              until { host.mirror.seq == 1 && host.mirror.text == "new second document\n" },
              "seq \(host.mirror.seq) \(host.mirror.text.debugDescription)")
    }

    // MARK: - (d)

    static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
    }

    static func focusEditor() -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        spin(0.2)
        if !NSApp.isActive && !window.forcedKey {
            // macOS 14's cooperative activation lets the frontmost app refuse.
            window.forcedKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            note("app could not be activated; key status forced on the window")
        }
        window.makeFirstResponder(host.webView)
        js("window.imarkEditor.focus()")
        spin(0.3)
        let pageFocus = js("document.hasFocus() && window.imarkEditor.__spike.view.hasFocus") as? Bool ?? false
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        note("key window \(window.isKeyWindow), app active \(NSApp.isActive), first responder \(responder), page focus \(pageFocus)")
        return window.isKeyWindow && pageFocus
    }

    static func commandZ() {
        print("▸ (d) ⌘Z")
        for withKeymap in [false, true] {
            let label = withKeymap ? "with historyKeymap" : "without historyKeymap (the plan)"
            host.load("start\n")
            _ = until { same(js("window.imarkEditor.__spike.slice()"), "start\n") }
            js("window.imarkEditor.__spike.setHistoryKeymap(\(withKeymap))")
            js("window.imarkEditor.__spike.view.dispatch({selection: {anchor: 5}})")
            let ready = focusEditor()
            check("(d) \(label): window key and editor focused", ready)

            // Three edits typed as real keys, each in its own history group
            // (CodeMirror joins typing closer together than 500 ms).
            for (c, code) in [("a", UInt16(0)), ("b", 11), ("c", 8)] {
                key(c, code: code)
                spin(0.7)
            }
            let typed = js("window.imarkEditor.__spike.slice()") as? String ?? ""
            check("(d) \(label): real keys typed", typed == "startabc\n", typed.debugDescription)
            note("(d) \(label): WebKit undoManager.canUndo = \(host.webView.undoManager?.canUndo ?? false) before ⌘Z")

            js("""
                window.__events = [];
                window.imarkEditor.__spike.nativeHistory.length = 0;
                if (!window.__wrapped) {
                  const u = imarkEditor.undo;
                  imarkEditor.undo = () => { __events.push('menu→undo()'); u() };
                  window.__wrapped = true;
                }
                """)
            let menuBefore = window.menuUndos
            let route = keyEquivalent("z", code: 6, flags: .command)
            spin(1.0)

            let after = js("window.imarkEditor.__spike.slice()") as? String ?? ""
            let events = js("JSON.stringify(window.__events)") as? String ?? ""
            let native = js("window.imarkEditor.__spike.nativeHistory.length") as? Int ?? -1
            note("(d) \(label): route \(route); menu actions \(window.menuUndos - menuBefore), page events \(events), native historyUndo \(native)")
            check("(d) \(label): the page saw the ⌘Z keydown first", events.hasPrefix("[\"keydown:z\""), events)
            check("(d) \(label): one ⌘Z undid exactly one step", after == "startab\n", after.debugDescription)
            check("(d) \(label): WebKit's own undo did not act", native == 0 && !events.contains("beforeinput"),
                  events)
            if !withKeymap {
                check("(d) \(label): went through the menu exactly once", window.menuUndos - menuBefore == 1)
                spin(0.2)
                check("(d) \(label): mirror followed the undo", host.mirror.text == "startab\n", host.mirror.text.debugDescription)
            }
            js("window.imarkEditor.__spike.setHistoryKeymap(false)")
        }

        // The Edit menu in a stock app sends `undo:` down the responder chain,
        // and WKWebView answers it. Does that reach WebKit's contenteditable undo?
        host.load("start\n")
        _ = until { same(js("window.imarkEditor.__spike.slice()"), "start\n") }
        js("window.imarkEditor.__spike.view.dispatch({selection: {anchor: 5}})")
        _ = focusEditor()
        key("q", code: 12)
        spin(0.7)
        js("window.__events = []; window.imarkEditor.__spike.nativeHistory.length = 0")
        let responds = host.webView.responds(to: Selector(("undo:")))
        let canUndo = host.webView.undoManager?.canUndo ?? false
        // WebKit's contenteditable undo, triggered directly: what a stock Edit
        // menu, or anything else that reaches the web view's undo manager, does.
        host.webView.undoManager?.undo()
        spin(0.5)
        let afterNative = js("window.imarkEditor.__spike.slice()") as? String ?? ""
        let nativeEvents = js("JSON.stringify(window.__events)") as? String ?? ""
        note("(d) WebKit undo manager: web view responds to undo: \(responds), canUndo \(canUndo), events \(nativeEvents), text \(afterNative.debugDescription)")
        check("(d) WebKit's own undo arrives as beforeinput historyUndo", nativeEvents.contains("historyUndo"), nativeEvents)
        check("(d) and the guard cancels it: text unchanged", afterNative == "startq\n", afterNative.debugDescription)
        spin(0.2)
        check("(d) mirror unchanged too", host.mirror.text == "startq\n", host.mirror.text.debugDescription)

        // The control: is the guard doing anything, or would WebKit's undo
        // have been a no-op anyway?
        js("window.imarkEditor.__spike.guardNativeHistory = false; 0")
        host.webView.undoManager?.undo()
        spin(0.5)
        let unguarded = js("window.imarkEditor.__spike.slice()") as? String ?? ""
        spin(0.2)
        note("(d) without the guard, WebKit's undo leaves \(unguarded.debugDescription); mirror \(host.mirror.text.debugDescription)")
        js("window.imarkEditor.__spike.guardNativeHistory = true; 0")
    }

    /// A key equivalent, delivered the way NSApplication delivers one: to the
    /// key window's views first (WKWebView sends it to the page and, if the page
    /// does not take it, sends it back through NSApp), then to the main menu.
    /// When the app is active `NSApp.sendEvent` does exactly that; when it could
    /// not be activated NSApp has no key window and would skip straight to the
    /// menu, so the window's turn is given by hand.
    static func keyEquivalent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) -> String {
        let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        var route: String
        if NSApp.isActive {
            NSApp.sendEvent(down)
            route = "NSApp.sendEvent"
        } else if window.performKeyEquivalent(with: down) {
            route = "window took it"
        } else {
            let menu = NSApp.mainMenu?.performKeyEquivalent(with: down) ?? false
            route = "window declined, menu \(menu)"
        }
        NSApp.sendEvent(up)
        return route
    }

    // MARK: - (e)

    static func inputMethod() {
        print("▸ (e) IME")
        let conforms = host.webView.conforms(to: NSTextInputClient.self)
        note("(e) WKWebView conforms to NSTextInputClient: \(conforms)")
        guard conforms, let client = host.webView as? NSTextInputClient else {
            check("(e) NSTextInputClient available", false)
            return
        }
        let none = NSRange(location: NSNotFound, length: 0)

        for decorations in [false, true] {
            let label = decorations ? "with caret-dependent decorations" : "plain"
            let doc = "# 标题\n\n**粗体** 后面\n"
            host.load(doc)
            _ = until { same(js("window.imarkEditor.__spike.slice()"), doc) }
            js("window.imarkEditor.__spike.setDecorations(\(decorations))")
            // The caret at the end of the bold line: with decorations on, the
            // heading's `#` is hidden; the `**` on this line are shown.
            let caret = (doc as NSString).range(of: "后面").upperBound
            js("window.imarkEditor.__spike.view.dispatch({selection: {anchor: \(caret)}})")
            let ready = focusEditor()
            check("(e) \(label): window key and editor focused", ready)
            js("window.__composition = []")

            var composing: [Bool] = []
            var marksShown: [Bool] = []
            let shown = "document.querySelector('.cm-content').textContent.includes('**')"
            check("(e) \(label): `**` on the caret's line \(decorations ? "hidden" : "shown") before composing",
                  (js(shown) as? Bool) == !decorations)
            for (marked, sel) in [("z", 1), ("zh", 2), ("zhong", 5), ("zhong wen", 9), ("中文", 2)] {
                client.setMarkedText(marked, selectedRange: NSRange(location: sel, length: 0), replacementRange: none)
                spin(0.15)
                composing.append(js("window.imarkEditor.__spike.view.composing") as? Bool ?? false)
                marksShown.append(js(shown) as? Bool ?? true)
            }
            if decorations {
                check("(e) \(label): the hidden `**` beside the composition stayed hidden while it ran",
                      !marksShown.contains(true), "\(marksShown)")
            }
            let midText = js("window.imarkEditor.__spike.slice()") as? String ?? ""
            client.insertText("中文", replacementRange: none)
            spin(0.4)

            // Then move off the line, which flips the decorations around it.
            client.insertText("。", replacementRange: none)
            spin(0.2)
            let intoBold = (doc as NSString).range(of: "粗").location + 1
            js("window.imarkEditor.__spike.view.dispatch({selection: {anchor: \(intoBold)}})")
            spin(0.2)
            check("(e) \(label): caret into the bold shows its `**`", (js(shown) as? Bool) == true)

            let expected = doc.replacingOccurrences(of: "后面", with: "后面中文。")
            let final = js("window.imarkEditor.__spike.slice()") as? String ?? ""
            let events = js("JSON.stringify(window.__composition)") as? String ?? ""
            let stillComposing = js("window.imarkEditor.__spike.view.composing") as? Bool ?? true
            note("(e) \(label): composing samples \(composing), marked text in doc mid-way \(midText.debugDescription)")
            note("(e) \(label): events \(events)")
            check("(e) \(label): composition events fired",
                  events.contains("compositionstart") && events.contains("compositionend"), events)
            check("(e) \(label): CodeMirror saw a composition", composing.contains(true), "\(composing)")
            check("(e) \(label): document correct, nothing doubled or lost", final == expected,
                  "\(final.debugDescription) expected \(expected.debugDescription)")
            check("(e) \(label): composition ended", !stillComposing)
            spin(0.2)
            check("(e) \(label): mirror agrees", host.mirror.text == final, host.mirror.text.debugDescription)

            // One undo should take back the composed word, not a letter of the romanisation.
            js("window.imarkEditor.undo()"); spin(0.2)
            js("window.imarkEditor.undo()"); spin(0.2)
            let undone = js("window.imarkEditor.__spike.slice()") as? String ?? ""
            note("(e) \(label): after two undos \(undone.debugDescription)")
            check("(e) \(label): undo never surfaces romanisation", !undone.contains("zh"), undone.debugDescription)
            js("window.imarkEditor.__spike.setDecorations(false)")
        }

        // The commit itself moves the caret off the construct whose marks were
        // showing. Rebuilding in the same transaction would hide them under the
        // input method's last update; the plugin waits for its own timer.
        let shown = "document.querySelector('.cm-content').textContent.includes('**')"
        for quick in [false, true] {
            let label = quick ? "a second composition within 50 ms of the first commit" : "caret after a revealed bold, commit moves past it"
            let doc = "**粗**\n\nend\n"
            host.load(doc)
            _ = until { same(js("window.imarkEditor.__spike.slice()"), doc) }
            js("window.imarkEditor.__spike.setDecorations(true)")
            let caret = (doc as NSString).range(of: "**粗**").upperBound
            js("window.imarkEditor.__spike.view.dispatch({selection: {anchor: \(caret)}})")
            check("(e) \(label): window key and editor focused", focusEditor())
            spin(0.2)
            check("(e) \(label): the adjacent `**` are showing before composing", (js(shown) as? Bool) == true)

            for (marked, sel) in [("z", 1), ("zhong wen", 9), ("中文", 2)] {
                client.setMarkedText(marked, selectedRange: NSRange(location: sel, length: 0), replacementRange: none)
                spin(0.1)
            }
            client.insertText("中文", replacementRange: none)
            var expected = "**粗**中文\n\nend\n"
            if quick {
                // No pause: inside the grace period after the first commit.
                client.setMarkedText("z", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                spin(0.01)
                client.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                spin(0.01)
                client.insertText("字", replacementRange: none)
                expected = "**粗**中文字\n\nend\n"
            }
            spin(0.5)
            let final = js("window.imarkEditor.__spike.slice()") as? String ?? ""
            check("(e) \(label): text exact", final == expected, "\(final.debugDescription) expected \(expected.debugDescription)")
            check("(e) \(label): composition ended", !(js("window.imarkEditor.__spike.view.compositionStarted") as? Bool ?? true))
            check("(e) \(label): the `**` hide after catch-up", (js(shown) as? Bool) == false)
            spin(0.2)
            check("(e) \(label): mirror agrees", host.mirror.text == final, host.mirror.text.debugDescription)
            js("window.imarkEditor.__spike.setDecorations(false)")
        }
    }
}
