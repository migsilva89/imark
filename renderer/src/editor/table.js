// GFM tables in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): the whole table
// drawn as the preview draws it, until the caret comes onto any of its lines.
//
// Not parsed here: the source goes through the preview's markdown-it, so the
// alignment, the inline markup in the cells and the classes are the reading
// view's, and a table that is wide scrolls sideways inside its widget as it
// does there. Only a table at the top level of the document: inside a list or a
// quote its lines begin with someone else's syntax, and cut out of it the table
// would not be the one the preview shows.

import { RenderedBlock, lastLineEnd } from './rendered.js'
import { registerBlock } from './blocks.js'

class TableWidget extends RenderedBlock {
  get kind() {
    return 'cm-live-table'
  }

  // A row of text and its padding; close enough before the first measure.
  get estimatedHeight() {
    return this.source.split('\n').length * 34
  }
}

registerBlock({
  type: 'table',
  nodes: ['Table'],
  match(node, state) {
    if (node.node.parent?.name !== 'Document') return null
    return { from: node.from, to: lastLineEnd(state.doc, node.from, node.to) }
  },
  widget: (data, info) => new TableWidget(info.source, data),
})
