import { t, setLanguage } from './i18n.js'
import katex from 'katex'

import {
  createMarkdown,
  isExternal,
} from './shared/markdown.js'
import {
  diagramsDrawn,
  drawDiagrams,
  placeDrawnDiagrams,
  readPalette,
} from './shared/diagrams.js'
import {
  close as closeDiagram,
  installDiagramClicks,
  isViewing,
  magnify,
  smartMagnify,
} from './zoom.js'

import {
  attachComments,
  attached as attachedNotes,
  buildNoteRail,
  extractComments,
  installCommentHandlers,
  isReviewing,
  pieceText,
  restoreNoteState,
  setReviewing as applyReviewing,
  stepNote,
  toVisibleText,
} from './comments.js'
import './style.css'

const bridge = (payload) => {
  window.webkit?.messageHandlers?.imark?.postMessage(payload)
}

/* ------------------------------------------------------------------ paths */

// Absolute path of the directory holding the document currently rendered.
let docDir = '/'
let lastPath = null

function normalizePath(path) {
  const parts = path.split('/')
  const out = []
  for (const part of parts) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return '/' + out.join('/')
}

// Each part of the path decoded whole: `decodeURI` leaves `%3F` and `%23`
// alone, and those are the only way to write a name with `?` or `#` in it once
// both mean a query and a fragment. A stray `%` is kept as it is.
const decodePart = (part) => {
  try {
    return decodeURIComponent(part)
  } catch {
    return part
  }
}

function resolveLocal(href) {
  const path = href.startsWith('/') ? href : `${docDir}/${href}`
  return normalizePath(path.split('/').map(decodePart).join('/'))
}

// Local files are served by a WKURLSchemeHandler on the Swift side so that
// images next to the document load without granting file:// access.
const fileURL = (absPath) => `imark://file${absPath.split('/').map(encodeURIComponent).join('/')}`

/* ----------------------------------------------------------------- parser */

// The markdown-it pipeline lives in shared/markdown.js, where nothing else on
// this page can reach into it. What it needs from the page comes in here: where
// a relative link points, and whether boxes are offered.
const pipeline = createMarkdown({
  resolveFile: (file) => fileURL(resolveLocal(file)),
  // Quick Look cannot write to anything, so a box there is not offered.
  isPreview: () => document.documentElement.dataset.preview === 'true',
})

/* ------------------------------------------------------------ task boxes */

// The line in the file a real box stands for, or null for anything else.
function taskLine(box) {
  const [key, line] = (box.dataset.task ?? '').split(':')
  return key === pipeline.taskKey && /^\d+$/.test(line ?? '') ? Number(line) : null
}

// The page never ticks a box on its own: the click asks the app to write the
// file, and the box changes when the document is rendered again from it. A tick
// that only lived in the page was the bug — it went with the next render.
document.addEventListener('click', (event) => {
  const box = event.target.closest?.('input.task-list-item-checkbox')
  if (!box || !content().contains(box)) return
  // By now the browser has already flipped it, so this is what was asked for.
  const checked = box.checked
  event.preventDefault()
  if (document.documentElement.dataset.preview === 'true') return
  const line = taskLine(box)
  if (line !== null) bridge({ type: 'task', line, checked })
})

// Hidden with CSS rather than by leaving the card out of the HTML: the front
// matter still occupies its lines in the file, and a document that is not built
// again is a document whose notes cannot move.
function applyFrontMatter(shown) {
  document.documentElement.dataset.frontMatter = shown ? 'shown' : 'hidden'
}

function setFrontMatter(shown) {
  applyFrontMatter(shown)
  // The card's height comes out of the page with it, so everything below moves
  // — and the rails are drawn from where things were. Without this the heading
  // tick and the note mark stay at the old height, pointing above their words.
  // A render does this for itself, further down; a toggle has nothing else.
  buildRail(content())
  buildNoteRail()
}

/* ------------------------------------------------------------------- toc */

function buildToc(root) {
  const headings = [...root.querySelectorAll('h1, h2, h3, h4, h5, h6')].filter((h) => h.id)
  bridge({
    type: 'toc',
    items: headings.map((h) => ({
      id: h.id,
      level: Number(h.tagName.slice(1)),
      title: h.textContent.trim(),
    })),
  })
  return headings
}

/* ---------------------------------------------------------------- scroll */

// The browser's own `behavior: 'smooth'` scales its duration with the distance
// travelled, so a jump across a long document takes one or two seconds. This
// starts at once and always lands in about a third of a second.
let scrollAnimation = 0
let glideFailsafe = 0
// Where a glide under way is going. That, not the frame it happens to be on, is
// where the page is for anybody asking — Back pressed halfway through a jump
// has to leave the heading for Forward, not a point on the way to it.
let glideTarget = null

const restingAt = () => glideTarget ?? window.scrollY

// Where the page can actually come to rest for a given top: not above the
// first line, and not so far down that the last one leaves the window.
const reachable = (top) => Math.max(0, Math.min(top, document.body.scrollHeight - window.innerHeight))

// How much of the top of the page the toolbar stands on, as Swift last said.
const topInset = () =>
  parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--top-inset')) || 0

// Where the page goes to show a heading: just under the toolbar. Measured from
// the top of the window it went behind the toolbar, and it took a line of
// scrolling back to read what the jump had been to.
const headingTop = (el) => el.getBoundingClientRect().top + window.scrollY - topInset() - 24

// The failsafe goes with the frames. Cancelling only the frames left it armed,
// and it landed the page on the old target after a newer glide had already
// arrived somewhere else — a link followed by a quick Back ended up at the
// link's heading instead of where the reader had been.
function stopGlide() {
  cancelAnimationFrame(scrollAnimation)
  clearTimeout(glideFailsafe)
  glideTarget = null
}

