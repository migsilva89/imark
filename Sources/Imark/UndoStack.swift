import Foundation

/// The document as it was before each change, so a comment can be taken back.
///
/// A window outlives the document open in it — you follow a wiki-link, press
/// Back, pick another file in the sidebar — so a snapshot has to carry the file
/// it came from. Restoring "the current document" is how the text of one file
/// ends up written over another.
struct UndoStack {
    struct Entry {
        /// The whole file, before the change.
        let text: String
        /// What the change was, for the menu item: "Undo Delete Comment".
        let what: String
        /// The file this text belongs to. Not the one on screen when you undo.
        let url: URL
        /// What that file looked like when the snapshot was taken. If it does
        /// not match at undo time, somebody else has written since.
        let stamp: Comments.Stamp?
    }

    /// Ten is what a person can remember doing. Documents are capped at 5 MB,
    /// so ten of them is still nothing.
    static let limit = 10

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// The next thing an undo would take back, for naming the menu item.
    var last: Entry? { entries.last }

    mutating func push(text: String, what: String, url: URL, stamp: Comments.Stamp?) {
        entries.append(Entry(text: text, what: what, url: url, stamp: stamp))
        if entries.count > Self.limit { entries.removeFirst() }
    }

    /// Takes the newest entry off. Returns nil when there is nothing to undo.
    mutating func pop() -> Entry? { entries.popLast() }

    /// Records what the file looks like now that the change has landed, so an
    /// edit made afterwards by somebody else can be told apart from our own.
    mutating func stampLast(_ stamp: Comments.Stamp?) {
        guard let entry = entries.popLast() else { return }
        entries.append(Entry(text: entry.text, what: entry.what, url: entry.url, stamp: stamp))
    }

    /// Takes the newest change back, writing to the file it came from.
    ///
    /// The caller never names a file. That is the whole point: the window shows
    /// whatever document you last opened, and asking it where to put the text
    /// is how one file's contents ended up written over another's.
    ///
    /// Throws `Comments.Failure.fileChanged` if that file has moved on since —
    /// an outside edit is somebody's work, and taking a comment back is not a
    /// reason to erase it.
    @discardableResult
    mutating func undoLast() throws -> Entry? {
        guard let entry = entries.popLast() else { return nil }
        do {
            try Comments.restore(entry.text, to: entry.url, expecting: entry.stamp)
        } catch {
            // Put it back: a refusal is not the same as having undone it, and
            // the next ⌘Z should still offer the same change.
            entries.append(entry)
            throw error
        }
        // Writing just moved the file's timestamp, and the entry underneath was
        // expecting the state we have this moment restored. Without this, a
        // second ⌘Z reads its own predecessor as somebody else's edit and
        // refuses — undo would only ever work once.
        if entries.last?.url == entry.url {
            stampLast(Comments.Stamp(of: entry.url))
        }
        return entry
    }

    /// Drops the newest entry without using it — for a change that was
    /// snapshotted and then failed to write, which would otherwise leave an
    /// undo offering to restore a file nobody changed.
    mutating func discardLast() {
        if !entries.isEmpty { entries.removeLast() }
    }
}
