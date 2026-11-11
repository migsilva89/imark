// Tests for the Live Preview's block widgets (docs/LIVE-PREVIEW.md §4, M3):
// where each one sits, when it gives way to its source, and the two that edit —
// a task box ticks one character, a comment block goes as one undoable piece.
// No DOM: `blockRanges` reads an EditorState and returns data, and the edits are
// transactions on a state.
//
//   node Support/test-live-blocks.mjs
//
// The rule above all (§1): nothing here writes anything but a transaction on the
// buffer, and nothing that only moves the selection changes a byte.

import { EditorState, EditorSelection } from '../renderer/node_modules/@codemirror/state/dist/index.js'
import { markdown, markdownLanguage } from '../renderer/node_modules/@codemirror/lang-markdown/dist/index.js'
import { ensureSyntaxTree, syntaxTree as syntaxTreeOf } from '../renderer/node_modules/@codemirror/language/dist/index.js'
import { history, undo, undoDepth } from '../renderer/node_modules/@codemirror/commands/dist/index.js'
import { inlineExtensions } from '../renderer/src/editor/inline.js'
import * as Live from '../renderer/src/editor/live.js'
import * as Blocks from '../renderer/src/editor/blocks.js'
import { toggleTask } from '../renderer/src/editor/tasks.js'
import { notesIn } from '../renderer/src/editor/notes.js'
import { displayMath } from '../renderer/src/editor/math-block.js'
import { setDocumentPath, resolveFile, resolveHref } from '../renderer/src/editor/doc-path.js'
import { createMarkdown, splitFrontMatter, renderFrontMatter } from '../renderer/src/shared/markdown.js'

const { blockRanges, blockDeletion, revealBlock, renderContext, liveBlocks } = Blocks