function glideTo(top) {
  stopGlide()

  const from = window.scrollY
  const to = reachable(top)
  const delta = to - from
  if (Math.abs(delta) < 2) return window.scrollTo(0, to)
  glideTarget = to

  // Long jumps get a little longer, but never much: 260ms to 420ms.
  const duration = Math.min(420, 260 + Math.abs(delta) * 0.06)
  const start = performance.now()
  // Quintic ease-out: leaves immediately, arrives without a bump.
  const ease = (t) => 1 - Math.pow(1 - t, 5)

  // If requestAnimationFrame is not running — WebKit stops it whenever it
  // decides the view is not visible — land on the target anyway.
  glideFailsafe = setTimeout(() => {
    cancelAnimationFrame(scrollAnimation)
    glideTarget = null
    window.scrollTo(0, to)
  }, duration + 120)

  const step = (now) => {
    const t = Math.min(1, (now - start) / duration)
    window.scrollTo(0, from + delta * ease(t))
    if (t < 1) {
      scrollAnimation = requestAnimationFrame(step)
    } else {
      clearTimeout(glideFailsafe)
      glideTarget = null
    }
  }
  scrollAnimation = requestAnimationFrame(step)
}

/* ------------------------------------------------------------------ rail */

// The table of contents for Quick Look, where there is no room for a sidebar.
// Only H1 to H3 get a tick: every mark has to be a place you can name, or the
// rail is texture rather than navigation.

const RAIL_SPAN = 0.72       // how much of the panel the rail should fill
// Between two headings. Every row is half of this, because a minor gradation
// sits in each gap.
const RAIL_PITCH_RANGE = [11, 22]
// A minor row is a gradation, not a place: thin, faint, and it grows far less
// than a heading when the funnel passes over it.
const RAIL_MINOR_WIDTH = 5
const RAIL_MINOR_OPACITY = 0.15
const RAIL_MINOR_AMPLITUDE = 10
// Narrow on purpose. At 2.6 the third tick either side still grew by half and
// the funnel read as a blunt bulge; at 1.15 only the immediate neighbours are
// clearly bigger and everything past them settles back to rest.
const RAIL_SIGMA = 1.15
const RAIL_AMPLITUDE = 32    // how much longer the mark at the centre grows

// Set per document: few headings spread out, many pack in, so the rail is
// neither a stub nor an overflowing column.
let railPitch = RAIL_PITCH_RANGE[0]

// Every row in the rail, majors and minors alike. Indices everywhere below are
// row indices; `railSection` maps one back to the heading it belongs to.
let railTicks = []
let railSection = []
let railBlocks = []
let railTip = null

let railScrollIndex = 0
// Where the funnel is centred. Normally that follows the scroll position, but
// while the pointer is on the rail it follows the pointer instead — you get to
// look around the document before deciding to go there.
let railHoverIndex = null

const paintRail = () => updateRail(railHoverIndex ?? railScrollIndex)

const headingLevel = (el) => (/^H[1-6]$/.test(el.tagName) ? Number(el.tagName[1]) : 0)

// Headings stand slightly proud of prose, but only slightly: if the resting
// widths spread too far they compete with the funnel and the rail reads as
// noise instead of as one moving shape.
const restingWidth = (level) => 10 + Math.max(0, 3 - level) * 3

const restingOpacity = (level) => 0.34 + Math.max(0, 3 - level) * 0.06

// A bell instead of a linear ramp with a cutoff: the taper has no edge, so the
// funnel reads as one soft shape however fast you move.
const falloffAt = (distance) => Math.exp(-(distance * distance) / (2 * RAIL_SIGMA * RAIL_SIGMA))

function collectBlocks(root) {
  const all = [...root.querySelectorAll('h1, h2, h3')]
  // As many headings as the panel can hold at the tightest pitch. Halved
  // against the row count, since each heading now brings a gradation with it.
  const capacity = Math.max(12, Math.floor((window.innerHeight * 0.94) / RAIL_PITCH_RANGE[0] / 2))
  if (all.length <= capacity) return all
  // Sample evenly instead of truncating: the rail has to stay proportional to
  // the whole document, or scrubbing lies about where you are.
  const step = all.length / capacity
  return Array.from({ length: capacity }, (_, i) => all[Math.floor(i * step)])
}

function buildRail(root) {
  document.querySelector('.rail')?.remove()
  document.querySelector('.rail-tip')?.remove()

  railTicks = []
  railSection = []
  railBlocks = collectBlocks(root)
  railHoverIndex = null
  if (railBlocks.length < 3) return

  // A row is half the distance between two headings: one heading, one gradation
  // between it and the next. The last heading has nothing after it to bridge to.
  const rows = railBlocks.length * 2 - 1
  // The range is written in headings, so it is halved before it meets a count
  // of rows. Clamping a row pitch with heading bounds and halving afterwards
  // gives a rail half the height it should be.
  const [minPitch, maxPitch] = RAIL_PITCH_RANGE
  railPitch = Math.min(maxPitch / 2, Math.max(minPitch / 2, (window.innerHeight * RAIL_SPAN) / rows))

  const rail = document.createElement('nav')
  rail.className = 'rail'
  rail.setAttribute('aria-hidden', 'true')
  rail.style.setProperty('--rail-row', `${railPitch}px`)

  const add = (block, index, minor) => {
    // The dash sits inside a taller transparent row, because a 2px mark is
    // impossible to hit with a pointer.
    const slot = document.createElement('span')
    slot.className = minor ? 'rail-tick minor' : 'rail-tick'
    slot.dataset.level = String(headingLevel(block))
    // Which heading a row belongs to. A minor answers to the heading above it,
    // so nothing on the rail is dead to the pointer — and the notes rail lines
    // its marks up with the majors, which need to say where in the document
    // they start. A tick's own position is a slot in a list, not a place.
    if (block.id && !minor) slot.dataset.heading = block.id
    slot.appendChild(document.createElement('i'))
    rail.appendChild(slot)
    railTicks.push(slot)
    railSection.push(index)
  }

  railBlocks.forEach((block, index) => {
    add(block, index, false)
    if (index < railBlocks.length - 1) add(block, index, true)
  })

  railTip = document.createElement('aside')
  railTip.className = 'rail-tip'
  document.body.appendChild(railTip)

  attachRail(rail)
  document.body.appendChild(rail)
}

