// Comments live inside the document, as HTML comments:
//
//   <!-- imark quote="exequível" by="john" at="2026-08-02T14:31Z"
//   Exequível com que equipa?
//   -->
//
// Invisible in GitHub, plain text in any editor, a balloon here. See
// docs/EDITOR.md for why this beats a sidecar file or a syntax of our own.
// Swift writes them; the escaping rules it has to match live in Comments.swift.

const bridge = (payload) => {
  window.webkit?.messageHandlers?.imark?.postMessage(payload)
}

const OPEN = /^\s*<!--\s*imark\b(.*)$/
const ATTR = /(\w+)="([^"]*)"/g

/// The colours a note may carry. A closed set on purpose: the value comes out
/// of somebody's file and ends up in a `data-color` attribute, so anything
/// unrecognised has to become the default rather than reach the stylesheet.
/// An absent colour is the default one and writes no attribute at all.
const COLOURS = new Set(['amber', 'green', 'blue', 'red'])
const colourOf = (raw) => (COLOURS.has(raw) ? raw : '')

/// Pulls the comment blocks out of the source and blanks the lines they came
/// from. Blanking rather than deleting is deliberate: every `data-line` in the
/// rendered HTML counts from the top of the file, and removing lines here would
/// silently shift everything below by however many notes came before it.
export function extractComments(body, lineOffset = 0) {
  const lines = body.split('\n')
  const comments = []

  for (let index = 0; index < lines.length; index += 1) {
    const open = OPEN.exec(lines[index])
    if (!open) continue

    let end = index
    while (end < lines.length && !lines[end].includes('-->')) end += 1
    // An unterminated block is somebody's half-typed comment; leave it as text
    // rather than swallowing the rest of the document.
    if (end >= lines.length) continue

    const attributes = {}
    for (const [, key, value] of open[1].matchAll(ATTR)) attributes[key] = unescapeHTML(value)

    comments.push({
      id: `note-${comments.length}`,
      quote: attributes.quote ?? '',
      by: attributes.by ?? '',
      at: attributes.at ?? '',
      nth: Number(attributes.nth) || 1,
      colour: colourOf(attributes.color),
      text: unwrap(unescapeHTML(lines.slice(index + 1, end).join('\n').trim())),
      // Both ends, because editing and deleting have to find the block again.
      line: index + lineOffset,
      endLine: end + lineOffset,
    })

    for (let i = index; i <= end; i += 1) lines[i] = ''
    index = end
  }

  return { body: lines.join('\n'), comments }
}

/// A note hard-wrapped in the file is one paragraph, not one line per line.
/// Single newlines become spaces; a blank line still starts a paragraph.
const unwrap = (text) =>
  text
    .split(/\n\s*\n/)
    .map((paragraph) => paragraph.replace(/\s*\n\s*/g, ' ').trim())
    .join('\n\n')

const unescapeHTML = (value) =>
  value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&')

/* --------------------------------------------------------------- anchoring */

/// The block a note belongs to is the one it physically follows in the file.
/// Searching the whole document for the quote would be more forgiving and much
/// less predictable — position is half the anchor, and it is the half a person
/// can see and fix by hand.
function blockAbove(root, line) {
  let best = null
  let bestEnd = -1
  for (const child of root.children) {
    const raw = child.getAttribute('data-line')
    if (!raw) continue
    const end = Number(raw.split(',')[1])
    if (Number.isFinite(end) && end <= line && end > bestEnd) {
      best = child
      bestEnd = end
    }
  }
  return best
}

/// Every text node under a block, in order, so a quote can be looked for in the
/// text the reader sees rather than in whatever pieces the markup happens to
/// have cut it into.
function textNodes(block) {
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT)
  const nodes = []
  for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node)
  return nodes
}

