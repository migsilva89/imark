// Footnote references in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): `[^1]`
// drawn as a small raised number, numbered as the preview numbers them — in the
// order the notes are first used, which only the whole document knows. So the
// number comes out of `ctx.env().footnotes`, the same parse the reading view
// would make, and is part of what makes two widgets equal: a note added above
// renumbers every reference below it, and each is drawn again.
//
// A `[^x]` the document does not define is plain text in the preview, and here.
// The definitions themselves (`[^1]: …`) stay as source, a little dimmer.

import { syntaxTree } from '@codemirror/language'
import { BlockWidget, registerBlock } from './blocks.js'

// For each reference, which use of its note it is (0 for the first): the
// preview shows the second as `[1:1]`. Counted in the order of the tree, once
// per tree.
const uses = new WeakMap()
function usesIn(state) {
  const tree = syntaxTree(state)
  let found = uses.get(tree)
  if (found) return found
  found = new Map()
  const counts = new Map()
  tree.iterate({
    enter(ref) {
      if (ref.name !== 'FootnoteRef') return
      const label = state.sliceDoc(ref.from + 2, ref.to - 1)
      const seen = counts.get(label) ?? 0
      counts.set(label, seen + 1)
      found.set(ref.from, seen)
    },
  })
  uses.set(tree, found)
  return found
}

class FootnoteWidget extends BlockWidget {
  eq(other) {
    return super.eq(other) && other.data.caption === this.data.caption
  }

  render() {
    const sup = document.createElement('sup')
    sup.className = 'cm-live-footnote'
    sup.textContent = this.data.caption
    return sup
  }
}

registerBlock({
  type: 'footnote',
  nodes: ['FootnoteRef'],
  block: false,
  reveal: 'range',
  match(node, state, ctx) {
    const label = state.sliceDoc(node.from + 2, node.to - 1)
    const refs = ctx.env().footnotes?.refs
    const id = refs?.[`:${label}`]
    // Undefined: no definition, so not a reference. Negative: defined and never
    // used, which cannot be said of a reference that is here, but costs nothing
    // to refuse.
    if (id === undefined || id < 0) return null
    const sub = usesIn(state).get(node.from) ?? 0
    return { from: node.from, to: node.to, data: { caption: `[${id + 1}${sub > 0 ? `:${sub}` : ''}]` } }
  },
  widget: (data, info) => new FootnoteWidget(info.source, data),
})
