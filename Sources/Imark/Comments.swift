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

    /// Puts a whole document back, for undo. No stamp check: the caller took
    /// the snapshot and is the one asking for it back.
    static func restore(_ text: String, to url: URL) throws {
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
        let at = min(max(line, 0), lines.count)

        var block = [format(
            quote: quote, body: body, colour: colour,
            author: author, date: date, occurrence: occurrence
        )]
        // A note glued to the paragraph above would be parsed as part of it by
        // some renderers, and reads badly in a plain-text editor either way.
        if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            block.insert("", at: 0)
        }
        if at < lines.count, !lines[at].trimmingCharacters(in: .whitespaces).isEmpty {
            block.append("")
        }

        let index = countNotes(in: lines.prefix(at))
        lines.insert(contentsOf: block, at: at)
        try write(lines.joined(separator: "\n"), to: url)
        return index
    }

    // MARK: - Shaping

    static func format(
        quote: String,
        body: String,
        colour: NoteColour = .standard,
        author: String,
        date: Date,
        occurrence: Int
    ) -> String {
        // No quote means the note is about the whole block, written by the `+`
        // in the margin rather than by selecting words. Writing `quote=""` would
        // be a lie in the file — nothing was quoted — and the position already
        // says which block it is, which is why such a note can never come loose.
        var attributes: [String] = []
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

    private static func countNotes(in lines: ArraySlice<String>) -> Int {
        lines.filter { $0.range(of: #"^\s*<!--\s*imark\b"#, options: .regularExpression) != nil }.count
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
