// Task boxes in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): the `[ ]` or
// `[x]` of a task item drawn as a real checkbox, ticked with a click.
//
// A tick here is an edit like any other: one transaction that changes the one
// character between the brackets, so it is unsaved until ⌘S, goes into the
// history, and reaches Swift as an ordinary `changes` message. The preview's
// way — posting `task` for Swift to write the file through Comments.setTask —
// would write under an open buffer and move the stamp the stale-save check
// relies on (§1, invariant 2). This page has no message that writes anything.
//
// The box shows even with the caret on its line, as in Obsidian; only the caret
// in or right beside the `[ ]` itself turns it back into source. The tree finds
// the markers, so a `- [ ]` inside a code block or a comment is never a box.

import { isolateHistory } from '@codemirror/commands'
import { BlockWidget, registerBlock } from './blocks.js'

const MARKER = /^\[[ xX]\]$/

/// The transaction that ticks or unticks the box whose `[` is at `from`, or null
/// when there is no box there. One character, a space for an `x` or an `X` and
/// an `x` for a space, and no selection: the caret stays wherever it was. Its
/// own step in the history, so ⌘Z takes back the tick and not the typing too.
export function toggleTask(state, from) {
  const marker = state.doc.sliceString(from, from + 3)
  if (!MARKER.test(marker)) return null
  return {
    changes: { from: from + 1, to: from + 2, insert: marker[1] === ' ' ? 'x' : ' ' },
    userEvent: 'input.toggle',
    annotations: isolateHistory.of('full'),
  }
}

class TaskWidget extends BlockWidget {
  render() {
    const box = document.createElement('input')
    box.type = 'checkbox'
    box.className = 'cm-live-task'
    box.checked = this.data.checked
    box.tabIndex = -1
    // The box changes when the text does: a tick the browser drew itself would
    // be a tick the document does not have.
    box.addEventListener('click', (event) => event.preventDefault())
    return box
  }

  mousedown(event, view, dom) {
    // Before anything else, or the browser moves the caret beside the box, the
    // box gives way to its source, and the click lands on text.
    event.preventDefault()
    if (event.button !== 0 || view.state.readOnly) return
    const spec = toggleTask(view.state, this.position(view, dom))
    if (spec) view.dispatch(spec)
  }
}

registerBlock({
  type: 'task',
  nodes: ['TaskMarker'],
  block: false,
  reveal: 'range',
  match(node, state) {
    const marker = state.doc.sliceString(node.from, node.to)
    return MARKER.test(marker) ? { from: node.from, to: node.to, data: { checked: marker[1] !== ' ' } } : null
  },
  widget: (data, info) => new TaskWidget(info.source, data),
})
