// Block widgets for the Live Preview (docs/LIVE-PREVIEW.md §4, M3): the pieces of
// a document drawn as something other than their source — a task box, a comment
// card, and after them tables, formulas, diagrams, images, footnotes and front
// matter. This file is the frame they plug into; each kind registers itself.
//
//   registerBlock({
//     type: 'table',
//     nodes: ['Table'],                     // syntax nodes `match` is offered
//     match(node, state, ctx) → {from, to, data} | [...] | null,
//     scan(state, ctx) → [{from, to, data}],  // instead of `match`, for what the
//                                             // tree does not name (see note-card.js)
//     widget(data, info) → WidgetType,      // info: {from, to, source, type}
//     block: true,                          // whole lines (default), or inline
//     reveal: 'lines',                      // or 'range', or 'never'
//     atomic: false,                        // the caret steps over it whole
//   })
//
// Why a StateField and not a ViewPlugin like live.js: CodeMirror only takes a
// block decoration — one that replaces whole lines — from state, because it has
// to know the height of what it lays out before any view exists to ask. So the
// widgets are kept here for the whole document and recomputed when the document,
// the syntax tree or the selection changes, while the plugin goes on painting the
// inline marks for what is on screen.
//
// Display, as in live.js, with two exceptions that are edits and say so: a click
// on a task box (tasks.js) and Backspace/Delete beside an atomic block. Both are
// transactions on the buffer, which Swift mirrors and ⌘S saves — never a write
// to the file (§1, invariant 2).

import { EditorState, StateField, StateEffect, RangeSet, Prec } from '@codemirror/state'
import { Decoration, EditorView, ViewPlugin, WidgetType, keymap } from '@codemirror/view'
import { syntaxTree } from '@codemirror/language'
import { isolateHistory } from '@codemirror/commands'
import { load as parseYaml } from 'js-yaml'
import { createMarkdown, splitFrontMatter } from '../shared/markdown.js'
import { notesIn } from './notes.js'

/// Where a leading front-matter block ends (the end of its closing `---`), or 0.
/// The preview takes `---` … `---` at the very top as front matter only when the
/// inside is YAML that reads as an object (shared/markdown.js, splitFrontMatter);
/// otherwise it is ordinary Markdown, and so it is here. Lezer reads the block as
/// a rule and a setext heading, which is why it has to be found first.
export function frontMatterEnd(state) {
  const doc = state.doc
  if (doc.lines < 3 || doc.line(1).text !== '---') return 0
  for (let n = 3; n <= doc.lines; n++) {
    const line = doc.line(n)
    if (!line.text.startsWith('---')) continue
    const yaml = doc.sliceString(doc.line(2).from, doc.line(n - 1).to)
    try {
      const data = parseYaml(yaml)
      if (data && typeof data === 'object') return line.to
    } catch {
      /* malformed front matter is shown as-is */
    }
    return 0
  }
  return 0
}

// --- The registry

const registry = []
const byType = new Map()

/// Adds a kind of block. Registered once, when its module loads; the order of
/// registration is the order of precedence when two kinds claim the same text.
export function registerBlock(definition) {
  const entry = { block: true, reveal: 'lines', atomic: false, nodes: [], ...definition }
  if (!entry.type || !entry.widget || !(entry.match || entry.scan)) {
    throw new Error('registerBlock needs a type, a widget, and match or scan')
  }
  // `match` is offered only the nodes named; without any it would never run.
  if (entry.match && !entry.nodes.length) throw new Error(`block type ${entry.type}: match needs nodes`)
  if (byType.has(entry.type)) throw new Error(`block type ${entry.type} registered twice`)
  registry.push(entry)
  byType.set(entry.type, entry)
}

// --- The render context: the whole document through markdown-it, once

// A slice rendered on its own loses what is defined elsewhere in the file — the
// target of `[x][ref]`, the number of `[^1]` (§4). So a widget renders with the
// `env` the whole document was parsed into. Parsing a long document on every
// key would be the slowest thing on the page, hence once per version of the
// text, and only when some widget asks.

let markdown = null
let parses = 0
const contexts = new WeakMap()

/// How many whole-document parses have run. For the tests, which check that a
/// caret moving through a document costs none.
export const parseCount = () => parses

