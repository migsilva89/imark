import Foundation

/// Swift's copy of the document in the Live editor, kept in step with
/// CodeMirror by the `changes` messages the page posts (docs/LIVE-PREVIEW.md
/// §3.2). It exists so `text` and `isDirty` can be answered synchronously —
/// closing a window, switching documents and the file watcher's dirty guard all
/// ask from code that cannot wait for a web view to reply.
///
/// The copy is held in CodeMirror's coordinates, not the file's: UTF-16 (the
/// same units JS string offsets count), and every line break is a single `\n`,
/// because with `lineSeparator: "\r\n"` CodeMirror counts a CRLF as one position
/// and reports inserted text with its lines joined by `\n`. `text` converts back.
/// That only works when the file uses one kind of break throughout; anything
/// else is refused by `lineSeparator(of:)` and stays out of Live mode.
///
/// No AppKit or WebKit in here: it is fed decoded messages and is tested alone.
final class LiveMirror {
    /// One `[fromA, toA, insert]` from `ChangeSet.iterChanges`: positions in the
    /// document before the transaction, and the text that replaced them.
    struct Change: Equatable {
        let from: Int
        let to: Int
        let insert: NSString
    }

    enum Outcome: Equatable {
        case applied
        /// From a document that has since been replaced. Dropped.
        case stale
        /// Out of sequence, out of range, or the length came out wrong. The
        /// caller asks the page for the whole text (`resync`).
        case needsResync
        /// A resync is under way; changes are ignored until `fullText` lands.
        case awaitingResync
    }

    private(set) var generation = 0
    /// The `seq` of the last change applied. The page restarts at 1 on load.
    private(set) var seq = 0
    private(set) var lineSeparator = "\n"
    private(set) var isAwaitingResync = false

    private let buffer = NSMutableString()
    /// The text on disk, in the same coordinates, for `isDirty`.
    private var disk: NSString = ""

    // MARK: - Reading

    /// The document as it would be written: CodeMirror's `\n` breaks turned back
    /// into the file's own.
    var text: String {
        guard lineSeparator != "\n" else { return buffer as String }
        return buffer.replacingOccurrences(of: "\n", with: lineSeparator)
    }

    /// In CodeMirror's coordinates, which is what `fullText` and the tests compare.
    var mirrorText: String { buffer.copy() as! String }

    var length: Int { buffer.length }

    /// A literal comparison, unit by unit. Swift's `==` on `String` treats
    /// canonically equivalent text as equal, and a file whose `é` changed from
    /// two code points to one has changed.
    var isDirty: Bool { !buffer.isEqual(to: disk as String) }

    // MARK: - Driving

    /// The line break a file uses, or nil if it mixes them or has a bare `\r`,
    /// which the mirror cannot convert back faithfully (§6). A file with no line
    /// break at all is LF.
    static func lineSeparator(of text: String) -> String? {
        let units = Array(text.utf16)
        var lf = false, crlf = false
        var i = 0
        while i < units.count {
            switch units[i] {
            case 0x0D:
                guard i + 1 < units.count, units[i + 1] == 0x0A else { return nil }
                crlf = true
                i += 2
                continue
            case 0x0A:
                lf = true
            default:
                break
            }
            i += 1
        }
        if lf && crlf { return nil }
        return crlf ? "\r\n" : "\n"
    }

    /// Replaces the document. Returns the new generation, which goes to the page
    /// with the text; every later message must carry it. The mirror is right from
    /// this moment on, before the page has even loaded.
    @discardableResult
    func load(_ fileText: String, lineSeparator separator: String) -> Int {
        precondition(separator == "\n" || separator == "\r\n", "unsupported line separator")
        lineSeparator = separator
        let coordinates = separator == "\n"
            ? fileText
            : fileText.replacingOccurrences(of: "\r\n", with: "\n")
        buffer.setString(coordinates)
        disk = buffer.copy() as! NSString
        generation += 1
        seq = 0
        isAwaitingResync = false
        return generation
    }

    /// What was just written is now what is on disk.
    func markSaved() {
        disk = buffer.copy() as! NSString
    }

    func apply(generation: Int, seq incoming: Int, length expected: Int, changes: [Change]) -> Outcome {
        guard generation == self.generation else { return .stale }
        guard !isAwaitingResync else { return .awaitingResync }
        guard incoming == seq + 1 else { return requestResync() }

        // Positions are in the document before the transaction, so apply from the
        // end backwards: an edit never moves the positions of the ones before it.
        for change in changes.sorted(by: { $0.from > $1.from }) {
            guard change.from >= 0, change.from <= change.to, change.to <= buffer.length else {
                return requestResync()
            }
            buffer.replaceCharacters(in: NSRange(location: change.from, length: change.to - change.from),
                                     with: change.insert as String)
        }
        seq = incoming
        guard buffer.length == expected else { return requestResync() }
        return .applied
    }

    /// The page's reply to `resync`: the whole document, `\n`-joined.
    func applyFullText(generation: Int, seq incoming: Int, text: NSString) -> Outcome {
        guard generation == self.generation else { return .stale }
        buffer.setString(text as String)
        seq = incoming
        isAwaitingResync = false
        return .applied
    }

    private func requestResync() -> Outcome {
        isAwaitingResync = true
        return .needsResync
    }

    // MARK: - Decoding

    /// The `changes` array of a message body, as WebKit hands it over. Strings are
    /// kept as `NSString` so a lone surrogate (an edit that split a pair) is not
    /// repaired into U+FFFD on the way through.
    static func changes(from raw: Any?) -> [Change]? {
        guard let list = raw as? [Any] else { return nil }
        var result: [Change] = []
        result.reserveCapacity(list.count)
        for item in list {
            guard let triple = item as? [Any], triple.count == 3,
                  let from = (triple[0] as? NSNumber)?.intValue,
                  let to = (triple[1] as? NSNumber)?.intValue,
                  let insert = triple[2] as? NSString
            else { return nil }
            result.append(Change(from: from, to: to, insert: insert))
        }
        return result
    }
}