/// Wraps the nth occurrence of `quote` inside `block`. Returns the first piece
/// of the wrap, or null when the quote is gone — which is how a note becomes
/// orphaned.
///
/// The search runs over the block's text as one string and is then mapped back
/// onto nodes, because a quote very often straddles markup: bold in the middle
/// of a sentence, or a phrase inside a code block that the highlighter has cut
/// into a dozen spans. Looking node by node found none of those and orphaned
/// them without a word. Counting occurrences over the whole block also makes
/// `nth=` mean the same thing here as it did when the note was written.
function wrapQuote(block, quote, nth) {
  if (!quote) return null

  const nodes = textNodes(block)
  const whole = nodes.map((node) => node.data).join('')

  let at = -1
  for (let seen = 0; seen < nth; seen += 1) {
    at = whole.indexOf(quote, at + 1)
    if (at < 0) return null
  }
  const end = at + quote.length

  // One piece per text node the quote passes through. Each piece sits wholly
  // inside its node, which is the only case surroundContents accepts.
  const pieces = []
  let cursor = 0
  for (const node of nodes) {
    const start = cursor
    cursor += node.data.length
    if (cursor <= at || start >= end) continue
    pieces.push({
      node,
      from: Math.max(0, at - start),
      to: Math.min(node.data.length, end - start),
    })
  }

  let first = null
  for (const piece of pieces) {
    if (piece.from === piece.to) continue
    const range = document.createRange()
    range.setStart(piece.node, piece.from)
    range.setEnd(piece.node, piece.to)
    const span = document.createElement('span')
    span.className = 'note-anchor'
    try {
      range.surroundContents(span)
    } catch {
      // Wrapping one node cannot fail, but a malformed tree is not worth
      // taking the whole render down for.
      continue
    }
    first = first ?? span
  }
  return first
}

/// The dot and the card have to be positioned against the block, and a block
/// can be a table or a list that will not accept stray children. Wrapping is
/// the one approach that works for every block type.
function holderFor(block) {
  const parent = block.parentElement
  if (parent?.classList.contains('note-holder')) return parent

  const holder = document.createElement('div')
  holder.className = 'note-holder'
  block.replaceWith(holder)
  holder.appendChild(block)
  return holder
}

/// Returns the notes that found a home, in the order they appear, so Swift can
/// list them without parsing the file a second time. A note whose block is gone
/// is not in the list because it is not on screen either.
/// Kept so the rail can build a card for each mark without re-reading the DOM.
let attachedNotes = []

export function attachComments(root, comments) {
  attachedNotes = []
  if (!comments.length) return []

  // Resolved before anything is wrapped: wrapping changes root.children, and
  // two notes on the same paragraph would then fail to find it.
  const resolved = comments.map((note) => ({ note, block: blockAbove(root, note.line) }))
  const attached = []

  for (const { note, block } of resolved) {
    if (!block) continue
    // A note with no quote at all was written about the whole block, by the `+`
    // in the margin. It has nothing to underline and nothing it could have
    // lost — treating it as an orphan would warn about a problem that cannot
    // exist for it.
    const aboutBlock = !note.quote
    const anchor = aboutBlock ? null : wrapQuote(block, note.quote, note.nth)
    const lost = !aboutBlock && !anchor
    // A quote split across markup becomes several spans; all of them have to
    // answer to the same note, or clicking half a phrase would do nothing.
    for (const piece of block.querySelectorAll('.note-anchor:not([data-note])')) {
      piece.dataset.note = note.id
      if (note.colour) piece.dataset.color = note.colour
    }

    const holder = holderFor(block)
    holder.classList.add('has-note')

    const dot = document.createElement('button')
    dot.type = 'button'
    dot.className = lost ? 'note-dot orphan' : (aboutBlock ? 'note-dot block' : 'note-dot')
    dot.dataset.note = note.id
    if (note.colour) dot.dataset.color = note.colour
    dot.setAttribute('aria-label', lost ? 'Comment with a missing quote' : 'Comment')
    // Two notes on one paragraph would otherwise sit exactly on top of each
    // other and only the last one would be clickable.
    const stacked = holder.querySelectorAll('.note-dot').length
    if (stacked) dot.style.top = `${2 + stacked * 17}px`
    holder.appendChild(dot)
    holder.appendChild(buildCard(note, lost))
    attached.push({
      quote: note.quote,
      colour: note.colour,
      by: note.by,
      // Formatted here, not in Swift: a hand-written note can carry any shape
      // of timestamp, and this is already the one place that copes with that.
      when: formatDate(note.at),
      text: note.text,
      orphan: lost,
    })
  }

  attachedNotes = attached
  return attached
}

