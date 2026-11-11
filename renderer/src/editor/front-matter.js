// The front-matter card in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): the
// `---` … `---` block at the top, drawn as the preview's card (`renderFrontMatter`)
// until the caret comes onto one of its lines.
//
// Which block counts is blocks.js's `frontMatterEnd`, which follows the rule the
// preview does: only YAML that reads as an object. And the card is shown or put
// away by the same switch (View ▸ Front Matter), as the same CSS rule: hidden,
// the card takes no room but the block is still there in the file — and a caret
// that arrives from the line below shows it.

import { load as parseYaml } from 'js-yaml'
import { renderFrontMatter } from '../shared/markdown.js'
import { BlockWidget, frontMatterEnd, registerBlock } from './blocks.js'

/// The front matter's parsed fields, or null when the block is not front matter
/// that the preview would draw anything for.
function fieldsOf(state, end) {
  const doc = state.doc
  const last = doc.lineAt(end).number
  try {
    return parseYaml(doc.sliceString(doc.line(2).from, doc.line(last - 1).to))
  } catch {
    return null
  }
}

class FrontMatterWidget extends BlockWidget {
  get estimatedHeight() {
    return 120
  }

  render() {
    const dom = document.createElement('div')
    dom.className = 'cm-live-md cm-live-frontmatter-card'
    dom.innerHTML = renderFrontMatter(this.data.fields)
    return dom
  }
}

registerBlock({
  type: 'front-matter',
  scan(state) {
    const end = frontMatterEnd(state)
    if (!end) return []
    const fields = fieldsOf(state, end)
    // The preview draws nothing for a block with neither a title nor a row to
    // show (an `imark:` key only); then there is nothing to put in the card's
    // place, and the source stays.
    if (!renderFrontMatter(fields)) return []
    return [{ from: 0, to: end, data: { fields } }]
  },
  widget: (data, info) => new FrontMatterWidget(info.source, data),
})