/// The context for this version of the document. The same object for every
/// state that shares the text, so moving the selection never parses again.
export function renderContext(state) {
  const doc = state.doc
  let ctx = contexts.get(doc)
  if (ctx) return ctx
  let env = null
  const pipeline = () => (markdown ??= createMarkdown())
  ctx = {
    doc,
    /// markdown-it's env for the whole document: `references`, `footnotes`.
    /// Parsed as the preview parses it — front matter off, comment blocks
    /// blanked — so a definition the preview does not see is not seen here.
    env() {
      if (env) return env
      parses += 1
      const lines = doc.toString().split('\n')
      for (const note of notesIn(lines)) for (let i = note.line; i <= note.endLine; i++) lines[i] = ''
      const { body } = splitFrontMatter(lines.join('\n'))
      env = {}
      pipeline().md.parse(body, env)
      return env
    },
    /// A slice of the document as the preview would draw it, with the
    /// document's definitions. The env is copied: rendering a footnote reference
    /// adds to the env's list, and one widget's render must not number the next.
    render(source, options) {
      const whole = ctx.env()
      const slice = { ...whole }
      if (whole.footnotes) {
        slice.footnotes = { ...whole.footnotes, list: whole.footnotes.list ? [...whole.footnotes.list] : undefined }
      }
      return pipeline().renderSlice(source, slice, options)
    },
  }
  contexts.set(doc, ctx)
  return ctx
}

// --- Finding the blocks (pure)

// Every block in the document, found once per syntax tree. Keyed by the text as
// well, since a state without a language has the same empty tree for any text.
const found = new WeakMap()

function collect(state) {
  const doc = state.doc
  const tree = syntaxTree(state)
  const hit = found.get(doc)
  if (hit && hit.tree === tree) return hit.items

  const ctx = renderContext(state)
  const raw = []
  const push = (entry, result) => {
    if (!result) return
    for (const r of [].concat(result)) {
      if (!r || !(r.to >= r.from) || r.from < 0 || r.to > doc.length) continue
      let { from, to } = r
      // A block decoration has to cover whole lines; CodeMirror draws it oddly
      // otherwise. Widened here so no kind can get that wrong.
      if (entry.block) {
        from = doc.lineAt(from).from
        to = doc.lineAt(to).to
      }
      raw.push({ entry, from, to, data: r.data ?? null })
    }
  }

  const byNode = new Map()
  for (const entry of registry) {
    if (entry.scan) push(entry, entry.scan(state, ctx))
    if (entry.match) {
      for (const name of entry.nodes) {
        if (!byNode.has(name)) byNode.set(name, [])
        byNode.get(name).push(entry)
      }
    }
  }
  if (byNode.size) {
    tree.iterate({
      enter(ref) {
        const entries = byNode.get(ref.name)
        if (entries) for (const entry of entries) push(entry, entry.match(ref, state, ctx))
      },
    })
  }

  // Two replaced stretches may not overlap. The outer one wins — a task inside a
  // note is part of the note — and, at the same start, the kind registered first.
  const order = new Map(registry.map((entry, i) => [entry, i]))
  raw.sort((a, b) => a.from - b.from || b.to - a.to || order.get(a.entry) - order.get(b.entry))
  const items = []
  let end = -1
  for (const r of raw) {
    if (r.from < end || (r.from === end && r.to === end)) continue
    end = Math.max(end, r.to)
    items.push({
      type: r.entry.type,
      from: r.from,
      to: r.to,
      block: r.entry.block,
      atomic: r.entry.atomic,
      reveal: r.entry.reveal,
      source: doc.sliceString(r.from, r.to),
      data: r.data,
    })
  }
  found.set(doc, { tree, items })
  return items
}

// The Obsidian rule, as in live.js: inclusive at both ends.
const touches = (selection, from, to) =>
  selection.ranges.some((range) => range.from <= to && range.to >= from)

function isRevealed(state, item, forced) {
  if (forced.includes(item.from)) return true
  switch (item.reveal) {
    case 'never':
      return false
    case 'range':
      return touches(state.selection, item.from, item.to)
    default:
      return touches(state.selection, state.doc.lineAt(item.from).from, state.doc.lineAt(item.to).to)
  }
}

/// Every block of the document, as plain data, sorted and never overlapping:
///
///   {type, from, to, block, atomic, reveal, source, data, revealed}
///
/// `revealed` is whether its source shows instead of its widget: the selection
/// touches it (by its kind's rule), or a double-click asked (`revealBlock`).
/// `forced` is the starts of blocks shown that way; by default the editor's own.
export function blockRanges(state, forced = state.field(blockField, false)?.forced ?? []) {
  return collect(state).map((item) => ({ ...item, revealed: isRevealed(state, item, forced) }))
}

/// Shows a block's source until the selection leaves it. The value is the
/// block's start; the caret should be put inside it in the same transaction.
export const revealBlock = StateEffect.define({ map: (pos, mapping) => mapping.mapPos(pos) })

