// Tests for taking a comment back.
//
//   swiftc -parse-as-library $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//          $(find Sources/ImarkRender -name '*.swift') \
//          Support/test-undo.swift -o /tmp/imark-test-undo && /tmp/imark-test-undo
//
// Undo is the only thing in Imark that writes a whole file at once. Everything
// else edits a range of lines and checks the file first. That makes it the one
// place where a mistake costs somebody a document rather than a comment, and it
// had two: the snapshot went back to whichever file the window happened to be
// showing, and it went back over an outside edit without a word.
//
// Most of it exercises the stack directly, which is where the rules live. The
// last case goes the whole way through a real window — a real comment, a real
// navigation, the real selector ⌘Z fires — because a correct model wired up
// wrongly is still a lost document.

import AppKit

@main
struct TestUndo {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    // A file per test, in its own directory, so nothing leaks between them.
    static func fixture(_ text: String, named: String = "DOC.md") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imark-undo-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(named)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
    }

    /// What the window does: snapshot, write, and seal the entry with what the
    /// file looks like once the change has landed.
    static func record(_ stack: inout UndoStack, _ what: String, on url: URL, change: () -> Void) {
        stack.push(text: read(url), what: what, url: url, stamp: nil)
        change()
        stack.stampLast(Comments.Stamp(of: url))
    }

    /// What ⌘Z does — the real path the window calls.
    static func undo(_ stack: inout UndoStack) throws -> Bool {
        try stack.undoLast() != nil
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        do {
            try theOrdinaryCases()
            try theStackItself()
            try theFileItGoesBackTo()
            try theFileChangingUnderneath()
            try theWholeWayThroughTheWindow()
        } catch {
            failures += 1
            print("FAIL threw: \(error)")
        }

        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Writing, editing and deleting all come back the same way

    static func theOrdinaryCases() throws {
        print("▸ a change comes back exactly as it was")

        for what in ["Comment", "Edit Comment", "Delete Comment"] {
            let original = "# Doc\n\nA paragraph.\n"
            let url = fixture(original)
            var stack = UndoStack()

            record(&stack, what, on: url) {
                try? "# Doc\n\nA paragraph.\n\n<!-- imark quote=\"paragraph\" by=\"m\" at=\"2026-08-10T09:00Z\"\nA note.\n-->\n"
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            check("\(what.lowercased()) changed the file", read(url) != original)

            _ = try undo(&stack)
            check("undoing \(what.lowercased()) puts it back byte for byte", read(url) == original,
                  String(read(url).prefix(60)))
        }

        print("▸ two changes undo newest first")
        let url = fixture("one\n")
        var stack = UndoStack()
        record(&stack, "Comment", on: url) { try? "two\n".write(to: url, atomically: true, encoding: .utf8) }
        record(&stack, "Comment", on: url) { try? "three\n".write(to: url, atomically: true, encoding: .utf8) }
        _ = try undo(&stack)
        check("the first undo goes back one step", read(url) == "two\n", read(url))
        _ = try undo(&stack)
        check("the second goes back to the start", read(url) == "one\n", read(url))
    }

    // MARK: - The stack's own rules

    static func theStackItself() throws {
        print("▸ the stack")

        var empty = UndoStack()
        check("an empty stack has nothing to undo", empty.isEmpty)
        check("and undoing it does nothing at all", try undo(&empty) == false)

        let url = fixture("x\n")
        var stack = UndoStack()
        for i in 0..<15 {
            stack.push(text: "\(i)", what: "Comment", url: url, stamp: nil)
        }
        check("the stack stops at ten", stack.last?.what == "Comment")
        var counted = 0
        while stack.pop() != nil { counted += 1 }
        check("keeping the ten newest", counted == UndoStack.limit, "kept \(counted)")

        var failed = UndoStack()
        failed.push(text: "before", what: "Comment", url: url, stamp: nil)
        failed.discardLast()
        check("a change that failed to write leaves nothing to undo", failed.isEmpty)

        var named = UndoStack()
        named.push(text: "before", what: "Delete Comment", url: url, stamp: nil)
        check("the menu can name the action", named.last?.what == "Delete Comment")
    }

    // MARK: - Which file the text goes back to

    static func theFileItGoesBackTo() throws {
        print("▸ the snapshot goes back to its own file, not the one on screen")

        // A window outlives the document in it: comment on A, follow a link to
        // B, press ⌘Z. Before this was fixed, A's whole text landed on B.
        let a = fixture("# A\n\nThe first document.\n", named: "A.md")
        let b = fixture("# B\n\nThe second document, which must survive.\n", named: "B.md")
        let bBefore = read(b)

        var stack = UndoStack()
        record(&stack, "Comment", on: a) {
            try? "# A\n\nThe first document.\n\n<!-- imark quote=\"first\" by=\"m\" at=\"2026-08-10T09:00Z\"\nA note.\n-->\n"
                .write(to: a, atomically: true, encoding: .utf8)
        }

        // The window is now showing B. The stack still holds A.
        _ = try undo(&stack)

        check("the other document is untouched", read(b) == bBefore, String(read(b).prefix(60)))
        check("and the comment came out of the one it was made in",
              read(a) == "# A\n\nThe first document.\n", String(read(a).prefix(60)))
    }

    // MARK: - Somebody else writing in between

    static func theFileChangingUnderneath() throws {
        print("▸ an outside edit is not something to write over")

        let url = fixture("# Doc\n\nA paragraph.\n")
        var stack = UndoStack()
        record(&stack, "Comment", on: url) {
            try? "# Doc\n\nA paragraph.\n\n<!-- imark quote=\"paragraph\" by=\"m\" at=\"2026-08-10T09:00Z\"\nA note.\n-->\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }

        // The file changes on disk: another editor saves over it, Imark
        // reloads, and the undo stack is still holding a snapshot from before
        // any of that. Restoring it would erase the outside work.
        Thread.sleep(forTimeInterval: 1.1)
        let outside = "# Doc\n\nA paragraph, rewritten elsewhere.\n"
        try outside.write(to: url, atomically: true, encoding: .utf8)

        var refused = false
        do {
            _ = try undo(&stack)
        } catch {
            refused = true
            check("and says why", (error as? LocalizedError)?.errorDescription?
                .contains("changed on disk") == true,
                  (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        check("undo refuses when the file moved on", refused)
        check("the outside edit survives", read(url) == outside, String(read(url).prefix(60)))

        print("▸ but our own writing is not an outside edit")
        let mine = fixture("start\n")
        var ours = UndoStack()
        record(&ours, "Comment", on: mine) {
            try? "start, commented\n".write(to: mine, atomically: true, encoding: .utf8)
        }
        var worked = false
        do { worked = try undo(&ours) } catch { check("our own change undoes cleanly", false, "\(error)") }
        check("our own change undoes cleanly", worked)
        check("leaving the file as it started", read(mine) == "start\n", read(mine))
    }

    // MARK: - The same thing, through the window that people actually use

    /// The model tests above prove the stack writes where it should. This one
    /// proves the window is wired to it: a real comment, a real navigation, and
    /// the real ⌘Z selector. It is the reported bug, start to finish.
    static func theWholeWayThroughTheWindow() throws {
        print("▸ through the window: comment on A, open B, press undo")

        let a = fixture("# A\n\nThe first document.\n", named: "A.md")
        let b = fixture("# B\n\nThe second document, which must survive.\n", named: "B.md")
        let aBefore = read(a)
        let bBefore = read(b)

        let window = DocumentWindowController(url: a)
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        window.showWindow(nil)
        spin(0.8)

        // A comment about the document needs no selection, so this is the whole
        // write path — snapshot, insert, seal — with nothing stubbed.
        window.composingFileNote = true
        window.saveComment("A note on the whole thing.", colour: .standard)
        spin(0.6)
        check("the comment went into A", read(a) != aBefore)

        // Follow a link, or click the sibling in the sidebar. Same call.
        window.show(b, pushingHistory: true)
        spin(0.6)
        check("the window is showing B now", window.url == b)

        // ⌘Z.
        window.undoComment(nil)
        spin(0.6)

        check("B is exactly as it was", read(b) == bBefore, String(read(b).prefix(60)))
        check("and A is back to before the comment", read(a) == aBefore, String(read(a).prefix(60)))

        window.close()
    }

    /// The window and its WebView need a run loop to get anything done.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
