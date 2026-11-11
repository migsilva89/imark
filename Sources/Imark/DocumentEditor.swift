import AppKit

/// What the window needs from whichever editor is holding the document: the
/// source editor (`MarkdownEditorView`, an `NSTextView`) or the Live one
/// (`LiveEditorView`, CodeMirror in a web view). Pulled out of what the source
/// editor already offered, so `DocumentWindowController` asks the same questions
/// of both and none of its saving, reverting or leaving changed meaning when the
/// second editor arrived (docs/LIVE-PREVIEW.md §3.1).
///
/// `text` and `isDirty` are synchronous on purpose. Closing a window, opening
/// another document in it and the file watcher's dirty guard all ask from code
/// that cannot wait for a web view to answer, and a wrong answer there is a lost
/// document.
protocol DocumentEditor: NSView {
    /// Called on every edit, so the window can find out it has something unsaved
    /// without asking.
    var onEdit: (() -> Void)? { get set }
    /// ⌘S from inside the editor, which owns the keyboard while it has focus.
    var onSave: (() -> Void)? { get set }

    /// The document as it would be written.
    var text: String { get }
    /// What the file held when it was loaded or last saved, as the file has it.
    var savedText: String { get }
    /// Compared unit by unit, never with `String ==`: a letter recomposed from
    /// two code points into one is the same to Swift and a different file.
    var isDirty: Bool { get }
    /// Whether `text` is the document as the person sees it right now. The Live
    /// editor's copy falls behind for the moment between noticing it has lost
    /// step with the page and the page's full text arriving; a save or a hand-
    /// over in that moment would write or carry a document missing the latest
    /// edits, so both refuse instead and the next attempt finds it caught up.
    var textIsCurrent: Bool { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }

    /// A file, freshly read: the buffer and the copy on disk are the same text.
    func load(_ text: String)
    /// A buffer with unsaved changes in it, handed over from the other editor.
    /// Undo history does not come with it.
    func load(_ text: String, saved: String)
    /// The same file read again after somebody else saved it, with nothing
    /// unsaved here: like `load`, but the caret stays on its line and the view
    /// on its top line, rather than both going back to the start every time the
    /// file changes on disk.
    func reload(_ text: String)
    func markSaved()
    func focus()

    /// Where the reader is, in the file's lines counted from zero — the lines
    /// the preview's `data-line` counts, front matter included and `\r\n` one
    /// break. The first line showing at the top, and the line the caret is on.
    /// Synchronous, because leaving editing and ⇧⌘E ask on their way out.
    var topLine: Int { get }
    var caretLine: Int { get }
    /// Puts `line` at the top of the view and the caret at the start of
    /// `caret`. Clamped to the document.
    func scrollTo(line: Int, caret: Int)
    func undo()
    func redo()
    func showFind()
}

extension DocumentEditor {
    func load(_ text: String) { load(text, saved: text) }
    var textIsCurrent: Bool { true }
}