// --- The field

const widgets = new WeakMap()
const widgetFor = (item, original) => {
  let widget = widgets.get(original)
  if (!widget) {
    widget = byType.get(item.type).widget(item.data, { from: item.from, to: item.to, source: item.source, type: item.type })
    widgets.set(original, widget)
  }
  return widget
}
const atomicMark = Decoration.mark({})

function draw(state, forced) {
  // A reveal lasts while the selection is on the block, and no longer.
  const items = collect(state)
  const kept = forced.filter((pos) => {
    const item = items.find((i) => i.from === pos)
    return item && touches(state.selection, state.doc.lineAt(item.from).from, state.doc.lineAt(item.to).to)
  })
  const decorations = []
  const atomic = []
  for (const item of items) {
    if (isRevealed(state, item, kept)) continue
    decorations.push(Decoration.replace({ widget: widgetFor(item, item), block: item.block }).range(item.from, item.to))
    if (item.atomic && item.to > item.from) atomic.push(atomicMark.range(item.from, item.to))
  }
  return {
    forced: kept,
    decorations: Decoration.set(decorations),
    atomic: RangeSet.of(atomic),
    stale: false,
  }
}

// Set from compositionstart until a moment after compositionend (the plugin
// below). Kept on the page rather than in the state because the composition is
// the view's business; there is one editor per page.
const composition = { holding: false, timer: 0 }

export const blockField = StateField.define({
  create(state) {
    return draw(state, [])
  },
  update(value, tr) {
    let forced = tr.docChanged ? value.forced.map((pos) => tr.changes.mapPos(pos)) : value.forced
    for (const effect of tr.effects) if (effect.is(revealBlock)) forced = [...forced, effect.value]
    // During a composition the set is kept, moved with the text, exactly as the
    // M2 plugin keeps its marks: redrawing a widget beside text the input method
    // owns loses its candidate window (§5). Caught up on the next transaction
    // after it, which the plugin dispatches.
    if (composition.holding || tr.isUserEvent('input.type.compose')) {
      if (!tr.docChanged && forced === value.forced) return value.stale ? value : { ...value, stale: true }
      return {
        forced,
        decorations: value.decorations.map(tr.changes),
        atomic: value.atomic.map(tr.changes),
        stale: true,
      }
    }
    if (
      value.stale ||
      tr.docChanged ||
      tr.selection ||
      forced !== value.forced ||
      syntaxTree(tr.state) !== syntaxTree(tr.startState)
    ) {
      return draw(tr.state, forced)
    }
    return value
  },
  provide: (field) => [
    EditorView.decorations.from(field, (value) => value.decorations),
    EditorView.atomicRanges.of((view) => view.state.field(field).atomic),
  ],
})

const holdDuringComposition = ViewPlugin.define(() => ({ destroy() { clearTimeout(composition.timer) } }), {
  eventHandlers: {
    compositionstart() {
      composition.holding = true
      clearTimeout(composition.timer)
    },
    compositionend(_event, view) {
      clearTimeout(composition.timer)
      composition.timer = setTimeout(() => {
        composition.holding = false
        if (view.dom.isConnected && !view.compositionStarted) view.dispatch({})
      }, 50)
    },
  },
})

// --- Widgets

/// The base for a block's widget. Equal when the source is: an unchanged table
/// keeps its DOM through every edit around it, and one that changed by a single
/// character is drawn again. A click puts the caret at the start of the block,
/// which for a block revealed by the caret shows its source.
///
/// Subclasses draw in `render(view)` and may give `estimatedHeight` (in pixels,
/// before the widget is ever drawn — what keeps the scroll bar from jumping).
export class BlockWidget extends WidgetType {
  constructor(source, data) {
    super()
    this.source = source
    this.data = data
  }

  eq(other) {
    return other.constructor === this.constructor && other.source === this.source
  }

  get estimatedHeight() {
    return -1
  }

  toDOM(view) {
    const dom = this.render(view)
    dom.addEventListener('mousedown', (event) => this.mousedown(event, view, dom))
    return dom
  }

  render() {
    return document.createElement('div')
  }

  /// The position of this widget in the document now: the DOM is reused across
  /// edits around it, so a position remembered at drawing time goes stale.
  position(view, dom) {
    return view.posAtDOM(dom)
  }

  mousedown(event, view, dom) {
    if (event.button !== 0) return
    event.preventDefault()
    view.dispatch({ selection: { anchor: this.position(view, dom) }, scrollIntoView: true })
    view.focus()
  }

