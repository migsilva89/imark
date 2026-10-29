// Tests for task lists — `- [ ]` and `- [x]` — through a real window.
//
//   TEST_BIN="$(swift build --show-bin-path)"
//   mkdir -p /tmp/imark-test-tasks
//   swiftc -parse-as-library -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-tasks.swift -o /tmp/imark-test-tasks/run && /tmp/imark-test-tasks/run
//
// A folder of its own, because the renderer is put beside the executable to be
// served from there.
//
// Issue #64. An agent hands over a document with two options as checkboxes, the
// reader ticks one and sends the file back. The tick was drawn and never
// written: it lived in the page alone, and the next render — a reload, a new
// comment — took it away again. A click on the item's words ticked the box as
// well, and the `+` for a comment sat on top of the box, so with the pointer on
// the item the box could not be reached at all.
//
// A tick is a write to somebody's file, so most of this is about which line it
// lands on and that nothing else in the file moves by a byte.

import AppKit
import WebKit

@main
enum TaskTest {
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
        .appendingPathComponent("imark-tasks-\(UUID().uuidString)")

    static func fixture(_ text: String, named name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The page is served from the executable's own resources, which for the
    /// app is its Resources folder and for this test is wherever swiftc put it.
    static func stageRenderer() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let built = repo.appendingPathComponent("Resources")
        guard let beside = Bundle.main.resourceURL else { return }
        for name in ["index.html", "bundle.js", "bundle.css"] {
            let target = beside.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: built.appendingPathComponent(name), to: target)
        }
    }

    static func main() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stageRenderer()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        theBoxOnALine()
        aTickNeedsTheFileItWasDrawnFrom()
        aTickIsWrittenToTheFile()
        everyBoxFindsItsOwnLine()
        aBoxTheDocumentWroteIsNotBelieved()
        theWordsDoNotTickTheBox()
        thePlusLeavesTheBoxAlone()
        quickLookOffersNoBoxes()

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Driving a window

    struct Opened {
        let window: DocumentWindowController
        let page: WKWebView

        /// Runs a line of script in the page and waits for what it returns.
        func evaluate(_ script: String) -> Any? {
            var result: Any?
            var done = false
            page.evaluateJavaScript(script) { value, _ in
                result = value
                done = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !done, Date() < deadline { spin(0.02) }
            return result
        }

        /// The checkboxes on the page, in reading order, as ticked or not.
        func boxes() -> [Bool] {
            let raw = evaluate("""
            JSON.stringify([...document.querySelectorAll('.task-list-item-checkbox')].map((b) => b.checked))
            """) as? String ?? "[]"
            return (try? JSONDecoder().decode([Bool].self, from: Data(raw.utf8))) ?? []
        }

        /// A press on the box itself, the way a pointer presses it.
        func click(box index: Int) {
            _ = evaluate("document.querySelectorAll('.task-list-item-checkbox')[\(index)].click(); true")
            // The write, the reload it causes, and the render after it.
            spin(0.7)
        }

        func close() {
            window.close()
            spin(0.3)
        }
    }

    static func open(_ url: URL) -> Opened? {
        let window = DocumentWindowController(url: url)
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        window.showWindow(nil)
        spin(1.0)
        guard let page = window.content.renderer.subviews.compactMap({ $0 as? WKWebView }).first else {
            check("the renderer has a web view", false)
            return nil
        }
        return Opened(window: window, page: page)
    }

    // MARK: - The bug

    /// The one the issue is about: tick a box, and the file says so.
    static func aTickIsWrittenToTheFile() {
        print("▸ a tick is written to the file")
        let url = fixture("""
        **2. AGENTS.md split.**
        - [ ] Keep wip's split
        - [ ] Drop the split
        """, named: "issue.md")
        guard let opened = open(url) else { return }
        check("two boxes, neither ticked", opened.boxes() == [false, false], "\(opened.boxes())")

        opened.click(box: 0)
        check("the file has the tick", read(url) == """
        **2. AGENTS.md split.**
        - [x] Keep wip's split
        - [ ] Drop the split
        """, read(url))

        opened.window.reloadDocument(nil)
        spin(0.6)
        check("and the tick survives a reload", opened.boxes() == [true, false], "\(opened.boxes())")

        opened.click(box: 0)
        check("a second press takes it off again", read(url).contains("- [ ] Keep wip's split"), read(url))
        opened.close()
    }

    // MARK: - Which character moves

    /// One line at a time, with no window: what counts as a box, and that only
    /// the character between the brackets ever changes.
    static func theBoxOnALine() {
        print("▸ the box on a line")
        let cases: [(String, Bool, String?)] = [
            ("- [ ] a", true, "- [x] a"),
            ("- [x] a", false, "- [ ] a"),
            ("- [X] a", false, "- [ ] a"),
            ("* [ ] a", true, "* [x] a"),
            ("+ [ ] a", true, "+ [x] a"),
            ("1. [ ] a", true, "1. [x] a"),
            ("12) [x] a", false, "12) [ ] a"),
            ("   - [ ] three in", true, "   - [x] three in"),
            ("\t- [ ] tabbed", true, "\t- [x] tabbed"),
            ("-\t[ ] tab after the marker", true, "-\t[x] tab after the marker"),
            ("> - [ ] quoted", true, "> - [x] quoted"),
            ("> > 1. [ ] twice quoted", true, "> > 1. [x] twice quoted"),
            ("  [ ] under a marker on its own", true, "  [x] under a marker on its own"),
            ("- [ ] crlf\r", true, "- [x] crlf\r"),
            ("- [ ] see [ ] here", true, "- [x] see [ ] here"),
            ("- [ ] café 🎉", true, "- [x] café 🎉"),
            // Already that way: nothing to write, and the caller is told.
            ("- [x] a", true, nil),
            ("- [ ] a", false, nil),
            // Not boxes, the same way the renderer does not draw them.
            ("- [ ]", true, nil),
            ("- [ ]\tno space", true, nil),
            ("- [y] a", true, nil),
            ("Some text - [ ] a", true, nil),
            ("- a [ ] later", true, nil),
        ]
        for (line, checked, expected) in cases {
            let got = Comments.task(line, checked: checked)
            check("\(line.debugDescription) → \(checked ? "x" : "_")", got == expected,
                  "got \(got.debugDescription)")
        }
    }

    /// The same refusals as a comment: a file that moved since it was read, a
    /// line that is no longer a box, a box inside a code fence.
    static func aTickNeedsTheFileItWasDrawnFrom() {
        print("▸ a tick needs the file it was drawn from")
        let text = "- [ ] a\n\n```\n- [ ] fenced\n```\n"
        let url = fixture(text, named: "refusals.md")
        let stale = Comments.Stamp(of: url)
        Thread.sleep(forTimeInterval: 1.1)
        try! (text + "Somebody else's line.\n").write(to: url, atomically: true, encoding: .utf8)

        var error: Error?
        do { try Comments.setTask(line: 0, checked: true, in: url, expecting: stale) } catch let e { error = e }
        check("a file that moved is not written", error as? Comments.Failure == .fileChanged,
              "\(String(describing: error))")
        check("and is left exactly as they wrote it", read(url) == text + "Somebody else's line.\n")

        let fresh = Comments.Stamp(of: url)
        error = nil
        do { try Comments.setTask(line: 3, checked: true, in: url, expecting: fresh) } catch let e { error = e }
        check("a box in a code fence is never written", error as? Comments.Failure == .notATask,
              "\(String(describing: error))")
        error = nil
        do { try Comments.setTask(line: 1, checked: true, in: url, expecting: fresh) } catch let e { error = e }
        check("nor a line that holds no box", error as? Comments.Failure == .notATask)
        error = nil
        do { try Comments.setTask(line: 99, checked: true, in: url, expecting: fresh) } catch let e { error = e }
        check("nor a line past the end", error as? Comments.Failure == .notATask)
        error = nil
        do { try Comments.setTask(line: 0, checked: false, in: url, expecting: fresh) } catch let e { error = e }
        check("nor a box already the way it was asked to be", error as? Comments.Failure == .notATask)
        check("the file is untouched by all of it", read(url) == text + "Somebody else's line.\n")
    }

    // MARK: - Which line a box is

    /// Every box pressed in turn, each against the whole file: the right line
    /// changes, by one character, and nothing else in the file moves.
    static func everyBoxFindsItsOwnLine() {
        print("▸ every box finds its own line")
        typealias Press = (box: Int, file: String)
        let cases: [(name: String, file: String, presses: [Press])] = [
            ("line endings from Windows",
             "# T\r\n\r\n- [ ] a\r\n- [x] b\r\n",
             [(0, "# T\r\n\r\n- [x] a\r\n- [x] b\r\n"),
              (1, "# T\r\n\r\n- [x] a\r\n- [ ] b\r\n")]),
            ("every kind of marker",
             "* [ ] star\n\n+ [ ] plus\n\n1. [ ] one\n2. [X] two\n\n3) [ ] paren\n\n-\t[ ] tab\n",
             [(0, "* [x] star\n\n+ [ ] plus\n\n1. [ ] one\n2. [X] two\n\n3) [ ] paren\n\n-\t[ ] tab\n"),
              (1, "* [x] star\n\n+ [x] plus\n\n1. [ ] one\n2. [X] two\n\n3) [ ] paren\n\n-\t[ ] tab\n"),
              (3, "* [x] star\n\n+ [x] plus\n\n1. [ ] one\n2. [ ] two\n\n3) [ ] paren\n\n-\t[ ] tab\n"),
              (4, "* [x] star\n\n+ [x] plus\n\n1. [ ] one\n2. [ ] two\n\n3) [x] paren\n\n-\t[ ] tab\n"),
              (5, "* [x] star\n\n+ [x] plus\n\n1. [ ] one\n2. [ ] two\n\n3) [x] paren\n\n-\t[x] tab\n")]),
            ("nested items",
             "- [ ] parent\n  - [ ] child\n    - [x] grandchild\n- [ ] sibling\n",
             [(1, "- [ ] parent\n  - [x] child\n    - [x] grandchild\n- [ ] sibling\n"),
              (2, "- [ ] parent\n  - [x] child\n    - [ ] grandchild\n- [ ] sibling\n"),
              (0, "- [x] parent\n  - [x] child\n    - [ ] grandchild\n- [ ] sibling\n"),
              (3, "- [x] parent\n  - [x] child\n    - [ ] grandchild\n- [x] sibling\n")]),
            ("inside a quote",
             "> Pick one:\n>\n> - [ ] quoted\n> - [x] done\n>   - [ ] nested in the quote\n",
             [(0, "> Pick one:\n>\n> - [x] quoted\n> - [x] done\n>   - [ ] nested in the quote\n"),
              (1, "> Pick one:\n>\n> - [x] quoted\n> - [ ] done\n>   - [ ] nested in the quote\n"),
              (2, "> Pick one:\n>\n> - [x] quoted\n> - [ ] done\n>   - [x] nested in the quote\n")]),
            ("boxes in code are left alone",
             "```\n- [ ] fenced\n```\n\n~~~~md\n- [x] tilde\n~~~~\n\n    - [ ] indented code\n\n- [ ] real\n",
             [(0, "```\n- [ ] fenced\n```\n\n~~~~md\n- [x] tilde\n~~~~\n\n    - [ ] indented code\n\n- [x] real\n")]),
            ("front matter and notes above and beside",
             "---\ntitle: Choices\n---\n\n<!-- imark at=\"2026-01-01T00:00:00Z\"\nA note above.\n-->\n\n"
                + "- [ ] first\n- [ ] second\n\n<!-- imark quote=\"second\" at=\"2026-01-01T00:00:00Z\"\n"
                + "About the second.\n-->\n\n- [ ] after the note\n",
             [(1, "---\ntitle: Choices\n---\n\n<!-- imark at=\"2026-01-01T00:00:00Z\"\nA note above.\n-->\n\n"
                + "- [ ] first\n- [x] second\n\n<!-- imark quote=\"second\" at=\"2026-01-01T00:00:00Z\"\n"
                + "About the second.\n-->\n\n- [ ] after the note\n"),
              (2, "---\ntitle: Choices\n---\n\n<!-- imark at=\"2026-01-01T00:00:00Z\"\nA note above.\n-->\n\n"
                + "- [ ] first\n- [x] second\n\n<!-- imark quote=\"second\" at=\"2026-01-01T00:00:00Z\"\n"
                + "About the second.\n-->\n\n- [x] after the note\n")]),
            ("loose items, a lone marker, wide gaps, no newline at the end",
             "- [ ] loose\n\n  more text\n\n- [ ] next\n\n-\n  [ ] marker alone\n\n1.  [ ] wide gap\n\n"
                + "- [ ] café 🎉 with [ ] inside  ",
             [(2, "- [ ] loose\n\n  more text\n\n- [ ] next\n\n-\n  [x] marker alone\n\n1.  [ ] wide gap\n\n"
                + "- [ ] café 🎉 with [ ] inside  "),
              (3, "- [ ] loose\n\n  more text\n\n- [ ] next\n\n-\n  [x] marker alone\n\n1.  [x] wide gap\n\n"
                + "- [ ] café 🎉 with [ ] inside  "),
              (4, "- [ ] loose\n\n  more text\n\n- [ ] next\n\n-\n  [x] marker alone\n\n1.  [x] wide gap\n\n"
                + "- [x] café 🎉 with [ ] inside  "),
              (1, "- [ ] loose\n\n  more text\n\n- [x] next\n\n-\n  [x] marker alone\n\n1.  [x] wide gap\n\n"
                + "- [x] café 🎉 with [ ] inside  ")]),
            ("a byte order mark",
             "\u{FEFF}# T\n\n- [ ] a\n",
             [(0, "\u{FEFF}# T\n\n- [x] a\n")]),
        ]

        for (index, item) in cases.enumerated() {
            let url = fixture(item.file, named: "map-\(index).md")
            guard let opened = open(url) else { continue }
            for press in item.presses {
                opened.click(box: press.box)
                let now = try! Data(contentsOf: url)
                check("\(item.name): box \(press.box)", now == Data(press.file.utf8),
                      "\n  file: \(read(url).debugDescription)\n  want: \(press.file.debugDescription)")
            }
            opened.close()
        }
    }

    /// The document may carry HTML of its own, and an <input> it wrote that
    /// looks like a box, line and all, must not be able to change the file.
    static func aBoxTheDocumentWroteIsNotBelieved() {
        print("▸ a box the document wrote is not believed")
        let text = """
        <ul><li class="task-list-item" data-line="4,5"><input class="task-list-item-checkbox" \
        type="checkbox" data-task="guess:4"> forged</li></ul>

        Real:

        - [ ] real
        """
        let url = fixture(text, named: "forged.md")
        guard let opened = open(url) else { return }
        opened.click(box: 0)
        check("the forged box wrote nothing", read(url) == text, read(url))
        opened.click(box: 1)
        check("the real one still does", read(url) == text.replacingOccurrences(of: "- [ ] real", with: "- [x] real"),
              read(url))
        opened.close()
    }

    // MARK: - Pointing at an item

    /// Only the box ticks. The words are for reading, selecting and commenting.
    static func theWordsDoNotTickTheBox() {
        print("▸ the words do not tick the box")
        let text = "- [ ] Keep wip's split\n- [ ] Drop the split\n"
        let url = fixture(text, named: "words.md")
        guard let opened = open(url) else { return }
        let hit = opened.evaluate("""
        (() => {
          const item = document.querySelector('.task-list-item')
          const walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT)
          let words = walker.nextNode()
          while (words && !words.textContent.trim()) words = walker.nextNode()
          const range = document.createRange()
          range.selectNodeContents(words)
          const box = range.getBoundingClientRect()
          const under = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
          under.click()
          return under.tagName
        })()
        """) as? String
        spin(0.7)
        check("a click lands on the words", hit != nil && hit != "INPUT", "\(hit ?? "nothing")")
        check("and leaves the box as it was", opened.boxes() == [false, false], "\(opened.boxes())")
        check("and the file as it was", read(url) == text, read(url))
        check("no <label> wraps the words",
              (opened.evaluate("document.querySelectorAll('.task-list-item label').length") as? Int) == 0)
        opened.close()
    }

    /// With the pointer on an item, the `+` for a comment used to be drawn right
    /// on top of its box.
    static func thePlusLeavesTheBoxAlone() {
        print("▸ the + leaves the box alone")
        let url = fixture("# Choices\n\n- [ ] Keep wip's split\n  - [ ] A nested one\n- [ ] Drop the split\n",
                          named: "plus.md")
        guard let opened = open(url) else { return }
        for index in 0..<3 {
            let raw = opened.evaluate("""
            (() => {
              const item = document.querySelectorAll('.task-list-item')[\(index)]
              const box = item.querySelector('input')
              const rect = item.getBoundingClientRect()
              document.dispatchEvent(new MouseEvent('mousemove', {
                bubbles: true, clientX: rect.left + 60, clientY: box.getBoundingClientRect().top + 4,
              }))
              item.dispatchEvent(new MouseEvent('mousemove', {
                bubbles: true, clientX: rect.left + 60, clientY: box.getBoundingClientRect().top + 4,
              }))
              const plus = document.querySelector('.block-plus')
              const p = plus.getBoundingClientRect()
              const b = box.getBoundingClientRect()
              const middle = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2)
              return JSON.stringify({
                shown: plus.style.display !== 'none',
                apart: p.right <= b.left || p.left >= b.right || p.bottom <= b.top || p.top >= b.bottom,
                reachable: middle === box,
                lit: item.classList.contains('block-target'),
              })
            })()
            """) as? String ?? "{}"
            let found = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Bool] ?? [:]
            check("item \(index): the + is offered for it", found["shown"] == true && found["lit"] == true, raw)
            check("item \(index): the + is not over the box", found["apart"] == true, raw)
            check("item \(index): the box is what a press there finds", found["reachable"] == true, raw)
        }
        opened.close()
    }

    // MARK: - Quick Look

    /// The preview panel cannot write to anything, so its boxes are drawn and
    /// not offered.
    static func quickLookOffersNoBoxes() {
        print("▸ Quick Look offers no boxes")
        let renderer = RendererView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = renderer
        window.orderFrontRegardless()
        var asked = false
        renderer.onMessage = { if case .task = $0 { asked = true } }
        renderer.setPreviewMode()
        renderer.render(markdown: "- [ ] open\n- [x] done\n", path: folder.appendingPathComponent("ql.md").path)
        spin(1.2)
        guard let page = renderer.subviews.compactMap({ $0 as? WKWebView }).first else {
            return check("the preview has a web view", false)
        }
        var result: String?
        page.evaluateJavaScript("""
        (() => {
          const boxes = [...document.querySelectorAll('.task-list-item-checkbox')]
          boxes.forEach((b) => b.click())
          return JSON.stringify(boxes.map((b) => [b.disabled, b.checked]))
        })()
        """) { value, _ in result = value as? String }
        let deadline = Date().addingTimeInterval(5)
        while result == nil, Date() < deadline { spin(0.02) }
        spin(0.3)
        check("both boxes are drawn, disabled, as the file has them",
              result == "[[true,false],[true,true]]", result ?? "nothing")
        check("and pressing them asks for nothing", !asked)
        window.orderOut(nil)
    }
}
