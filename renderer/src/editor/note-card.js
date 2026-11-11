// `<!-- imark … -->` comment blocks in the Live Preview (docs/LIVE-PREVIEW.md §4,
// M3): each drawn as a small card — who wrote it and the start of what they
// said — that the caret steps over as one piece.
//
// Read-only in v1: notes are written in the reading view, where they can be
// anchored to what they are about. Here a note can only be deleted, whole, with
// Backspace or Delete beside it (blocks.js, `blockDeletion`), which is one
// undoable edit to the buffer like any other. The caret never reveals one, so
// arrowing through a document does not keep opening its notes; a double-click
// shows the raw source until the caret leaves it.

import { t } from '../i18n.js'
import { BlockWidget, frontMatterEnd, registerBlock, revealBlock } from './blocks.js'
import { notesIn } from './notes.js'

const SVG = 'http://www.w3.org/2000/svg'

/// A speech balloon, drawn here rather than taken from a font: no glyph means
/// "a note" in every typeface the editor might be set in.
function balloon() {
  const svg = document.createElementNS(SVG, 'svg')
  svg.setAttribute('viewBox', '0 0 16 16')
  svg.setAttribute('aria-hidden', 'true')
  svg.classList.add('cm-live-note-icon')
  const path = document.createElementNS(SVG, 'path')
  path.setAttribute('d', 'M3 2.5h10a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H8l-3.5 3v-3H3A1.5 1.5 0 0 1 1.5 10V4A1.5 1.5 0 0 1 3 2.5z')
  svg.append(path)
  return svg
}

const span = (cls, text) => {
  const element = document.createElement('span')
  element.className = cls
  element.textContent = text
  return element
}

class NoteWidget extends BlockWidget {
  // A card is a line and a bit; close enough for the scroll bar before it is
  // ever measured.
  get estimatedHeight() {
    return 36
  }

  render() {
    const { by, colour, resolved, text } = this.data
    const card = document.createElement('div')
    card.className = 'cm-live-note'
    if (colour) card.dataset.color = colour
    if (resolved) card.classList.add('cm-live-note-resolved')
    // Everything below comes out of somebody's file: text, never markup.
    card.title = text
    card.append(balloon(), span('cm-live-note-label', t('Note')))
    if (by) card.append(span('cm-live-note-by', by))
    if (resolved) card.append(span('cm-live-note-resolved-on', t('resolved {date}', { date: resolved })))
    const first = text.split('\n')[0]
    if (first) card.append(span('cm-live-note-text', first))
    return card
  }

  mousedown(event, view, dom) {
    if (event.button !== 0) return
    if (event.detail < 2) return super.mousedown(event, view, dom)
    event.preventDefault()
    const pos = this.position(view, dom)
    view.dispatch({ selection: { anchor: pos }, effects: revealBlock.of(pos), scrollIntoView: true })
    view.focus()
  }
}

registerBlock({
  type: 'note',
  block: true,
  reveal: 'never',
  atomic: true,
  scan(state) {
    const doc = state.doc
    // The preview takes front matter off before it looks for notes; a
    // `<!-- imark` in there is a YAML value.
    const fm = frontMatterEnd(state)
    const first = fm ? doc.lineAt(fm).number + 1 : 1
    if (first > doc.lines) return []
    const body = doc.sliceString(doc.line(first).from)
    if (!body.includes('<!--')) return []
    return notesIn(body.split('\n')).map((note) => ({
      from: doc.line(first + note.line).from,
      to: doc.line(first + note.endLine).to,
      data: { by: note.by, colour: note.colour, resolved: note.resolved, text: note.text },
    }))
  },
  widget: (data, info) => new NoteWidget(info.source, data),
})
