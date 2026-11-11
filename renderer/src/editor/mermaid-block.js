// ```mermaid fences in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): the
// diagram, drawn by shared/diagrams.js — the preview's own drawing, palette and
// cache — in place of the fence until the caret comes onto it.
//
// Drawing is asynchronous and the editor lays out before it finishes, so a
// diagram is a block of its own height first: the height it had the last time it
// was drawn, or a guess, which `estimatedHeight` tells CodeMirror before the
// widget exists. When the drawing lands the page asks to be measured again.
//
// What is drawn depends on the palette, which a diagram bakes into its SVG, so
// the theme is part of what makes two widgets equal and a change of theme draws
// every diagram again (blocks.js, `restyle`) — from diagrams.js's cache where it
// has drawn that palette before.
//
// Zoom: `sizeDiagram` (zoom.js) is applied by diagrams.js to every drawing, so
// a diagram is at its own size, grown with the text and scrolling sideways when
// it is wider than the column. A single click on the drawing opens the reading
// view's full-window viewer (zoom.js, `openDiagram`, unchanged); a double-click,
// or the caret arriving by keyboard, shows the source as it does for any block.
//
// Mermaid is not in editor.js. The drawing lives in editor-diagrams.js
// (build.mjs; `window.imarkDiagrams`), a script this file adds to the page the
// first time a diagram is wanted, so a document without one never fetches it.

import { BlockWidget, registerBlock } from './blocks.js'
import { lastLineEnd } from './rendered.js'
import { fenceLanguage } from './diff-block.js'
import { currentLanguage } from '../i18n.js'

// Loaded when the first diagram is drawn, so a document without one never pays
// for Mermaid, and a test with no DOM can load this file. The script is the
// page's own (imark://app, which its CSP allows), and a failed load is tried
// again with the next diagram.
const DIAGRAMS_SCRIPT = 'imark://app/editor-diagrams.js'
let diagrams = null
const load = () =>
  (diagrams ??= new Promise((resolve, reject) => {
    const ready = () => {
      const module = window.imarkDiagrams
      if (!module) return reject(new Error('editor-diagrams.js defines nothing'))
      resolve(module)
    }
    if (window.imarkDiagrams) return ready()
    const script = document.createElement('script')
    script.src = DIAGRAMS_SCRIPT
    script.onload = ready
    script.onerror = () => {
      script.remove()
      reject(new Error('editor-diagrams.js did not load'))
    }
    document.head.append(script)
  })).catch((error) => {
    diagrams = null
    throw error
  })

// A click opens the viewer once it is clear it is not the first half of a
// double-click, which shows the source instead.
const CLICK_DELAY = 300

// How tall each diagram was when it was last drawn, by palette and source.
const heights = new Map()
const HEIGHTS_KEPT = 200
let loaded = null

const themeOf = () => (typeof document === 'undefined' ? '' : document.documentElement.dataset.theme ?? '')

// Diagrams waiting to be drawn. Drawn together, in one call: diagrams.js lets a
// newer call take the page from an older one, so a widget calling it on its own
// would cancel the one made a moment before it.
let queue = []
let timer = 0
let drawing = false

function enqueue(entries, themeVariables) {
  for (const entry of entries) queue.push({ ...entry, themeVariables })
  if (!timer && !drawing) timer = setTimeout(flush, 0)
}

async function flush() {
  timer = 0
  drawing = true
  try {
    while (queue.length) {
      const batch = queue.filter((entry) => entry.block.isConnected)
      queue = []
      if (!batch.length) break
      const { drawDiagrams, diagramsDrawn, setLanguage } = await load()
      // The script has an i18n of its own, which the error box and the viewer read.
      setLanguage(currentLanguage())
      drawDiagrams({ themeVariables: batch[0].themeVariables, undrawn: batch })
      await diagramsDrawn()
      for (const entry of batch) {
        const finished = entry.block.classList.contains('is-rendered') || entry.block.classList.contains('is-error')
        if (finished) entry.done()
        // Taken over by a newer drawing before it landed: asked for again, a
        // few times, and then given up on.
        else if (entry.block.isConnected && (entry.tries = (entry.tries ?? 0) + 1) < 3) queue.push(entry)
      }
    }
  } catch {
    /* a diagram that cannot be drawn stays the empty box it was */
    queue = []
  } finally {
    drawing = false
    if (queue.length) timer = setTimeout(flush, 0)
  }
}

class MermaidWidget extends BlockWidget {
  constructor(source, data) {
    super(source, data)
    this.theme = themeOf()
  }

  eq(other) {
    return super.eq(other) && other.theme === this.theme
  }

  get key() {
    return `${this.theme}\n${this.data.code}`
  }

  get estimatedHeight() {
    return heights.get(this.key) ?? 180
  }

  render(view) {
    const dom = document.createElement('div')
    dom.className = 'cm-live-md cm-live-diagram'
    const block = document.createElement('div')
    block.className = 'mermaid-block'
    block.dataset.graph = encodeURIComponent(this.data.code)
    dom.append(block)

    const remember = () => {
      if (!dom.isConnected) return
      heights.delete(this.key)
      heights.set(this.key, dom.offsetHeight)
      if (heights.size > HEIGHTS_KEPT) heights.delete(heights.keys().next().value)
    }
    const done = () => {
      remember()
      view.requestMeasure()
    }
    const start = (module) => {
      module.setLanguage(currentLanguage())
      const themeVariables = module.readPalette()
      const { undrawn } = module.placeDrawnDiagrams({ querySelectorAll: () => [block] }, themeVariables)
      if (undrawn.length) enqueue(undrawn.map((entry) => ({ ...entry, done })), themeVariables)
      // Already in place: CodeMirror measures it with the rest of the update.
      else requestAnimationFrame(remember)
    }
    // Drawn from the cache in this very call when the module is already loaded,
    // so a diagram that comes back (the caret leaves its source) does not flash.
    if (loaded) start(loaded)
    else load().then((module) => { loaded = module; start(module) }, () => {})
    return dom
  }

  mousedown(event, view, dom) {
    // The viewer is for a plain click on the drawing itself. Anything else (the
    // margin around it, an error box, a second click, a modifier) is the
    // block's ordinary click, which puts the caret on it and shows the source.
    const drawing = event.target.closest?.('.mermaid-block.is-rendered > svg')
    const plain = !event.shiftKey && !event.metaKey && !event.altKey && !event.ctrlKey
    if (event.button !== 0 || !drawing || !plain || event.detail > 1) {
      clearTimeout(this.opening)
      return super.mousedown(event, view, dom)
    }
    event.preventDefault()
    const block = drawing.parentElement
    clearTimeout(this.opening)
    this.opening = setTimeout(() => {
      if (block.isConnected && loaded) loaded.openDiagram(block)
    }, CLICK_DELAY)
  }

  destroy() {
    clearTimeout(this.opening)
  }
}

registerBlock({
  type: 'mermaid',
  nodes: ['FencedCode'],
  match(node, state) {
    if (node.node.parent?.name !== 'Document' || fenceLanguage(node, state) !== 'mermaid') return null
    const text = node.node.getChild('CodeText')
    return {
      from: node.from,
      to: lastLineEnd(state.doc, node.from, node.to),
      data: { code: text ? state.doc.sliceString(text.from, text.to) : '' },
    }
  },
  widget: (data, info) => new MermaidWidget(info.source, data),
})
