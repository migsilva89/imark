// ```diff fences in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): a diff
// drawn as the preview draws one — each row tinted, the old and new line numbers
// down the side — by `renderDiff`, through the same markdown-it as the reading
// view. Top level only, and the caret on any line of the fence shows the source.

import { RenderedBlock, lastLineEnd } from './rendered.js'
import { registerBlock } from './blocks.js'

/// The first word of a fence's info string, as the preview reads it.
export function fenceLanguage(node, state) {
  const info = node.node.getChild('CodeInfo')
  return info ? state.sliceDoc(info.from, info.to).trim().split(/\s+/)[0] : ''
}

class DiffWidget extends RenderedBlock {
  get kind() {
    return 'cm-live-diff'
  }

  get bare() {
    return true
  }

  get estimatedHeight() {
    return this.source.split('\n').length * 21 + 16
  }
}

registerBlock({
  type: 'diff',
  nodes: ['FencedCode'],
  match(node, state) {
    if (node.node.parent?.name !== 'Document' || fenceLanguage(node, state) !== 'diff') return null
    return { from: node.from, to: lastLineEnd(state.doc, node.from, node.to) }
  },
  widget: (data, info) => new DiffWidget(info.source, data),
})
