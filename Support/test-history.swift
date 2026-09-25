// Tests for Back and Forward, through a real window.
//
//   mkdir -p /tmp/imark-test-history && swiftc -parse-as-library -I .build/debug/Modules \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-history.swift -o /tmp/imark-test-history/run && /tmp/imark-test-history/run
//
// A folder of its own, because the renderer is put beside the executable to be
// served from there.
//
// History used to be a list of files. Following a link to a heading in the same
// document moved the page and left nothing behind, so ⌘[ skipped straight past
// the place you had just been reading to whatever file came before — and a file
// you did go Back to opened wherever the page happened to be scrolled, not where
// you left it. A link to a heading in another file did not open the file at all.
//
// Support/test-anchors.swift checks what the page reports. This checks that the
// window listens: a real document, real clicks on its links, and ⌘[ and ⌘]
// sent the way the menu sends them — along the responder chain from the view
// with focus. Calling the controller directly passed for as long as the keys
// did nothing at all: the page has focus, and the web view answers `goBack:`
// and `goForward:` itself, with a history of its own that is always empty.

import AppKit
import WebKit

@main
enum HistoryTest {
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
        .appendingPathComponent("imark-history-\(UUID().uuidString)")

    static func fixture(_ text: String, named name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Lets the run loop turn: the web view, the glide and the messages coming
    /// back from the page all answer on the main queue.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The page is served from the executable's own resources, which for the
    /// app is its Resources folder and for this test is wherever swiftc put it.
    /// So the renderer goes there first — built, as the other web-view suites
    /// expect, by `(cd renderer && node build.mjs)`.
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

        backAndForwardInsideTheDocument()

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    static func backAndForwardInsideTheDocument() {
        print("▸ a jump inside the page is a step of history, and so is a file")

        let filler = (0..<40).map { "Filler paragraph number \($0)." }.joined(separator: "\n\n")
        let a = fixture("""
        # Зміст

        - [Мій розділ](#мій-розділ)
        - [The other document](B.md)
        - [A heading in the other document](B.md#розділ-b)
        - [A heading in this one, by its file name](A.md#кінець)

        \(filler)

        ## Мій розділ

        \(filler)

        ## Кінець

        \(filler)
        """, named: "A.md")
        let b = fixture("# B\n\n\(filler)\n\n## Розділ B\n\n\(filler)\n", named: "B.md")

        let window = DocumentWindowController(url: a)
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        window.showWindow(nil)
        spin(1.2)

        guard let page = window.content.renderer.subviews.compactMap({ $0 as? WKWebView }).first else {
            return check("the renderer has a web view", false)
        }

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

        func scrollY() -> Double { (evaluate("window.scrollY") as? Double) ?? -1 }
        func near(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 3 }

        /// The first thing along the responder chain that answers `action`,
        /// which is where a menu item's action goes.
        func taker(of action: Selector) -> NSObject? {
            var responder = window.window?.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            let delegate = window.window?.delegate as? NSObject
            return delegate?.responds(to: action) == true ? delegate : nil
        }

        /// Whether the menu item would be enabled — asked of whoever takes it.
        /// The controller answers `validateMenuItem:` without declaring the
        /// protocol, which AppKit asks by selector and a cast would miss.
        func isEnabled(_ action: Selector) -> Bool {
            guard let taker = taker(of: action) else { return false }
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            if let controller = taker as? DocumentWindowController { return controller.validateMenuItem(item) }
            if let validator = taker as? NSUserInterfaceValidations {
                return validator.validateUserInterfaceItem(item)
            }
            return true
        }

        /// The key, or the menu item: nothing happens unless it is enabled.
        func press(_ action: Selector) {
            guard isEnabled(action), let taker = taker(of: action) else { return }
            _ = taker.perform(action, with: nil)
        }

        let back = #selector(DocumentWindowController.goBackInHistory(_:))
        let forward = #selector(DocumentWindowController.goForwardInHistory(_:))
        /// Where a heading the page was taken to sits: just under the toolbar.
        let inset = (evaluate("parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--top-inset')) || 0") as? Double) ?? 0
        func headingTop(_ id: String) -> Double? {
            evaluate("document.getElementById('\(id)')?.getBoundingClientRect().top") as? Double
        }

        // 0. The window opens with the page focused, and nothing to go back to.
        let focused = window.window?.firstResponder as? NSView
        check("the page has focus", focused.map { $0 === page || $0.isDescendant(of: page) } ?? false,
              String(describing: window.window?.firstResponder))
        check("the page does not take ⌘[ for itself", taker(of: back) === window,
              String(describing: taker(of: back)))
        check("the page does not take ⌘] for itself", taker(of: forward) === window,
              String(describing: taker(of: forward)))
        check("back is greyed out with nowhere to go", !isEnabled(back))
        check("so is forward", !isEnabled(forward))
        check("the toolbar stands on the page", inset > 0, "\(inset)")

        // 1. Follow the link to the Ukrainian heading. It lands under the
        //    toolbar, not behind it.
        _ = evaluate("document.querySelector('a[href^=\"#\"]').click()")
        spin(0.8)
        let section = scrollY()
        check("the link moves the page", section > 100, "\(section)")
        check("the heading shows just under the toolbar",
              headingTop("мій-розділ").map { near($0, inset + 24) } ?? false,
              "\(String(describing: headingTop("мій-розділ"))) with the toolbar at \(inset)")
        check("back is enabled after a jump", isEnabled(back))

        // 2. Back is the top of the page again, in the same document.
        press(back)
        spin(0.8)
        check("back stays in the document", window.url == a, window.url.lastPathComponent)
        check("back returns to where the link was", near(scrollY(), 0), "\(scrollY())")

        // 3. And Forward is the heading.
        press(forward)
        spin(0.8)
        check("forward returns to the heading", near(scrollY(), section), "\(scrollY()) vs \(section)")

        // 4. Read on a little, then follow a link to another file. It opens at
        //    its top, not as far down as this one was.
        _ = evaluate("window.scrollTo(0, \(section + 400))")
        spin(0.5)
        let readingAt = scrollY()
        _ = evaluate("document.querySelector('a[href$=\"B.md\"]').click()")
        spin(1.0)
        check("the link opens the other document", window.url == b, window.url.lastPathComponent)
        check("which starts at its top", near(scrollY(), 0), "\(scrollY())")

        // 5. Back to the first document, where the reading stopped.
        press(back)
        spin(1.0)
        check("back returns to the first document", window.url == a, window.url.lastPathComponent)
        check("at the place it was left", near(scrollY(), readingAt), "\(scrollY()) vs \(readingAt)")

        // 6. Back once more is the jump from before, still there underneath.
        press(back)
        spin(0.8)
        check("the earlier jump is still in the history", near(scrollY(), 0), "\(scrollY())")

        // 7. And Forward twice walks the same road the other way.
        press(forward)
        spin(0.8)
        check("forward to the place it was left", near(scrollY(), readingAt), "\(scrollY()) vs \(readingAt)")
        press(forward)
        spin(1.0)
        check("forward to the other document", window.url == b, window.url.lastPathComponent)

        // 8. A new jump in the middle of the road drops what was ahead of it.
        press(back)
        spin(1.0)
        _ = evaluate("window.imark.scrollToAnchor('кінець')")
        spin(0.8)
        let end = scrollY()
        press(forward)
        spin(0.8)
        check("a new jump clears forward", window.url == a && near(scrollY(), end), "\(window.url.lastPathComponent) at \(scrollY())")

        // 9. A link to a heading in another file opens the file at the heading,
        //    and Back is the place the link was followed from.
        _ = evaluate("window.scrollTo(0, 0)")
        spin(0.5)
        _ = evaluate("document.querySelector('a[href*=\"B.md#\"]').click()")
        spin(1.0)
        check("the heading's file opens", window.url == b, window.url.lastPathComponent)
        check("at the heading", headingTop("розділ-b").map { near($0, inset + 24) } ?? false,
              "\(String(describing: headingTop("розділ-b")))")
        press(back)
        spin(1.0)
        check("back from the heading is where the link was", window.url == a && near(scrollY(), 0),
              "\(window.url.lastPathComponent) at \(scrollY())")

        // 10. The same, naming the document already open: a jump, not a reload.
        _ = evaluate("document.querySelector('h1').dataset.untouched = 'yes'")
        _ = evaluate("document.querySelector('a[href*=\"A.md#\"]').click()")
        spin(0.8)
        check("naming this file is a jump inside it", near(scrollY(), end), "\(scrollY()) vs \(end)")
        check("without building the page again",
              (evaluate("document.querySelector('h1').dataset.untouched") as? String) == "yes")
        press(back)
        spin(0.8)
        check("and back is where it was followed from", near(scrollY(), 0), "\(scrollY())")

        window.close()
    }
}
