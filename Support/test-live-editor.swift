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
        try aTaskBoxTicksTheBufferNotTheFile()
        try aNoteIsACardUntilDoubleClicked()
        try theWidgetsOfTheReadingViewAreDrawn()
        try imagesAreFoundBesideTheDocument()
        try aTableGivesWayToItsSource()
        try theFrontMatterCardFollowsTheSwitch()
        try aMirrorCatchingUpIsNeitherSavedNorSwitched()
        linksFromTheEditorGoWhereThePreviewsGo()
        // M4
        try thePlaceSurvivesARoundTripThroughTheEditor()
        try aReloadKeepsTheCaretLine()
        try switchingStylesKeepsTheCaretLine()
        try aLargeFileIsEditedAsSource()
        try theGutterMarksTheEditedLines()
        if ProcessInfo.processInfo.environment["IMARK_TIMINGS"] != nil { timesLargeDocuments() }

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

    /// Invariant 2, for task boxes (§4, M3): a click on a box in Live is an edit
    /// to the buffer — one character, unsaved until ⌘S — and never the reading
    /// view's path, which writes the file through Comments.setTask.
    static func aTaskBoxTicksTheBufferNotTheFile() throws {
        print("▸ a task box in Live ticks the buffer, not the file")
        let original = "- [ ] one\n- [x] two\n\nend\n"
        let url = fixture(original, named: "tasks.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        let caret = { js(window, "const s = window.imarkEditor.__spike.view.state.selection.main; return [s.anchor, s.head]") as? [Int] }
        js(window, "window.imarkEditor.__spike.view.dispatch({selection: {anchor: 22}}); return 0")
        let before = caret()
        let boxes = { js(window, "return [...document.querySelectorAll('input.cm-live-task')].map((b) => b.checked)") as? [Bool] }
        check("each task item is drawn as a real checkbox", until { boxes() == [false, true] }, "\(boxes() ?? [])")

        // The events a click sends, on the box itself: the page's own handlers
        // decide what happens, as they would for the mouse.
        js(window, """
            const box = document.querySelectorAll('input.cm-live-task')[0];
            for (const type of ['mousedown', 'mouseup', 'click'])
              box.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, button: 0, detail: 1}));
            return 0
            """)
        let ticked = "- [x] one\n- [x] two\n\nend\n"
        check("the click ticks the buffer", until { window.content.editor.text == ticked }, window.content.editor.text)
        check("which is unsaved", window.content.editor.isDirty)
        spin(0.5)
        check("and the file is byte for byte what it was", bytes(url) == Data(original.utf8),
              String(decoding: bytes(url), as: UTF8.self).debugDescription)
        check("the caret stayed where it was", caret() == before, "\(caret() ?? []) vs \(before ?? [])")
        check("the box is drawn ticked", until { boxes() == [true, true] }, "\(boxes() ?? [])")

        // The reading view's task message, arriving while the buffer is open:
        // the window must not write the file under it.
        window.content.onMessage?(.task(line: 1, checked: false))
        spin(0.4)
        check("the reading view's task path does not write under a buffer", bytes(url) == Data(original.utf8))
        check("nor touch the buffer", window.content.editor.text == ticked && window.content.editor.isDirty)

        window.undoComment(nil)
        check("⌘Z takes the tick back, and the buffer is clean again",
              until { window.content.editor.text == original && !window.content.editor.isDirty }, window.content.editor.text)
        finish(window)
    }

    /// A comment block is a card in Live; a double-click shows its source.
    static func aNoteIsACardUntilDoubleClicked() throws {
        print("▸ a note in Live is a card, until a double-click")
        let original = "Before.\n\n<!-- imark by=\"reviewer\"\nTighten this.\n-->\n\nAfter.\n"
        let url = fixture(original, named: "note-card.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        let card = { js(window, "const c = document.querySelector('.cm-live-note'); return c ? c.textContent : ''") as? String }
        check("the note is drawn as a card with its author and words",
              until { (card() ?? "").contains("reviewer") && (card() ?? "").contains("Tighten this.") }, card() ?? "nil")
        js(window, """
            const c = document.querySelector('.cm-live-note');
            c.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, button: 0, detail: 1}));
            c.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, button: 0, detail: 2}));
            return 0
            """)
        check("a double-click shows the source", until { card() == "" })
        let head = js(window, "return window.imarkEditor.__spike.view.state.selection.main.head") as? Int
        check("with the caret at its start", head == 9, "\(head ?? -1)")
        js(window, "window.imarkEditor.__spike.view.dispatch({selection: {anchor: 0}}); return 0")
        check("and the card comes back when the caret leaves", until { (card() ?? "").contains("reviewer") })
        check("none of which is an edit", !window.content.editor.isDirty && bytes(url) == Data(original.utf8))

        // Backspace from the line after the card, through the page's own keymap:
        // the note goes whole, with its line break, as one undoable edit.
        js(window, """
            const view = window.imarkEditor.__spike.view;
            view.dispatch({selection: {anchor: view.state.doc.toString().indexOf('-->') + 4}});
            view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'Backspace', code: 'Backspace', keyCode: 8, bubbles: true, cancelable: true}));
            return 0
            """)
        check("Backspace beside the card deletes the note and its newline",
              until { window.content.editor.text == "Before.\n\n\nAfter.\n" }, window.content.editor.text.debugDescription)
        check("in the buffer, not the file", window.content.editor.isDirty && bytes(url) == Data(original.utf8))
        window.undoComment(nil)
        check("and one ⌘Z brings it back", until { window.content.editor.text == original && !window.content.editor.isDirty },
              window.content.editor.text.debugDescription)
        finish(window)
    }

    // MARK: - M3b: the preview's blocks, in the real web view

    static let widgetDocument = """
        ---
        title: A Title
        tags: [one, two]
        ---

        # Widgets

        | name | value |
        |------|:-----:|
        | **a** | 1 |
        | b | 2 |

        $$
        \\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}
        $$

        Inline $x^2$ and a footnote[^1] and a price of $5 or $6.

        ```mermaid
        graph TD
          A --> B
        ```

        ```diff
        - old
        + new
        ```

        [^1]: The note.

        """

    /// Tables, formulas, diagrams, diffs, footnotes and the front matter are
    /// drawn by the preview's own pipeline: real DOM, with the preview's classes,
    /// and not one byte of the document touched.
    static func theWidgetsOfTheReadingViewAreDrawn() throws {
        print("▸ tables, formulas, diagrams, diffs, footnotes and front matter in the Live editor")
        let original = widgetDocument
        let url = fixture(original, named: "widgets.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        // The caret at the very end, off every widget.
        js(window, "const v = window.imarkEditor.__spike.view; v.dispatch({selection: {anchor: v.state.doc.length}}); return 0")
        let count = { (selector: String) -> Int in
            js(window, "return document.querySelectorAll(selector).length", ["selector": selector]) as? Int ?? -1
        }
        check("the table is a real <table> with the preview's cells",
              until { count(".cm-live-md.cm-live-table table th") == 2 && count(".cm-live-md.cm-live-table table td") == 4 },
              "\(count(".cm-live-table table"))")
        check("its markup is the preview's: bold in a cell, alignment on a column",
              (js(window, "const t = document.querySelector('.cm-live-table table'); return t.querySelector('strong') !== null && /center/.test(t.innerHTML)") as? Bool) == true)
        check("a display formula is KaTeX markup", until { count(".cm-live-math .katex-display .katex") == 1 }, "\(count(".cm-live-math .katex"))")
        check("an inline formula sits in the line, and $5 or $6 is not one",
              until { count(".cm-line .cm-live-math-inline .katex") == 1 }, "\(count(".cm-live-math-inline"))")
        check("the footnote reference is a superscript with the preview's number",
              (js(window, "return document.querySelector('sup.cm-live-footnote')?.textContent") as? String) == "[1]")
        check("the front matter is the preview's card",
              (js(window, "return document.querySelector('.cm-live-frontmatter-card .fm-title')?.textContent") as? String) == "A Title"
                && count(".cm-live-frontmatter-card .fm-chip") == 2)
        check("the mermaid fence is drawn as an SVG, not left as an empty box",
              until(15) { count(".cm-live-diagram .mermaid-block.is-rendered svg") == 1 }, "\(count(".cm-live-diagram .mermaid-block"))")
        check("and sized by zoom.js's sizeDiagram",
              (js(window, "return document.querySelector('.cm-live-diagram svg')?.style.getPropertyValue('--natural-width') !== ''") as? Bool) == true)
        check("none of it is an edit", !window.content.editor.isDirty && window.content.editor.text == original
                && bytes(url) == Data(original.utf8))
        check("and the page's text is the file", samePage(window, original))

        // CodeMirror draws what is on screen; the rest of the page is below.
        let toEnd = { js(window, "const s = window.imarkEditor.__spike.view.scrollDOM; s.scrollTop = s.scrollHeight; return 0") }
        toEnd()
        check("the diff is the preview's diff block",
              until { toEnd(); return count(".cm-live-diff .diff-block .diff-add") == 1 && count(".cm-live-diff .diff-del") == 1 },
              "\(count(".cm-live-diff"))")

        // A formula KaTeX cannot read, and a diagram Mermaid cannot read: the
        // preview's error styling, and the editor goes on.
        js(window, """
            const v = window.imarkEditor.__spike.view;
            v.dispatch({changes: {from: v.state.doc.length, insert: '\\n$$\\\\frac{1}{$$\\n\\n```mermaid\\nnot a diagram at all\\n```\\n'}});
            return 0
            """)
        check("broken TeX shows the preview's error styling", until { toEnd(); return count(".cm-live-math .katex-error") == 1 }, "\(count(".katex-error"))")
        check("an invalid diagram shows the localized error box",
              until(15) { toEnd(); return count(".cm-live-diagram .diagram-error") == 1 }, "\(count(".diagram-error"))")
        finish(window)
    }

    /// An image is found where the preview finds it: beside the document.
    static func imagesAreFoundBesideTheDocument() throws {
        print("▸ images in the Live editor resolve against the document")
        // A 1x1 PNG, so that the scheme handler's answer can be told from a miss.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("pics"), withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("pics/dot.png"))
        let original = "# Pictures\n\n![a dot](pics/dot.png \"Dot\") and ![remote](https://example.com/x.png) and ![gone](pics/nothing.png)\n\nend\n"
        let url = fixture(original, named: "images.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        js(window, "const v = window.imarkEditor.__spike.view; v.dispatch({selection: {anchor: v.state.doc.length}}); return 0")
        let src = { js(window, "return document.querySelector('img.cm-live-image')?.src") as? String }
        let expected = js(window, "return 'imark://file' + (dir + '/pics/dot.png').split('/').map(encodeURIComponent).join('/')",
                          ["dir": folder.path]) as? String
        check("the image's src is the document's folder through imark://file", until { src() != nil && src() == expected },
              "\(src() ?? "nil") vs \(expected ?? "nil")")
        check("and the scheme handler serves it", until {
            (js(window, "const i = document.querySelector('img.cm-live-image'); return !!i && i.complete && i.naturalWidth === 1") as? Bool) == true
        })
        check("its alt and title are kept",
              (js(window, "const i = document.querySelector('img.cm-live-image'); return [i.alt, i.title]") as? [String]) == ["a dot", "Dot"])
        check("a remote image is not loaded: its alt text stands in, no <img>",
              until {
                  (js(window, """
                      const w = [...document.querySelectorAll('.cm-live-image-blocked')].map((e) => e.textContent);
                      return w.includes('remote') && ![...document.querySelectorAll('img')].some((i) => i.src.startsWith('http'))
                      """) as? Bool) == true
              })
        check("and so does a local file that is not there",
              until {
                  (js(window, "return [...document.querySelectorAll('.cm-live-image-blocked')].map((e) => e.textContent).includes('gone')") as? Bool) == true
              })
        check("none of it touches the document", !window.content.editor.isDirty && bytes(url) == Data(original.utf8))
        finish(window)
    }

    /// The caret coming onto a table turns it back into its lines.
    static func aTableGivesWayToItsSource() throws {
        print("▸ the caret entering a table shows its source")
        let original = "before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter\n"
        let url = fixture(original, named: "table-reveal.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        let tables = { js(window, "return document.querySelectorAll('.cm-live-table table').length") as? Int ?? -1 }
        let lines = { js(window, "return [...document.querySelectorAll('.cm-line')].map((l) => l.textContent)") as? [String] ?? [] }
        js(window, "window.imarkEditor.__spike.view.dispatch({selection: {anchor: 0}}); return 0")
        check("with the caret above, the table is drawn", until { tables() == 1 })
        check("and its pipes are not on the page", !lines().contains("| a | b |"), "\(lines())")
        let into = original.distance(from: original.startIndex, to: original.range(of: "| 1")!.lowerBound) + 4
        js(window, "window.imarkEditor.__spike.view.dispatch({selection: {anchor: pos}}); return 0", ["pos": into])
        check("the caret in a row turns the table into its lines", until { tables() == 0 && lines().contains("| a | b |") && lines().contains("|---|---|") },
              "\(lines())")
        js(window, "const v = window.imarkEditor.__spike.view; v.dispatch({selection: {anchor: v.state.doc.length}}); return 0")
        check("and it is drawn again when the caret leaves", until { tables() == 1 })
        check("moving through it changed nothing", !window.content.editor.isDirty && bytes(url) == Data(original.utf8)
                && samePage(window, original))
        finish(window)
    }

    /// View > Front Matter puts the card away in the editor as in the preview.
    static func theFrontMatterCardFollowsTheSwitch() throws {
        print("▸ the front matter card follows View > Front Matter")
        let original = "---\ntitle: Card\n---\n\nbody\n"
        let url = fixture(original, named: "front-matter-switch.md")
        Settings.showsFrontMatter = true
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        js(window, "const v = window.imarkEditor.__spike.view; v.dispatch({selection: {anchor: v.state.doc.length}}); return 0")
        let shown = { js(window, """
            const c = document.querySelector('.cm-live-frontmatter-card');
            return c ? getComputedStyle(c).display !== 'none' : false
            """) as? Bool }
        check("shown, the card is on the page", until { shown() == true })
        Settings.showsFrontMatter = false
        check("put away, it takes no room — and the attribute is the preview's", until {
            shown() == false && (js(window, "return document.documentElement.dataset.frontMatter") as? String) == "hidden"
        })
        Settings.showsFrontMatter = true
        check("and it comes back", until { shown() == true })
        check("the document is as it was", !window.content.editor.isDirty && bytes(url) == Data(original.utf8))
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

    // MARK: - M4: keeping the place

    /// Long enough to scroll, with the two things that shift a line count: front
    /// matter at the top, which the preview draws as a card with no lines of its
    /// own, and CRLF breaks. Every paragraph is one line, so a block's first line
    /// is the only line it has.
    static func longDocument(crlf: Bool = true, sections: Int = 80) -> String {
        var lines = ["---", "title: Long", "tags: [a, b]", "---", ""]
        for i in 1...sections {
            lines += ["## Section \(i)", "", "Paragraph \(i) has a few words in it, enough to read as prose.", "",
                      "- item \(i)a", "- item \(i)b", "", "Closing \(i).", ""]
        }
        return lines.joined(separator: crlf ? "\r\n" : "\n")
    }

    /// The file line (from zero) a line of `text` is on.
    static func line(of needle: String, in text: String) -> Int {
        let lines = text.components(separatedBy: text.contains("\r\n") ? "\r\n" : "\n")
        return lines.firstIndex(of: needle) ?? -1
    }

    static func previewTop(_ window: DocumentWindowController) -> Int? {
        var answer: Int?
        var done = false
        window.content.renderer.topLine { answer = $0; done = true }
        _ = until(3) { done }
        return answer
    }

    /// What the page itself has as its top line and caret line, from the last
    /// `topLine` it posted, and measured fresh.
    static func pagePlace(_ window: DocumentWindowController) -> [Int]? {
        js(window, """
            const s = window.imarkEditor.__spike, v = s.view
            const top = v.lineBlockAtHeight(v.scrollDOM.getBoundingClientRect().top + 1 - v.documentTop)
            return [s.placed.line, s.placed.caret, v.state.doc.lineAt(top.from).number - 1,
                    v.state.doc.lineAt(v.state.selection.main.head).number - 1]
            """) as? [Int]
    }

    static func thePlaceSurvivesARoundTripThroughTheEditor() throws {
        print("▸ preview → editor → preview keeps the place")
        let text = longDocument()
        let url = fixture(text, named: "place.md")
        let window = open(url)
        _ = until { (previewTop(window) ?? -1) == 0 }
        window.content.renderer.scrollTo(offset: 2_400)
        check("the preview has moved down", until { (previewTop(window) ?? 0) > 20 }, "\(previewTop(window) ?? -1)")
        let reading = previewTop(window) ?? -1

        guard startEditing(window, expecting: text) else { return check("the page has the file", false) }
        check("the editor opens with the preview's top line at its top, the caret on it",
              until { pagePlace(window) == [reading, reading, reading, reading] },
              "preview \(reading), page \(pagePlace(window) ?? [])")
        check("and Swift knows it", window.content.editor.topLine == reading && window.content.editor.caretLine == reading)

        window.toggleEditMode(nil)
        check("back in the preview, the same block is at the top",
              until { previewTop(window) == reading }, "\(previewTop(window) ?? -1) for \(reading)")

        // The other way: moved in the editor, the preview follows.
        guard startEditing(window, expecting: text) else { return check("the page has the file again", false) }
        let target = line(of: "Paragraph 47 has a few words in it, enough to read as prose.", in: text)
        _ = until { (pagePlace(window)?[2] ?? -1) == reading }
        window.content.editor.scrollTo(line: target, caret: target)
        check("the editor moved to the paragraph", until { pagePlace(window) == [target, target, target, target] },
              "\(target): \(pagePlace(window) ?? [])")
        window.toggleEditMode(nil)
        check("the preview opens on the paragraph the editor had at its top",
              until { previewTop(window) == target }, "\(previewTop(window) ?? -1) for \(target)")

        // At the very top, the front matter card: the top, both ways.
        window.content.renderer.scrollTo(line: 0)
        _ = until { previewTop(window) == 0 }
        guard startEditing(window, expecting: text) else { return check("the page has the file a third time", false) }
        check("from the top of the preview, the editor is at the top", until { pagePlace(window) == [0, 0, 0, 0] },
              "\(pagePlace(window) ?? [])")
        finish(window)

        // The source editor, where a file over the threshold always goes.
        Settings.editorStyle = .source
        defer { Settings.editorStyle = .live }
        let other = fixture(text, named: "place-source.md")
        let source = open(other)
        _ = until { (previewTop(source) ?? -1) == 0 }
        source.content.renderer.scrollTo(offset: 3_000)
        check("source: the preview has moved down", until { (previewTop(source) ?? 0) > 20 })
        let shown = previewTop(source) ?? -1
        source.toggleEditMode(nil)
        check("source: the editor opens with the preview's top line at its top, the caret on it",
              until { source.content.editor.topLine == shown && source.content.editor.caretLine == shown },
              "preview \(shown), editor \(source.content.editor.topLine), \(source.content.editor.caretLine)")
        let elsewhere = line(of: "Paragraph 21 has a few words in it, enough to read as prose.", in: text)
        source.content.editor.scrollTo(line: elsewhere, caret: elsewhere)
        source.toggleEditMode(nil)
        check("source: the preview opens on the paragraph the editor had at its top",
              until { previewTop(source) == elsewhere }, "\(previewTop(source) ?? -1) for \(elsewhere)")
        finish(source)
    }

    static func aReloadKeepsTheCaretLine() throws {
        print("▸ a reload after an outside change keeps the caret line")
        let text = longDocument()
        let url = fixture(text, named: "reload-place.md")
        let window = open(url)
        guard startEditing(window, expecting: text) else { return check("the page has the file", false) }
        let top = line(of: "## Section 30", in: text)
        let caret = top + 2
        window.content.editor.scrollTo(line: top, caret: caret)
        _ = until { pagePlace(window) == [top, caret, top, caret] }
        // Somebody else changes a line near the top; the line count stays.
        let theirs = text.replacingOccurrences(of: "Paragraph 1 has", with: "Paragraph one has")
        try theirs.write(to: url, atomically: true, encoding: .utf8)
        check("their save reached the editor", until(4) { window.content.editor.text == theirs && samePage(window, theirs) })
        check("the caret is on its line and the view on its top line",
              until { pagePlace(window) == [top, caret, top, caret] }, "\(top), \(caret): \(pagePlace(window) ?? [])")
        check("and Swift knows it", window.content.editor.caretLine == caret && window.content.editor.topLine == top)
        finish(window)

        // The source editor does the same.
        Settings.editorStyle = .source
        defer { Settings.editorStyle = .live }
        let other = fixture(text, named: "reload-place-source.md")
        let source = open(other)
        source.toggleEditMode(nil)
        _ = until { source.content.editor.text == text }
        // The preview's answer to where it was comes a moment after editing
        // starts, and moves the editor to its top line.
        spin(0.5)
        source.content.editor.scrollTo(line: top, caret: caret)
        check("source: placed", source.content.editor.caretLine == caret && source.content.editor.topLine == top,
              "\(source.content.editor.topLine), \(source.content.editor.caretLine)")
        try theirs.write(to: other, atomically: true, encoding: .utf8)
        check("source: their save reached the editor", until(4) { source.content.editor.text == theirs })
        check("source: the caret is on its line and the view on its top line",
              source.content.editor.caretLine == caret && source.content.editor.topLine == top,
              "\(source.content.editor.topLine), \(source.content.editor.caretLine)")
        finish(source)
    }

    static func switchingStylesKeepsTheCaretLine() throws {
        print("▸ ⇧⌘E keeps the caret line both ways")
        let text = longDocument()
        let url = fixture(text, named: "switch-place.md")
        let window = open(url)
        guard startEditing(window, expecting: text) else { return check("the page has the file", false) }
        let top = line(of: "## Section 40", in: text)
        window.content.editor.scrollTo(line: top, caret: top + 4)
        _ = until { pagePlace(window) == [top, top + 4, top, top + 4] }

        window.toggleEditorStyle(nil)
        check("in source", !window.content.isLiveActive)
        check("Live → source: the caret line and the top line come across",
              window.content.editor.caretLine == top + 4 && window.content.editor.topLine == top,
              "\(window.content.editor.topLine), \(window.content.editor.caretLine)")

        let back = line(of: "## Section 12", in: text)
        window.content.editor.scrollTo(line: back, caret: back + 2)
        window.toggleEditorStyle(nil)
        check("in Live", window.content.isLiveActive)
        check("source → Live: the caret line and the top line come across",
              until { pagePlace(window) == [back, back + 2, back, back + 2] }, "\(back): \(pagePlace(window) ?? [])")
        finish(window)
    }

    /// Realistic Markdown of about `bytes` bytes: headings, prose, lists, a
    /// table and a code block now and then, so the Live Preview has its usual
    /// work to do on every screen.
    static func markdown(bytes: Int) -> String {
        var out = "# A long document\n\n"
        var i = 0
        while out.utf8.count < bytes {
            i += 1
            out += "## Section \(i)\n\nSome **bold** and *italic* prose with `code` and a [link](https://example.com/\(i)) in it, long enough to wrap once or twice at the usual width of the window.\n\n"
            out += "- first item \(i)\n- second item with ==mark==\n  - nested\n\n"
            if i % 5 == 0 { out += "| a | b |\n|---|---|\n| \(i) | x |\n\n" }
            if i % 7 == 0 { out += "```swift\nlet value = \(i)\nprint(value)\n```\n\n" }
        }
        return out
    }

    static func aLargeFileIsEditedAsSource() throws {
        print("▸ a file over the threshold is edited as source")
        let text = markdown(bytes: LiveEditorView.largeFileThreshold + 4_096)
        let url = fixture(text, named: "large.md")
        let window = open(url)
        let note = NSLocalizedString("Large file · editing as source", comment: "")
        window.toggleEditMode(nil)
        check("editing, in the source editor", window.editMode && !window.content.isLiveActive
                && window.content.editor === window.content.sourceEditor && !window.content.sourceEditor.isHidden)
        check("with the note in the status bar", window.content.statusNote == note, window.content.statusNote)
        check("and the file in it", (window.content.editor.text as NSString).isEqual(to: text))
        check("no Live editor was built for it", window.content.liveEditor == nil)

        window.content.setStatus(path: url)
        window.toggleEditorStyle(nil)
        check("⇧⌘E into Live is refused", !window.content.isLiveActive && window.content.editor === window.content.sourceEditor)
        check("with the same note", window.content.statusNote == note, window.content.statusNote)
        finish(window)

        // A small file still opens in Live, and a buffer typed past the line in
        // the source editor stays there on ⇧⌘E.
        let small = fixture("small\n", named: "small.md")
        let other = open(small)
        guard startEditing(other, expecting: "small\n") else { return check("the small file opens in Live", false) }
        other.toggleEditorStyle(nil)
        other.content.sourceEditor.load(text, saved: "small\n")
        other.content.setStatus(path: small)
        other.toggleEditorStyle(nil)
        check("a buffer grown past the line stays in source", !other.content.isLiveActive)
        check("with the note", other.content.statusNote == note, other.content.statusNote)
        other.content.sourceEditor.load("small\n")
        finish(other)
    }

    static func gutterMarks(_ window: DocumentWindowController) -> [Int]? {
        js(window, "return window.imarkEditor.__spike.changedLines") as? [Int]
    }

    static func drawnMarks(_ window: DocumentWindowController) -> Int? {
        js(window, "return document.querySelectorAll('.cm-imark-changes .cm-imark-changed-bar').length") as? Int
    }

    static func theGutterMarksTheEditedLines() throws {
        print("▸ the gutter marks the lines that differ from the file")
        let original = "alpha\r\nbravo\r\ncharlie\r\ndelta\r\necho\r\n"
        let url = fixture(original, named: "gutter.md")
        let window = open(url)
        guard startEditing(window, expecting: original) else { return check("the page has the file", false) }
        check("nothing is marked in a file just opened", until { gutterMarks(window) == [] && drawnMarks(window) == 0 })

        // "bravo" → "bravo!" on line 1, and a new line after "delta".
        edit(window, from: 11, insert: "!")
        edit(window, from: 26, insert: "\nnew")
        _ = until { window.content.editor.text == "alpha\r\nbravo!\r\ncharlie\r\ndelta\r\nnew\r\necho\r\n" }
        check("exactly the edited and the inserted line are marked", until { gutterMarks(window) == [1, 4] },
              "\(gutterMarks(window) ?? [])")
        check("and two bars are drawn", until { drawnMarks(window) == 2 }, "\(drawnMarks(window) ?? -1)")
        // The source editor's look: two points of the accent at the left edge,
        // two points in from the line's top and bottom — and the text column
        // where it was, the gutter taking no room.
        let geometry = js(window, """
            const bar = document.querySelector('.cm-imark-changed-bar')
            const line = window.imarkEditor.__spike.view.domAtPos(window.imarkEditor.__spike.view.state.doc.line(2).from).node
            const row = (line.nodeType === 1 ? line : line.parentElement).closest('.cm-line').getBoundingClientRect()
            const b = bar.getBoundingClientRect()
            const scroller = document.querySelector('.cm-scroller').getBoundingClientRect()
            const content = document.querySelector('.cm-content').getBoundingClientRect()
            return [b.width, b.left - scroller.left, b.top - row.top, row.bottom - b.bottom,
                    Math.round(content.left - scroller.left), Math.round(scroller.right - content.right),
                    getComputedStyle(bar).backgroundColor === getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()
                      || getComputedStyle(bar).backgroundColor]
            """) as? [Any] ?? []
        let numbers = geometry.prefix(6).compactMap { ($0 as? NSNumber)?.doubleValue }
        check("the bar is 2 wide at the left edge, inset 2 from the line's top and bottom",
              numbers.count == 6 && numbers[0] == 2 && numbers[1] == 0 && numbers[2] == 2 && numbers[3] == 2,
              "\(geometry)")
        check("and the column is centred as it was, the gutter taking no room",
              numbers.count == 6 && abs(numbers[4] - numbers[5]) <= 1, "\(geometry)")

        window.saveDocument(nil)
        check("saved", until { !window.content.editor.isDirty })
        check("a save clears them", until { gutterMarks(window) == [] && drawnMarks(window) == 0 },
              "\(gutterMarks(window) ?? [])")

        // A buffer handed across unsaved keeps its marks: the page is told what
        // the file holds, not only what the buffer does.
        edit(window, from: 0, insert: "ALPHA ")
        _ = until { window.content.editor.isDirty }
        window.toggleEditorStyle(nil)
        window.toggleEditorStyle(nil)
        check("after ⇧⌘E there and back the edited line is still marked",
              until { window.content.isLiveActive && gutterMarks(window) == [0] && drawnMarks(window) == 1 },
              "\(gutterMarks(window) ?? [])")
        finish(window)
    }

    // MARK: - Timings (IMARK_TIMINGS=1)

    /// How long Live takes to open a large document and to take a keystroke in
    /// it, which is what `LiveEditorView.largeFileThreshold` was picked from.
    /// A bare editor in a window, so the threshold itself is not in the way.
    static func timesLargeDocuments() {
        print("▸ timings")
        for kilobytes in [512, 1_024, 5_120] {
            let megabytes = Double(kilobytes) / 1_024
            let text = markdown(bytes: kilobytes * 1_024)
            let length = (text as NSString).length
            let window = NSWindow(contentRect: NSRect(x: -6_000, y: 0, width: 900, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let live = LiveEditorView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
            window.contentView = live
            window.orderFront(nil)
            // What the window does on every edit: ask whether anything is unsaved.
            live.onEdit = { _ = live.isDirty }
            spin(1.5)
            let run = { (body: String) -> Any? in
                var value: Any?
                var done = false
                live.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                    if case .success(let v) = result { value = v }
                    done = true
                }
                _ = until(60) { done }
                return value
            }
            let start = Date()
            live.load(text)
            _ = until(60) { (run("return window.imarkEditor.__spike.view.state.doc.length") as? Int) == length }
            let loaded = Date().timeIntervalSince(start)
            // The first screen laid out, decorations and all. Forced: the frame
            // callbacks CodeMirror measures from do not run in a window nobody
            // can see.
            _ = run("const v = window.imarkEditor.__spike.view; if (v.measure) v.measure(); return 0")
            let drawn = Date().timeIntervalSince(start)

            // Fifty keystrokes in the middle, each a transaction measured in the
            // page through its DOM update and a forced measure, then the whole
            // run through to the mirror having all of them.
            let keys = 50
            let typing = Date()
            let perKey = run("""
                const v = window.imarkEditor.__spike.view
                const at = v.state.doc.line(Math.floor(v.state.doc.lines / 2)).from
                v.dispatch({ selection: { anchor: at }, effects: v.constructor.scrollIntoView(at, { y: 'center' }) })
                if (v.measure) v.measure()
                const times = []
                for (let i = 0; i < \(keys); i++) {
                    const t = performance.now()
                    v.dispatch({ changes: { from: at + i, insert: 'x' }, selection: { anchor: at + i + 1 }, userEvent: 'input.type' })
                    if (v.measure) v.measure()
                    times.push(performance.now() - t)
                }
                times.sort((a, b) => a - b)
                return [times[Math.floor(times.length / 2)], times[times.length - 1]]
                """) as? [Double] ?? []
            _ = until(60) { (live.text as NSString).length == length + keys }
            let throughMirror = Date().timeIntervalSince(typing)
            // The same keys with the Live Preview's decorations off, to tell its
            // share from CodeMirror's own.
            let plain = run("""
                const s = window.imarkEditor.__spike, v = s.view
                s.setDecorations(false)
                if (v.measure) v.measure()
                const at = v.state.selection.main.head
                const times = []
                for (let i = 0; i < \(keys); i++) {
                    const t = performance.now()
                    v.dispatch({ changes: { from: at + i, insert: 'y' }, selection: { anchor: at + i + 1 }, userEvent: 'input.type' })
                    if (v.measure) v.measure()
                    times.push(performance.now() - t)
                }
                s.setDecorations(true)
                times.sort((a, b) => a - b)
                return times[Math.floor(times.length / 2)]
                """) as? Double ?? -1
            print(String(format: "TIME %.1f MB: keystroke in page with the decorations off, median %.1f ms", megabytes, plain))
            print(String(format: "TIME %.1f MB: page has it %.0f ms, first screen %.0f ms; keystroke in page median %.1f ms, worst %.1f ms; %d keystrokes through the mirror %.0f ms (%.1f ms each)",
                         megabytes, loaded * 1000, drawn * 1000, perKey.first ?? -1, perKey.last ?? -1,
                         keys, throughMirror * 1000, throughMirror * 1000 / Double(keys)))
            window.orderOut(nil)
            window.contentView = nil
            spin(0.3)
        }
    }
}