function buildCard(note, orphan) {
  const card = document.createElement('aside')
  card.className = 'note-card'
  card.dataset.note = note.id
  if (note.colour) card.dataset.color = note.colour
  card.hidden = true

  const head = document.createElement('header')
  head.textContent = [note.by, formatDate(note.at)].filter(Boolean).join(' · ') || 'Note'
  card.appendChild(head)

  if (orphan) {
    const warning = document.createElement('p')
    warning.className = 'note-orphan'
    warning.textContent = note.quote
      ? `The quoted text is gone: “${note.quote}”`
      : 'This note has no quote.'
    card.appendChild(warning)
  }

  const body = document.createElement('p')
  body.className = 'note-text'
  body.textContent = note.text
  card.appendChild(body)

  card.appendChild(cardActions(note))
  return card
}

/// Drawn rather than typed. The Unicode pencil and cross are hairlines at this
/// size and read as smudges; a stroked path is legible at 13px and takes the
/// card's colour with it.
const ICONS = {
  edit: 'M11.4 2.6a1.7 1.7 0 0 1 2.4 2.4L6 12.8l-3.2.8.8-3.2z',
  delete: 'M3 4.5h10M6.4 4.5V3h3.2v1.5M4.6 4.5l.5 8.4h5.8l.5-8.4',
}

/// Edit and delete live on the card itself. A note you can write but not take
/// back is a trapdoor, and hiding the controls in a menu somewhere else would
/// mean guessing which note the menu meant. At the foot rather than in the
/// header: beside the byline they squeezed the date onto a second line.
function cardActions(note) {
  const actions = document.createElement('footer')
  actions.className = 'note-actions'

  for (const [command, label] of [
    ['edit', 'Edit'],
    ['delete', 'Delete'],
  ]) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = `note-action note-${command}`
    button.title = `${label} this note`
    button.setAttribute('aria-label', `${label} this note`)
    button.innerHTML =
      `<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor"` +
      ` stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">` +
      `<path d="${ICONS[command]}"/></svg>`
    button.addEventListener('click', (event) => {
      event.preventDefault()
      event.stopPropagation()
      const dot = document.querySelector(`.note-dot[data-note="${note.id}"]`)
      const box = (dot ?? button).getBoundingClientRect()
      bridge({
        type: 'noteCommand',
        command,
        line: note.line,
        endLine: note.endLine,
        text: note.text,
        quote: note.quote,
        colour: note.colour,
        rect: { x: box.left, y: box.top, width: box.width, height: box.height },
      })
    })
    actions.appendChild(button)
  }
  return actions
}

function formatDate(raw) {
  if (!raw) return ''
  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return raw
  return date.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
}

/* ------------------------------------------------------------- interaction */

function closeCards(except) {
  for (const card of document.querySelectorAll('.note-card')) {
    if (card !== except) card.hidden = true
  }
  for (const dot of document.querySelectorAll('.note-dot')) {
    if (!except || dot.dataset.note !== except.dataset.note) dot.classList.remove('open')
  }
}

/// One listener on the document rather than one per note: the notes are rebuilt
/// on every render, and per-note listeners would leak with them.
export function installCommentHandlers() {
  document.addEventListener('click', (event) => {
    const trigger = event.target.closest('.note-dot, .note-anchor')
    if (!trigger) {
      if (!event.target.closest('.note-card')) closeCards(null)
      return
    }
    event.preventDefault()
    event.stopPropagation()

    const id = trigger.dataset.note
    const card = document.querySelector(`.note-card[data-note="${id}"]`)
    if (!card) return

    const opening = card.hidden
    closeCards(opening ? card : null)
    card.hidden = !opening
    const dot = document.querySelector(`.note-dot[data-note="${id}"]`)
    dot?.classList.toggle('open', opening)
    // The card lines up with its own dot, so stacked notes open at the height
    // of the one you pressed rather than all at the top of the paragraph.
    card.style.top = dot?.style.top || '0px'
    if (opening) placeCard(card)
  })

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeCards(null)
  })

  window.addEventListener('resize', () => {
    for (const card of document.querySelectorAll('.note-card:not([hidden])')) placeCard(card)
  })
}