function updateRail(centre) {
  railTicks.forEach((tick, index) => {
    const dash = tick.firstElementChild
    if (!dash) return

    const minor = tick.classList.contains('minor')
    const level = Number(tick.dataset.level || 0)
    const base = minor ? RAIL_MINOR_WIDTH : restingWidth(level)
    const rest = minor ? RAIL_MINOR_OPACITY : restingOpacity(level)
    const amplitude = minor ? RAIL_MINOR_AMPLITUDE : RAIL_AMPLITUDE
    // Measured in headings, not rows. The bell was tuned so that the tick
    // either side grows and the third is back at rest; counting gradations
    // would halve its reach and the funnel would crawl at half speed.
    const weight = falloffAt((index - centre) / 2)

    dash.style.width = `${base + weight * amplitude}px`
    dash.style.opacity = `${rest + weight * (1 - rest)}`
    tick.classList.toggle('is-active', index === centre && !minor)
  })
}

/* ---------------------------------------------------------- rail tooltip */

// A comment card lives inside the block it is attached to, so the plain text of
// a block is not its text content any more — without this the preview quoted
// somebody's note back as if it were the document.
const flatten = (el) => {
  const copy = el.cloneNode(true)
  for (const note of copy.querySelectorAll('.note-card, .note-dot, .note-actions')) note.remove()
  return copy.textContent.replace(/\s+/g, ' ').trim()
}

// A commented block is wrapped, so its neighbours are the wrapper's neighbours.
const outermost = (el) =>
  el.parentElement?.classList.contains('note-holder') ? el.parentElement : el

const headingIn = (el) =>
  /^H[1-6]$/.test(el.tagName) ? el : el.querySelector('h1, h2, h3, h4, h5, h6')

/// How many notes fall under this heading, down to the next one at the same
/// level or higher. The rail on the other edge says where the notes are; this
/// says whether the section you are about to jump to has any, which is the
/// question you have while reading the outline.
function notesInSection(heading) {
  const start = outermost(heading)
  const level = headingLevel(heading)
  let count = start.querySelectorAll('.note-dot').length

  for (let node = start.nextElementSibling; node; node = node.nextElementSibling) {
    const inner = headingIn(node)
    const innerLevel = inner ? headingLevel(inner) : 0
    if (innerLevel > 0 && innerLevel <= level) break
    count += node.querySelectorAll('.note-dot').length
  }
  return count
}

function tipContent(index) {
  const heading = railBlocks[index]
  if (!heading) return null

  // Every tick is a heading now, so the title is the tick itself. The body has
  // to come from the DOM rather than from railBlocks — the prose that follows
  // is no longer in the list.
  let body = ''
  let sibling = outermost(heading).nextElementSibling
  while (sibling && !headingIn(sibling)) {
    body = flatten(sibling)
    if (body) break
    sibling = sibling.nextElementSibling
  }

  const position = railBlocks.length > 1 ? index / (railBlocks.length - 1) : 0

  return {
    label: t('{percent}% in', { percent: Math.round(position * 100) }),
    title: flatten(heading),
    body,
    notes: notesInSection(heading),
  }
}

function showTip(index, tick) {
  if (!railTip || !tick) return
  const content = tipContent(railSection[index] ?? index)
  if (!content) return

  railTip.replaceChildren()

  const label = document.createElement('em')
  label.textContent = content.label
  if (content.notes) {
    const badge = document.createElement('i')
    badge.className = 'rail-tip-notes'
    badge.textContent = content.notes === 1 ? t('1 comment') : t('{count} comments', { count: content.notes })
    label.appendChild(badge)
  }
  railTip.appendChild(label)

  const heading = document.createElement('strong')
  heading.textContent = content.title
  railTip.appendChild(heading)

  if (content.body) {
    const body = document.createElement('span')
    body.textContent = content.body
    railTip.appendChild(body)
  }

  railTip.classList.add('is-visible')

  // Anchor to the tick, then keep the whole card on screen. Height has to be
  // read after the content lands or the first frame is positioned wrong.
  const box = tick.getBoundingClientRect()
  const height = railTip.offsetHeight
  const top = Math.min(
    Math.max(10, box.top + box.height / 2 - height / 2),
    window.innerHeight - height - 10,
  )
  railTip.style.top = `${top}px`
}

function hideTip() {
  railTip?.classList.remove('is-visible')
}

/* --------------------------------------------------------- rail scrubbing */

function attachRail(rail) {
  let scrubbing = false

  const nearest = (clientY) => {
    const first = railTicks[0].getBoundingClientRect()
    // Ticks are evenly pitched, so arithmetic beats measuring all of them on
    // every pointer move.
    const index = Math.round((clientY - (first.top + first.height / 2)) / railPitch)
    return Math.min(Math.max(index, 0), railTicks.length - 1)
  }

  /// Where the document should sit for a pointer anywhere along the rail —
  /// between headings as well as on them.
  ///
  /// Snapping to the nearest heading is right for a click and wrong for a drag:
  /// it made scrubbing jump from section to section, which reads as the rail
  /// resisting rather than following. This interpolates between the heading
  /// above and the one below, so the page moves with the hand the way a
  /// scrollbar does, while the rail still means headings.
  const scrollAt = (clientY) => {
    const first = railTicks[0].getBoundingClientRect()
    const row = (clientY - (first.top + first.height / 2)) / railPitch
    // Rows are half-headings — one tick per heading, one gradation between.
    const at = Math.min(Math.max(row / 2, 0), railBlocks.length - 1)
    const lower = Math.floor(at)
    const upper = Math.min(lower + 1, railBlocks.length - 1)
    const topOf = (i) => headingTop(railBlocks[i])
    const from = topOf(lower)
    return from + (topOf(upper) - from) * (at - lower)
  }

  // A gradation takes you to the heading it sits under. It is not a place of
  // its own, and a row that swallows a click is worse than one that is not
  // there.
  const goTo = (index, smooth) => {
    const target = railBlocks[railSection[index]]
    if (!target) return
    const top = headingTop(target)
    // Dragging tracks the pointer one to one; a click gets the glide.
    if (smooth) glideTo(top)
    else {
      stopGlide()
      window.scrollTo(0, top)
    }
    railScrollIndex = index
  }

  // Deliberately not coalesced through requestAnimationFrame: WebKit stops
  // firing it whenever it decides the view is not visible, and a rail that
  // freezes is worse than one that does a little extra work. Instead the work
  // is skipped outright while the pointer stays within the same tick, which is
  // most pointer moves.
  const track = (clientY) => {
    // The page follows the pointer continuously, on every move — outside the
    // tick check below, which exists to skip repainting the funnel and would
    // otherwise make the scroll steppy again for a different reason.
    if (scrubbing) {
      stopGlide()
      window.scrollTo(0, scrollAt(clientY))
    }
    const index = nearest(clientY)
    if (index === railHoverIndex) return
    railHoverIndex = index
    paintRail()
    showTip(index, railTicks[index])
    if (scrubbing) railScrollIndex = index
  }

  rail.addEventListener('pointermove', (event) => track(event.clientY))

  rail.addEventListener('pointerdown', (event) => {
    scrubbing = true
    rail.classList.add('is-scrubbing')
    rail.setPointerCapture(event.pointerId)
    goTo(nearest(event.clientY), true)
    event.preventDefault()
  })

  const release = (event) => {
    if (!scrubbing) return
    scrubbing = false
    rail.classList.remove('is-scrubbing')
    if (rail.hasPointerCapture?.(event.pointerId)) rail.releasePointerCapture(event.pointerId)
  }
  rail.addEventListener('pointerup', release)
  rail.addEventListener('pointercancel', release)

  rail.addEventListener('pointerleave', () => {
    if (scrubbing) return
    railHoverIndex = null
    paintRail()
    hideTip()
  })
}

