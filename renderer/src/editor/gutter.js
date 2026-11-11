// The bar beside every line that differs from the file as saved, as the source
// editor's `LineGutter` draws it (docs/LIVE-PREVIEW.md §5, M4): two pixels of the
// accent, at the window's left edge, inset a little from the line's top and
// bottom. No line numbers — the Live editor is the page, not the source.
//
// The saved text is kept here, as lines, in a state field next to the marks.
// `setBaseline` replaces it: on `load` with what Swift says the file holds (the
// buffer itself for a file just read, something older for a buffer handed over
// with unsaved changes in it) and on `markSaved` with the document as it stands.
// Every edit diffs the document against it again (changed-lines.js), which costs
// a line or two for ordinary typing.

import { StateEffect, StateField } from '@codemirror/state'
import { GutterMarker, gutter } from '@codemirror/view'
import { diffAgainst } from './changed-lines.js'

/// The saved text: a CodeMirror `Text`, or a string as the file has it, split
/// on any line break.
export const setBaseline = StateEffect.define()

const linesOf = (saved) =>
  typeof saved === 'string' ? saved.split(/\r\n|\r|\n/) : saved.toJSON()

/// The document's lines, read one at a time: copying a megabyte out of the
/// document on every keystroke cost more than everything else a key does.
const linesIn = (doc) => ({ length: doc.lines, line: (i) => doc.line(i + 1).text })

function measure(baseline, doc, known) {
  const { list, prefix, suffix } = diffAgainst(baseline, linesIn(doc), known)
  return { baseline, list, prefix, suffix }
}

/// What an edit leaves known: the lines above the first one it touched and
/// below the last one are as they were, so as far as they were the same as the
/// saved text, they still are.
function stillKnown(value, tr) {
  const before = tr.startState.doc
  let first = before.lines
  let last = -1
  tr.changes.iterChangedRanges((fromA, toA) => {
    first = Math.min(first, before.lineAt(fromA).number - 1)
    last = Math.max(last, before.lineAt(toA).number - 1)
  })
  return {
    prefix: Math.min(value.prefix, first),
    suffix: Math.min(value.suffix, before.lines - 1 - last),
  }
}

export const changedLinesField = StateField.define({
  create: (state) => ({ baseline: state.doc.toJSON(), list: [], prefix: state.doc.lines, suffix: 0 }),
  update(value, tr) {
    let baseline = value.baseline
    for (const effect of tr.effects) if (effect.is(setBaseline)) baseline = linesOf(effect.value)
    if (baseline !== value.baseline) return measure(baseline, tr.state.doc, {})
    if (!tr.docChanged) return value
    return measure(baseline, tr.state.doc, stillKnown(value, tr))
  },
})

/// Whether a line, from zero, is marked. The list is in order.
function isMarked(list, line) {
  let low = 0
  let high = list.length - 1
  while (low <= high) {
    const mid = (low + high) >> 1
    if (list[mid] === line) return true
    if (list[mid] < line) low = mid + 1
    else high = mid - 1
  }
  return false
}

/// The marked lines, counted from zero. For the tests and the harness.
export const changedLinesOf = (state) => state.field(changedLinesField).list

class ChangedMarker extends GutterMarker {
  eq(other) { return other instanceof ChangedMarker }
  toDOM() {
    const bar = document.createElement('div')
    bar.className = 'cm-imark-changed-bar'
    return bar
  }
}
ChangedMarker.prototype.elementClass = 'cm-imark-changed'
const changedMarker = new ChangedMarker()

export const changedLinesGutter = [
  changedLinesField,
  gutter({
    class: 'cm-imark-changes',
    // One block can stand for several lines — a table drawn as a widget — and
    // it is marked when any of them changed.
    lineMarker(view, block) {
      const { list } = view.state.field(changedLinesField)
      if (!list.length) return null
      const doc = view.state.doc
      const first = doc.lineAt(block.from).number - 1
      const last = doc.lineAt(block.to).number - 1
      for (let i = first; i <= last; i += 1) if (isMarked(list, i)) return changedMarker
      return null
    },
    lineMarkerChange: (update) =>
      update.startState.field(changedLinesField) !== update.state.field(changedLinesField),
    initialSpacer: null,
  }),
]

