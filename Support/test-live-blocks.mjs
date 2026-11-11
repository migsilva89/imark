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
import { ensureSyntaxTree } from '../renderer/node_modules/@codemirror/language/dist/index.js'
import { history, undo, undoDepth } from '../renderer/node_modules/@codemirror/commands/dist/index.js'
import { inlineExtensions } from '../renderer/src/editor/inline.js'
import * as Live from '../renderer/src/editor/live.js'
import * as Blocks from '../renderer/src/editor/blocks.js'
import { toggleTask } from '../renderer/src/editor/tasks.js'
import { notesIn } from '../renderer/src/editor/notes.js'

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
  const doc = 'see [x][ref] and a note[^1]\n\n[ref]: http://r.test\n\n[^1]: the note\n'
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