/* -------------------------------------------------------- code copy button */

function addCopyButtons(root) {
  for (const wrap of root.querySelectorAll('.code-wrap')) {
    const button = document.createElement('button')
    button.className = 'copy-btn'
    button.type = 'button'
    button.textContent = t('Copy')
    button.addEventListener('click', async () => {
      // A diff is one `code` per row, so the first one alone would copy a
      // single line and look like it had worked.
      const code = wrap.classList.contains('diff-wrap')
        ? [...wrap.querySelectorAll('.diff-row code')].map((el) => el.textContent).join('\n')
        : wrap.querySelector('code')?.textContent ?? ''
      try {
        await navigator.clipboard.writeText(code)
        button.textContent = t('Copied')
      } catch {
        button.textContent = t('Failed')
      }
      setTimeout(() => {
        button.textContent = t('Copy')
      }, 1400)
    })
    wrap.appendChild(button)
  }
}

/* ---------------------------------------------------------------- render */

const content = () => document.getElementById('content')

let activeHeadings = []
let renderToken = 0

// Kept so comments can be exported without asking Swift to hand the file back.
let lastSource = ''

async function render({ markdown, path, theme, language, preview, rail, frontMatter, commentingControls, scroll, anchor }) {
  setLanguage(language)
  plusButton?.setAttribute('aria-label', t('Comment on this block'))
  const token = ++renderToken
  lastSource = markdown ?? ''
  docDir = path ? path.slice(0, path.lastIndexOf('/')) || '/' : '/'
  // Another document is another set of diagrams. The same one saved again
  // keeps the viewer open: a file being followed is saved every few seconds.
  if (path !== lastPath) closeDiagram()
  lastPath = path

  // The very first render carries the theme and the preview flag — without this
  // the page keeps the defaults from index.html until something calls the
  // setters, and in Quick Look those calls arrive before the page exists.
  if (theme) document.documentElement.dataset.theme = theme
  if (preview) document.documentElement.dataset.preview = 'true'
  // 'left' in the preview panel, 'right' in a window where the sidebar already
  // owns the left edge. Absent means no rail at all.
  if (rail) document.documentElement.dataset.rail = rail
  else delete document.documentElement.dataset.rail
  // Carried too, so a document opened after the card was put away does not
  // flash it back for the length of one render.
  if (frontMatter !== undefined) applyFrontMatter(frontMatter)
  if (commentingControls !== undefined) setCommentingControls(commentingControls)

  const root = content()
  // A reload keeps the place. Another document, or a step Back to one, says
  // where to land instead: without it a file opened from a link started as far
  // down as the one it was opened from. A link to a heading in it names the
  // heading, and the page lands there if it has one.
  const kept = window.scrollY
  const moving = typeof scroll === 'number' || !!anchor
  const landing = () => {
    const heading = anchor ? findAnchor(anchor) : null
    if (heading) return headingTop(heading)
    return typeof scroll === 'number' ? scroll : kept
  }

  // Taken out before parsing so the blocks can never show up as document text,
  // and blanked rather than deleted so the line map stays honest.
  let comments
  const { html } = pipeline.renderDocument(markdown ?? '', {
    prepare: (body, offset) => {
      const lifted = extractComments(body, offset)
      comments = lifted.comments
      return lifted.body
    },
  })
  root.innerHTML = html
  if (token !== renderToken) return
  const diagrams = placeDrawnDiagrams(root, readPalette())
  // Now as well as at the end, so the new document does not sit at the old
  // one's place for as long as its diagrams take — and a glide still running
  // in the old one does not carry on in this one. After the drawings already
  // made are back in, so a heading or an offset is found on the page as it
  // will stand, not on the source text of its diagrams.
  if (moving) {
    stopGlide()
    window.scrollTo(0, landing())
  }

  const notes = attachComments(root, comments)
  restoreNoteState()
  bridge({ type: 'comments', count: notes.length, reviewing: isReviewing(), items: notes })

  // The highlight elements went out with the old DOM.
  matches = []
  matchIndex = -1

  addCopyButtons(root)
  activeHeadings = buildToc(root)
  buildRail(root)
  // After the outline rail, never before: the marks are placed against its
  // ticks, and ticks that do not exist yet put every note at the top.
  buildNoteRail()
  drawDiagrams(diagrams)
  await diagramsDrawn()
  if (token !== renderToken) return

  const words = root.textContent.trim().split(/\s+/).filter(Boolean).length
  bridge({ type: 'meta', words, minutes: Math.max(1, Math.round(words / 220)) })

  // Swift resolves these against the filesystem and tells us which ones are
  // dead, so the renderer never has to know where notes live.
  const targets = [...root.querySelectorAll('a.wikilink')].map((a) => a.dataset.wikilink)
  if (targets.length) bridge({ type: 'wikilinks', targets: [...new Set(targets)] })

  window.scrollTo(0, Math.min(landing(), document.body.scrollHeight))
  updateActiveHeading()
  reportPlace()
  bridge({ type: 'rendered' })
}

/* --------------------------------------------------------- scroll tracking */

let scrollQueued = false

