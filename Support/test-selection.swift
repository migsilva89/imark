// ⌘C while the row of actions is up over a selection, through a real window.
//
//   TEST_BIN="$(swift build --show-bin-path)"
//   mkdir -p /tmp/imark-test-selection && swiftc -parse-as-library \
//     -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-selection.swift -o /tmp/imark-test-selection/run \
//     && /tmp/imark-test-selection/run
//
// A folder of its own, because the renderer is put beside the executable to be
// served from there.
//
// The row leaves copying to ⌘C, and with Keyboard navigation turned on ⌘C beeped:
// the popover handed the document window's focus to its first button, the web
// view dropped out of the responder chain, and nothing was left to answer
// `copy:`. The selection is made in the page, the row comes up the way it does
// for a hand, and `copy:` goes up the chain from the window's first responder,
// the way the Copy menu item sends it.

import AppKit
import WebKit

@main
enum SelectionTest {
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
        .appendingPathComponent("imark-selection-\(UUID().uuidString)")

    /// Lets the run loop turn: the page's messages and the pasteboard written
    /// on the web view's behalf all arrive on the main queue.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func waitFor(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { spin(0.02) }
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

        // What decides whether a button can take the keyboard at all. It is read
        // from the system and cannot be set for one process, so with it off the
        // cases pass with or without the fix.
        if !app.isFullKeyboardAccessEnabled {
            print("note: Keyboard navigation is off in System Settings › Keyboard, and the bug needs it on")
        }

        try copyingWithTheRowUp(commenting: true)
        try copyingWithTheRowUp(commenting: false)

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Helpers

    struct Opened {
        let controller: DocumentWindowController
        let window: NSWindow
        let page: WKWebView
    }

    static func open(commenting: Bool) throws -> Opened? {
        // The argument domain wins over anything saved and is never written to
        // disk, so the case leaves no setting behind.
        UserDefaults.standard.setVolatileDomain(
            ["showsCommentingControls": commenting], forName: UserDefaults.argumentDomain
        )
        let url = folder.appendingPathComponent("words-\(UUID().uuidString).md")
        try "# Words\n\nSome words worth copying out of a paragraph.\n\nAnother paragraph to select.\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let controller = DocumentWindowController(url: url)
        controller.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        controller.showWindow(nil)
        spin(1.5)

        guard let window = controller.window,
              let page = controller.content.renderer.subviews.compactMap({ $0 as? WKWebView }).first
        else {
            check("the window has a web view", false)
            return nil
        }
        // Where a click in the text leaves the keyboard.
        window.makeFirstResponder(page)
        return Opened(controller: controller, window: window, page: page)
    }

    /// Selects one paragraph of the page, the way a drag across it would, and
    /// waits for the row. Returns what the page says is selected.
    @discardableResult
    static func select(paragraph: Int, in opened: Opened) -> String? {
        var selected: String?
        opened.page.evaluateJavaScript("""
        (() => {
          const range = document.createRange()
          range.selectNodeContents(document.querySelectorAll('#content p')[\(paragraph)])
          getSelection().removeAllRanges()
          getSelection().addRange(range)
          return getSelection().toString()
        })()
        """) { value, _ in selected = value as? String }
        waitFor(3) { selected != nil && !row(besides: opened.window).isEmpty }
        return selected
    }

    /// The buttons of the row, found by what they say rather than where they
    /// are: the popover's window is AppKit's own.
    static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    static func row(besides document: NSWindow) -> [NSButton] {
        for window in NSApp.windows where window !== document && window.isVisible {
            guard let content = window.contentView else { continue }
            let found = buttons(in: content)
            if found.contains(where: { $0.toolTip == "Translate" }) { return found }
        }
        return []
    }

    static func holder(of window: NSWindow) -> String {
        guard let responder = window.firstResponder else { return "nothing" }
        if let button = responder as? NSButton { return "the \(button.toolTip ?? button.title) button" }
        return String(describing: type(of: responder))
    }

    /// The pasteboard is the one the person running the suite copies to, so
    /// whatever was on it goes back when the case is done.
    static func keepingThePasteboard(_ body: (NSPasteboard) -> Void) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let kept = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { kept.setData(data, forType: type) }
            }
            return kept
        }
        defer {
            board.clearContents()
            board.writeObjects(saved)
        }
        body(board)
    }

    /// Sends `copy:` the way the Copy menu item does and returns what landed on
    /// the pasteboard.
    static func copyFromFirstResponder(of window: NSWindow) -> (handled: Bool, copied: String) {
        var result = (handled: false, copied: "")
        keepingThePasteboard { board in
            board.clearContents()
            board.setString("left over", forType: .string)
            let before = board.changeCount
            result.handled = window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) ?? false
            waitFor(3) { board.changeCount != before }
            result.copied = board.string(forType: .string) ?? ""
        }
        return result
    }

    // MARK: - Cases

    static func copyingWithTheRowUp(commenting: Bool) throws {
        print("▸ ⌘C copies with the row up, commenting \(commenting ? "on" : "off")")
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        guard let opened = try open(commenting: commenting) else { return }
        defer { opened.controller.close() }

        let selected = select(paragraph: 0, in: opened)
        let shown = row(besides: opened.window).compactMap(\.toolTip)
        check("the words are selected in the page", selected?.contains("Some words worth copying") == true,
              "selected \(selected ?? "nothing")")
        check("the row is up over them", shown.first == (commenting ? "Comment" : "Translate"),
              "row \(shown)")
        check("the page keeps the keyboard", opened.window.firstResponder === opened.page,
              "it went to \(holder(of: opened.window))")

        let copy = copyFromFirstResponder(of: opened.window)
        check("something in the chain answers copy:", copy.handled)
        check("⌘C puts the words on the pasteboard", copy.copied.contains("Some words worth copying"),
              "pasteboard \(copy.copied.debugDescription)")
    }
}
