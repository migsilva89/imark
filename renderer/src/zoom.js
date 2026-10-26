// Mermaid diagrams at a size that can be read, and a closer look at any of them.
//
// Mermaid draws a diagram as wide as the column and no wider, so a sequence
// diagram with eight participants came out with its labels three to five
// pixels tall, and nothing on the page could make them bigger: the text size
// leaves an SVG alone, and the web view does not pinch.

const MIN_SCALE = 0.1
const MAX_SCALE = 8
// How far a press may wander and still count as a click rather than a drag.
const SLOP = 4
// The margin the whole diagram is fitted inside when the viewer opens.
const PAD = 32

/// Draws a diagram at its own size, grown and shrunk with the text. Wider than
/// the column, it scrolls sideways inside its block, as a wide table does.
/// Called each time a drawing goes into a block: the drawing is plain markup
/// kept as text, so nothing set on the element survives being put back.
export function sizeDiagram(block) {
  const svg = block.querySelector(':scope > svg')
  const box = svg?.viewBox?.baseVal
  if (!box?.width) return
  // Mermaid writes `width="100%"` and a `max-width` of its own size, which is
  // what pinned it to the column. The size is set through the stylesheet
  // instead, against the text size, so a step of it is a step of the diagram.
  svg.removeAttribute('width')
  svg.removeAttribute('height')
  svg.style.removeProperty('max-width')
  svg.style.setProperty('--natural-width', box.width)
}

/* ---------------------------------------------------------------- viewer */

let viewer = null
let stage = null
let canvas = null
let readout = null
let returnFocus = null
let size = { width: 0, height: 0 }
// Where the diagram's top left corner sits in the stage, and how big it is.
let view = { x: 0, y: 0, scale: 1 }
let fitted = 1

export const isViewing = () => !!viewer && !viewer.hidden

function build() {
  viewer = document.createElement('div')
  viewer.className = 'diagram-viewer'
  viewer.hidden = true
  viewer.tabIndex = -1
  viewer.setAttribute('role', 'dialog')
  viewer.setAttribute('aria-modal', 'true')
  viewer.setAttribute('aria-label', 'Diagram')

  stage = document.createElement('div')
  stage.className = 'diagram-viewer-stage'
  canvas = document.createElement('div')
  canvas.className = 'diagram-viewer-canvas'
  stage.appendChild(canvas)

  const controls = document.createElement('div')
  controls.className = 'diagram-viewer-controls'
  const button = (label, title, action) => {
    const el = document.createElement('button')
    el.type = 'button'
    el.textContent = label
    el.title = title
    el.setAttribute('aria-label', title)
    el.addEventListener('click', (event) => {
      event.stopPropagation()
      action()
    })
    controls.appendChild(el)
    return el
  }
  button('−', 'Zoom out', () => zoomBy(1 / 1.25))
  readout = button('100%', 'Actual size', () => zoomTo(1))
  readout.classList.add('diagram-viewer-readout')
  button('+', 'Zoom in', () => zoomBy(1.25))
  button('Fit', 'Fit to window', fit)
  button('Done', 'Close', close)

  viewer.append(stage, controls)
  document.body.appendChild(viewer)
  wire()
}

/// Opens a diagram in the viewer, fitted to the window.
export function openDiagram(block) {
  const svg = block.querySelector(':scope > svg')
  const box = svg?.viewBox?.baseVal
  if (!box?.width) return
  if (!viewer) build()

  canvas.replaceChildren(svg.cloneNode(true))
  const shown = canvas.firstElementChild
  renameIds(shown)
  size = { width: box.width, height: box.height }
  shown.removeAttribute('style')
  shown.setAttribute('width', size.width)
  shown.setAttribute('height', size.height)
  canvas.style.width = `${size.width}px`
  canvas.style.height = `${size.height}px`

  returnFocus = document.activeElement
  viewer.hidden = false
  document.documentElement.dataset.viewing = 'true'
  viewer.focus({ preventScroll: true })
  fit()
}