// Where the page is, for the app to remember: leaving a place is what puts it
// in the history, and the app cannot ask the page on the way out. Told on every
// scroll event, which WebKit already sends at most once a frame — waiting for
// the scrolling to stop was a timer, and timers are held back in a window
// WebKit thinks nobody is looking at. Not from the frame callback below either:
// that is as many messages (one a frame, measured, at 6.5 µs each to the page),
// and in such a window frame callbacks do not run at all.
function reportPlace() {
  bridge({ type: 'scrolled', y: restingAt() })
}

function updateActiveHeading() {
  if (!activeHeadings.length) return
  // Counted from under the toolbar, where the visible page starts: from the
  // top of the window, a heading a jump had just put on screen could still
  // read as the section after the active one.
  const inset = topInset()
  let index = 0
  for (let i = 0; i < activeHeadings.length; i += 1) {
    if (activeHeadings[i].getBoundingClientRect().top <= inset + 80) index = i
    else break
  }
  bridge({ type: 'active', id: activeHeadings[index].id })

  let block = 0
  for (let i = 0; i < railBlocks.length; i += 1) {
    if (railBlocks[i].getBoundingClientRect().top <= inset + 90) block = i
    else break
  }
  // Headings sit on the even rows, gradations on the odd ones.
  railScrollIndex = block * 2
  paintRail()
}

window.addEventListener(
  'scroll',
  () => {
    reportPlace()
    if (scrollQueued) return
    scrollQueued = true
    requestAnimationFrame(() => {
      scrollQueued = false
      updateActiveHeading()
    })
  },
  { passive: true },
)

/* ------------------------------------------------------------- selection */

const lineRange = (el) => {
  const raw = el?.getAttribute?.('data-line')
  if (!raw) return null
  const [start, end] = raw.split(',').map(Number)
  return Number.isFinite(start) && Number.isFinite(end) ? { start, end } : null
}

function selectionInfo() {
  const selection = window.getSelection()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null

  const text = selection.toString().trim()
  if (!text) return null

  const range = selection.getRangeAt(0)
  const root = content()
  if (!root.contains(range.commonAncestorContainer)) return null

  // Text inside a note is not document text: it has no line of its own, and
  // offering to comment on a comment is not a thing worth building.
  const within =
    range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement
  if (within?.closest('.note-card')) return null

  const rect = range.getBoundingClientRect()
  if (!rect.width && !rect.height) return null

  const start =
    range.startContainer.nodeType === Node.ELEMENT_NODE
      ? range.startContainer
      : range.startContainer.parentElement

  // Two ranges: the tightest element that knows its lines, and the top-level
  // block it belongs to. A comment is written after the block; the tighter one
  // is what a quote should be looked for in.
  let block = start
  while (block && block.parentElement !== root && block.parentElement) {
    // A commented block is wrapped, so the top-level element is one step
    // further out than it used to be.
    if (block.parentElement.classList.contains('note-holder')) break
    block = block.parentElement
  }

  return {
    type: 'selection',
    text,
    rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
    inline: lineRange(start?.closest('[data-line]')),
    block: lineRange(block),
    // Which copy of these exact words inside the block this is. Written into
    // the note as nth= so two comments on the same word stay apart.
    occurrence: countBefore(block, range, text),
  }
}

/// Which copy of these words the piece is, counted the same way a selection is
/// counted, because the note is read back by looking for the nth occurrence of
/// the quote in the block. Two identical rows in a table are not rare.
function occurrenceOfPiece(block, piece, quote) {
  const range = document.createRange()
  try {
    range.setStartBefore(piece)
  } catch {
    return 1
  }
  return countBefore(block, range, quote)
}

/// How many times the selected text already appeared in this block before the
/// point where the selection starts, plus one.
function countBefore(block, range, text) {
  if (!block || !text) return 1
  const before = document.createRange()
  before.selectNodeContents(block)
  try {
    before.setEnd(range.startContainer, range.startOffset)
  } catch {
    return 1
  }
  return before.toString().split(text).length
}

/* ------------------------------------------------------ comment on a block */

/// The `+` in the margin. One button that follows the block under the pointer,
/// rather than one per paragraph: a document is thousands of blocks, and most
/// of them are never hovered.
///
/// It exists because commenting on a whole paragraph through a selection is
/// work pretending to be precision — you pick some words arbitrarily just to
/// have somewhere to hang the note. A block note has no `quote=` at all: the
/// note is written directly after the block, so its position already says which
/// one it is, and it can never come loose the way a quote can.
let plusButton = null
let plusTarget = null
let plusBlock = null
/// Hiding is delayed, because the way to the button leads out of the text: the
/// pointer crosses the margin, which belongs to no block, and hiding on the
/// first frame outside meant the button vanished exactly as you reached for it.
let plusHideTimer = 0

const cancelHide = () => clearTimeout(plusHideTimer)
const scheduleHide = () => {
  clearTimeout(plusHideTimer)
  plusHideTimer = setTimeout(hidePlus, 220)
}

/// The block on the same line as the pointer, whatever the pointer is actually
/// over. A reading column is centred and narrow, so most of the window beside a
/// paragraph belongs to nothing — and aiming at the words to reach a button
/// that lives in the margin is backwards.
///
/// Bounded rather than the whole width: the rails sit at the window edges and
/// have their own hover behaviour to answer for.
function blockAtHeight(clientX, clientY) {
  const root = content()
  const box = root.getBoundingClientRect()
  // Never into the outer strip, whatever the reach works out to: the rails live
  // there and answer to the pointer themselves. On a narrow window this is what
  // decides, and the reach never comes into it.
  const from = Math.max(box.left - PLUS_REACH, RAIL_GUTTER)
  const to = Math.min(box.right + PLUS_REACH, window.innerWidth - RAIL_GUTTER)
  if (clientX < from || clientX > to) return null
  for (const child of root.children) {
    if (!lineRange(child)) continue
    const rect = child.getBoundingClientRect()
    if (clientY >= rect.top && clientY <= rect.bottom) return child
  }
  return null
}

/// How far past the text column the `+` still answers, in points.
const PLUS_REACH = 120
/// And how much of each edge it never touches, because the rails are there.
const RAIL_GUTTER = 56