let failures = 0
const check = (name, ok, detail = '') => {
  if (ok) console.log(`OK   ${name}`)
  else {
    failures += 1
    console.log(`FAIL ${name}  ${detail}`)
  }
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

/// A state set up as the editor sets one up: the language, history, and the
/// block field (which the Backspace/Delete commands and forced reveals read).
function stateFor(doc, at = 0, crlf = false) {
  const extensions = [
    markdown({ base: markdownLanguage, extensions: inlineExtensions }),
    EditorState.allowMultipleSelections.of(true),
    history(),
    liveBlocks(),
  ]
  if (crlf) extensions.push(EditorState.lineSeparator.of('\r\n'))
  const length = doc.split('\r\n').join('\n').length
  const ranges = [].concat(at).map((a) =>
    a === 'end' ? EditorSelection.cursor(length) : typeof a === 'number' ? EditorSelection.cursor(a) : EditorSelection.range(a.from, a.to)
  )
  const state = EditorState.create({ doc, extensions, selection: EditorSelection.create(ranges) })
  ensureSyntaxTree(state, state.doc.length, 5000)
  return state
}

// Where a substring starts, in CodeMirror's coordinates (a CRLF is one position).
const at = (doc, needle, nth = 0) => {
  let from = -1
  for (let i = 0; i <= nth; i++) from = doc.indexOf(needle, from + 1)
  if (from < 0) throw new Error(`no ${needle}`)
  return from - (doc.slice(0, from).match(/\r\n/g) || []).length
}

const ofType = (state, type, ranges = blockRanges(state)) => ranges.filter((r) => r.type === type)
const texts = (state, items) => items.map((r) => state.doc.sliceString(r.from, r.to))

/// Runs a StateCommand-shaped spec against a state and returns the new state.
const apply = (state, spec) => state.update(spec).state

// --- Tasks: where the boxes are

{
  const doc = '- [ ] one\n* [x] two\n+ [X] three\n1. [ ] four\n2) [x] five\n- [ ]no space\n- plain\n\nz'
  const s = stateFor(doc, 'end')
  const tasks = ofType(s, 'task')
  check('tasks: -, *, +, 1. and 2) items each get a box', same(texts(s, tasks), ['[ ]', '[x]', '[X]', '[ ]', '[x]']), JSON.stringify(texts(s, tasks)))
  check('tasks: checked is read from the marker, X counts', same(tasks.map((t) => t.data.checked), [false, true, true, false, true]))
  check('tasks: a box is inline, not a block, and not atomic', tasks.every((t) => !t.block && !t.atomic))
  check('tasks: drawn while the caret is elsewhere', tasks.every((t) => !t.revealed))

  const nested = '- [ ] outer\n  - [x] inner\n    1. [ ] deeper\n> - [ ] quoted\n\nz'
  const n = stateFor(nested, 'end')
  check('tasks: nested and quoted items get boxes too', same(texts(n, ofType(n, 'task')), ['[ ]', '[x]', '[ ]', '[ ]']))

  const fenced = '```\n- [ ] not a task\n```\n\n    - [ ] indented code\n\n<!-- imark by="a"\n- [ ] inside a note\n-->\n\n- [ ] real\n'
  const f = stateFor(fenced, 0)
  check('tasks: none in fenced or indented code, nor inside a comment block',
    same(texts(f, ofType(f, 'task')), ['[ ]']) && ofType(f, 'task')[0].from === at(fenced, '[ ] real'))

  const crlf = '- [ ] a\r\n- [x] b\r\n'
  const c = stateFor(crlf, 'end', true)
  check('tasks: CRLF positions are CodeMirror positions',
    same(ofType(c, 'task').map((t) => t.from), [2, 10]) && same(texts(c, ofType(c, 'task')), ['[ ]', '[x]']))
}

// --- Tasks: when the source shows

{
  const doc = '- [ ] one two\n\nz'
  const onLine = stateFor(doc, at(doc, 'two'))
  check('tasks: the box stays with the caret elsewhere on its line', !ofType(onLine, 'task')[0].revealed)
  const inside = stateFor(doc, at(doc, '[ ]') + 1)
  check('tasks: the caret inside [ ] shows the source', ofType(inside, 'task')[0].revealed)
  const before = stateFor(doc, at(doc, '[ ]'))
  check('tasks: the caret at the [ (adjacent) shows it too', ofType(before, 'task')[0].revealed)
  const spanning = stateFor(doc, { from: 0, to: doc.length })
  check('tasks: a selection over the line shows it', ofType(spanning, 'task')[0].revealed)
}

// --- Tasks: the bullet beside a box

{
  const doc = '- [ ] one\n1. [ ] two\n- plain\n\nz'
  const s = stateFor(doc, 'end')
  const items = Live.liveDecorations(s, [{ from: 0, to: s.doc.length }])
  const hidden = items.filter((i) => i.kind === 'hide').map((i) => s.sliceDoc(i.from, i.to))
  check('tasks: a bullet task hides its "- ", as the preview draws no bullet beside a box', same(hidden, ['- ']), JSON.stringify(hidden))
  check('tasks: a plain item keeps its bullet; an ordered task keeps its number',
    items.filter((i) => i.kind === 'bullet').length === 1 && items.some((i) => i.class === 'cm-live-number'))
  const near = stateFor(doc, at(doc, '[ ] one'))
  const shown = Live.liveDecorations(near, [{ from: 0, to: near.doc.length }]).filter((i) => i.kind === 'hide')
  check('tasks: revealing the box reveals its "- " too', shown.length === 0)
}

// --- Tasks: the tick is one character, and nothing else moves

{
  const doc = '- [ ] one\n- [x] two\n- [X] three\n'
  let s = stateFor(doc, at(doc, 'two') + 1)
  const selection = s.selection
  const tasks = ofType(s, 'task')

  const tick = toggleTask(s, tasks[0].from)
  const ticked = apply(s, tick)
  const changed = []
  s.update(tick).changes.iterChanges((fromA, toA, _fB, _tB, inserted) => changed.push([fromA, toA, inserted.toString()]))
  check('toggle: [ ] → [x] is one character replaced by one', same(changed, [[3, 4, 'x']]), JSON.stringify(changed))
  check('toggle: the rest of the document is byte for byte the same', ticked.sliceDoc() === '- [x] one\n- [x] two\n- [X] three\n')
  check('toggle: the selection does not move', ticked.selection.eq(selection))
  check('toggle: no selection is set by the transaction', !('selection' in tick))

  const untick = apply(s, toggleTask(s, tasks[1].from))
  check('toggle: [x] → [ ]', untick.sliceDoc() === '- [ ] one\n- [ ] two\n- [X] three\n')
  const upper = apply(s, toggleTask(s, tasks[2].from))
  check('toggle: [X] → [ ] (a tick in either case is a tick)', upper.sliceDoc() === '- [ ] one\n- [x] two\n- [ ] three\n')
  check('toggle: not a box, no transaction', toggleTask(s, 0) === null)

  const crlf = '- [ ] a\r\n- [ ] b\r\n'
  const c = stateFor(crlf, 0, true)
  const t = apply(c, toggleTask(c, ofType(c, 'task')[1].from))
  check('toggle: CRLF document keeps every break', t.sliceDoc() === '- [ ] a\r\n- [x] b\r\n')
  check('toggle: one undo step takes it back', undoDepth(t) === 1 && (() => { let back = t; undo({ state: t, dispatch: (tr) => { back = tr.state } }); return back.sliceDoc() === crlf })())
}

// --- Comments: where the blocks are

{
  const doc = 'Para.\n\n<!-- imark by="ian" at="2026-08-02T14:31Z" color="blue"\nFirst line of it.\nSecond &amp; last.\n-->\n\nNext.\n\n<!-- imark scope="file" -->\n'
  const s = stateFor(doc, 0)
  const notes = ofType(s, 'note')
  check('notes: two blocks found', notes.length === 2, JSON.stringify(notes))
  check('notes: each spans its whole lines, open to close',
    same(texts(s, notes), ['<!-- imark by="ian" at="2026-08-02T14:31Z" color="blue"\nFirst line of it.\nSecond &amp; last.\n-->', '<!-- imark scope="file" -->']))
  check('notes: a note is an atomic block', notes.every((n) => n.block && n.atomic))
  check('notes: author, colour and body are read as the preview reads them',
    notes[0].data.by === 'ian' && notes[0].data.colour === 'blue' && notes[0].data.text === 'First line of it. Second & last.', JSON.stringify(notes[0].data))
  const inside = stateFor(doc, at(doc, 'First') + 2)
  check('notes: the caret does not reveal a note', ofType(inside, 'note').every((n) => !n.revealed))

  const fenced = '```md\n<!-- imark by="example"\nnot a note\n-->\n```\n\n~~~~\n<!-- imark by="x" -->\n~~~\n~~~~\n\n<!-- imark by="real" -->\n'
  const f = stateFor(fenced, 0)
  check('notes: inside a closed fence (backticks, or a longer tilde run) a note is an example, not a note',
    same(ofType(f, 'note').map((n) => n.data.by), ['real']), JSON.stringify(ofType(f, 'note').map((n) => n.data.by)))
  const unclosed = '```\n<!-- imark by="seen" -->\n'
  check('notes: a fence that never closes is not a fence (Comments.swift fencedLines)',
    same(ofType(stateFor(unclosed, 0), 'note').map((n) => n.data.by), ['seen']))
  check('notes: a block that never closes is left as text', ofType(stateFor('<!-- imark by="a"\nhalf typed\n', 0), 'note').length === 0)
  check('notes: a plain HTML comment is not a note', ofType(stateFor('<!-- just html -->\n', 0), 'note').length === 0)
  const fm = '---\ntitle: x\nnote: <!-- imark by="fm" -->\n---\n\n<!-- imark by="body" -->\n'
  check('notes: nothing in front matter counts', same(ofType(stateFor(fm, 'end'), 'note').map((n) => n.data.by), ['body']))

  const crlf = 'a\r\n\r\n<!-- imark by="c"\r\nbody\r\n-->\r\n\r\nb\r\n'
  const c = stateFor(crlf, 0, true)
  const cn = ofType(c, 'note')
  check('notes: CRLF positions are CodeMirror positions and the text is clean',
    cn.length === 1 && cn[0].from === 3 && c.sliceDoc(cn[0].from, cn[0].to) === '<!-- imark by="c"\r\nbody\r\n-->' && cn[0].data.text === 'body',
    JSON.stringify(cn))
}

// --- Comments: the parser agrees with the preview's

{
  // comments.js reaches for `window` when it loads; the parser itself does not.
  globalThis.window = globalThis.window ?? { addEventListener() {} }
  const { extractComments } = await import('../renderer/src/comments.js')
  const samples = [
    'a\n<!-- imark by="x" quote="q &quot;r&quot;" nth="2"\nline one\nline two\n\nnew para\n-->\nb',
    '  <!-- imark by="i" resolved="2026-01-01" -->\n```\n<!-- imark by="no" -->\n```\n````\n```\n<!-- imark by="no2" -->\n````\n',
    '<!-- imark\nunterminated',
    '``` js\n<!-- imark by="never" -->\n',
    '<!--imark by="tight"-->\n<!-- imarkable -->\n<!-- imark color="purple" -->\n',
  ]
  for (const [i, text] of samples.entries()) {
    const theirs = extractComments(text).comments.map(({ by, at, resolved, text, colour, scope, line, endLine }) => ({ by, at, resolved, text, colour, scope, line, endLine }))
    const ours = notesIn(text.split('\n')).map(({ by, at, resolved, text, colour, scope, line, endLine }) => ({ by, at, resolved, text, colour, scope, line, endLine }))
    check(`notes: sample ${i + 1} parses as the preview parses it`, same(ours, theirs), `${JSON.stringify(ours)} vs ${JSON.stringify(theirs)}`)
  }
}

// --- Comments: double-click reveal, until the caret leaves

{
  const doc = 'top\n\n<!-- imark by="a"\nbody\n-->\n\nbottom\n'
  let s = stateFor(doc, 0)
  const note = ofType(s, 'note')[0]
  s = apply(s, { selection: { anchor: note.from }, effects: revealBlock.of(note.from) })
  check('reveal: the effect shows the source', ofType(s, 'note')[0].revealed)
  check('reveal: and lifts the atomic range while it does', !blockRanges(s).some((r) => r.atomic && !r.revealed))
  s = apply(s, { selection: { anchor: at(doc, 'body') + 2 } })
  check('reveal: moving inside the block keeps it shown', ofType(s, 'note')[0].revealed)
  s = apply(s, { changes: { from: at(doc, 'body'), insert: 'x' } })
  check('reveal: an edit inside it keeps it shown', ofType(s, 'note')[0].revealed)
  s = apply(s, { selection: { anchor: s.doc.length } })
  check('reveal: leaving the block draws it again', !ofType(s, 'note')[0].revealed)
  s = apply(s, { selection: { anchor: ofType(s, 'note')[0].from } })
  check('reveal: and coming back by caret alone does not reveal it', !ofType(s, 'note')[0].revealed)
}

// --- Comments: one Backspace or Delete takes the whole block, one undo puts it back

{
  const doc = 'top\n<!-- imark by="a"\nbody\n-->\nnext\n'
  const s0 = stateFor(doc, 0)
  const note = ofType(s0, 'note')[0]
  const block = s0.sliceDoc(note.from, note.to)
  const without = 'top\nnext\n'

  const cases = [
    ['Backspace at the start of the line after', note.to + 1, false],
    ['Backspace at the end of the block', note.to, false],
    ['Delete at the start of the block', note.from, true],
    ['Delete at the end of the line before', note.from - 1, true],
  ]
  for (const [name, pos, forward] of cases) {
    // Typing just before, so a delete that joined the typing's undo group would show.
    let s = apply(stateFor(doc, 0), { changes: { from: 0, insert: 'T' }, userEvent: 'input.type' })
    s = apply(s, { selection: { anchor: pos + 1 } })
    const spec = blockDeletion(s, forward)
    if (!spec) { check(`delete: ${name}`, false, 'no deletion'); continue }
    const tr = s.update(spec)
    const removed = []
    tr.changes.iterChanges((fromA, toA) => removed.push(s.sliceDoc(fromA, toA)))
    check(`delete: ${name} removes exactly the block and its newline`, same(removed, [block + '\n']), JSON.stringify(removed))
    check(`delete: ${name} leaves no blank line`, tr.state.sliceDoc() === 'T' + without, JSON.stringify(tr.state.sliceDoc()))
    let back = tr.state
    undo({ state: tr.state, dispatch: (u) => { back = u.state } })
    check(`delete: ${name} is one undo step, apart from the typing`, back.sliceDoc() === 'T' + doc, JSON.stringify(back.sliceDoc()))
  }

  {
    // Holding Backspace: a character, then the block. Two deletions side by
    // side are one undo group to CodeMirror unless the block's says otherwise.
    const run = 'top\n<!-- imark by="a"\nbody\n-->\nXnext\n'
    let s = stateFor(run, at(run, 'Xnext') + 1)
    s = apply(s, { changes: { from: at(run, 'Xnext'), to: at(run, 'Xnext') + 1 }, userEvent: 'delete.backward' })
    s = apply(s, blockDeletion(s, false))
    let back = s
    undo({ state: s, dispatch: (u) => { back = u.state } })
    check('delete: after a Backspace run, one undo brings back the block and only the block',
      s.sliceDoc() === 'top\nnext\n' && back.sliceDoc() === 'top\n<!-- imark by="a"\nbody\n-->\nnext\n', JSON.stringify(back.sliceDoc()))
  }

  const last = 'top\n<!-- imark by="a" -->'
  const l = stateFor(last, 'end')
  const tr = l.update(blockDeletion(l, false))
  check('delete: a block at the very end takes the break before it', tr.state.sliceDoc() === 'top')

  const crlf = 'top\r\n<!-- imark by="a"\r\nbody\r\n-->\r\nnext\r\n'
  const c = stateFor(crlf, at(crlf, 'next'), true)
  const ct = c.update(blockDeletion(c, false))
  check('delete: CRLF block and its break go together', ct.state.sliceDoc() === 'top\r\nnext\r\n', JSON.stringify(ct.state.sliceDoc()))

  const onIt = stateFor(doc, note.from)
  const step = blockDeletion(onIt, false)
  check('delete: Backspace at the start of a block steps over the break, not into the note',
    step && !step.changes && onIt.update(step).state.selection.main.head === note.from - 1)
  const afterIt = stateFor(doc, note.to)
  const fwd = blockDeletion(afterIt, true)
  check('delete: Delete at the end of a block steps to the next line, it does not glue it on',
    fwd && !fwd.changes && afterIt.update(fwd).state.selection.main.head === note.to + 1)
  check('delete: elsewhere it is ordinary Backspace', blockDeletion(stateFor(doc, 2), false) === null)

  const revealed = apply(s0, { selection: { anchor: note.to }, effects: revealBlock.of(note.from) })
  check('delete: a revealed note deletes a character at a time, like any text', blockDeletion(revealed, false) === null)
}

// --- Comments: no other edit can half-eat a drawn note

{
  const doc = 'top\n<!-- imark by="a"\nbody\n-->\nnext\n'
  const s = stateFor(doc, 0)
  const note = ofType(s, 'note')[0]
  const after = (spec, state = s) => state.update(spec).state.sliceDoc()

  check('atomic: typing at the end of a note does not land on its --> line', after({ changes: { from: note.to, insert: 'x' }, userEvent: 'input.type' }) === doc)
  check('atomic: typing at its start does not unmake it', after({ changes: { from: note.from, insert: 'x' }, userEvent: 'input.type' }) === doc)
  check('atomic: pasting at its end neither', after({ changes: { from: note.to, insert: 'pasted' }, userEvent: 'input.paste' }) === doc)
  check('atomic: removing the break after it does not glue the next line on', after({ changes: { from: note.to, to: note.to + 1 }, userEvent: 'delete.forward' }) === doc)
  check('atomic: removing the break before it does not glue it onto the line above', after({ changes: { from: note.from - 1, to: note.from }, userEvent: 'delete.backward' }) === doc)
  check('atomic: an edit into its middle (a word-delete from outside) is refused', after({ changes: { from: note.to - 2, to: note.to + 2 }, userEvent: 'delete.backward' }) === doc)
  check('atomic: Enter at either edge is a new line, and allowed',
    after({ changes: { from: note.to, insert: '\n' }, userEvent: 'input' }) === 'top\n<!-- imark by="a"\nbody\n-->\n\nnext\n' &&
    after({ changes: { from: note.from, insert: '\n' }, userEvent: 'input' }) === 'top\n\n<!-- imark by="a"\nbody\n-->\nnext\n')
  check('atomic: a change that takes the whole note is allowed', after({ changes: { from: 0, to: note.to + 1 }, userEvent: 'delete.selection' }) === 'next\n')
  check('atomic: edits elsewhere are untouched', after({ changes: { from: 0, insert: 'x' }, userEvent: 'input.type' }) === 'x' + doc)
  const emptyAbove = 'a\n\n<!-- imark by="a" -->\nb'
  const e = stateFor(emptyAbove, 0)
  const en = ofType(e, 'note')[0]
  check('atomic: removing an empty line above it leaves it a whole-line note, and is allowed',
    after({ changes: { from: en.from - 1, to: en.from }, userEvent: 'delete.backward' }, e) === 'a\n<!-- imark by="a" -->\nb')

  const revealed = apply(s, { selection: { anchor: note.from + 3 }, effects: revealBlock.of(note.from) })
  const typed = apply(revealed, { changes: { from: note.to, insert: ' x' }, userEvent: 'input.type' })
  check('atomic: a revealed note is text, typed into like any', typed.sliceDoc() === 'top\n<!-- imark by="a"\nbody\n--> x\nnext\n')
  const away = apply(typed, { selection: { anchor: typed.doc.length } })
  let back = away
  undo({ state: away, dispatch: (u) => { back = u.state } })
  check('atomic: and undoing that once it is drawn again is not refused', back.sliceDoc() === doc, JSON.stringify(back.sliceDoc()))

  const crlf = 'top\r\n<!-- imark by="a"\r\nbody\r\n-->\r\nnext\r\n'
  const c = stateFor(crlf, 0, true)
  const cn = ofType(c, 'note')[0]
  check('atomic: CRLF, typing at the end is refused, Enter is not',
    after({ changes: { from: cn.to, insert: 'x' }, userEvent: 'input.type' }, c) === crlf &&
    // CodeMirror's Enter inserts the state's own break; in the editor a pasted
    // lone \n is made one by main.js's filter before this one looks.
    after({ changes: { from: cn.to, insert: c.lineBreak }, userEvent: 'input' }, c) === 'top\r\n<!-- imark by="a"\r\nbody\r\n-->\r\n\r\nnext\r\n')
}

// --- IME: the drawn set holds still through a composition

{
  const doc = '- [ ] one\n\nz'
  const s = stateFor(doc, 'end')
  const field = Blocks.blockField
  const drawnCount = (state) => state.field(field).decorations.size
  check('ime: the box is drawn to start with', drawnCount(s) === 1)
  const composing = apply(s, { selection: { anchor: at(doc, '[ ]') + 1 }, userEvent: 'input.type.compose' })
  check('ime: a composition transaction moving the caret into [ ] leaves the set as it was', drawnCount(composing) === 1)
  const after = apply(composing, {})
  check('ime: the next ordinary transaction catches up', drawnCount(after) === 0)
}

// --- The render context: the whole document, parsed once per version

{
  // No footnote reference in it: one that the document defines needs the whole
  // parse to be numbered, so it is parsed when the blocks are first found
  // (footnotes, below). Everything else waits until a widget draws.
  const doc = 'see [x][ref] and a note\n\n[ref]: http://r.test\n\n[^1]: the note\n'
  const s = stateFor(doc, 0)
  const before = Blocks.parseCount()
  const ctx = renderContext(s)
  check('context: nothing is parsed until a widget asks', Blocks.parseCount() === before)
  const env = ctx.env()
  check('context: reference definitions are in the env', env.references?.REF?.href === 'http://r.test', JSON.stringify(env.references))
  check('context: footnotes are in the env', !!env.footnotes, JSON.stringify(Object.keys(env)))
  ctx.env()
  const moved = apply(s, { selection: { anchor: 5 } })
  renderContext(moved).env()
  check('context: one parse for one version, however the caret moves', Blocks.parseCount() === before + 1 && renderContext(moved) === ctx)
  const edited = apply(s, { changes: { from: 0, insert: 'x' } })
  check('context: a new version is a new context', renderContext(edited) !== ctx)
  const html = ctx.render('[x][ref]\n')
  check('context: a slice renders with the document\'s definitions', html.includes('href="http://r.test"'), html)
}

// --- Overlaps and the M2 decorations under a drawn block

{
  const doc = 'a\n\n<!-- imark by="a"\n**bold** [l](u)\n-->\n\nb **c**\n'
  const s = stateFor(doc, 'end')
  const items = Live.liveDecorations(s, [{ from: 0, to: s.doc.length }])
  const note = ofType(s, 'note')[0]
  check('m2: nothing is decorated under a drawn note', !items.some((i) => i.from >= note.from && i.to <= note.to), JSON.stringify(items))
  check('m2: and the text after it still is', items.some((i) => i.class === 'cm-live-strong'))
  const ranges = blockRanges(s)
  let end = -1
  let overlap = false
  for (const r of ranges) { if (r.from < end) overlap = true; end = Math.max(end, r.to) }
  check('blocks: no two ranges overlap', !overlap)
  check('blocks: plain data, nothing but numbers, strings and flags', ranges.every((r) => typeof r.from === 'number' && typeof r.type === 'string' && typeof r.source === 'string'))
}


// --- M3b: the widgets of the preview's own blocks

/// The widgets the block field is drawing, in document order.
const widgetsOf = (state) => {
  const found = []
  state.field(Blocks.blockField).decorations.between(0, state.doc.length, (from, to, value) => {
    found.push({ from, to, widget: value.spec.widget })
  })
  return found
}
const textOf = (state, items) => texts(state, items)

// --- Tables

{
  const doc = '# T\n\n| a | b |\n|---|:-:|\n| 1 | **2** |\n\nafter\n'
  const s = stateFor(doc, 'end')
  const tables = ofType(s, 'table')
  check('table: one block, whole lines from the header to the last row', tables.length === 1 && tables[0].source === '| a | b |\n|---|:-:|\n| 1 | **2** |', JSON.stringify(tables.map((t) => t.source)))
  check('table: a block widget, revealed by lines, not atomic', tables[0].block && tables[0].reveal === 'lines' && !tables[0].atomic && !tables[0].revealed)
  const html = renderContext(s).render(tables[0].source)
  check('table: rendered by the preview\'s markdown-it, alignment and inline markup included',
    html.includes('<table') && html.includes('<strong>2</strong>') && /text-align:center/.test(html), html)
  for (const [name, caret] of [['header', at(doc, '| a')], ['delimiter row', at(doc, '|---')], ['last row', at(doc, '| 1') + 4], ['its end', at(doc, '**2** |') + 7]]) {
    check(`table: the caret on the ${name} shows its source`, ofType(stateFor(doc, caret), 'table')[0].revealed)
  }
  check('table: and the line after does not', !ofType(stateFor(doc, at(doc, 'after')), 'table')[0].revealed)
  check('table: the line before does not', !ofType(stateFor(doc, 1), 'table')[0].revealed)

  const nested = '- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n\n```\n| a | b |\n|---|---|\n```\n\n    | a | b |\n    |---|---|\n\nz'
  check('table: none inside a list, a quote, a fence or indented code', ofType(stateFor(nested, 'end'), 'table').length === 0, JSON.stringify(ofType(stateFor(nested, 'end'), 'table').map((t) => t.source)))
  check('table: a line with pipes and no delimiter row is not one', ofType(stateFor('| a | b |\n| c | d |\n\nz', 'end'), 'table').length === 0)

  const crlf = '| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\nz'
  const c = stateFor(crlf, 'end', true)
  const t = ofType(c, 'table')[0]
  check('table: CRLF — positions are CodeMirror\'s, the source has no \\r', t && t.from === 0 && t.to === 29 && !t.source.includes('\r'), JSON.stringify(t))
  check('table: CRLF — the caret on a row reveals it', ofType(stateFor(crlf, at(crlf, '| 1'), true), 'table')[0].revealed)
  const grown = apply(s, { changes: { from: at(doc, '| 1'), insert: '| 0 | 0 |\n' } })
  const [before, after] = [widgetsOf(s).find((w) => w.widget.constructor.name === 'TableWidget'), widgetsOf(grown).find((w) => w.widget.constructor.name === 'TableWidget')]
  check('table: a changed table is a different widget, an unchanged one keeps its DOM',
    !before.widget.eq(after.widget) && before.widget.eq(widgetsOf(apply(s, { changes: { from: 0, insert: 'x' } })).find((w) => w.widget.constructor.name === 'TableWidget').widget))
}

// --- Display math

{
  const doc = 'a\n\n$$x^2$$\n\nb\n\n$$\n\\begin{aligned}\n- a &= 1 \\\\\n# b &= 2\n\\end{aligned}\n$$\n\nc\n'
  const s = stateFor(doc, 'end')
  const math = ofType(s, 'math')
  check('math: a one-line and a multi-line formula, the inside not read as Markdown',
    same(math.map((m) => m.source), ['$$x^2$$', '$$\n\\begin{aligned}\n- a &= 1 \\\\\n# b &= 2\n\\end{aligned}\n$$']), JSON.stringify(math.map((m) => m.source)))
  check('math: blocks revealed by lines', math.every((m) => m.block && m.reveal === 'lines' && !m.revealed))
  check('math: the caret anywhere inside the multi-line formula shows it', ofType(stateFor(doc, at(doc, '# b')), 'math')[1].revealed)
  check('math: the line after does not', !ofType(stateFor(doc, at(doc, 'c\n')), 'math')[1].revealed)
  const html = renderContext(s).render(math[0].source, { bare: true })
  check('math: rendered through the preview pipeline (math.js, KaTeX)', html.includes('katex-block') && html.includes('class="katex'), html)

  const found = (text) => displayMath(stateFor(text, 'end')).map((r) => text.slice(r.from, r.to))
  check('math: text before the opener on the same paragraph — the plugin lets $$ interrupt it', same(found('text\n$$\nx\n$$\n'), ['$$\nx\n$$']))
  check('math: two $$ on the first line is a sentence, not a block', same(found('$$a$$ and $$b$$\n'), []))
  check('math: an opener never closed is left as text (the preview would take the rest of the file)', same(found('$$\nx\n\nmore text\n'), []))
  check('math: the closer may carry text — the plugin ends the formula at the line', same(found('$$\nx\n$$ trailing\n\nz'), ['$$\nx\n$$ trailing']))
  check('math: $$ in a fence, a list, a quote or indented code is not a block', same(found('```\n$$\nx\n$$\n```\n\n- a\n\n  $$\n  x\n  $$\n\n> $$\n> x\n> $$\n\n    $$\n    x\n    $$\n'), []), JSON.stringify(found('```\n$$\nx\n$$\n```\n')))
  check('math: up to three spaces of indentation open one', same(found('   $$x$$\n'), ['   $$x$$']))
  check('math: none in front matter or a note', same(found('---\ntitle: $$x$$\n---\n\n<!-- imark by="a"\n$$x$$\n-->\n'), []), JSON.stringify(found('---\ntitle: $$x$$\n---\n\n<!-- imark by="a"\n$$x$$\n-->\n')))

  const broken = '$$\\frac{1}{$$\n\nz'
  const b = stateFor(broken, 'end')
  let html2 = ''
  let threw = false
  try { html2 = renderContext(b).render(ofType(b, 'math')[0].source, { bare: true }) } catch { threw = true }
  check('math: TeX KaTeX cannot read shows the preview\'s error styling and does not throw', !threw && html2.includes('katex-error'), html2)

  const crlf = 'a\r\n\r\n$$\r\nx\r\n$$\r\n\r\nz'
  const c = stateFor(crlf, 'end', true)
  const m = ofType(c, 'math')[0]
  check('math: CRLF — the range is CodeMirror\'s, the source has \\n', m && m.from === 3 && m.source === '$$\nx\n$$' && m.to === 10, JSON.stringify(m))
  check('math: CRLF — the caret in it reveals', ofType(stateFor(crlf, at(crlf, 'x\r\n$$'), true), 'math')[0].revealed)
}

// --- Inline math: the delimiter rules are math.js's

{
  // Each sample is parsed by the preview's markdown-it and by the editor's Lezer
  // extension, and the formulas each finds must be the same.
  const { md } = createMarkdown()
  const previewMath = (text) => {
    const out = []
    const walk = (tokens) => {
      for (const tok of tokens) {
        if (tok.type === 'math_inline') out.push(`$${tok.content}$`)
        if (tok.children) walk(tok.children)
      }
    }
    walk(md.parse(text, {}))
    return out
  }
  const editorMath = (text) => {
    const s = stateFor(text, 'end')
    const out = []
    syntaxTreeOf(s).iterate({ enter(ref) { if (ref.name === 'InlineMath') out.push(s.sliceDoc(ref.from, ref.to)) } })
    return out
  }
  const samples = [
    '$x$', 'a $x$ b', 'cost $5 and $6 today', 'cost $5 and $x$ today', '\\$x\\$', '\\$x$', '$x\\$', 'a$x$b', '$x$b', 'a$x$', '2$x$', '$x$2',
    '$ x$', '$x $', '$ x $', '($x$)', '$x$.', '$x$,', '$x$_', '_$x$_', '$$', '$$$', '$$$$', '$a$$b$', '$a$ $b$', '$a\nb$', '$a\n\nb$',
    '`$x$`', '$a `b$` c', '`a` $x$ `b`', 'x $$y$$ z', '$$y$$', '$x_1 + y_2$', '$a*b*c$', '$\\{x\\}$', '[$x$](u)', '**$x$**', '$x$ and $$y$$ and $z$',
    '$1$', '$1.5$', 'a $$ x $$ $y$', '\\\\$x$', '\\\\\\$x$', 'é$x$', '$x$é', '日本$x$語', '$x$ $', '$', 'a $ b $ c',
  ]
  const bad = []
  for (const text of samples) {
    const a = previewMath(text)
    const b = editorMath(text)
    if (!same(a, b)) bad.push(`${JSON.stringify(text)}: preview ${JSON.stringify(a)} editor ${JSON.stringify(b)}`)
  }
  check(`math inline: ${samples.length} samples find exactly the formulas math.js finds`, bad.length === 0, '\n  ' + bad.join('\n  '))

  const doc = 'a $x^2$ b and `$not$` and \\$esc\\$ and $5 or $6\n'
  const s = stateFor(doc, 'end')
  const inline = ofType(s, 'math-inline')
  check('math inline: an inline replace, revealed by range', same(texts(s, inline), ['$x^2$']) && !inline[0].block && inline[0].reveal === 'range')
  check('math inline: the caret in or beside it shows the source; a space away does not',
    ofType(stateFor(doc, at(doc, 'x^2') + 1), 'math-inline')[0].revealed && ofType(stateFor(doc, at(doc, '$x^2$')), 'math-inline')[0].revealed
    && !ofType(stateFor(doc, at(doc, '$x^2$') - 1), 'math-inline')[0].revealed)
  const html = renderContext(s).render('$x^2$', { bare: true })
  check('math inline: rendered by KaTeX through the preview', /<span class="katex"/.test(html), html)
  const bad2 = renderContext(s).render('$\\frac{$', { bare: true })
  check('math inline: broken TeX shows the error styling and does not throw', bad2.includes('katex-error'), bad2)
  const decos = Live.liveDecorations(stateFor(doc, 'end'), [{ from: 0, to: doc.length }])
  check('math inline: nothing is decorated inside a drawn formula', !decos.some((i) => i.from > at(doc, '$x^2$') && i.to <= at(doc, '$x^2$') + 5))
}

// --- Mermaid and diff fences

{
  const doc = 'a\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n~~~mermaid theme=x\nflowchart LR\n~~~\n\n```diff\n- old\n+ new\n```\n\n```js\nlet a\n```\n\n- item\n\n  ```mermaid\n  graph TD\n  ```\n\nz\n'
  const s = stateFor(doc, 'end')
  const mer = ofType(s, 'mermaid')
  check('mermaid: top-level mermaid fences, ``` and ~~~, and only those', mer.length === 2 && mer[0].source.startsWith('```mermaid') && mer[1].source.startsWith('~~~mermaid'), JSON.stringify(mer.map((m) => m.source)))
  check('mermaid: the diagram source is the fence\'s content', mer[0].data.code === 'graph TD\n  A-->B' && mer[1].data.code === 'flowchart LR', JSON.stringify(mer.map((m) => m.data)))
  check('mermaid: blocks, revealed by lines', mer.every((m) => m.block && m.reveal === 'lines' && !m.revealed))
  check('mermaid: the caret inside the fence shows it', ofType(stateFor(doc, at(doc, 'A-->B')), 'mermaid')[0].revealed)
  const diff = ofType(s, 'diff')
  check('diff: one block, the ```diff fence', diff.length === 1 && diff[0].source === '```diff\n- old\n+ new\n```', JSON.stringify(diff.map((d) => d.source)))
  check('diff: other languages and fences in a list are left alone', ofType(s, 'mermaid').length === 2 && ofType(s, 'diff').length === 1)
  const html = renderContext(s).render(diff[0].source, { bare: true })
  check('diff: rendered by renderDiff, rows tinted', html.includes('diff-block') && html.includes('diff-del') && html.includes('diff-add'), html)
  check('diff: the caret on the fence shows it', ofType(stateFor(doc, at(doc, '- old')), 'diff')[0].revealed)

  const crlf = '```mermaid\r\ngraph TD\r\n```\r\n\r\n```diff\r\n-a\r\n```\r\n\r\nz'
  const c = stateFor(crlf, 'end', true)
  check('mermaid and diff: CRLF — sources have \\n and ranges are CodeMirror\'s',
    ofType(c, 'mermaid')[0].data.code === 'graph TD' && ofType(c, 'mermaid')[0].to === 23 && ofType(c, 'diff')[0].source === '```diff\n-a\n```', JSON.stringify([ofType(c, 'mermaid'), ofType(c, 'diff')]))
  const unclosed = '```mermaid\ngraph TD\n'
  check('mermaid: an unclosed fence is a fence to the end of the file, as in the preview', ofType(stateFor(unclosed, 'end'), 'mermaid').length === 1)

  // The theme is part of what a diagram is: the same source in another palette
  // is another widget, so a change of theme draws it again.
  globalThis.document = { documentElement: { dataset: { theme: 'paper-light' } } }
  const light = widgetsOf(stateFor(doc, 'end')).find((w) => w.widget.constructor.name === 'MermaidWidget').widget
  const light2 = widgetsOf(stateFor(doc, 'end')).find((w) => w.widget.constructor.name === 'MermaidWidget').widget
  globalThis.document.documentElement.dataset.theme = 'paper-dark'
  const dark = widgetsOf(stateFor(doc, 'end')).find((w) => w.widget.constructor.name === 'MermaidWidget').widget
  delete globalThis.document
  check('mermaid: the same diagram in the same theme keeps its DOM', light.eq(light2))
  check('mermaid: a different theme is a different widget', !light.eq(dark))
  check('mermaid: a height is guessed before the first drawing', light.estimatedHeight > 0)
}

// --- Images

{
  setDocumentPath('/Users/me/Notes/doc.md')
  const doc = 'a ![alt *text*](img/a%20b.png "Title") b ![](../up.png) c ![r][ref] d ![w](https://x.test/p.png) e ![d](data:image/png;base64,AAAA)\n\n[ref]: img/r.png\n'
  const s = stateFor(doc, 'end')
  const images = ofType(s, 'image')
  check('image: each inline image, the reference one left as source',
    images.length === 4 && images.every((i) => !i.block && i.reveal === 'range' && !i.atomic) && !texts(s, images).some((t) => t.includes('[ref]')), JSON.stringify(texts(s, images)))
  check('image: alt and title come out of the source', images[0].data.alt === 'alt *text*' && images[0].data.title === 'Title' && images[1].data.alt === '' && images[1].data.title === '')
  const srcs = widgetsOf(s).filter((w) => w.widget.constructor.name === 'ImageWidget').map((w) => w.widget.src)
  check('image: src is relative to the document\'s folder, through imark://file',
    srcs[0] === 'imark://file/Users/me/Notes/img/a%20b.png' && srcs[1] === 'imark://file/Users/me/up.png', JSON.stringify(srcs))
  check('image: a remote src is kept as written (the widget shows its alt text instead of loading it)', srcs[2] === 'https://x.test/p.png' && srcs[3].startsWith('data:'))
  check('image: the caret in or beside it shows the source',
    ofType(stateFor(doc, at(doc, 'alt')), 'image')[0].revealed && ofType(stateFor(doc, at(doc, '![alt')), 'image')[0].revealed
    && !ofType(stateFor(doc, at(doc, '![alt') - 2), 'image')[0].revealed)

  // The same rules as the preview's: shared/markdown.js is given main.js's
  // resolveFile, and doc-path.js is a copy of it.
  const { md } = createMarkdown({ resolveFile })
  const samples = ['p.png', './p.png', '../p.png', 'a/../b/p.png', '/abs/p.png', 'a b.png', 'a%20b.png', 'a%3Fb.png', 'p.png?raw=true', 'p.png#frag', '#frag', '?plain=1#L3', 'https://x.test/a.png', 'data:image/png;base64,AA', 'imark://file/x', 'é/日本.png', '100%.png', '../../../../../p.png']
  const bad = []
  for (const sample of samples) {
    const html = md.render(`![a](<${sample}>)`)
    const expected = /src="([^"]*)"/.exec(html)?.[1]?.replace(/&amp;/g, '&')
    if (expected !== resolveHref(sample)) bad.push(`${sample}: preview ${expected} editor ${resolveHref(sample)}`)
  }
  check(`image: ${samples.length} paths resolve exactly as the preview resolves them`, bad.length === 0, '\n  ' + bad.join('\n  '))
  setDocumentPath('/Other/doc.md')
  const moved = widgetsOf(stateFor(doc, 'end')).find((w) => w.widget.constructor.name === 'ImageWidget').widget
  check('image: a widget made for another folder is not equal (the path is part of it)', !moved.eq(widgetsOf(s).find((w) => w.widget.constructor.name === 'ImageWidget').widget))
  setDocumentPath('')
}