/// The card overlaps the right edge of the text, which is what "floating over
/// the margin" means and what keeps the reading column its full width. Only a
/// window too narrow to have a margin at all falls back to sitting below.
function placeCard(card) {
  const holder = card.parentElement
  if (!holder) return
  card.classList.toggle('below', holder.getBoundingClientRect().width < 320)
}

/* ---------------------------------------------------------- seeing them all */

const dots = () => [...document.querySelectorAll('.note-dot')]

// Kept in module scope so it survives a re-render: reloading a document you are
// reviewing should not quietly put the notes away again.
let reviewing = false
let cursor = -1

/// Review mode: every note open at once, laid out under its own block instead
/// of floating over the margin. Overlapping cards would bury the text they are
/// about, and stacking them into a side column is the permanent column this
/// design set out to avoid — under the paragraph is also how the file reads in
/// any plain-text editor, which is the honest layout.
export function setReviewing(on) {
  reviewing = on
  document.documentElement.dataset.notes = on ? 'all' : ''
  for (const card of document.querySelectorAll('.note-card')) {
    card.hidden = !on
    card.style.top = ''
    card.classList.toggle('below', on)
  }
  for (const dot of dots()) dot.classList.toggle('open', on)
  return document.querySelectorAll('.note-card').length
}

export const isReviewing = () => reviewing

/// The notes exactly as they were attached, for anyone who has to announce them
/// again without re-rendering. Reaching for the DOM instead would rebuild them
/// from what is on screen, which is a second parser to keep in step.
export const attached = () => attachedNotes

/// Moves to the next or previous note, wrapping around. In review mode the
/// notes are already open, so this only scrolls.
export function stepNote(delta) {
  const all = dots()
  if (!all.length) return 0
  cursor = (cursor + delta + all.length) % all.length
  const dot = all[cursor]

  // The rail says which one you are on, so stepping does not feel like it
  // lost your place.
  for (const mark of document.querySelectorAll('.note-mark')) mark.classList.remove('is-active')
  document.querySelectorAll('.note-mark')[cursor]?.classList.add('is-active')

  if (!reviewing) {
    closeCards(null)
    const card = document.querySelector(`.note-card[data-note="${dot.dataset.note}"]`)
    if (card) {
      card.hidden = false
      card.style.top = dot.style.top || '0px'
      dot.classList.add('open')
      placeCard(card)
    }
  }
  dot.scrollIntoView({ block: 'center', behavior: 'smooth' })
  return cursor + 1
}

/// Called after every render, since the notes are rebuilt from scratch.
/// The rail is not built here: it has to wait for the outline rail, which main
/// builds later in the same pass.
export function restoreNoteState() {
  cursor = -1
  if (reviewing) setReviewing(true)
}

/* ------------------------------------------------------------------- rail */