/// A list item or a table cell: the piece of a block somebody points at when
/// they point at a list or a table. Agents write long lists, and a note on the
/// list as a whole leaves the reader — human or agent — to work out which of
/// nineteen items it meant.
const PIECE = 'li, td, th'

/// The piece of `block` under `node`, if any. The innermost one, so a list
/// inside a list item answers with the item you are actually on.
const pieceIn = (block, node) => {
  const piece = node?.closest?.(PIECE)
  return piece && block.contains(piece) ? piece : null
}

/// Out in the margin there is nothing under the pointer to ask, so the question
/// goes to the text at the same height instead.
///
/// Only a list answers it. Items are stacked, so the one level with the pointer
/// is the one meant — while a table row has three or four cells at that height
/// and answering with the first would be a guess dressed up as an offer. Beside
/// a table the margin still offers the table, and a cell has to be pointed at.
function itemAtHeight(block, clientY) {
  const box = block.getBoundingClientRect()
  // Looking past the `+`, which stands on this very spot once it offers an
  // item: finding the button meant offering the whole list, which sent the
  // button to the top of it, and the next move found the item again.
  const item = document.elementsFromPoint(box.left + 8, clientY)
    .find((el) => el !== plusButton)?.closest?.('li')
  return item && block.contains(item) ? item : null
}

const topLevelBlock = (node) => {
  const root = content()
  let block = node
  while (block && block.parentElement !== root && block.parentElement) {
    if (block.parentElement.classList.contains('note-holder')) break
    block = block.parentElement
  }
  return block?.parentElement === root || block?.parentElement?.classList.contains('note-holder')
    ? block
    : null
}

function hidePlus() {
  plusTarget?.classList.remove('block-target', 'block-armed')
  plusTarget = null
  plusBlock = null
  if (plusButton) plusButton.style.display = 'none'
}

/// `target` is what lights up and what the note will be about — a whole block,
/// or one item or cell inside it. `block` is the top-level element it lives in,
/// which is where the note goes in the file: an HTML comment written between
/// two list items or two table rows would break the list or the table in half.
function showPlus(target, block) {
  if (!plusButton) return
  plusBlock = block
  if (plusTarget === target) return
  plusTarget?.classList.remove('block-target', 'block-armed')
  plusTarget = target
  // Lit as soon as the button appears, not only once the pointer reaches it.
  // Waiting meant the highlight never showed at all if you never got there.
  target.classList.add('block-target')

  const rect = target.getBoundingClientRect()
  // A task item's box hangs out to the left of the item, exactly where the `+`
  // goes, and the `+` on top of it made the box impossible to press. It moves
  // out past the box instead.
  const box = target.matches('.task-list-item')
    ? target.querySelector(':scope > input.task-list-item-checkbox, :scope > p > input.task-list-item-checkbox')
    : null
  const left = box ? Math.min(rect.left, box.getBoundingClientRect().left) : rect.left
  plusButton.style.display = 'flex'
  plusButton.style.top = `${rect.top + 1}px`
  plusButton.style.left = `${Math.max(4, left - 34)}px`
}

/// Whether the pointer is between a lit item or cell and its `+`, level with it.
/// The button hangs to the left of what it offers, and for a table cell that is
/// inside the cell next door: the way to it crossed that cell, which lit up and
/// took the button along, so no cell but the first could be reached — and the
/// first lost to the whole table as soon as the pointer left it for the margin.
/// A pointer here is on its way to the button, and the offer stays put.
///
/// Only for a piece. Beside a whole block the margin at the same height already
/// answers with that block, and beside a whole list it has to go on offering
/// the item level with the pointer.
function onTheWayToPlus(clientX, clientY) {
  if (!plusTarget || plusTarget === plusBlock || plusButton.style.display === 'none') return false
  const target = plusTarget.getBoundingClientRect()
  const button = plusButton.getBoundingClientRect()
  return clientX >= button.left && clientX < target.left
    && clientY >= target.top && clientY <= target.bottom
}

function setUpBlockPlus() {
  plusButton = document.createElement('button')
  plusButton.type = 'button'
  plusButton.className = 'block-plus'
  plusButton.textContent = '+'
  plusButton.setAttribute('aria-label', t('Comment on this block'))
  plusButton.style.display = 'none'
  document.body.appendChild(plusButton)

  plusButton.addEventListener('mouseenter', () => {
    cancelHide()
    plusTarget?.classList.add('block-armed')
  })
  plusButton.addEventListener('mouseleave', () => {
    plusTarget?.classList.remove('block-armed')
    scheduleHide()
  })

  plusButton.addEventListener('click', () => {
    const target = plusTarget
    const block = plusBlock ?? plusTarget
    const lines = lineRange(block)
    if (!target || !block || !lines) return
    const anchor = plusButton.getBoundingClientRect()
    target.classList.add('block-target')
    // On a whole block: no text. Everything downstream already carries the
    // quote through as a string, and empty means "the block".
    //
    // On one item or one cell, the piece's own words are the quote. The note
    // still lands after the block in the file, so its words are the only thing
    // that can say which item it was about — to the renderer, and to whoever
    // reads the file without ever opening the app.
    const piece = target === block ? null : target
    const quote = piece ? pieceText(piece) : ''
    bridge({
      type: 'selection',
      // A press on the margin `+` is already an explicit request to comment.
      // Keep it distinct from selecting the same words by hand, which still
      // offers Translate and Search as well.
      directComment: true,
      text: quote,
      // Point the native popover at the control that was pressed, not at the
      // potentially very wide block or table cell it represents.
      rect: { x: anchor.left, y: anchor.top, width: anchor.width, height: anchor.height },
      inline: lineRange(target.closest('[data-line]')) ?? lines,
      block: lines,
      occurrence: piece ? occurrenceOfPiece(block, piece, quote) : 1,
    })
  })

  document.addEventListener('mousemove', (event) => {
    // The Quick Look panel renders with the same bundle and cannot write to
    // anything. Existing notes still show — that is reading — but offering a
    // way to add one there is offering something that cannot happen.
    if (
      document.documentElement.dataset.preview === 'true'
      || document.documentElement.dataset.commenting === 'false'
    ) return hidePlus()
    if (event.target === plusButton) return cancelHide()
    // The viewer covers the page; the block under it is not on offer.
    if (isViewing()) return hidePlus()
    // Not while a selection is live: the popover is already open on words the
    // reader chose, and a second way in would fight it.
    if (hadSelection) return hidePlus()
    if (onTheWayToPlus(event.clientX, event.clientY)) return cancelHide()
    // By line first, so the whole width of the reading area answers; the
    // element under the pointer only decides it when the two disagree, which
    // is inside a note card or a holder.
    const onText = content().contains(event.target) ? topLevelBlock(event.target) : null
    const block = onText ?? blockAtHeight(event.clientX, event.clientY)
    if (!block || !lineRange(block)) return scheduleHide()
    cancelHide()
    // Inside a list or a table the offer is for the item or the cell, whether
    // the pointer is on the words or out in the margin beside them.
    const piece = (onText && pieceIn(block, event.target)) ?? itemAtHeight(block, event.clientY)
    showPlus(piece ?? block, block)
  })

  // Fixed positioning against a rect taken once — scrolling moves the block out
  // from under it, so it goes away and comes back on the next move.
  document.addEventListener('scroll', hidePlus, true)
}