// --- Footnotes

{
  const doc = 'one[^b] two[^a] again[^b] third[^b] missing[^zz] `code[^a]`\n\n[^a]: first\n[^b]: second\n  more\n\nx[^a]: not a definition\n'
  const s = stateFor(doc, 'end')
  const notes = ofType(s, 'footnote')
  const captions = notes.map((n) => n.data.caption)
  check('footnote: numbered by first use, a second use is n:1 — and only defined notes', same(captions, ['[1]', '[2]', '[1:1]', '[1:2]', '[2:1]']), JSON.stringify(captions))
  const definitions = [at(doc, '[^a]: first'), at(doc, '[^b]: second')]
  check('footnote: inline, revealed by range; the definitions are not references',
    notes.every((n) => !n.block && n.reveal === 'range') && !notes.some((n) => definitions.includes(n.from)))
  // The preview's own numbers for the same document.
  const html = createMarkdown().renderDocument(doc).html
  const preview = [...html.matchAll(/<sup class="footnote-ref"><a [^>]*>(\[[^\]]*\])<\/a><\/sup>/g)].map((m) => m[1])
  check('footnote: the numbers are the ones the preview prints', same(captions, preview), `${JSON.stringify(captions)} vs ${JSON.stringify(preview)}`)
  check('footnote: the caret in a reference shows the source; away from it does not',
    ofType(stateFor(doc, at(doc, '[^a]') + 2), 'footnote')[1].revealed && !ofType(stateFor(doc, 'end'), 'footnote')[1].revealed)
  check('footnote: a [^x] with no definition is not a widget', !texts(s, notes).includes('[^zz]') && texts(s, notes).length === 5)

  // `[^b]` is the first note used in one document and the second in the other:
  // the same source with another number is another widget, so a note added
  // above renumbers every reference below it on screen.
  const doc2 = '[^b] x[^a]\n\n[^a]: A\n[^b]: B\n'
  const doc3 = '[^a] x[^b]\n\n[^a]: A\n[^b]: B\n'
  const w2 = widgetsOf(stateFor(doc2, 'end')).map((w) => w.widget)
  const w3 = widgetsOf(stateFor(doc3, 'end')).map((w) => w.widget)
  check('footnote: the same source with another number is not the same widget', !w2[0].eq(w3[1]) && !w2[1].eq(w3[0]))
  check('footnote: the same source and number is', w2[0].eq(w3[0]) === false && w2[0].eq(widgetsOf(stateFor(doc2 + '\nmore', 'end')).map((w) => w.widget)[0]))
  const decos = Live.liveDecorations(stateFor(doc, 'end'), [{ from: 0, to: doc.length }])
  check('footnote: definitions get their quiet class, whole', decos.some((i) => i.class === 'cm-live-footnote-def' && i.from === at(doc, '[^a]: first')))
  check('footnote: and a use that happens to start a paragraph does not', !decos.some((i) => i.class === 'cm-live-footnote-def' && i.from === at(doc, 'x[^a]')))
}

