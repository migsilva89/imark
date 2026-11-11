// Tests for the Live editor's changed-lines gutter (docs/LIVE-PREVIEW.md §5, M4):
// which lines differ from the saved text, measured the way the source editor's
// `MarkdownEditorView.modifiedLines` measures them — a real line diff, so one
// inserted line marks that line and not everything under it, and a deleted line
// marks nothing. No DOM: the diff is plain arrays, and the gutter's state is a
// field on an EditorState.
//
//   node Support/test-live-gutter.mjs

import { EditorState } from '../renderer/node_modules/@codemirror/state/dist/index.js'
import { changedLines } from '../renderer/src/editor/changed-lines.js'
import { changedLinesField, setBaseline, changedLinesOf } from '../renderer/src/editor/gutter.js'

let failures = 0
const check = (name, ok, detail = '') => {
  if (ok) console.log(`OK   ${name}`)
  else {
    failures += 1
    console.log(`FAIL ${name}  ${detail}`)
  }
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const lines = (s) => s.split('\n')
const diff = (saved, now) => changedLines(lines(saved), lines(now))

// --- The diff, against the same cases the source editor's gutter answers

check('nothing changed marks nothing', same(diff('a\nb\nc', 'a\nb\nc'), []))
check('an edited line is marked', same(diff('a\nb\nc', 'a\nB\nc'), [1]), JSON.stringify(diff('a\nb\nc', 'a\nB\nc')))
check('an inserted line marks only itself, not the lines below it',
  same(diff('a\nb\nc\nd', 'a\nnew\nb\nc\nd'), [1]), JSON.stringify(diff('a\nb\nc\nd', 'a\nnew\nb\nc\nd')))
check('a deleted line marks nothing', same(diff('a\nb\nc\nd', 'a\nc\nd'), []))
check('a line added at the end', same(diff('a\nb', 'a\nb\nc'), [2]))
check('a line added at the top', same(diff('a\nb', 'z\na\nb'), [0]))
check('two edits far apart are two marks',
  same(diff(Array.from({ length: 5000 }, (_, i) => `l${i}`).join('\n'),
    Array.from({ length: 5000 }, (_, i) => (i === 3 || i === 4900 ? `x${i}` : `l${i}`)).join('\n')), [3, 4900]))
check('a repeated line inserted next to its twin marks one line',
  diff('a\nb\nb\nc', 'a\nb\nb\nb\nc').length === 1)
check('an emptied document marks its one empty line', same(diff('a\nb', ''), [0]))
check('a document filled from empty marks every line', same(diff('', 'a\nb'), [0, 1]))
{
  // Past the effort the diff is allowed, the changed middle is marked whole
  // rather than the page stalling. Still only the middle: the untouched top and
  // bottom stay clean.
  const saved = ['top', ...Array.from({ length: 3000 }, (_, i) => `s${i}`), 'bottom']
  const now = ['top', ...Array.from({ length: 3000 }, (_, i) => `n${i}`), 'bottom']
  const marks = changedLines(saved, now)
  check('a wholesale rewrite marks the rewritten lines and not the rest',
    marks.length === 3000 && marks[0] === 1 && marks[marks.length - 1] === 3000, `${marks.length}`)
}

// --- The field: a baseline, edits against it, and a save that clears it

function stateFor(doc, crlf = false) {
  return EditorState.create({
    doc,
    extensions: [changedLinesField, ...(crlf ? [EditorState.lineSeparator.of('\r\n')] : [])],
  })
}

{
  let s = stateFor('one\ntwo\nthree\n')
  check('a fresh document has no marks', same(changedLinesOf(s), []))
  s = s.update({ changes: { from: 4, insert: 'TWO ' } }).state
  check('typing in a line marks it', same(changedLinesOf(s), [1]))
  s = s.update({ changes: { from: 0, insert: 'zero\n' } }).state
  check('a line typed above moves the mark with its line', same(changedLinesOf(s), [0, 2]))
  s = s.update({ effects: setBaseline.of(s.doc) }).state
  check('saving clears every mark', same(changedLinesOf(s), []))
  s = s.update({ changes: { from: 0, to: 5 } }).state
  check('deleting a saved line marks nothing', same(changedLinesOf(s), []))
}

{
  // CRLF: CodeMirror's lines are the file's lines.
  let s = stateFor('a\r\nb\r\nc\r\n', true)
  s = s.update({ changes: { from: s.doc.line(3).from, insert: 'C' } }).state
  check('CRLF: the third line is the third line', same(changedLinesOf(s), [2]))
}

{
  // A buffer handed over with unsaved changes in it: the baseline is the file.
  let s = stateFor('a\nB\nc')
  s = s.update({ effects: setBaseline.of('a\nb\nc') }).state
  check('a baseline given as the saved text marks what differs from it', same(changedLinesOf(s), [1]))
  s = s.update({ effects: setBaseline.of('a\r\nb\r\nc') }).state
  check('the saved text is split on any break', same(changedLinesOf(s), [1]))
}

{
  // The field keeps what it knew between edits and diffs only what an edit
  // touched. Whatever it kept, the marks must be the ones a diff from scratch
  // gives: random edits of every shape — several at once, lines joined and
  // split, at both ends — and now and then a save.
  let seed = 7
  const random = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648)
  const pick = (n) => Math.floor(random() * n)
  const words = ['a', 'b', 'c', '\n', '\n\n', 'line\n', 'x', '']
  let s = stateFor(Array.from({ length: 40 }, (_, i) => `line ${i % 7}`).join('\n'))
  let baseline = s.doc.toJSON()
  let agree = true
  let detail = ''
  for (let step = 0; step < 3000 && agree; step += 1) {
    if (pick(40) === 0) {
      s = s.update({ effects: setBaseline.of(s.doc) }).state
      baseline = s.doc.toJSON()
      continue
    }
    const changes = []
    let at = 0
    for (let n = 1 + pick(3); n > 0 && at <= s.doc.length; n -= 1) {
      const from = Math.min(s.doc.length, at + pick(Math.max(1, Math.floor(s.doc.length / 3))))
      const to = Math.min(s.doc.length, from + pick(8))
      changes.push({ from, to, insert: words[pick(words.length)] })
      at = to + 1
    }
    const end = pick(10) === 0 ? [{ from: s.doc.length, insert: words[pick(words.length)] }] : []
    const start = pick(10) === 0 ? [{ from: 0, to: Math.min(2, s.doc.length), insert: words[pick(words.length)] }] : []
    s = s.update({ changes: [...start, ...changes.filter((c) => c.from >= (start.length ? 3 : 0)), ...end] }).state
    const kept = changedLinesOf(s)
    const fresh = changedLines(baseline, s.doc.toJSON())
    if (!same(kept, fresh)) {
      agree = false
      detail = `step ${step}: kept ${JSON.stringify(kept)} fresh ${JSON.stringify(fresh)}`
    }
  }
  check('after thousands of random edits the kept marks are a fresh diff\'s marks', agree, detail)
}

console.log(failures ? `\n${failures} failed` : '\nall passed')
process.exit(failures ? 1 : 0)