function clearBlockTarget() {
  document.querySelectorAll('.block-target').forEach((el) => el.classList.remove('block-target'))
  hidePlus()
}

function setCommentingControls(on) {
  document.documentElement.dataset.commenting = on ? 'true' : 'false'
  if (!on) clearBlockTarget()
}

let selectionTimer = 0
let hadSelection = false

document.addEventListener('selectionchange', () => {
  clearTimeout(selectionTimer)
  // Debounced: a drag fires this on every pixel, and the popover should appear
  // when the hand stops, not chase it across the paragraph.
  selectionTimer = setTimeout(() => {
    const info = selectionInfo()
    if (info) {
      hadSelection = true
      bridge(info)
    } else if (hadSelection) {
      hadSelection = false
      bridge({ type: 'selectionCleared' })
    }
  }, 180)
})

/* ----------------------------------------------------------- link routing */

document.addEventListener('click', (event) => {
  const anchorEl = event.target.closest('a')
  if (!anchorEl) return

  // Leaving for another file: where the page is goes first, in the same
  // breath, so Back has it even if no scroll has been told about yet.
  const wiki = anchorEl.dataset.wikilink
  if (wiki) {
    event.preventDefault()
    reportPlace()
    bridge({ type: 'openWiki', target: wiki })
    return
  }

  const href = anchorEl.getAttribute('href') ?? ''
  if (href.startsWith('#')) {
    event.preventDefault()
    scrollToAnchor(href.slice(1))
    return
  }

  event.preventDefault()
  if (href.startsWith('imark://file')) {
    // Every `#` in the path was encoded on the way in, so the first one left
    // is where the heading's name starts.
    const hash = href.indexOf('#')
    const path = decodeURIComponent((hash < 0 ? href : href.slice(0, hash)).replace('imark://file', ''))
    const anchor = hash < 0 ? '' : href.slice(hash + 1)
    reportPlace()
    bridge({ type: 'openLocal', path, anchor })
  } else if (isExternal(href)) {
    bridge({ type: 'openExternal', url: href })
  }
})

function scrollToAnchor(fragment) {
  const target = findAnchor(fragment)
  if (!target) return
  const top = headingTop(target)
  // Where the reader was, so Back can bring them there, and where they are
  // going, so a Back pressed mid-glide knows what Forward returns to. A link to
  // the place the page is already at moves nothing and is not a step at all.
  const from = restingAt()
  const to = reachable(top)
  if (Math.abs(to - from) >= 2) bridge({ type: 'jump', from, to })
  glideTo(top)
}

/// The element a `#fragment` names. A link's href arrives percent-encoded —
/// markdown-it escapes everything outside ASCII, so `#мій-розділ` gets here as
/// `%D0%BC%D1%96%D0%B9-…` and no id is spelled like that. The outline in the
/// sidebar sends the id as it is, which decoding leaves alone.
function findAnchor(fragment) {
  let id = fragment
  try {
    id = decodeURIComponent(fragment)
  } catch {
    /* a lone `%` is just a character */
  }
  const exact = document.getElementById(id) ?? document.getElementById(fragment)
  if (exact) return exact
  const lineLink = LINE_LINK.exec(id)
  if (lineLink) return blockAtLine(Number(lineLink[1]))
  // Links written against the ids Imark used to make are in documents already:
  // accents off, underscores gone, a run of spaces as one hyphen — `#acao-rapida`
  // for "Ação rápida". Compared with all of that taken out of both sides.
  const plain = (s) =>
    s.normalize('NFD').toLowerCase().replace(/[^\p{L}\p{Nd}\p{Nl}-]/gu, '').replace(/-+/g, '-')
  const wanted = plain(id)
  return [...content().querySelectorAll('[id]')].find((el) => plain(el.id) === wanted) ?? null
}

// GitHub's links to lines of a file's source, `#L12`, `#L12-L20` or `#L12C3`:
// a rendered page has blocks, so they land on the innermost block holding the
// first line, or the next one when that line is blank.
const LINE_LINK = /^L([1-9]\d*)(?:C\d+)?(?:-L[1-9]\d*(?:C\d+)?)?$/

function blockAtLine(lineNumber) {
  const index = lineNumber - 1 // `data-line` counts from zero
  // The front matter is a card with no lines of its own, at the top.
  if (index < pipeline.lineOffset) return content()
  let holder = null
  for (const block of content().querySelectorAll('[data-line]')) {
    const range = lineRange(block)
    if (!range) continue
    if (range.start > index) return holder && !holder.contains(block) ? holder : block
    if (index < range.end) holder = block
  }
  return holder
}

/* ------------------------------------------------------------------ find */

let matches = []
let matchIndex = -1

function clearFind() {
  for (const hit of [...document.querySelectorAll('mark.find')]) {
    const parent = hit.parentNode
    if (!parent) continue
    parent.replaceChild(document.createTextNode(hit.textContent), hit)
    parent.normalize()
  }
  matches = []
  matchIndex = -1
}