  // The widget handles its own mouse; CodeMirror leaves it be.
  ignoreEvent() {
    return true
  }
}

// --- Deleting an atomic block

/// What Backspace (`forward` false) or Delete does beside an atomic block that
/// is drawn, as a transaction spec, or null when it is ordinary editing.
///
/// CodeMirror's own atomic handling only widens a deletion that would land
/// inside the range; Backspace from the line after would take the line break
/// and glue that line onto the block's `-->`. Here the block goes whole, with
/// the break after it — or before it, at the very end of the file — so no blank
/// line is left where it was, and as one step of its own in the history.
///
/// The other two edges step over the break instead of deleting it: Backspace at
/// a block's start, or Delete at its end, would merge the block into the line
/// beside it and turn a note into prose, or prose into part of a note.
export function blockDeletion(state, forward) {
  const selection = state.selection
  if (selection.ranges.length !== 1 || !selection.main.empty) return null
  const pos = selection.main.head
  const doc = state.doc
  for (const block of blockRanges(state)) {
    if (!block.atomic || block.revealed) continue
    const takes = forward
      ? pos === block.from || (block.from > 0 && pos === block.from - 1)
      : pos === block.to || (block.to < doc.length && pos === block.to + 1)
    if (takes) {
      let from = block.from
      let to = block.to
      if (to < doc.length) to += 1
      else if (from > 0) from -= 1
      return {
        changes: { from, to },
        selection: { anchor: from },
        scrollIntoView: true,
        userEvent: forward ? 'delete.forward' : 'delete.backward',
        annotations: isolateHistory.of('full'),
      }
    }
    if (!forward && pos === block.from && pos > 0) return { selection: { anchor: pos - 1 }, scrollIntoView: true }
    if (forward && pos === block.to && pos < doc.length) return { selection: { anchor: pos + 1 }, scrollIntoView: true }
  }
  return null
}

/// Every other edit that reaches a drawn atomic block — typing or pasting at
/// either edge, a word-delete across one, the break beside it taken out — would
/// change it without anyone seeing: text typed at the end of a note lands on its
/// `-->` line, under the card, and the preview hides that line too; a letter
/// before its `<!--` makes it prose. So a change that touches such a block goes
/// through only when it takes the whole block, or leaves its text as it was and
/// on lines of its own (Enter at either edge does). Anything else is refused,
/// the way a read-only stretch refuses it.
///
/// Undo and redo are let through: they put back a state that was, including an
/// edit made while the note's source was showing.
const keepAtomicBlocksWhole = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || tr.isUserEvent('undo') || tr.isUserEvent('redo')) return tr
  if (!tr.startState.field(blockField, false)) return tr
  const blocks = blockRanges(tr.startState).filter((b) => b.atomic && !b.revealed)
  if (!blocks.length) return tr
  const doc = tr.newDoc
  for (const block of blocks) {
    let touched = false
    let whole = true
    tr.changes.iterChangedRanges((fromA, toA) => {
      if (fromA > block.to || toA < block.from) return
      touched = true
      if (!(fromA <= block.from && toA >= block.to && toA > fromA)) whole = false
    })
    if (!touched || whole) continue
    const from = tr.changes.mapPos(block.from, 1)
    const to = tr.changes.mapPos(block.to, -1)
    const intact =
      to - from === block.to - block.from &&
      doc.sliceString(from, to) === block.source &&
      doc.lineAt(from).from === from &&
      doc.lineAt(to).to === to
    if (!intact) return []
  }
  return tr
})

const deleteCommand = (forward) => ({ state, dispatch }) => {
  const spec = blockDeletion(state, forward)
  if (!spec) return false
  dispatch(state.update(spec))
  return true
}

/// The block widgets as an extension: the field, the guard on atomic blocks,
/// their keys, and the composition hold. Part of `livePreview()`, so switching the Live look off removes them.
export function liveBlocks() {
  return [
    blockField,
    // High, so it runs after main.js's filter has made every pasted `\n` of a
    // CRLF document a real line break: transaction filters run lowest first.
    Prec.high(keepAtomicBlocksWhole),
    holdDuringComposition,
    // Ahead of the default keymap, which would take a single character. The
    // same keys it binds to deleting one: ⇧⌫, and the Emacs-style ⌃H and ⌃D.
    Prec.high(keymap.of([
      { key: 'Backspace', run: deleteCommand(false), shift: deleteCommand(false) },
      { key: 'Delete', run: deleteCommand(true) },
      { mac: 'Ctrl-h', run: deleteCommand(false) },
      { mac: 'Ctrl-d', run: deleteCommand(true) },
    ])),
  ]
}
