// Images in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): `![alt](path)` drawn
// as the picture, in the line, until the caret touches it.
//
// The path is resolved as the preview resolves it — relative to the document's
// folder, through the `imark://file/…` scheme the app serves local files under
// (doc-path.js) — and the page has the preview's content security policy, which
// lets in `imark:` and `data:` and nothing else. So an `http(s)` image is not
// fetched, and is not tried: its alt text is shown where it would have been,
// quietly, and a local file that is not there falls back to the same.
//
// Only an image written with its address (`![a](b)`): one that names a reference
// (`![a][b]`) depends on a definition somewhere else in the file, and stays
// source.

import { t } from '../i18n.js'
import MarkdownIt from 'markdown-it'
import { BlockWidget, registerBlock } from './blocks.js'
import { resolveHref } from './doc-path.js'

// markdown-it's own unescaping of a destination, as live.js does for links.
const { unescapeAll } = new MarkdownIt('zero').utils

// img-src imark: data: — what the page's policy lets through.
const loads = (src) => /^(imark|data):/i.test(src)

class ImageWidget extends BlockWidget {
  constructor(source, data) {
    super(source, data)
    // Worked out when the widget is made, not when the text is read: the folder
    // it is relative to can change without the text doing so, and then the
    // widgets are made again (blocks.js, `restyle`).
    this.src = resolveHref(data.href)
  }

  eq(other) {
    return super.eq(other) && other.src === this.src
  }

  render(view) {
    const { alt, title } = this.data
    const src = this.src
    // One box either way, so a click anywhere on what stands here — picture or
    // words — reaches the handler BlockWidget puts on it.
    const box = document.createElement('span')
    box.className = 'cm-live-imagebox'
    const fallback = () => {
      const span = document.createElement('span')
      span.className = 'cm-live-image-blocked'
      span.textContent = alt || t('Image')
      if (!loads(src)) span.title = t('Remote images are not loaded')
      return span
    }
    if (!loads(src)) {
      box.append(fallback())
      return box
    }
    const img = document.createElement('img')
    img.className = 'cm-live-image'
    img.alt = alt
    if (title) img.title = title
    img.draggable = false
    // The line grows when the picture arrives, and CodeMirror only measures what
    // it is told changed.
    img.addEventListener('load', () => view.requestMeasure())
    img.addEventListener('error', () => {
      img.replaceWith(fallback())
      view.requestMeasure()
    })
    img.src = src
    box.append(img)
    return box
  }
}

registerBlock({
  type: 'image',
  nodes: ['Image'],
  block: false,
  reveal: 'range',
  match(node, state) {
    const url = node.node.getChild('URL')
    const marks = node.node.getChildren('LinkMark')
    // `![`, `]`, `(` and `)`: anything less is a reference or not an image.
    if (!url || marks.length < 4) return null
    const href = unescapeAll(state.sliceDoc(url.from, url.to).replace(/^<|>$/g, ''))
    if (!href) return null
    const title = node.node.getChild('LinkTitle')
    return {
      from: node.from,
      to: node.to,
      data: {
        href,
        alt: state.sliceDoc(marks[0].to, marks[1].from),
        title: title ? unescapeAll(state.sliceDoc(title.from + 1, title.to - 1)) : '',
      },
    }
  },
  widget: (data, info) => new ImageWidget(info.source, data),
})
