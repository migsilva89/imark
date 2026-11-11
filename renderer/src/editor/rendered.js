// The base for a block whose picture is the preview's own HTML: the source goes
// through `ctx.render` (blocks.js), which is markdown-it with the preview's
// plugins, so the markup and its classes are what the reading view would put in
// the page, and the preview's styles — copied into editor.css under `.cm-live-md`
// — draw it.
//
// Display only, like every widget: the HTML is built from the text and thrown
// away with the widget; nothing in it can reach the document.

import { BlockWidget, renderContext } from './blocks.js'

export class RenderedBlock extends BlockWidget {
  /// The class that scopes this kind's styles, next to `cm-live-md`.
  get kind() {
    return ''
  }

  /// Whether the rendering needs the rest of the document (references,
  /// footnotes). A formula or a diff does not, and is drawn without parsing it.
  get bare() {
    return false
  }

  render(view) {
    const dom = document.createElement('div')
    dom.className = `cm-live-md ${this.kind}`
    try {
      dom.innerHTML = renderContext(view.state).render(this.source, { bare: this.bare })
    } catch {
      // A renderer that throws must not take the editor down with it; the text
      // is shown as it is, which is also what the caret would reveal.
      dom.textContent = this.source
    }
    return dom
  }
}

/// The end of a node as a block wants it: a node that stops just past its last
/// line break has not started the next line.
export function lastLineEnd(doc, from, to) {
  return to > from && doc.lineAt(to).from === to ? to - 1 : to
}