/// One mark per note, in the column beside the outline. Each sits level with
/// the tick of the section it belongs to, so the two rails read as one thing
/// instead of two that nearly agree. What that costs is the exact position
/// inside a section — and what it keeps is the clustering, since several notes
/// under one heading come out as a short run of marks against that tick.
export function buildNoteRail() {
  document.querySelector('.note-rail')?.remove()
  hideTip()

  const all = dots()
  if (all.length < 2) {
    delete document.documentElement.dataset.noteRail
    return
  }

  const rail = document.createElement('nav')
  rail.className = 'note-rail'
  rail.setAttribute('aria-label', 'Comments')

  const tops = placeMarks(all)

  for (const [index, dot] of all.entries()) {
    const note = attachedNotes[index]
    const mark = document.createElement('button')
    mark.type = 'button'
    mark.className = dot.classList.contains('orphan') ? 'note-mark orphan' : 'note-mark'
    if (note?.colour) mark.dataset.color = note.colour
    mark.style.top = `${tops[index]}px`
    mark.setAttribute('aria-label', note?.quote || 'Comment')

    // Hovering shows the note without going there; clicking goes there.
    mark.addEventListener('mouseenter', () => showTip(note, mark))
    mark.addEventListener('mouseleave', scheduleHide)
    mark.addEventListener('click', () => {
      hideTip()
      cursor = index - 1
      stepNote(1)
    })
    rail.appendChild(mark)
  }

  document.body.appendChild(rail)
  document.documentElement.dataset.noteRail = 'true'
}

const MARK_SIZE = 9  // .note-mark in style.css

const where = (el) => el.getBoundingClientRect().top + window.scrollY

/// Every mark's resting position, before they are pushed apart.
///
/// The outline rail is a list: its ticks sit at a fixed pitch, so the third one
/// is the third heading whether that is on the first screen or the ninth. Marks
/// placed by their true position in the document therefore never lined up with
/// it, however close they looked. So each note is put level with the tick of
/// the section it is in.
///
/// Without an outline rail — a short document has none, and Quick Look can turn
/// it off — there is nothing to line up with, and the old proportional mapping
/// is the honest answer.
function placeMarks(all) {
  const ticks = outlineTicks()
  if (!ticks.length) return spread(proportional(all))

  // Measured off the rail rather than agreed with it: main.js sets the pitch
  // per document, and a second copy of that sum here would be one to keep in
  // step.
  const pitch = ticks.length > 1 ? ticks[1].y - ticks[0].y : MARK_GAP * 2

  // The section a note is in is the last heading above it. A note higher than
  // every heading — front matter, an opening paragraph — takes the first one,
  // which is the section it reads as being part of.
  const section = all.map((dot) => {
    const at = where(dot)
    let index = 0
    for (let i = 0; i < ticks.length; i += 1) {
      if (ticks[i].at > at) break
      index = i
    }
    return index
  })

  const tops = new Array(all.length)
  for (let first = 0; first < all.length; ) {
    let last = first
    while (last < all.length && section[last] === section[first]) last += 1
    const count = last - first

    // Several notes under one heading come out as a short stack against its
    // tick. Tightened to fit inside the pitch, so a stack can never reach the
    // next section and read as belonging to it — which is the whole reason for
    // lining these up in the first place. Below about 11px of pitch the marks
    // start to overlap, and a pile is still a truer answer than a queue
    // wandering into somebody else's section.
    const step = count > 1 ? Math.max(3, Math.min(MARK_GAP, (pitch * 0.8 - MARK_SIZE) / (count - 1))) : 0
    const centre = ticks[section[first]].y - ((count - 1) * step) / 2

    for (let n = 0; n < count; n += 1) tops[first + n] = centre + n * step - MARK_SIZE / 2
    first = last
  }
  return tops
}

/// The ticks that are actually on screen, each with where its heading starts in
/// the document — which is what a note gets compared against.
function outlineTicks() {
  const rail = document.querySelector('.rail')
  if (!rail || !rail.getBoundingClientRect().height) return []
  return [...rail.querySelectorAll('.rail-tick')]
    .map((tick) => ({ tick, heading: document.getElementById(tick.dataset.heading || '') }))
    .filter((entry) => entry.heading)
    .map(({ tick, heading }) => {
      // The centre of the dash, not the top of its row: the row is a hit area
      // and stands taller than anything visible in it.
      const box = tick.getBoundingClientRect()
      return { y: box.top + box.height / 2, at: where(heading) }
    })
}

/// Only used when there is no outline to line up with. Mapped into the part of
/// the window you can actually see: the toolbar stands on the top of the page,
/// and a mark up there would be behind it.
const proportional = (all) => {
  const height = document.documentElement.scrollHeight || 1
  const top = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--top-inset')) || 0
  return all.map((dot) => top + (where(dot) / height) * (window.innerHeight - top))
}