function runFind(query) {
  clearFind()
  const needle = (query ?? '').toLowerCase()
  if (needle.length === 0) return report()

  const root = content()
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT
      const tag = node.parentElement?.tagName
      return tag === 'SCRIPT' || tag === 'STYLE'
        ? NodeFilter.FILTER_REJECT
        : NodeFilter.FILTER_ACCEPT
    },
  })

  // Collected up front: splitting text nodes while walking invalidates it.
  const nodes = []
  for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node)

  for (const node of nodes) {
    const text = node.nodeValue
    const lower = text.toLowerCase()
    let at = lower.indexOf(needle)
    if (at < 0) continue

    const fragment = document.createDocumentFragment()
    let from = 0
    while (at >= 0) {
      fragment.appendChild(document.createTextNode(text.slice(from, at)))
      const hit = document.createElement('mark')
      hit.className = 'find'
      hit.textContent = text.slice(at, at + needle.length)
      fragment.appendChild(hit)
      matches.push(hit)
      from = at + needle.length
      at = lower.indexOf(needle, from)
    }
    fragment.appendChild(document.createTextNode(text.slice(from)))
    node.parentNode?.replaceChild(fragment, node)
  }

  if (matches.length) step(0)
  return report()
}

function step(delta) {
  if (!matches.length) return report()
  matches[matchIndex]?.classList.remove('is-active')
  matchIndex = (matchIndex + delta + matches.length) % matches.length
  if (matchIndex < 0) matchIndex = 0
  const hit = matches[matchIndex]
  hit.classList.add('is-active')
  hit.scrollIntoView({ block: 'center', behavior: 'smooth' })
  return report()
}

function report() {
  bridge({ type: 'find', count: matches.length, index: matches.length ? matchIndex + 1 : 0 })
}

/* ------------------------------------------------------ keeping the place */

// Runs a change that moves the text — the text size, the column width — and
// puts the reader back on the line they were reading. The page keeps its
// scroll offset in pixels, and with the text a size bigger every paragraph
// above the window is taller, so the same offset is further up the document:
// each ⌘+ scrolled the page back and each ⌘− scrolled it on.
function keepingPlace(change) {
  // Measured from under the toolbar, where the visible page starts.
  const top = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--top-inset')) || 0
  // The last block to start at or above that line: the list item or table row
  // being read rather than the whole list, so a long one is not guessed
  // through. Blocks come in the order they sit on the page; one with no height
  // is not on it, like a front matter card that has been put away.
  let block = null
  for (const candidate of content().querySelectorAll('[data-line]')) {
    const box = candidate.getBoundingClientRect()
    if (!box.height) continue
    if (box.top > top) break
    block = candidate
  }
  if (!block) return change()
  const before = block.getBoundingClientRect()
  // Inside the block, how far into it as a share of its height: the block
  // grows with its text, and the line that was at the top grows with it. Past
  // its end, in the gap before the next block, how far past in pixels: the
  // gaps are fixed, and a share of a taller block overshot into the next one.
  const inside = top < before.bottom
  const share = (top - before.top) / before.height
  const past = top - before.bottom
  change()
  const after = block.getBoundingClientRect()
  const by = (inside ? after.top + share * after.height : after.bottom + past) - top
  // Every window is sent every setting on any change in Settings, and one that
  // did not change should not nudge the page by a rounding error.
  if (Math.abs(by) >= 1) window.scrollBy(0, by)
}

/* ------------------------------------------------------------------- api */

window.imark = {
  render,
  scrollToAnchor,
  /// Back and Forward inside one document. The place is where the reader was,
  /// not a heading, and going there is not a jump of its own.
  scrollToOffset(y) {
    glideTo(y)
  },
  setTheme(theme) {
    // The copy in the viewer keeps the colours it was opened in.
    if (theme !== document.documentElement.dataset.theme) closeDiagram()
    document.documentElement.dataset.theme = theme
    const blocks = document.querySelectorAll('.mermaid-block')
    if (blocks.length) drawDiagrams(placeDrawnDiagrams(content(), readPalette()))
  },
  setWidth(width) {
    keepingPlace(() => {
      document.documentElement.dataset.width = width
    })
  },
  setFrontMatter,
  setCommentingControls,
  setPreview(on) {
    document.documentElement.dataset.preview = on ? 'true' : 'false'
  },
  setRail(side) {
    if (side) document.documentElement.dataset.rail = side
    else delete document.documentElement.dataset.rail
    buildRail(content())
    buildNoteRail()
  },
  find: runFind,
  findStep: step,
  findClear: clearFind,
  setTextScale(scale) {
    keepingPlace(() => {
      document.documentElement.style.setProperty('--size-body', `${scale}px`)
    })
  },
  /// How much of the top of the page the toolbar is standing on. Everything
  /// pinned to the viewport has to start below it, not just the prose — a rail
  /// that runs to the top edge runs under the toolbar.
  setTopInset(points) {
    document.documentElement.style.setProperty('--top-inset', `${points}px`)
    buildNoteRail()
  },
  clearSelection() {
    window.getSelection()?.removeAllRanges()
    // The block lit up by the `+` is not a selection and would otherwise stay
    // lit after the popover closed.
    clearBlockTarget()
  },
  markMissing(targets) {
    const dead = new Set(targets)
    for (const link of document.querySelectorAll('a.wikilink')) {
      if (dead.has(link.dataset.wikilink)) link.dataset.missing = 'true'
    }
  },
  setReviewing(on) {
    applyReviewing(on)
    // The notes have to go with it. Announcing a count and no items left the
    // app believing the document had none: the status bar read zero, every
    // comment command greyed out, and the switch that had just been turned on
    // could not be turned off again.
    const items = attachedNotes()
    bridge({ type: 'comments', count: items.length, reviewing: on, items })
  },
  stepNote,
  magnify,
  smartMagnify,
  exportComments: () => toVisibleText(lastSource),
  /// Opens the note that was just written, so a comment lands visibly rather
  /// than silently changing a file.
  revealNote(index) {
    const dots = [...document.querySelectorAll('.note-dot')]
    const dot = dots[index] ?? dots[dots.length - 1]
    if (!dot) return
    dot.scrollIntoView({ block: 'center', behavior: 'smooth' })
    dot.click()
  },
}

installCommentHandlers()
setUpBlockPlus()
installDiagramClicks()

// KaTeX is imported for its side-effect-free API; keep a reference so the
// bundler cannot tree-shake the font-bearing CSS away.
window.imark.katexVersion = katex.version

bridge({ type: 'ready' })