// Gives the copy ids of its own. A drawing styles itself and points at its
// arrowheads by id, and mermaid names some parts plainly — `actor3`, `root-3` —
// so the copy and the drawing on the page would share them, and each find the
// other's. Every id goes, with what refers to it: `url(#…)`, `href="#…"`, and
// the drawing's own stylesheet.
function renameIds(svg) {
  const renamed = new Map()
  for (const el of [svg, ...svg.querySelectorAll('[id]')]) {
    if (!el.id) continue
    renamed.set(el.id, `${el.id}-zoom`)
    el.id = `${el.id}-zoom`
  }
  if (!renamed.size) return
  const escape = (id) => id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const pattern = new RegExp(`#(${[...renamed.keys()].map(escape).join('|')})(?![\\w-])`, 'g')
  const swap = (text) => text.replace(pattern, (_, id) => `#${renamed.get(id)}`)
  for (const el of svg.querySelectorAll('*')) {
    for (const attr of [...el.attributes]) {
      if (attr.value.includes('#')) el.setAttribute(attr.name, swap(attr.value))
    }
  }
  for (const style of svg.querySelectorAll('style')) style.textContent = swap(style.textContent)
}

export function close() {
  if (!isViewing()) return
  viewer.hidden = true
  canvas.innerHTML = ''
  delete document.documentElement.dataset.viewing
  returnFocus?.focus?.({ preventScroll: true })
  returnFocus = null
}

/// A pinch from the trackpad, sent over by the app: the web view does not
/// magnify, so the gesture arrives here instead. `x` and `y` are where the
/// fingers are, in the page's own pixels. Over a diagram it opens one; with the
/// viewer open it zooms around the fingers.
export function magnify(delta, x, y) {
  if (isViewing()) {
    const rect = stage.getBoundingClientRect()
    zoomAround(view.scale * (1 + delta), x - rect.left, y - rect.top)
    return
  }
  // Only a pinch that opens: one closing the fingers is not asking for a
  // closer look.
  if (delta <= 0) return
  const block = diagramAt(x, y)
  if (!block) return
  openDiagram(block)
  const rect = stage.getBoundingClientRect()
  zoomAround(view.scale * (1 + delta), x - rect.left, y - rect.top)
}

/// The two-finger double tap: a closer look at a diagram, or back from one.
export function smartMagnify(x, y) {
  if (isViewing()) return close()
  const block = diagramAt(x, y)
  if (block) openDiagram(block)
}

function diagramAt(x, y) {
  const block = document.elementFromPoint(x, y)?.closest?.('.mermaid-block.is-rendered')
  return block && block.querySelector(':scope > svg') ? block : null
}

/* ------------------------------------------------------------------ view */

function apply() {
  canvas.style.transform = `translate(${view.x}px, ${view.y}px) scale(${view.scale})`
  readout.textContent = `${Math.round(view.scale * 100)}%`
}

// Keeps at least a corner of the diagram in the window, so a fling cannot lose
// it off the edge.
function clampView() {
  const { width, height } = stage.getBoundingClientRect()
  const w = size.width * view.scale
  const h = size.height * view.scale
  const keep = 80
  view.x = Math.min(width - Math.min(keep, w), Math.max(Math.min(keep, w) - w, view.x))
  view.y = Math.min(height - Math.min(keep, h), Math.max(Math.min(keep, h) - h, view.y))
}

function fit() {
  const { width, height } = stage.getBoundingClientRect()
  // Never blown up past twice its size: a small diagram filling a big window
  // is all stroke and no detail.
  fitted = Math.min(2, (width - PAD * 2) / size.width, (height - PAD * 2) / size.height)
  view.scale = Math.max(MIN_SCALE, fitted)
  view.x = (width - size.width * view.scale) / 2
  view.y = (height - size.height * view.scale) / 2
  apply()
}

