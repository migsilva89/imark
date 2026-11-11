// Tests for the Live editor (docs/LIVE-PREVIEW.md §7, M1), through the window
// people actually use: DocumentWindowController, its ContentViewController and
// the CodeMirror page in a real WKWebView, mirrored into Swift.
//
//   (cd renderer && npm run build)
//   swift build
//   TEST_BIN="$(swift build --show-bin-path)"
//   mkdir -p /tmp/imark-test-live
//   swiftc -parse-as-library -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-live-editor.swift -o /tmp/imark-test-live/run && /tmp/imark-test-live/run
//
// The binary copies the renderer's Resources next to itself first: that is where
// SchemeHandler and `LiveEditorView.isAvailable` look, and without editor.html
// every window would quietly edit in the source editor instead. Fixtures live in
// a temporary folder, never in the repository's testdata.
//
// Nothing here needs the app to be frontmost: the page is driven through
// `imarkEditor.__spike`, which the page only exposes because
// `LiveEditorView.exposesTestHooks` is set before any window is built.

import AppKit
import WebKit

@main
enum LiveEditorTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)  \(detail())")
        }
    }

    static let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("imark-live-editor-\(UUID().uuidString)")

    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            spin(0.05)
        }
        return condition()
    }

    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        installResources()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        LiveEditorView.exposesTestHooks = true
        Settings.editorStyle = .live

        check("the editor page is in this build", LiveEditorView.isAvailable)
        guard LiveEditorView.isAvailable else { exit(1) }

        mirrorBaselines()
        try opensLazilyInLive()
        try roundTrips()
        try mixedBreaksFallBack()
        try aStaleBufferIsRefused()
        try theEditorFollowsTheFile()
        try menuUndoIsTheEditors()
        try aRecomposedLetterIsAnEdit()
        try commandSSavesOnce()
        try aSaveMessageIsAFallback()
        try aCrashKeepsTheBuffer()
        try switchingStylesKeepsTheBuffer()
        try findGoesToTheEditor()
        try theEditorTakesTheSettings()
        try noCommentIsWrittenUnderABuffer()
        try aMirrorCatchingUpIsNeitherSavedNorSwitched()
        linksFromTheEditorGoWhereThePreviewsGo()

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    /// Resources/ from the repository, beside the binary, which is where a
    /// non-bundled executable's `Bundle.main` looks for its resources.
    static func installResources() {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = repo.appendingPathComponent("Resources")
        let here = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: resources.path)) ?? [] {
            let target = here.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: resources.appendingPathComponent(name), to: target)
        }
    }

    // MARK: - Driving a window

    static func open(_ url: URL) -> DocumentWindowController {
        let window = DocumentWindowController(url: url)
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        window.showWindow(nil)
        spin(0.8)
        return window
    }

    static func write(_ bytes: Data, named name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! bytes.write(to: url)
        return url
    }

    static func fixture(_ text: String, named name: String) -> URL {
        write(Data(text.utf8), named: name)
    }

    static func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    /// Runs `body` as an async function in the page and waits for what it returns.
    @discardableResult
    static func js(_ window: DocumentWindowController, _ body: String, _ arguments: [String: Any] = [:]) -> Any? {
        guard let web = window.content.liveEditor?.webView else { return nil }
        var value: Any?
        var done = false
        web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .success(let v) = result { value = v }
            done = true
        }
        _ = until(5) { done }
        return value
    }

    /// The text CodeMirror would save, in the file's own line breaks.
    static func pageText(_ window: DocumentWindowController) -> String? {
        js(window, "return window.imarkEditor.__spike.slice()") as? String
    }

    static func samePage(_ window: DocumentWindowController, _ expected: String) -> Bool {
        guard let page = pageText(window) else { return false }
        return (page as NSString).isEqual(to: expected)
    }

    /// Edits as CodeMirror would after a keystroke: a transaction, which the page
    /// reports to Swift as `changes`.
    static func edit(_ window: DocumentWindowController, from: Int, to: Int? = nil, insert: String) {
        js(window, "window.imarkEditor.__spike.view.dispatch({changes: {from, to: to ?? from, insert}, userEvent: 'input.type'}); return 0",
           ["from": from, "to": to ?? NSNull(), "insert": insert])
    }

    static func startEditing(_ window: DocumentWindowController, expecting text: String) -> Bool {
        window.toggleEditMode(nil)
        return until(10) { samePage(window, text) }
    }

    static func finish(_ window: DocumentWindowController) {
        // Nothing unsaved is left behind, so closing asks no question.
        if window.content.editor.isDirty {
            window.content.editor.load(window.content.editor.savedText)
        }
        window.close()
        spin(0.3)
    }

    // MARK: - The mirror's new entry points

    /// A buffer handed over from the source editor carries what the file holds
    /// as well. Under CRLF the mirror folds breaks, and folding a file that is
    /// not pure CRLF could make a different file look like the buffer.
    static func mirrorBaselines() {
        print("▸ the mirror's saved baseline")
        let m = LiveMirror()
        m.load("a\r\nb\r\n", lineSeparator: "\r\n", saved: "a\r\nb\r\n")
        check("same text, same breaks: clean", !m.isDirty)
        m.load("a\r\nb\r\n", lineSeparator: "\r\n", saved: "a\nb\r\n")
        check("a saved file with a lone \\n is never the CRLF buffer", m.isDirty)
        m.load("a\r\nb\r\n", lineSeparator: "\r\n", saved: "a\nb\n")
        check("nor is an LF file", m.isDirty)
        m.load("a\r\nb\r\n", lineSeparator: "\r\n", saved: "a\r\nc\r\n")
        check("a different CRLF file is unsaved", m.isDirty && m.savedText == "a\r\nc\r\n")
        m.markSaved()
        check("until it is saved", !m.isDirty && m.savedText == "a\r\nb\r\n")

        let generation = m.generation
        let fresh = m.restart()
        check("restart starts a generation and keeps the buffer",
              fresh == generation + 1 && m.seq == 0 && m.text == "a\r\nb\r\n" && !m.isDirty)
    }

    // MARK: - Opening

    static func opensLazilyInLive() throws {
        print("▸ the Live editor is built on first use")
        let url = fixture("# One\n\nOriginal.\n", named: "lazy.md")
        let window = open(url)
        check("a reading window has no Live editor", window.content.liveEditor == nil)
        check("the page has the file", startEditing(window, expecting: "# One\n\nOriginal.\n"),
              pageText(window) ?? "nil")
        check("editing built it and put it on screen",
              window.content.isLiveActive && window.content.liveEditor?.isHidden == false
                && window.content.sourceEditor.isHidden)
        check("the mirror is the file and nothing is unsaved",
              window.content.editor.text == "# One\n\nOriginal.\n" && !window.content.editor.isDirty)
        check("the test hooks are only there because this test asked",
              js(window, "return typeof window.imarkEditor.__spike") as? String == "object")
        finish(window)
    }

    /// Invariant 1: a file comes back from a save as it was, but for the change —
    /// breaks, mark, tabs, trailing spaces, a missing last newline.
    static func roundTrips() throws {
        print("▸ load → edit → save keeps every other byte")
        let mark = Data([0xEF, 0xBB, 0xBF])
        let cases: [(String, Data, String)] = [
            ("lf", Data("# LF\n\n\tTabbed  \nlast line, no newline".utf8), "\n"),
            ("crlf", Data("# CRLF\r\n\r\n\tTabbed  \r\nlast\r\n".utf8), "\r\n"),
            ("bom-crlf", mark + Data("# BOM\r\n\r\nbody\r\n".utf8), "\r\n"),
            ("bom-lf", mark + Data("# BOM\n\nbody\n".utf8), "\n"),
        ]
        for (name, original, separator) in cases {
            let url = write(original, named: "\(name).md")
            let window = open(url)
            let hasMark = original.prefix(3) == mark
            let text = String(decoding: hasMark ? original.dropFirst(3) : original[...], as: UTF8.self)
            guard startEditing(window, expecting: text) else {
                check("\(name): the page has the file", false, pageText(window) ?? "nil")
                finish(window)
                continue
            }
            check("\(name): opened in Live", window.content.isLiveActive)

            // An insert and a delete that cancel out: back to clean, nothing to save.
            edit(window, from: 0, insert: "x")
            _ = until { window.content.editor.isDirty }
            edit(window, from: 0, to: 1, insert: "")
            check("\(name): an edit taken back is not unsaved", until { !window.content.editor.isDirty })
            window.saveDocument(nil)
            spin(0.3)
            check("\(name): and a save then leaves the file alone", bytes(url) == original)

            // Typed with a plain `\n`, as CodeMirror's own Enter does in the
            // document's coordinates; the file gets its own break.
            edit(window, from: 0, insert: "Added\n")
            _ = until { window.content.editor.isDirty }
            window.saveDocument(nil)
            spin(0.5)
            let expected = (hasMark ? mark : Data()) + Data(("Added" + separator + text).utf8)
            check("\(name): the save is the file plus the edit, in its own breaks", bytes(url) == expected,
                  "\(String(decoding: bytes(url), as: UTF8.self).debugDescription)")
            check("\(name): and is clean afterwards", !window.content.editor.isDirty)
            finish(window)
        }
    }

    static func mixedBreaksFallBack() throws {
        print("▸ a file Live cannot write back goes to the source editor")
        for (name, text) in [("mixed", "a\r\nb\nc\n"), ("bare-cr", "a\rb\r")] {
            let url = fixture(text, named: "\(name).md")
            let window = open(url)
            window.toggleEditMode(nil)
            spin(0.5)
            check("\(name): editing in source", window.editMode && !window.content.isLiveActive
                    && window.content.editor === window.content.sourceEditor)
            check("\(name): with the file in it", (window.content.editor.text as NSString).isEqual(to: text))
            finish(window)
        }
    }

    // MARK: - The data-safety rules

    /// The bug test-editor.swift exists for, in the Live editor.
    static func aStaleBufferIsRefused() throws {
        print("▸ a save will not land on somebody else's work")
        let url = fixture("# Two\n\nMine to edit.\n", named: "race.md")
        let window = open(url)
        guard startEditing(window, expecting: "# Two\n\nMine to edit.\n") else {
            return check("the page has the file", false)
        }
        edit(window, from: 0, insert: "Mine: ")
        check("the window knows it has something unsaved", until { window.content.editor.isDirty })

        let theirs = "# Two\n\nTheir work, which must survive.\n"
        try theirs.write(to: url, atomically: true, encoding: .utf8)
        spin(1.6)
        check("their save did not wipe the buffer", window.content.editor.text.hasPrefix("Mine: "),
              window.content.editor.text)
        window.saveDocument(nil)
        spin(0.6)
        check("the save was refused and their work is intact",
              (try? String(contentsOf: url, encoding: .utf8)) == theirs)
        check("and the edit is still in the buffer", window.content.editor.text.hasPrefix("Mine: "))
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        finish(window)
    }

    static func theEditorFollowsTheFile() throws {
        print("▸ the editor follows the file while nothing is unsaved")
        let url = fixture("one\n", named: "follows.md")
        let window = open(url)
        guard startEditing(window, expecting: "one\n") else { return check("the page has the file", false) }
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        check("their save reached the mirror and the page",
              until(4) { window.content.editor.text == "theirs\n" && samePage(window, "theirs\n") },
              window.content.editor.text)
        check("and nothing is unsaved", !window.content.editor.isDirty)
        // A change from the document before is stale and does not land.
        edit(window, from: 0, insert: ">")
        check("an edit after the reload is mirrored", until { window.content.editor.text == ">theirs\n" },
              window.content.editor.text)
        finish(window)
    }

    static func menuUndoIsTheEditors() throws {
        print("▸ ⌘Z in the menu undoes the typing")
        let url = fixture("start\n", named: "undo.md")
        let window = open(url)
        guard startEditing(window, expecting: "start\n") else { return check("the page has the file", false) }
        edit(window, from: 5, insert: " typed")
        check("the menu can undo once the page says so",
              until { window.content.editor.canUndo && window.content.editor.isDirty })
        window.undoComment(nil)
        check("undo took it back", until { window.content.editor.text == "start\n" && !window.content.editor.isDirty },
              window.content.editor.text)
        check("redo is offered", until { window.content.editor.canRedo })
        window.redoTyping(nil)
        check("and redo puts it back", until { window.content.editor.text == "start typed\n" })
        check("the file was never touched", (try? String(contentsOf: url, encoding: .utf8)) == "start\n")
        finish(window)
    }

    static func aRecomposedLetterIsAnEdit() throws {
        print("▸ a recomposed letter is an edit")
        let url = fixture("Cafe\u{301}\n", named: "recomposed.md")
        let window = open(url)
        guard startEditing(window, expecting: "Cafe\u{301}\n") else { return check("the page has the file", false) }
        edit(window, from: 3, to: 5, insert: "\u{E9}")
        check("one code point for two counts as unsaved", until { window.content.editor.isDirty })
        window.saveDocument(nil)
        spin(0.5)
        check("and the save writes it", bytes(url) == Data("Caf\u{E9}\n".utf8), "\(Array(bytes(url)))")
        finish(window)
    }

    /// ⌘S belongs to the page: keys reach it in order and its `save` comes back
    /// behind the `changes` of everything typed first. Taken in Swift from the
    /// event, a save could run before the last keystroke reached the mirror.
    static func commandSSavesOnce() throws {
        print("▸ ⌘S saves once, after what was typed before it")
        let url = fixture("keys\n", named: "keys.md")
        let window = open(url)
        guard startEditing(window, expecting: "keys\n"), let host = window.window,
              let web = window.content.liveEditor?.webView else {
            return check("the page has the file", false)
        }
        host.makeFirstResponder(web)
        js(window, "window.imarkEditor.focus(); return 0")

        func commandS() {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: host.windowNumber, context: nil, characters: "s",
                charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
            )!
            // As NSApplication would: the window's views first, then the menu
            // if nobody took it. The page answers asynchronously, so WebKit
            // takes the key for now and hands it back later if the page did not.
            if !host.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
        }

        // An edit still on its way to Swift when ⌘S goes down: fired, not awaited.
        web.callAsyncJavaScript("window.imarkEditor.__spike.view.dispatch({changes: {from: 0, insert: 's'}, userEvent: 'input.type'})",
                                arguments: [:], in: nil, in: .page, completionHandler: nil)
        commandS()
        check("the save has the edit typed just before it", until(3) { bytes(url) == Data("skeys\n".utf8) },
              String(decoding: bytes(url), as: UTF8.self).debugDescription)
        spin(0.3)
        check("and nothing is left unsaved", !window.content.editor.isDirty)

        // Once, not twice: a refused save says so in one sheet.
        edit(window, from: 0, insert: "t")
        _ = until { window.content.editor.isDirty }
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        spin(1.6)
        commandS()
        _ = until(3) { host.attachedSheet != nil }
        check("a stale buffer is refused", host.attachedSheet != nil && bytes(url) == Data("theirs\n".utf8))
        if let sheet = host.attachedSheet { host.endSheet(sheet) }
        spin(0.8)
        check("in one sheet, not two", host.attachedSheet == nil)
        if let sheet = host.attachedSheet { host.endSheet(sheet) }
        finish(window)
    }

    static func aSaveMessageIsAFallback() throws {
        print("▸ the page's save message saves")
        let url = fixture("fallback\n", named: "fallback.md")
        let window = open(url)
        guard startEditing(window, expecting: "fallback\n") else { return check("the page has the file", false) }
        edit(window, from: 0, insert: "1 ")
        _ = until { window.content.editor.isDirty }
        // One from a document that has since been replaced says nothing.
        js(window, "webkit.messageHandlers.imarkEditor.postMessage({type: 'save', generation: -1}); return 0")
        spin(0.4)
        check("a stale save message is ignored", bytes(url) == Data("fallback\n".utf8))
        js(window, "webkit.messageHandlers.imarkEditor.postMessage({type: 'save', generation: \(currentGeneration(window))}); return 0")
        check("a current one saves", until { bytes(url) == Data("1 fallback\n".utf8) })
        finish(window)
    }

    /// The generation the page is on, which every message it sends carries.
    static func currentGeneration(_ window: DocumentWindowController) -> Int {
        (js(window, "return window.imarkEditor.__spike.generation") as? Int) ?? -1
    }

    /// §3.2: the mirror outlives the page. Kill the web content process, and the
    /// page comes back with the buffer, still unsaved, still editable.
    static func aCrashKeepsTheBuffer() throws {
        print("▸ a dead web process keeps the buffer")
        let url = fixture("before the crash\n", named: "crash.md")
        let window = open(url)
        guard startEditing(window, expecting: "before the crash\n"),
              let web = window.content.liveEditor?.webView else { return check("the page has the file", false) }
        edit(window, from: 0, insert: "unsaved, ")
        _ = until { window.content.editor.isDirty }

        let kill = NSSelectorFromString("_killWebContentProcess")
        guard web.responds(to: kill) else {
            check("this WebKit can be told to kill its process", false)
            return finish(window)
        }
        web.perform(kill)
        check("the page came back with the buffer",
              until(10) { samePage(window, "unsaved, before the crash\n") }, pageText(window) ?? "nil")
        check("and it is still unsaved", window.content.editor.isDirty)
        edit(window, from: 0, insert: "and ")
        check("an edit after the restart is mirrored",
              until { window.content.editor.text == "and unsaved, before the crash\n" }, window.content.editor.text)
        window.saveDocument(nil)
        spin(0.5)
        check("and saves", bytes(url) == Data("and unsaved, before the crash\n".utf8))
        finish(window)
    }

    static func switchingStylesKeepsTheBuffer() throws {
        print("▸ ⇧⌘E keeps the buffer and what is unsaved")
        let original = "line one\r\nline two\r\n"
        let url = fixture(original, named: "switch.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        edit(window, from: 0, insert: "edited ")
        _ = until { window.content.editor.isDirty }

        window.toggleEditorStyle(nil)
        check("now in source", !window.content.isLiveActive && window.content.liveEditor?.isHidden == true
                && !window.content.sourceEditor.isHidden)
        check("with the buffer, breaks and all",
              (window.content.editor.text as NSString).isEqual(to: "edited line one\r\nline two\r\n"))
        check("still unsaved", window.content.editor.isDirty)

        window.toggleEditorStyle(nil)
        check("back in Live", window.content.isLiveActive)
        check("the page has the buffer", until { samePage(window, "edited line one\r\nline two\r\n") })
        check("and it is still unsaved", window.content.editor.isDirty)

        // The source editor's Return types a bare `\n`, which a CRLF buffer
        // cannot take back to Live.
        window.toggleEditorStyle(nil)
        window.content.sourceEditor.load("edited line one\r\nline two\nthree", saved: original)
        window.toggleEditorStyle(nil)
        check("a buffer with mixed breaks stays in source", !window.content.isLiveActive)
        check("unchanged", window.content.editor.text == "edited line one\r\nline two\nthree")

        // The way back is the same, clean or not: saving still writes what is there.
        window.content.sourceEditor.load("edited line one\r\nline two\r\n", saved: original)
        window.toggleEditorStyle(nil)
        _ = until { samePage(window, "edited line one\r\nline two\r\n") }
        window.saveDocument(nil)
        spin(0.5)
        check("a save after two switches writes the buffer",
              bytes(url) == Data("edited line one\r\nline two\r\n".utf8))
        finish(window)
    }

    static func findGoesToTheEditor() throws {
        print("▸ the find bar searches the Live editor")
        let url = fixture("alpha needle beta\nNeedle gamma\n", named: "find.md")
        let window = open(url)
        guard startEditing(window, expecting: "alpha needle beta\nNeedle gamma\n") else {
            return check("the page has the file", false)
        }
        window.performFind(nil)
        window.content.showFind(with: "needle")
        check("both matches are marked, ignoring case",
              until { (js(window, "return document.querySelectorAll('.cm-imark-match').length") as? Int) == 2 })
        window.findNext(nil)
        let selection = { js(window, "const s = window.imarkEditor.__spike.view.state.selection.main; return [s.from, s.to]") as? [Int] }
        check("Find Next selects the next match", until { selection() == [18, 24] }, "\(selection() ?? [])")
        window.content.closeFind()
        check("closing the bar clears the marks",
              until { (js(window, "return document.querySelectorAll('.cm-imark-match').length") as? Int) == 0 })
        finish(window)
    }

    /// The preview's palette, width and text size, from the same settings, and
    /// following them when they change.
    static func theEditorTakesTheSettings() throws {
        print("▸ the editor wears the preview's settings")
        Settings.palette = .warm
        Settings.width = .wide
        Settings.textScale = 18
        let url = fixture("settings\n", named: "settings.md")
        let window = open(url)
        guard startEditing(window, expecting: "settings\n") else { return check("the page has the file", false) }
        let read = {
            js(window, """
                const r = document.documentElement;
                return [r.dataset.theme ?? '', r.dataset.width ?? '', r.style.getPropertyValue('--size-body'),
                        getComputedStyle(document.querySelector('.cm-scroller')).fontSize]
                """) as? [String] ?? []
        }
        let dark = window.content.liveEditor!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let face = Settings.Palette.warm.face(dark: dark)
        check("palette, width and size arrive with the document",
              until { read() == [face, "wide", "18px", "18px"] }, "\(read())")
        Settings.textScale = 21
        Settings.width = .narrow
        check("and follow the settings when they change",
              until { read() == [face, "narrow", "21px", "21px"] }, "\(read())")
        Settings.palette = .classic
        Settings.width = .normal
        Settings.textScale = Settings.defaultTextScale
        finish(window)
    }

    /// Invariant 2: with a buffer open, nothing writes the file but ⌘S.
    static func noCommentIsWrittenUnderABuffer() throws {
        print("▸ no comment is written under an open buffer")
        let url = fixture("text\n", named: "comment.md")
        let window = open(url)
        guard startEditing(window, expecting: "text\n") else { return check("the page has the file", false) }
        window.composingFileNote = true
        window.saveComment("a note", colour: .standard)
        spin(0.3)
        check("the file is untouched", bytes(url) == Data("text\n".utf8))
        finish(window)
    }

    /// While the mirror waits for the page's `fullText` after a seq mismatch its
    /// ⌘-click in the Live editor reaches the same messages the preview's links
    /// do. A link to the document being edited goes nowhere: the preview that
    /// would scroll is hidden, and opening the file again would leave edit mode.
    static func linksFromTheEditorGoWhereThePreviewsGo() {
        print("▸ links from the editor")
        let doc = URL(fileURLWithPath: "/tmp/imark-links/notes/this.md")
        func message(_ link: LiveEditorView.Link) -> RendererMessage? {
            DocumentWindowController.liveLinkMessage(link, from: doc)
        }
        if case .openLocal(let path, let anchor)? = message(.href("other.md#Some%20Heading")) {
            check("a relative link resolves beside the document, anchor kept encoded",
                  path == "/tmp/imark-links/notes/other.md" && anchor == "Some%20Heading", path)
        } else { check("a relative link opens a local file", false) }
        if case .openLocal(let path, _)? = message(.href("../up/a%20b.md?plain=1")) {
            check("dots, percent-encoding and a query are handled", path == "/tmp/imark-links/up/a b.md", path)
        } else { check("a parent-folder link opens a local file", false) }
        if case .openExternal(let url)? = message(.href("https://example.com/a")) {
            check("a URL goes out as external", url.absoluteString == "https://example.com/a")
        } else { check("a URL is external", false) }
        if case .openExternal(let url)? = message(.href("mailto:me@x.co")) {
            check("mailto goes out as external", url.scheme == "mailto")
        } else { check("mailto is external", false) }
        if case .openWiki(let name)? = message(.wiki("Page")) {
            check("a wikilink asks for its target", name == "Page")
        } else { check("a wikilink opens a wiki target", false) }
        check("a link to the open document goes nowhere", message(.href("this.md")) == nil)
        check("a link to a heading in the open document goes nowhere", message(.href("./this.md#h")) == nil)
        check("a link to a heading in this page goes nowhere", message(.href("#h")) == nil)
    }

    /// text is missing the latest edits: writing it, or handing it to the other
    /// editor, would lose them. Both refuse until the reply lands.
    static func aMirrorCatchingUpIsNeitherSavedNorSwitched() throws {
        print("▸ a mirror waiting for a resync is neither saved nor switched")
        let url = fixture("catching up\n", named: "resync.md")
        let window = open(url)
        guard startEditing(window, expecting: "catching up\n") else { return check("the page has the file", false) }
        edit(window, from: 0, insert: "edited ")
        let edited = "edited catching up\n"
        check("the mirror has the edit", until { window.content.editor.text == edited && window.content.editor.isDirty })
        check("and is current", window.content.editor.textIsCurrent)

        // The page's reply is held back, so the mirror stays where the real code
        // leaves it after a gap: out of step and waiting. A `changes` message with
        // a seq from the future goes in through the page's own channel.
        js(window, "window.__realResync = window.imarkEditor.resync; window.imarkEditor.resync = () => {}; return 0")
        js(window, "webkit.messageHandlers.imarkEditor.postMessage({type: 'changes', generation, seq: 99, length: 0, changes: []}); return 0",
           ["generation": currentGeneration(window)])
        check("a gap in the sequence puts the mirror to waiting",
              until { !window.content.editor.textIsCurrent })

        window.saveDocument(nil)
        _ = until(3) { window.window?.attachedSheet != nil }
        check("a save is refused with a sheet", window.window?.attachedSheet != nil)
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        spin(0.3)
        check("the file is untouched", bytes(url) == Data("catching up\n".utf8))
        check("and the buffer is still unsaved", window.content.editor.isDirty)

        window.toggleEditorStyle(nil)
        check("⇧⌘E leaves the Live editor active", window.content.isLiveActive
                && window.content.liveEditor?.isHidden == false && window.content.sourceEditor.isHidden)
        check("with the buffer as it was", window.content.editor.text == edited && window.content.editor.isDirty)

        js(window, "window.imarkEditor.resync = window.__realResync; window.imarkEditor.resync(); return 0")
        check("the page's text lands and the mirror is current",
              until { window.content.editor.textIsCurrent })
        check("with the edit in it", window.content.editor.text == edited, window.content.editor.text)
        window.saveDocument(nil)
        check("a save now writes the full edited text", until { bytes(url) == Data(edited.utf8) },
              String(decoding: bytes(url), as: UTF8.self).debugDescription)
        check("and nothing is left unsaved", until { !window.content.editor.isDirty })
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        finish(window)
    }
}