// --- Front matter

{
  const doc = '---\ntitle: Hello\ntags: [a, b]\n---\n\n# Real\n'
  const s = stateFor(doc, 'end')
  const fm = ofType(s, 'front-matter')
  check('front matter: one block, from the first --- to the closing one', fm.length === 1 && fm[0].from === 0 && fm[0].source === '---\ntitle: Hello\ntags: [a, b]\n---', JSON.stringify(fm.map((f) => f.source)))
  check('front matter: a block widget revealed by lines', fm[0].block && fm[0].reveal === 'lines' && !fm[0].revealed)
  check('front matter: the caret on any of its lines shows the source', [1, 8, 20, at(doc, '---\n\n#')].every((pos) => ofType(stateFor(doc, pos), 'front-matter')[0].revealed))
  check('front matter: the line after it does not', !ofType(stateFor(doc, at(doc, '# Real')), 'front-matter')[0].revealed)
  const card = renderFrontMatter(splitFrontMatter(doc).data)
  check('front matter: the preview\'s card for it', card.includes('class="front-matter"') && card.includes('Hello') && card.includes('fm-chip'), card)
  check('front matter: broken YAML is Markdown and no card', ofType(stateFor('---\n: : [\n---\n\nbody', 'end'), 'front-matter').length === 0)
  check('front matter: only at the very top', ofType(stateFor('x\n\n---\ntitle: x\n---\n\nz', 'end'), 'front-matter').length === 0)
  check('front matter: nothing to show (only imark:) is no card', ofType(stateFor('---\nimark: {a: 1}\n---\n\nz', 'end'), 'front-matter').length === 0)
  const crlf = '---\r\ntitle: x\r\n---\r\n\r\nbody'
  const c = stateFor(crlf, 'end', true)
  check('front matter: CRLF — the range is CodeMirror\'s', ofType(c, 'front-matter')[0]?.to === 16 && ofType(c, 'front-matter')[0].source === '---\ntitle: x\n---', JSON.stringify(ofType(c, 'front-matter')))
  check('front matter: a note inside it is a value, not a card', ofType(stateFor('---\ntitle: x\nnote: "<!-- imark by=a\\n-->"\n---\n\nz', 'end'), 'note').length === 0)
}

