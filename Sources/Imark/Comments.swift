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

    /// Writes a note into the file, immediately after the block the selection
    /// came from. Returns its position among all the notes in the document, so
    /// the caller can open the one that was just written.
    @discardableResult
    static func insert(
        quote: String,
        body: String,
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

        var block = [format(quote: quote, body: body, author: author, date: date, occurrence: occurrence)]
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
        author: String,
        date: Date,
        occurrence: Int
    ) -> String {
        var attributes = ["quote=\"\(escapeAttribute(quote))\""]
        if !author.isEmpty { attributes.append("by=\"\(escapeAttribute(author))\"") }
        attributes.append("at=\"\(ISO8601DateFormatter().string(from: date))\"")
        // Only written when it is needed to tell two identical quotes apart;
        // an nth="1" on every note would be noise in the file.
        if occurrence > 1 { attributes.append("nth=\"\(occurrence)\"") }

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
    private static func neutralize(_ body: String) -> String {
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
