// Mermaid: drawing the diagrams in a rendered document, and remembering what
// was drawn. The markdown pipeline only leaves an empty `.mermaid-block` with
// its source in `data-graph`; this fills them in, in whatever root the caller
// hands over and whatever palette it supplies, so the preview and any other
// view of a document draw a diagram the same way.
//
// Importing this does nothing until something is drawn. The caches below are
// shared by everything that imports it, which is the point: a diagram drawn
// for one view is not drawn again for the next.

import mermaid from 'mermaid'

import { t } from '../i18n.js'
import { escapeHtml } from './markdown.js'
import { sizeDiagram } from '../zoom.js'

let mermaidSeq = 0

// Mermaid ships its own palette, which clashes badly with ours. Feeding it the
// live CSS variables keeps diagrams on-theme in both light and dark. Read off
// `element` — the page's root — so a view with a palette of its own can say so.
export function readPalette(element = document.documentElement) {
  const css = getComputedStyle(element)
  const token = (name) => css.getPropertyValue(name).trim()
  return {
    background: token('--bg'),
    primaryColor: token('--code-bg'),
    primaryTextColor: token('--text'),
    primaryBorderColor: token('--diagram'),
    secondaryColor: token('--accent-soft'),
    secondaryBorderColor: token('--diagram'),
    tertiaryColor: token('--bg'),
    tertiaryBorderColor: token('--border'),
    lineColor: token('--secondary'),
    textColor: token('--text'),
    mainBkg: token('--code-bg'),
    nodeBorder: token('--diagram'),
    clusterBkg: token('--bg'),
    clusterBorder: token('--border'),
    edgeLabelBackground: token('--bg'),
    fontSize: '14px',
  }
}

// Every diagram drawn so far, by palette and source. Mermaid is by far the
// slowest part of a render — eight small diagrams in a long document took a
// second and a half, all of its markdown about a tenth of a second — and all
// of it was done again for a step Back, for a document opened a second time,
// for every save of a file being followed and for every change in Settings,
// which sends the palette again. A diagram that changed is a different key,
// so nothing here goes stale. A drawing is 20 to 50 KB of text, so keeping a
// hundred costs a few megabytes; past that the oldest are let go.
const drawnDiagrams = new Map()
const DIAGRAMS_KEPT = 100

// Which drawing each block on the page is showing, by the same key. Every
// change in Settings sends the palette again, the one already on the page, and
// putting the same drawings back in made WebKit lay the whole document out
// again: 230 ms of the 400 that a step of the text size took on a long one.
const showing = new WeakMap()

function remember(key, svg) {
  // Put back at the end, so the diagrams in use are the last to go.
  drawnDiagrams.delete(key)
  drawnDiagrams.set(key, svg)
  if (drawnDiagrams.size > DIAGRAMS_KEPT) drawnDiagrams.delete(drawnDiagrams.keys().next().value)
}

// Puts in every diagram in `root` already drawn in the palette `themeVariables`
// (see `readPalette`), and hands the rest to `drawDiagrams`. A render calls it
// before anything measures the page, so a document seen before is laid out once
// with its diagrams in it, and not a second time when they arrive.
export function placeDrawnDiagrams(root, themeVariables) {
  const palette = JSON.stringify(themeVariables)
  const blocks = [...root.querySelectorAll('.mermaid-block')].map((block) => {
    const source = decodeURIComponent(block.dataset.graph || '')
    return { block, source, key: `${palette}\n${source}` }
  })
  // Once per page: an SVG styles itself by its own id, and the same diagram
  // placed twice would put two of that id in one document. Blocks already
  // showing their drawing are counted first, wherever they sit: counted on the
  // way down, one lower on the page was missed, and a palette that came back
  // while it was being drawn in another gave its drawing to a block above too.
  const placed = new Set(blocks.filter(({ block, key }) => showing.get(block) === key).map(({ key }) => key))
  const undrawn = []
  for (const { block, source, key } of blocks) {
    if (showing.get(block) === key) continue
    const svg = drawnDiagrams.get(key)
    if (svg === undefined || placed.has(key)) {
      undrawn.push({ block, source, key })
      continue
    }
    placed.add(key)
    remember(key, svg)
    block.innerHTML = svg
    block.classList.add('is-rendered')
    sizeDiagram(block)
    showing.set(block, key)
  }
  return { themeVariables, undrawn }
}

let drawing = 0
let latestDrawing = Promise.resolve()

export function drawDiagrams(diagrams) {
  // Counted even with nothing to draw: a document whose diagrams all came back
  // still takes the page from one whose diagrams are being drawn.
  latestDrawing = drawEach(diagrams, ++drawing)
  return latestDrawing
}

// Waits for the drawing that has the page, whichever it is by then. A change
// in Settings while a render waits on its own drawing draws everything again in
// the new palette, and the render went on as soon as its own gave up: it put
// the page back where it was against a page still missing its diagrams, and
// said it was done before they were in.
export async function diagramsDrawn() {
  let latest
  while (latest !== latestDrawing) {
    latest = latestDrawing
    await latest
  }
}

async function drawEach({ themeVariables, undrawn }, token) {
  if (!undrawn.length) return
  mermaid.initialize({
    startOnLoad: false,
    theme: 'base',
    themeVariables,
    securityLevel: 'strict',
    fontFamily: 'inherit',
  })
  for (const { block, source, key } of undrawn) {
    try {
      const { svg } = await mermaid.render(`mermaid-${mermaidSeq++}`, source)
      // Another document, or this one in another palette, has started
      // drawing since, and has the page now. Mermaid's settings are global and
      // that drawing has just changed them, so this SVG may be half in the
      // wrong colours — and kept, it would come back in them every time.
      if (token !== drawing) return
      block.innerHTML = svg
      block.classList.add('is-rendered')
      sizeDiagram(block)
      showing.set(block, key)
      remember(key, svg)
    } catch (error) {
      if (token !== drawing) return
      block.classList.add('is-error')
      block.innerHTML = `<div class="diagram-error"><strong>${t('Invalid diagram')}</strong><pre>${escapeHtml(
        error?.message ?? error,
      )}</pre></div>`
      // Shown as well, or every change in Settings parsed it again and put in a
      // new error box. Not kept: a new render parses it once more, which costs
      // nothing like a drawing.
      showing.set(block, key)
    }
  }
}
