import Foundation

/// Reading and writing the `<!-- imark … -->` blocks that carry comments.
///
/// The renderer parses them in `renderer/src/comments.js`; the escaping here
/// has to stay the mirror image of the unescaping there.
enum Comments {
    /// What the file looked like when it was read. Writing over a file that
    /// changed underneath us is exactly how an editor loses somebody's work.
    struct Stamp: Equatable {
        let size: Int
        let modified: Date

        /// Read through FileManager rather than `URL.resourceValues`, which
        /// caches on the URL instance: asking the same URL twice returned the
        /// values from the first call and the check never fired.
        init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            self.size = size
            self.modified = modified
        }
    }

    enum Failure: LocalizedError {
        case fileChanged
        case unreadable

        var errorDescription: String? {
            switch self {
            case .fileChanged: "This file changed on disk since Imark opened it."
            case .unreadable: "Imark can't read this file as UTF-8 text."
            }
        }
    }

    /// Every change to a document goes through here: read, check nobody else
    /// got there first, rewrite atomically. Keeping it in one place is what
    /// stops delete and edit from quietly growing weaker guarantees than insert.
    private static func edit(
        _ url: URL,
        expecting stamp: Stamp?,
        _ change: (inout [String]) -> Void
    ) throws {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.unreadable
        }
        if let stamp, let now = Stamp(of: url), now != stamp {
            throw Failure.fileChanged
        }
        var lines = source.components(separatedBy: "\n")
        change(&lines)
        try write(lines.joined(separator: "\n"), to: url)
    }

    /// Takes a note out, along with one blank line it left behind — otherwise
    /// deleting notes slowly fills a document with gaps.
    static func remove(lines range: ClosedRange<Int>, from url: URL, expecting stamp: Stamp?) throws {
        try edit(url, expecting: stamp) { lines in
            guard let bounds = clamp(range, to: lines) else { return }
            var cut = bounds
            if cut.upperBound + 1 < lines.count, lines[cut.upperBound + 1].isBlank {
                cut = cut.lowerBound...(cut.upperBound + 1)
            } else if cut.lowerBound > 0, lines[cut.lowerBound - 1].isBlank {
                cut = (cut.lowerBound - 1)...cut.upperBound
            }
            lines.removeSubrange(cut)
        }
    }

    /// Rewrites the text of a note, and its colour if that changed. Everything
    /// else on the opening line is kept exactly as it was and read back out of
    /// the file rather than passed in: editing your own wording should not
    /// silently re-anchor the note, restamp it, or put your name on somebody
    /// else's.
    static func update(
        lines range: ClosedRange<Int>,
        body: String,
        colour: NoteColour,
        in url: URL,
        expecting stamp: Stamp?
    ) throws {
        try edit(url, expecting: stamp) { lines in
            guard let bounds = clamp(range, to: lines) else { return }
            lines.replaceSubrange(bounds, with: [
                recolour(lines[bounds.lowerBound], to: colour),
                neutralize(body),
                "-->",
            ])
        }
    }

    /// Swaps the `color=` on an opening line, leaving every other attribute and
    /// the spacing between them untouched. Rebuilding the line from parsed
    /// parts would be tidier and would quietly discard anything we do not know
    /// about — including whatever a later version writes there.
    static func recolour(_ line: String, to colour: NoteColour) -> String {
        var out = line.replacingOccurrences(
            of: #"\s*color="[^"]*""#,
            with: "",
            options: .regularExpression
        )
        if let attribute = colour.attribute {
            out += " color=\"\(attribute)\""
        }
        return out
    }

    /// Puts a whole document back, for undo.
    ///
    /// This is the only write in the app that replaces a file wholesale, which
    /// makes it the only one that can cost somebody a document rather than a
    /// comment. It used to skip the staleness check on the grounds that the
    /// caller took the snapshot and is the one asking for it back — true, but
    /// only until something else writes in between. An editor saving over the
    /// file, or a `git checkout`, and the snapshot is a way to erase it.
    static func restore(_ text: String, to url: URL, expecting stamp: Stamp?) throws {
        if let stamp, let now = Stamp(of: url), now != stamp {
            throw Failure.fileChanged
        }
        try write(text, to: url)
    }

    /// A file can shrink under us — a stale range must not take neighbouring
    /// lines with it.
    private static func clamp(_ range: ClosedRange<Int>, to lines: [String]) -> ClosedRange<Int>? {
        let lower = max(0, range.lowerBound)
        let upper = min(lines.count - 1, range.upperBound)
        guard lower <= upper, lines[lower].hasPrefix("<!--") || lines[lower].contains("<!-- imark")
        else { return nil }
        return lower...upper
    }

    /// Writes a note into the file, immediately after the block the selection
    /// came from. Returns its position among all the notes in the document, so
    /// the caller can open the one that was just written.
    @discardableResult
    static func insert(
        quote: String,
        body: String,
        colour: NoteColour = .standard,
        after line: Int,
        occurrence: Int,
        by author: String,
        on date: Date,
        scope: Scope = .block,
        into url: URL,
        expecting stamp: Stamp?
    ) throws -> Int {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.unreadable
        }
        // Checked against the file rather than against a cached copy: another
        // editor may have written since, and a size that matches by luck still
        // has a different timestamp.
        if let stamp, let now = Stamp(of: url), now != stamp {
            throw Failure.fileChanged
        }

        var lines = source.components(separatedBy: "\n")
        // A note about the file goes to the top, where somebody opening the
        // document in an editor reads it before anything else. Anywhere further
        // down and it would look like it belonged to whatever it followed.
        let at = scope == .file ? topOfBody(lines) : min(max(line, 0), lines.count)

        var block = [format(
            quote: quote, body: body, colour: colour,
            author: author, date: date, occurrence: occurrence, scope: scope
        )]
        // A note glued to the paragraph above would be parsed as part of it by
        // some renderers, and reads badly in a plain-text editor either way.
        if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            block.insert("", at: 0)
        }
        if at < lines.count, !lines[at].trimmingCharacters(in: .whitespaces).isEmpty {
            block.append("")
        }

        let index = countNotes(in: lines, above: at)
        lines.insert(contentsOf: block, at: at)
        try write(lines.joined(separator: "\n"), to: url)
        return index
    }

    // MARK: - Shaping

    /// What a note is about. A quoted note names its words; a block note is the
    /// paragraph it follows; a file note is the document, and is the one kind
    /// whose position in the file carries no meaning at all.
    enum Scope: String {
        case block
        case file
    }

    /// The line a file note goes on: straight after the front matter, or the top
    /// of the file when there is none. Written above the first heading rather
    /// than below it, because a note about the document is not part of it.
    static func topOfBody(_ lines: [String]) -> Int {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return 0 }
        for index in 1..<max(lines.count, 1)
        where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return index + 1
        }
        // Unterminated front matter is somebody's half-written header; putting a
        // note inside it would make the document unparseable.
        return 0
    }

    static func format(
        quote: String,
        body: String,
        colour: NoteColour = .standard,
        author: String,
        date: Date,
        occurrence: Int,
        scope: Scope = .block
    ) -> String {
        // No quote means the note is about the whole block, written by the `+`
        // in the margin rather than by selecting words. Writing `quote=""` would
        // be a lie in the file — nothing was quoted — and the position already
        // says which block it is, which is why such a note can never come loose.
        var attributes: [String] = []
        // Written first so it is the first thing read, in the app and in a text
        // editor. `block` is the default and writes nothing.
        if scope == .file { attributes.append("scope=\"file\"") }
        if !quote.isEmpty { attributes.append("quote=\"\(escapeAttribute(quote))\"") }
        if !author.isEmpty { attributes.append("by=\"\(escapeAttribute(author))\"") }
        attributes.append("at=\"\(ISO8601DateFormatter().string(from: date))\"")
        // Only written when it is needed to tell two identical quotes apart;
        // an nth="1" on every note would be noise in the file.
        if occurrence > 1 { attributes.append("nth=\"\(occurrence)\"") }
        // The default writes nothing: a color= on every note would be noise in
        // a document that mostly has one colour.
        if let colour = colour.attribute { attributes.append("color=\"\(colour)\"") }

        return "<!-- imark \(attributes.joined(separator: " "))\n\(neutralize(body))\n-->"
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// A literal `-->` inside the note would close the comment early and spill
    /// the rest of it into the document as text.
    static func neutralize(_ body: String) -> String {
        body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "-->", with: "--&gt;")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many notes the document holds above `line`, which is the position the
    /// new one takes in the list the renderer builds. Fenced examples are left
    /// out because the renderer leaves them out too: counting one here would
    /// open the note above the one somebody just wrote.
    ///
    /// Asked of the whole document rather than of the lines above `line`, so a
    /// fence opened above the insertion point and closed below it is still read
    /// as a fence.
    private static func countNotes(in lines: [String], above line: Int) -> Int {
        let fenced = fencedLines(lines)
        return lines.indices.prefix(line)
            .filter { !fenced.contains($0) }
            .filter {
                lines[$0].range(of: #"^\s*<!--\s*imark\b"#, options: .regularExpression) != nil
            }
            .count
    }

    /// A code fence, the way CommonMark draws one: a run of three or more
    /// backticks or tildes, indented by no more than three spaces.
    private static func fenceRun(_ line: String) -> (marker: Character, length: Int)? {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3, let marker = body.first,
              marker == "`" || marker == "~"
        else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    /// A fence closes only with its own character and at least as long a run, and
    /// carries nothing else: anything after the run is an info string, which only
    /// an opening fence may have.
    private static func closes(_ line: String, _ open: (marker: Character, length: Int)) -> Bool {
        guard let run = fenceRun(line), run.marker == open.marker, run.length >= open.length
        else { return false }
        return String(line.drop { $0 == " " }.drop { $0 == open.marker }).isBlank
    }

    /// The lines of every closed code fence, the fences included. A note inside
    /// one is an example of the format rather than a note — the same reading the
    /// renderer and the plugin take, and the three have to agree or the app and
    /// the file disagree about what the document holds.
    ///
    /// A fence that never closes is not a fence, it is somebody mid-sentence, and
    /// taking it at its word would silently lose every note below it.
    private static func fencedLines(_ lines: [String]) -> Set<Int> {
        var fenced: Set<Int> = []
        var index = 0
        while index < lines.count {
            guard let open = fenceRun(lines[index]) else {
                index += 1
                continue
            }
            guard let end = lines.indices.dropFirst(index + 1).first(where: { closes(lines[$0], open) }) else {
                index += 1
                continue
            }
            fenced.formUnion(index...end)
            index = end + 1
        }
        return fenced
    }

    // MARK: - Saving

    /// Written to a temporary file in the same directory and moved into place,
    /// so an interrupted write can never leave a half-written document behind.
    /// `replaceItemAt` keeps the original's permissions and creation date.
    private static func write(_ text: String, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).imark-\(UUID().uuidString)")
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}


private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}