/// How far apart two marks have to be to still read as two. Only the fallback
/// needs pushing apart: with an outline to line up against, a section's marks
/// are laid out together and cannot collide with the next section's.
const MARK_GAP = 12

function spread(positions) {
  const limit = window.innerHeight - MARK_GAP
  const out = []
  let previous = -Infinity
  for (const wanted of positions) {
    const placed = Math.min(Math.max(wanted, previous + MARK_GAP), limit)
    out.push(placed)
    previous = placed
  }
  return out
}

/* -------------------------------------------------------------- rail card */

let tip = null
let hideTimer = 0

/// Built once and reused. Moving from one mark to the next fires a leave before
/// the next enter, so hiding is deferred by a frame or two and cancelled by
/// whichever mark you landed on — otherwise the card blinks between every pair.
function showTip(note, mark) {
  clearTimeout(hideTimer)
  if (!note) return

  if (!tip) {
    tip = document.createElement('aside')
    tip.className = 'note-tip'
    document.body.appendChild(tip)
  }
  if (note.colour) tip.dataset.color = note.colour
  else delete tip.dataset.color

  tip.replaceChildren()
  const who = document.createElement('em')
  who.textContent = note.by || 'Note'
  tip.appendChild(who)

  const quote = document.createElement('strong')
  quote.textContent = note.orphan
    ? 'Quote no longer in the document'
    : `“${note.quote}”`
  tip.appendChild(quote)

  if (note.text) {
    const body = document.createElement('span')
    body.textContent = note.text
    tip.appendChild(body)
  }
  if (note.when) {
    const when = document.createElement('b')
    when.textContent = note.when
    tip.appendChild(when)
  }

  tip.classList.add('is-visible')
  mark.classList.add('is-active')

  // Height has to be read after the content lands, or the first card of a
  // session is positioned against the previous one's size.
  const box = mark.getBoundingClientRect()
  const height = tip.offsetHeight
  tip.style.top = `${Math.min(
    Math.max(10, box.top + box.height / 2 - height / 2),
    window.innerHeight - height - 10,
  )}px`
}

function scheduleHide() {
  clearTimeout(hideTimer)
  hideTimer = setTimeout(hideTip, 60)
}

function hideTip() {
  clearTimeout(hideTimer)
  tip?.classList.remove('is-visible')
  for (const mark of document.querySelectorAll('.note-mark.is-active')) {
    mark.classList.remove('is-active')
  }
}

// Positions are a fraction of the document height, so they are wrong the moment
// it reflows.
window.addEventListener('resize', () => buildNoteRail())

/* ----------------------------------------------------------------- export */

/// Turns the notes into blockquotes anybody can see. HTML comments are perfect
/// for notes between people who both use Imark and useless for a review the
/// other person has to read on GitHub — this is the bridge, and it produces a
/// copy rather than touching the document it came from.
export function toVisibleText(source) {
  const lines = source.split('\n')
  const out = []

  for (let index = 0; index < lines.length; index += 1) {
    const open = OPEN.exec(lines[index])
    if (!open) {
      out.push(lines[index])
      continue
    }
    let end = index
    while (end < lines.length && !lines[end].includes('-->')) end += 1
    if (end >= lines.length) {
      out.push(lines[index])
      continue
    }

    const attributes = {}
    for (const [, key, value] of open[1].matchAll(ATTR)) attributes[key] = unescapeHTML(value)

    const who = [attributes.by, formatDate(attributes.at)].filter(Boolean).join(', ')
    const head = [`**${who || 'Note'}**`, attributes.quote ? `on *“${attributes.quote}”*` : '']
      .filter(Boolean)
      .join(' ')
    const body = unwrap(unescapeHTML(lines.slice(index + 1, end).join('\n').trim()))

    out.push(`> ${head}`, '>', ...body.split('\n').map((line) => (line ? `> ${line}` : '>')))
    index = end
  }

  return out.join('\n')
}
