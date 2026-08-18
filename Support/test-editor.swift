// Tests for the half of the app that writes a whole document.
//
//   swiftc -parse-as-library -I .build/debug/Modules \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-editor.swift -o /tmp/imark-test-editor && /tmp/imark-test-editor
//
// Comments edit a range of lines and check the file first. The editor replaces the
// whole thing, which makes it the second place in Imark where a mistake costs
// somebody a document rather than a comment — and it had one: reloading the page
// after an outside save moved the mark that says how the file looked, while the
// buffer kept text from minutes earlier. The next ⌘S passed the staleness check
// and wrote the stale document over the other person's work.
//
// Most of it goes through a real window, because the model was never wrong on its
// own; the wiring was.

import AppKit

@main
enum EditorTest {
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
        .appendingPathComponent("imark-editor-\(UUID().uuidString)")

    static func fixture(_ text: String, named name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
    }

    /// Lets the run loop turn: the watcher, the web view and the sheets all answer
    /// on the main queue, and a test that never yields sees none of it.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        countingLines()
        modifiedLines()
        try theEditorFollowsTheFile()
        try aSaveWillNotLandOnSomebodyElsesWork()
        try typingIsUndoneByTyping()

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - The gutter's numbers

    /// The line the caret is on has to be counted the way the numbers beside it
    /// are drawn. Counting `\n` characters looks equivalent and is not: Swift reads
    /// `\r\n` as one character that is not a newline, so on a file saved by a
    /// Windows editor the caret lit a line further off with every break it passed.
    static func countingLines() {
        print("▸ counting lines")
        let unix = "one\ntwo\nthree\n" as NSString
        check("first line", LineGutter.lineNumber(at: 0, in: unix) == 1)
        check("second line", LineGutter.lineNumber(at: 4, in: unix) == 2)
        check("third line", LineGutter.lineNumber(at: 8, in: unix) == 3)
        check("past the end clamps", LineGutter.lineNumber(at: 9_999, in: unix) == 4,
              "\(LineGutter.lineNumber(at: 9_999, in: unix))")

        let windows = "one\r\ntwo\r\nthree\r\n" as NSString
        check("a CRLF break counts once",
              LineGutter.lineNumber(at: 5, in: windows) == 2,
              "\(LineGutter.lineNumber(at: 5, in: windows))")
        check("and again on the next one",
              LineGutter.lineNumber(at: 10, in: windows) == 3,
              "\(LineGutter.lineNumber(at: 10, in: windows))")

        check("an empty document is on line one",
              LineGutter.lineNumber(at: 0, in: "" as NSString) == 1)
    }

    /// The bars in the gutter are a diff, not a positional compare: one inserted
    /// line used to flag everything below it, which drowned the signal.
    static func modifiedLines() {
        print("▸ modified lines")
        let disk = "a\nb\nc\n"
        check("nothing changed, nothing marked",
              MarkdownEditorView.modifiedLines(current: disk, original: disk).isEmpty)
        check("one line retyped marks one line",
              MarkdownEditorView.modifiedLines(current: "a\nB\nc\n", original: disk) == [2],
              "\(MarkdownEditorView.modifiedLines(current: "a\nB\nc\n", original: disk))")
        check("a line inserted at the top does not mark the rest",
              MarkdownEditorView.modifiedLines(current: "new\na\nb\nc\n", original: disk) == [1],
              "\(MarkdownEditorView.modifiedLines(current: "new\na\nb\nc\n", original: disk))")
    }

    // MARK: - Through the window that people actually use

    /// The text view inside the editor, found the way somebody clicking into it
    /// finds it. Driving the real view rather than a seam cut into the class keeps
    /// the test honest about what typing does.
    static func buffer(of window: DocumentWindowController) -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            for child in view.subviews { if let hit = find(child) { return hit } }
            return nil
        }
        guard let root = window.window?.contentView else { return nil }
        return find(root)
    }

    static func type(_ text: String, into window: DocumentWindowController) {
        guard let view = buffer(of: window) else { return check("found the buffer", false) }
        view.string = text
        // Setting a string is not typing, and only typing tells the delegate.
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: view)
    }

    static func open(_ url: URL) -> DocumentWindowController {
        let window = DocumentWindowController(url: url)
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        window.showWindow(nil)
        spin(0.8)
        return window
    }

    /// With nothing unsaved, the editor is a reader too: somebody else's save has
    /// to land in it, or the next ⌘S writes a document from before their edit.
    static func theEditorFollowsTheFile() throws {
        print("▸ the editor follows the file")
        let url = fixture("# One\n\nOriginal.\n", named: "follows.md")
        let window = open(url)
        window.toggleEditMode(nil)
        spin(0.5)
        check("the editor opened on the file", window.content.editor.text.contains("Original."),
              window.content.editor.text)

        try "# One\n\nTheirs, saved elsewhere.\n".write(to: url, atomically: true, encoding: .utf8)
        spin(1.6)
        check("their save arrived in the buffer",
              window.content.editor.text.contains("Theirs, saved elsewhere."),
              window.content.editor.text)
        check("and nothing counts as unsaved", !window.content.editor.isDirty)
        window.close()
        spin(0.3)
    }

    /// The bug this suite exists for.
    static func aSaveWillNotLandOnSomebodyElsesWork() throws {
        print("▸ a save will not land on somebody else's work")
        let url = fixture("# Two\n\nMine to edit.\n", named: "race.md")
        let window = open(url)
        window.toggleEditMode(nil)
        spin(0.5)

        type("# Two\n\nMine to edit, with my change.\n", into: window)
        spin(0.3)
        check("the window knows it has something unsaved", window.content.editor.isDirty)

        let theirs = "# Two\n\nTheir work, which must survive.\n"
        try theirs.write(to: url, atomically: true, encoding: .utf8)
        spin(1.6)
        check("their save did not wipe the buffer",
              window.content.editor.text.contains("with my change"),
              window.content.editor.text)

        window.saveDocument(nil)
        spin(0.6)
        check("the save was refused and their work is intact", read(url) == theirs,
              read(url))
        check("and the text typed here is still on screen",
              window.content.editor.text.contains("with my change"))
        window.close()
        spin(0.3)
    }

    /// ⌘Z while the file is open as text means the typing, not the app's own undo
    /// stack — which puts whole documents back and would throw away everything
    /// since the last save.
    static func typingIsUndoneByTyping() throws {
        print("▸ typing is undone by typing")
        let url = fixture("# Three\n\nAs it was.\n", named: "undo.md")
        let before = read(url)
        let window = open(url)
        window.toggleEditMode(nil)
        spin(0.5)

        guard let view = buffer(of: window) else { return check("found the buffer", false) }
        // Through the text view's own editing, so its undo manager records it.
        view.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        spin(0.3)
        check("the buffer has the typing", window.content.editor.text.hasPrefix("typed"),
              String(window.content.editor.text.prefix(20)))

        window.undoComment(nil)
        spin(0.4)
        check("undo took the typing back", !window.content.editor.text.hasPrefix("typed"),
              String(window.content.editor.text.prefix(20)))
        check("and the file was never touched", read(url) == before)
        window.close()
        spin(0.3)
    }
}
