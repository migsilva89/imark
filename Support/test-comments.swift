// Tests for the one thing in Imark that writes to your files.
//
//   swiftc -parse-as-library Sources/Imark/Comments.swift \
//          Sources/Imark/NoteColour.swift \
//          Support/test-comments.swift -o /tmp/imark-test && /tmp/imark-test
//
// A script rather than a test target because Imark is an executable with a
// hand-written main.swift, and `swift test` cannot import that.

import Foundation

@main
enum CommentsTest {
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
        .appendingPathComponent("imark-comments-\(UUID().uuidString)")

    static func fixture(_ text: String) -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).md")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func read(_ url: URL) -> [String] {
        try! String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    static let date = Date(timeIntervalSince1970: 1_754_150_000)

    static func main() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try placement()
        try ordering()
        try fencedExamples()
        try escaping()
        try conflict()
        try atomicity()
        try manyInARow()
        try deleting()
        try editing()
        try undoing()
        try staleRanges()
        try colours()
        try savingWholeDocument()

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Where the note lands

    static func placement() throws {
        let url = fixture("""
        # Title

        First paragraph.

        Second paragraph.
        """)
        // "First paragraph." is lines 2..3 with an exclusive end, so 3.
        let index = try Comments.insert(
            quote: "First", body: "Why first?", after: 3, occurrence: 1,
            by: "john", on: date, into: url, expecting: Comments.Stamp(of: url)
        )
        let lines = read(url)
        check("lands right after the block", lines[4].hasPrefix("<!-- imark"), lines.joined(separator: "⏎"))
        check("blank line before the note", lines[3].isEmpty)
        check("original text untouched", lines[2] == "First paragraph." && lines.last == "Second paragraph.")
        check("first note has index 0", index == 0)
        check("quote and author written", lines[4].contains("quote=\"First\"") && lines[4].contains("by=\"john\""))
        check("no nth for a first occurrence", !lines[4].contains("nth="))
        check("body on its own line", lines[5] == "Why first?")
        check("closed", lines[6] == "-->")
    }

    // MARK: - Which note is which

    static func ordering() throws {
        let url = fixture("One.\n\nTwo.\n\nThree.")
        _ = try Comments.insert(quote: "One", body: "a", after: 1, occurrence: 1,
                                by: "m", on: date, into: url, expecting: nil)
        let second = try Comments.insert(quote: "Three", body: "c", after: 8, occurrence: 1,
                                         by: "m", on: date, into: url, expecting: nil)
        check("a later note counts the earlier one", second == 1, "got \(second)")

        let middle = try Comments.insert(quote: "Two", body: "b", after: 6, occurrence: 1,
                                         by: "m", on: date, into: url, expecting: nil)
        check("a note between them counts only what precedes it", middle == 1, "got \(middle)")
    }

    // MARK: - A document that shows the format

    /// The index insert returns is the note's place in the list the renderer
    /// builds, and the renderer skips fenced examples. Counting one here would
    /// open the note above the one that was just written.
    static func fencedExamples() throws {
        let example = """
        # Doc

        Nobody commented on this document.

        ```markdown
        <!-- imark quote="a phrase" by="john" at="2026-08-02T14:31Z"
        An example, not a note.
        -->
        ```
        """

        let fenced = fixture(example)
        let first = try Comments.insert(quote: "Doc", body: "n", after: 1, occurrence: 1,
                                        by: "m", on: date, into: fenced, expecting: nil)
        check("a note inside a fence is not counted", first == 0, "got \(first)")

        let after = fixture("""
        \(example)

        <!-- imark quote="Nobody commented" by="m" at="2026-08-02T14:31Z"
        A real one, below the example.
        -->
        """)
        let below = try Comments.insert(quote: "Doc", body: "n", after: 99, occurrence: 1,
                                        by: "m", on: date, into: after, expecting: nil)
        check("a real note after an example still counts", below == 1, "got \(below)")

        // The fence never closes, so it is not a fence, and the note in it is a
        // note. Anything else loses every note below an unclosed fence.
        let unclosed = fixture("""
        # Doc

        ```markdown
        <!-- imark quote="Doc" by="m" at="2026-08-02T14:31Z"
        Somebody is still typing the block.
        -->
        """)
        let past = try Comments.insert(quote: "Doc", body: "n", after: 99, occurrence: 1,
                                       by: "m", on: date, into: unclosed, expecting: nil)
        check("an unclosed fence hides nothing", past == 1, "got \(past)")

        let tildes = fixture("""
        # Doc

        ~~~markdown
        <!-- imark quote="a phrase" by="john" at="2026-08-02T14:31Z"
        An example, not a note.
        -->
        ~~~
        """)
        let beside = try Comments.insert(quote: "Doc", body: "n", after: 99, occurrence: 1,
                                         by: "m", on: date, into: tildes, expecting: nil)
        check("a tilde fence counts as a fence", beside == 0, "got \(beside)")
    }

    // MARK: - Text that could break the block

    static func escaping() throws {
        let url = fixture("Text with \"quotes\" & ampersands.\n")
        _ = try Comments.insert(
            quote: "\"quotes\" & ampersands", body: "Ends with an arrow --> right here.",
            after: 1, occurrence: 2, by: "m", on: date, into: url, expecting: nil
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        check("quotes escaped in the attribute", text.contains("quote=\"&quot;quotes&quot; &amp; ampersands\""))
        check("nth written when it is needed", text.contains("nth=\"2\""))
        check("--> neutralised so the block cannot close early", text.contains("--&gt;"))
        check("only one closing marker", text.components(separatedBy: "-->").count == 2)
    }

    // MARK: - Somebody else got there first

    static func conflict() throws {
        let url = fixture("A paragraph.\n")
        let stamp = Comments.Stamp(of: url)
        Thread.sleep(forTimeInterval: 0.02)
        try "A different paragraph.\n".write(to: url, atomically: true, encoding: .utf8)

        var refused = false
        do {
            _ = try Comments.insert(quote: "A", body: "note", after: 1, occurrence: 1,
                                    by: "m", on: date, into: url, expecting: stamp)
        } catch Comments.Failure.fileChanged {
            refused = true
        }
        check("refuses to write over an outside edit", refused)
        check("and left the file alone",
              try String(contentsOf: url, encoding: .utf8) == "A different paragraph.\n")
    }

    // MARK: - What the replace leaves behind

    static func atomicity() throws {
        let url = fixture("Body.\n")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        _ = try Comments.insert(quote: "Body", body: "n", after: 1, occurrence: 1,
                                by: "m", on: date, into: url, expecting: nil)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        check("permissions preserved across the atomic replace",
              before[.posixPermissions] as? Int == after[.posixPermissions] as? Int)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains("imark-") }
        check("no temporary file left behind", leftovers.isEmpty, "\(leftovers)")
    }

    // MARK: - Taking a note back out

    static func deleting() throws {
        let url = fixture("""
        Before.

        <!-- imark quote="Before" by="m" at="x"
        a note
        -->

        After.
        """)
        try Comments.remove(lines: 2...4, from: url, expecting: Comments.Stamp(of: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        check("the note is gone", !text.contains("imark"))
        check("the document is not", text.contains("Before.") && text.contains("After."))
        check("no gap left where it was", !text.contains("\n\n\n"), text.debugDescription)
    }

    // MARK: - Rewriting one

    static func editing() throws {
        let url = fixture("""
        Text.

        <!-- imark quote="Text" by="jane" at="2026-08-01T09:00Z" nth="2"
        first thought
        -->
        """)
        try Comments.update(lines: 2...4, body: "second thought", colour: .standard,
                            in: url, expecting: Comments.Stamp(of: url))
        let lines = read(url)
        check("the body is replaced", lines[3] == "second thought")
        check("the anchor is untouched",
              lines[2] == "<!-- imark quote=\"Text\" by=\"jane\" at=\"2026-08-01T09:00Z\" nth=\"2\"",
              lines[2])
        check("still closed", lines[4] == "-->")

        try Comments.update(lines: 2...4, body: "an arrow --> here", colour: .standard,
                            in: url, expecting: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        check("an edit escapes --> too", text.contains("--&gt;"))
        check("and cannot close the block early", text.components(separatedBy: "-->").count == 2)
    }

    // MARK: - Putting it back

    static func undoing() throws {
        let url = fixture("A paragraph.\n")
        let original = try String(contentsOf: url, encoding: .utf8)

        _ = try Comments.insert(quote: "A", body: "note", after: 1, occurrence: 1,
                                by: "m", on: date, into: url, expecting: nil)
        check("the note went in", try String(contentsOf: url, encoding: .utf8) != original)

        // Passing no stamp is "restore this, whatever the file looks like now".
        // The window always passes one; the exhaustive cases live in
        // Support/test-undo.swift, including the refusal.
        try Comments.restore(original, to: url, expecting: nil)
        check("undo puts the file back exactly",
              try String(contentsOf: url, encoding: .utf8) == original)

        // And with a stamp, restoring over somebody else's write is refused —
        // the one guarantee this function used to be missing.
        let stale = Comments.Stamp(of: url)
        Thread.sleep(forTimeInterval: 1.1)
        try "written by somebody else\n".write(to: url, atomically: true, encoding: .utf8)
        var refused = false
        do { try Comments.restore(original, to: url, expecting: stale) } catch { refused = true }
        check("restoring over an outside write is refused", refused)
        check("and that write is still there",
              try String(contentsOf: url, encoding: .utf8) == "written by somebody else\n")
    }

    // MARK: - A range that no longer points at a note

    static func staleRanges() throws {
        let url = fixture("Just a paragraph.\n\nAnd another.\n")
        let before = try String(contentsOf: url, encoding: .utf8)

        // The lines a note used to be on, after somebody deleted it by hand.
        try Comments.remove(lines: 0...2, from: url, expecting: nil)
        check("refuses to delete lines that are not a note",
              try String(contentsOf: url, encoding: .utf8) == before)

        try Comments.update(lines: 0...2, body: "hello", colour: .standard, in: url, expecting: nil)
        check("and refuses to rewrite them",
              try String(contentsOf: url, encoding: .utf8) == before)

        try Comments.remove(lines: 90...99, from: url, expecting: nil)
        check("a range past the end of the file is harmless",
              try String(contentsOf: url, encoding: .utf8) == before)
    }

    // MARK: - Colour

    static func colours() throws {
        // The default writes nothing at all.
        let plain = fixture("Text.\n")
        _ = try Comments.insert(quote: "Text", body: "n", after: 1, occurrence: 1,
                                by: "m", on: date, into: plain, expecting: nil)
        check("the default colour writes no attribute",
              !(try String(contentsOf: plain, encoding: .utf8)).contains("color="))

        let url = fixture("Text.\n")
        _ = try Comments.insert(quote: "Text", body: "n", colour: .amber, after: 1,
                                occurrence: 1, by: "m", on: date, into: url, expecting: nil)
        check("a chosen colour is written",
              (try String(contentsOf: url, encoding: .utf8)).contains("color=\"amber\""))

        // Changing it must not disturb anything else on the line.
        let header = "<!-- imark quote=\"a\" by=\"jane\" at=\"2026-08-01T09:00Z\" nth=\"2\""
        check("colour added without touching the rest",
              Comments.recolour(header, to: .green) == header + " color=\"green\"",
              Comments.recolour(header, to: .green))
        check("colour replaced, not appended twice",
              Comments.recolour(header + " color=\"red\"", to: .blue) == header + " color=\"blue\"",
              Comments.recolour(header + " color=\"red\"", to: .blue))
        check("back to default removes it",
              Comments.recolour(header + " color=\"red\"", to: .standard) == header,
              Comments.recolour(header + " color=\"red\"", to: .standard))
        check("a colour in the middle is found too",
              Comments.recolour("<!-- imark color=\"red\" quote=\"a\"", to: .standard)
                  == "<!-- imark quote=\"a\"",
              Comments.recolour("<!-- imark color=\"red\" quote=\"a\"", to: .standard))

        // An edit goes through the same path and must keep the anchor.
        let edited = fixture("""
        Text.

        <!-- imark quote="Text" by="jane" at="2026-08-01T09:00Z" color="red"
        first
        -->
        """)
        try Comments.update(lines: 2...4, body: "second", colour: .blue, in: edited, expecting: nil)
        let lines = read(edited)
        check("editing keeps quote, author and date",
              lines[2].contains("quote=\"Text\"") && lines[2].contains("by=\"jane\"")
                  && lines[2].contains("at=\"2026-08-01T09:00Z\""), lines[2])
        check("and swaps the colour", lines[2].contains("color=\"blue\"")
                  && !lines[2].contains("color=\"red\""), lines[2])

        check("an unknown name from a file is not a colour",
              NoteColour(attribute: "chartreuse") == .standard)
        check("and neither is nothing", NoteColour(attribute: nil) == .standard)

    }

    // MARK: - The acceptance criterion from the plan

    static func manyInARow() throws {
        let url = fixture("Paragraph one.\n\nParagraph two.\n")
        for i in 0..<50 {
            _ = try Comments.insert(quote: "Paragraph one", body: "note \(i)", after: 1,
                                    occurrence: 1, by: "m", on: date, into: url, expecting: nil)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        check("50 notes in a row, none lost", text.components(separatedBy: "<!-- imark").count == 51)
        check("and the document itself is still there",
              text.contains("Paragraph one.") && text.contains("Paragraph two."))
    }

    // MARK: - Editing document text

    static func savingWholeDocument() throws {
        let url = fixture("One.\n\nTwo.\n")
        try Comments.save("One, edited.\n\nTwo.\n", to: url, expecting: Comments.Stamp(of: url))
        check("the whole document is written",
              try! String(contentsOf: url, encoding: .utf8) == "One, edited.\n\nTwo.\n")

        // Somebody else wrote while the editor was open.
        let raced = fixture("Theirs.\n")
        let stamp = Comments.Stamp(of: raced)
        try! "Somebody else's work.\n".write(to: raced, atomically: true, encoding: .utf8)
        var refused = false
        do { try Comments.save("mine\n", to: raced, expecting: stamp) }
        catch Comments.Failure.fileChanged { refused = true } catch {}
        check("a save over somebody else's write is refused", refused)
        check("and their work is intact",
              try! String(contentsOf: raced, encoding: .utf8) == "Somebody else's work.\n")

        // A file that was deleted or moved while the editor held it open.
        let gone = fixture("Here for now.\n")
        let goneStamp = Comments.Stamp(of: gone)
        try! FileManager.default.removeItem(at: gone)
        refused = false
        do { try Comments.save("my buffer\n", to: gone, expecting: goneStamp) }
        catch Comments.Failure.fileChanged { refused = true } catch {}
        check("a save onto a file that vanished is refused", refused)
        check("and it is not recreated from the buffer",
              !FileManager.default.fileExists(atPath: gone.path))

        // With no stamp there is nothing to compare against, and the caller is
        // saying so — undo restoring a file it has just written, for instance.
        let fresh = folder.appendingPathComponent("written-from-nothing.md")
        try Comments.save("brand new\n", to: fresh, expecting: nil)
        check("with no stamp, a save still writes",
              (try? String(contentsOf: fresh, encoding: .utf8)) == "brand new\n")

        // The permissions and the creation date belong to the file, not to us.
        let owned = fixture("Text.\n")
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owned.path)
        try Comments.save("Text, edited.\n", to: owned, expecting: nil)
        let mode = try! FileManager.default.attributesOfItem(atPath: owned.path)[.posixPermissions] as! NSNumber
        check("an atomic save keeps the file's own permissions", mode.intValue == 0o600, "\(mode)")
    }
}