// Zooms keeping the point under (x, y), in the stage's pixels, where it is.
function zoomAround(scale, x, y) {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale))
  const ratio = next / view.scale
  view.x = x - (x - view.x) * ratio
  view.y = y - (y - view.y) * ratio
  view.scale = next
  clampView()
  apply()
}

function zoomAroundCentre(scale) {
  const { width, height } = stage.getBoundingClientRect()
  zoomAround(scale, width / 2, height / 2)
}

const zoomBy = (factor) => zoomAroundCentre(view.scale * factor)
const zoomTo = (scale) => zoomAroundCentre(scale)

function panBy(dx, dy) {
  view.x += dx
  view.y += dy
  clampView()
  apply()
}

/* ---------------------------------------------------------------- events */

function wire() {
  // Two fingers move the diagram; with Control held, as a pinch arrives from
  // some mice and from WebKit itself, they zoom it.
  stage.addEventListener(
    'wheel',
    (event) => {
      event.preventDefault()
      if (event.ctrlKey) {
        const rect = stage.getBoundingClientRect()
        zoomAround(view.scale * Math.exp(-event.deltaY * 0.01), event.clientX - rect.left, event.clientY - rect.top)
      } else {
        panBy(-event.deltaX, -event.deltaY)
      }
    },
    { passive: false },
  )

  let press = null
  stage.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return
    press = { x: event.clientX, y: event.clientY, from: { ...view }, moved: false }
    stage.setPointerCapture(event.pointerId)
  })
  stage.addEventListener('pointermove', (event) => {
    if (!press) return
    const dx = event.clientX - press.x
    const dy = event.clientY - press.y
    if (!press.moved && Math.hypot(dx, dy) < SLOP) return
    press.moved = true
    stage.classList.add('dragging')
    view.x = press.from.x + dx
    view.y = press.from.y + dy
    clampView()
    apply()
  })
  const release = (event) => {
    if (!press) return
    const { moved } = press
    press = null
    stage.classList.remove('dragging')
    // A click on the empty space around the diagram puts it away, as it would
    // a sheet; a click on the diagram itself is somebody about to drag it.
    if (!moved && event.type === 'pointerup' && !canvas.contains(event.target)) close()
  }
  stage.addEventListener('pointerup', release)
  stage.addEventListener('pointercancel', release)

  stage.addEventListener('dblclick', (event) => {
    const rect = stage.getBoundingClientRect()
    // In twice as far each time, until it is as far as it goes; then back.
    const next = view.scale >= MAX_SCALE * 0.99 ? fitted : view.scale * 2
    if (next === fitted) fit()
    else zoomAround(next, event.clientX - rect.left, event.clientY - rect.top)
  })

  viewer.addEventListener('keydown', (event) => {
    if (event.metaKey || event.altKey || event.ctrlKey) return
    const step = 60
    const keys = {
      Escape: close,
      '+': () => zoomBy(1.25),
      '=': () => zoomBy(1.25),
      '-': () => zoomBy(1 / 1.25),
      0: fit,
      ArrowLeft: () => panBy(step, 0),
      ArrowRight: () => panBy(-step, 0),
      ArrowUp: () => panBy(0, step),
      ArrowDown: () => panBy(0, -step),
    }
    const action = keys[event.key]
    // Every other key stays with the viewer as well: Space or Page Down would
    // otherwise scroll the document behind it.
    if (event.key !== 'Tab') event.preventDefault()
    event.stopPropagation()
    action?.()
  })

  window.addEventListener('resize', () => {
    if (!isViewing()) return
    clampView()
    apply()
  })
}

/// A click on a diagram that is not the end of selecting its words.
export function installDiagramClicks() {
  document.addEventListener('click', (event) => {
    if (event.button !== 0 || event.metaKey || event.shiftKey) return
    const block = event.target.closest?.('.mermaid-block.is-rendered')
    if (!block || !event.target.closest('svg')) return
    if (!window.getSelection()?.isCollapsed) return
    event.preventDefault()
    openDiagram(block)
  })
}