// --- M3b: the document never changes

{
  const doc = '---\r\ntitle: T\r\n---\r\n\r\n# H\r\n\r\n| a | b |\r\n|---|---|\r\n| 1 | $x$ |\r\n\r\n$$\r\nx^2\r\n$$\r\n\r\n```mermaid\r\ngraph TD\r\n```\r\n\r\n```diff\r\n-a\r\n+b\r\n```\r\n\r\n![i](p.png) and $y$ and a note[^1]\r\n\r\n[^1]: the note\r\n\r\n<!-- imark by="z"\r\nnote\r\n-->\r\n'
  let s = stateFor(doc, 0, true)
  const kinds = new Set(blockRanges(s).map((b) => b.type))
  let ok = s.sliceDoc() === doc
  for (let pos = 0; pos <= s.doc.length; pos++) {
    s = apply(s, { selection: { anchor: pos } })
    blockRanges(s)
    widgetsOf(s)
    ok = ok && s.sliceDoc() === doc
  }
  s = apply(s, { selection: { anchor: 0 }, effects: Blocks.restyle.of(null) })
  check('m3b fidelity: a document with every kind of block — every caret position, a restyle — and sliceDoc() is the file',
    ok && s.sliceDoc() === doc && ['front-matter', 'table', 'math', 'mermaid', 'diff', 'image', 'footnote', 'math-inline', 'note'].every((k) => kinds.has(k)), [...kinds].join(','))
  let overlap = false
  let end = -1
  for (const r of blockRanges(s)) { if (r.from < end) overlap = true; end = Math.max(end, r.to) }
  check('m3b fidelity: and no two blocks overlap', !overlap)
}

// --- Fidelity: moving the selection never changes the document

{
  const doc = '# T\r\n\r\n- [ ] a\r\n  - [x] b\r\n\r\n<!-- imark by="z"\r\nnote\r\n-->\r\n\r\n```\r\n- [ ] c\r\n```\r\n'
  let s = stateFor(doc, 0, true)
  let ok = s.sliceDoc() === doc
  for (let pos = 0; pos <= s.doc.length; pos++) {
    s = apply(s, { selection: { anchor: pos } })
    blockRanges(s)
    ok = ok && s.sliceDoc() === doc
  }
  const note = ofType(s, 'note')[0]
  s = apply(s, { selection: { anchor: note.from }, effects: revealBlock.of(note.from) })
  s = apply(s, { selection: { anchor: 0 } })
  check('fidelity: every caret position, a reveal and back, and sliceDoc() is the file', ok && s.sliceDoc() === doc)
}

console.log(failures ? `\n${failures} failed` : '\nall passed')
process.exit(failures ? 1 : 0)
