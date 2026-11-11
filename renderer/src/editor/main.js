// The Live editor page: CodeMirror 6 in its own web view, talking to Swift
// through `webkit.messageHandlers.imarkEditor` and `window.imarkEditor`.
//
// Separate from the preview (src/main.js) on purpose: the preview is shared with
// Quick Look and owns the comment rail and selection logic; this page owns a
// contenteditable. See docs/LIVE-PREVIEW.md §2 and §3.
//
// The mirror protocol (§3.2). Swift keeps a copy of the document in CodeMirror's
// own coordinates — every line break is one position and is written `\n` — so
// it can answer `text` and `isDirty` synchronously. After every transaction that
// changes the document this page posts
//
//   {type: 'changes', generation, seq, length, changes: [[fromA, toA, insert], …]}
//
// where `fromA`/`toA` are positions in the document before the change and
// `insert` is the inserted text with its lines joined by `\n`. Swift applies
// them in descending `fromA` order and checks `seq` and `length`; on a mismatch
// it calls `resync()` and gets the whole document back as `fullText`.

import { EditorState, Compartment, StateEffect, Text, Transaction } from '@codemirror/state'
import {
  EditorView,
  keymap,
  drawSelection,
  highlightActiveLine,
  highlightSpecialChars,
  Decoration,
  ViewPlugin,
} from '@codemirror/view'
import {
  history,
  historyKeymap,
  defaultKeymap,
  indentWithTab,
  undo as cmUndo,
  redo as cmRedo,
  undoDepth,
  redoDepth,
} from '@codemirror/commands'
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { SearchQuery } from '@codemirror/search'
import { setLanguage } from '../i18n.js'
import { inlineExtensions } from './inline.js'
import { livePreview } from './live.js'
import { restyle } from './blocks.js'
import { setDocumentPath } from './doc-path.js'
import './editor.css'

const handler = () => window.webkit?.messageHandlers?.imarkEditor

// The test harnesses (Support/spike-live-editor.swift, test-live-editor.swift)
// set this from a user script before the page runs. Nothing in the app does:
// the hooks reach straight into the editor and around the mirror protocol, so a
// normal page has no business exposing them.
const hooksEnabled = window.__imarkEditorHooks === true

let generation = 0
let seq = 0

function post(type, payload = {}) {
  const message = { type, generation, ...payload }
  const h = handler()
  if (h) h.postMessage(message)
  else if (hooksEnabled) spike.outbox.push(message) // Outside the app (a plain browser): keep for inspection.
}

// ⌘Z, ⇧⌘Z and ⌘F belong to the app's menu, which calls `undo()` / `redo()` /
// `find()` here. The page sees a key before the menu does, so any binding
// CodeMirror has for a key the menu also owns wins and the menu never hears of
// it: undo would bypass Swift, and ⌘[ / ⌘] would indent instead of going Back
// and Forward, ⌘/ would comment a line instead of showing the shortcuts. Those
// stay out. `keys` is a compartment only so the spike can put historyKeymap
// back and measure what that does.
const menuKeys = new Set(['Mod-[', 'Mod-]', 'Mod-/'])
const keys = new Compartment()
const baseKeys = keymap.of([
  // ⌘S is saved through the bridge, not left to the menu: `save` is posted
  // after the `changes` of every key typed before it, so Swift saves a mirror
  // that has caught up. Eaten, so the menu cannot save (or refuse to save) a
  // second time.
  { key: 'Mod-s', run: () => { post('save'); return true } },
  ...defaultKeymap.filter((binding) => !menuKeys.has(binding.key)),
  indentWithTab,
])

// In a CRLF document CodeMirror splits only on `\r\n`, so a pasted or dispatched
// lone `\n` or `\r` would sit inside a line as a literal character. The mirror
// could not tell it from a line break (`Text.toString()` joins lines with `\n`
// too) and saving would write a file with mixed endings. Every break that comes
// in becomes a real line break instead; each is one position either way, so
// selections stay valid.
const normaliseBreaks = new Compartment()
const breakFilter = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || tr.startState.lineBreak !== '\r\n') return tr
  let literal = false
  tr.changes.iterChanges((_fA, _tA, _fB, _tB, inserted) => {
    if (literal) return
    for (const line of inserted.iterLines()) if (/[\r\n]/.test(line)) { literal = true; break }
  })
  if (!literal) return tr
  const changes = []
  tr.changes.iterChanges((fromA, toA, _fB, _tB, inserted) => {
    const flat = inserted.sliceString(0, inserted.length, '\n')
    changes.push({ from: fromA, to: toA, insert: Text.of(flat.split(/\r\n|\r|\n/)) })
  })
  return {
    changes,
    selection: tr.selection,
    effects: tr.effects,
    scrollIntoView: tr.scrollIntoView,
    userEvent: tr.annotation(Transaction.userEvent),
  }
})

const noHistory = { canUndo: false, canRedo: false }
let reported = noHistory

function reportHistory(state) {
  const next = { canUndo: undoDepth(state) > 0, canRedo: redoDepth(state) > 0 }
  if (next.canUndo !== reported.canUndo || next.canRedo !== reported.canRedo) {
    reported = next
    post('history', next)
  }
}

const mirror = EditorView.updateListener.of((update) => {
  if (update.docChanged) {
    for (const tr of update.transactions) {
      if (!tr.docChanged) continue
      const changes = []
      tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
        changes.push([fromA, toA, inserted.toString()])
      })
      seq += 1
      post('changes', { seq, length: tr.newDoc.length, changes })
    }
  }
  if (update.transactions.length) reportHistory(update.state)
})

// --- Find (§3.4). The app's own find bar drives this, the same bar the preview
// uses, so CodeMirror's search panel never opens. Its highlighter only paints
// while that panel is open, which is why the matches are decorated here: a plain,
// case-insensitive search for the literal text, counted the way the preview
// counts, with the current match marked apart from the rest.

let findQuery = null
let findMatches = []
let findIndex = -1
const findChanged = StateEffect.define()
const matchMark = Decoration.mark({ class: 'cm-imark-match' })
const currentMark = Decoration.mark({ class: 'cm-imark-match cm-imark-match-current' })

/// A document with tens of thousands of hits is not one anybody steps through;
/// past this the count stops, rather than the page.
const maxMatches = 10000

function collectMatches(state) {
  findMatches = []
  if (!findQuery) return
  const cursor = findQuery.getCursor(state)
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    findMatches.push({ from: next.value.from, to: next.value.to })
    if (findMatches.length >= maxMatches) break
  }
}

function reportFind() {
  post('find', { count: findMatches.length, index: findMatches.length ? findIndex + 1 : 0 })
}

const findHighlighter = ViewPlugin.fromClass(
  class {
    constructor() { this.decorations = Decoration.none }
    update(update) {
      const asked = update.transactions.some((tr) => tr.effects.some((e) => e.is(findChanged)))
      if (findQuery && update.docChanged) {
        // The text moved under the matches: count again, and keep the current
        // one as close to where it was as the new list allows.
        const was = findMatches[findIndex]?.from ?? 0
        collectMatches(update.state)
        const at = update.changes.mapPos(was)
        findIndex = findMatches.length ? Math.max(0, findMatches.findIndex((m) => m.from >= at)) : -1
        if (findIndex < 0 && findMatches.length) findIndex = 0
        reportFind()
      } else if (!asked) {
        return
      }
      this.decorations = Decoration.set(
        findMatches.map((m, i) => (i === findIndex ? currentMark : matchMark).range(m.from, m.to))
      )
    }
  },
  { decorations: (v) => v.decorations }
)

function showCurrentMatch(select) {
  const match = findMatches[findIndex]
  const effects = [findChanged.of(null)]
  if (match) effects.push(EditorView.scrollIntoView(match.from, { y: 'center' }))
  view.dispatch({
    effects,
    // Selecting the match is what makes Return in the find bar and then a click
    // back into the text carry on from it, as in any editor.
    selection: select && match ? { anchor: match.from, head: match.to } : undefined,
  })
}

function find(text) {
  const query = new SearchQuery({ search: text ?? '', caseSensitive: false, literal: true })
  findQuery = query.valid ? query : null
  collectMatches(view.state)
  // From the caret onwards, the way the find bar reads: the first match after
  // where you are, not the first one in the document.
  const head = view.state.selection.main.from
  findIndex = findMatches.length ? Math.max(0, findMatches.findIndex((m) => m.from >= head)) : -1
  showCurrentMatch(false)
  reportFind()
}

function findStep(delta) {
  if (!findMatches.length) return reportFind()
  findIndex = (findIndex + delta + findMatches.length) % findMatches.length
  showCurrentMatch(true)
  reportFind()
}

function findClear() {
  findQuery = null
  findMatches = []
  findIndex = -1
  view.dispatch({ effects: findChanged.of(null) })
}

// --- The Live Preview (live.js, inline.js). In a compartment so the harness can
// switch it off: off is the M1 look, the Markdown source highlighted in full,
// which is also what the default highlight style gives the marks the Live
// Preview hides and restyles itself.
const livePreviewOn = livePreview({ openLink: (target) => post('openLink', target) })
const sourceLook = syntaxHighlighting(defaultHighlightStyle, { fallback: true })
const liveLook = new Compartment()

function extensions(lineSeparator) {
  const list = [
    highlightSpecialChars(),
    history(),
    drawSelection(),
    highlightActiveLine(),
    markdown({ base: markdownLanguage, extensions: inlineExtensions }),
    findHighlighter,
    keys.of(baseKeys),
    normaliseBreaks.of(breakFilter),
    liveLook.of(livePreviewOn),
    EditorView.lineWrapping,
    EditorView.contentAttributes.of({
      spellcheck: 'false',
      autocorrect: 'off',
      autocapitalize: 'off',
    }),
    mirror,
  ]
  if (lineSeparator === '\r\n') list.push(EditorState.lineSeparator.of('\r\n'))
  return list
}

const view = new EditorView({
  state: EditorState.create({ doc: '', extensions: extensions('\n') }),
  parent: document.getElementById('editor'),
})

// WebKit keeps its own undo stack for the contenteditable. CodeMirror's history
// is the only one that may act, so a native undo/redo (from WebKit's own ⌘Z
// handling, the Edit menu's `undo:` reaching the web view, or a gesture) is
// cancelled here. The harness can count them, and switch the guard off to see
// what would happen without it; nothing else can.
document.addEventListener(
  'beforeinput',
  (event) => {
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      if (hooksEnabled) {
        spike.nativeHistory.push(event.inputType)
        if (!spike.guardNativeHistory) return
      }
      event.preventDefault()
    }
  },
  true
)

// --- Appearance, from the same settings the preview reads. The colours,
// sizes and widths are the preview's own tokens (tokens.css), switched by the
// same attributes the preview sets on its root.

function setTheme(theme) {
  if (!theme) return
  document.documentElement.dataset.theme = theme
  // A diagram is drawn in the palette it was made for; the widgets that depend
  // on the page's colours are made again.
  view.dispatch({ effects: restyle.of(null) })
}

/// Where the document is, so an image next to it is found; the widgets that
/// point at files are made again.
function setPath(path) {
  setDocumentPath(path)
  view.dispatch({ effects: restyle.of(null) })
}

/// The preview's View ▸ Front Matter switch, as the attribute its stylesheet
/// reads. The card is only hidden, never taken out of the document.
function setFrontMatter(shown) {
  document.documentElement.dataset.frontMatter = shown === false ? 'hidden' : 'shown'
  view.requestMeasure()
}

function setTextScale(scale) {
  if (typeof scale === 'number' && scale > 0) {
    document.documentElement.style.setProperty('--size-body', `${scale}px`)
    // Lines change height, and CodeMirror caches every measurement it made.
    view.requestMeasure()
  }
}

function setWidth(width) {
  if (width) document.documentElement.dataset.width = width
  view.requestMeasure()
}

function load(args) {
  generation = args.generation
  seq = 0
  setLanguage(args.language)
  setDocumentPath(args.path)
  setFrontMatter(args.frontMatter)
  setTheme(args.theme)
  setTextScale(args.textScale)
  setWidth(args.width)
  const lineSeparator = args.lineSeparator === '\r\n' ? '\r\n' : '\n'
  // `text` arrives with its original line breaks. With the CRLF facet set,
  // CodeMirror splits only on `\r\n`; a `\n`-joined text would be one line.
  view.setState(EditorState.create({ doc: args.text, extensions: extensions(lineSeparator) }))
  // A new document starts with nothing found in it, whatever the last one had.
  findQuery = null
  findMatches = []
  findIndex = -1
  reported = noHistory
  post('history', reported)
}

/// The saved baseline lives in Swift, which is what answers "is anything
/// unsaved". Kept here too for the gutter of changed lines that M4 adds.
let savedDoc = null
function markSaved() {
  savedDoc = view.state.doc
}

function resync() {
  post('fullText', { seq, text: view.state.doc.toString() })
}

function undo() {
  if (hooksEnabled) spike.calls.push('undo')
  cmUndo(view)
}

function redo() {
  if (hooksEnabled) spike.calls.push('redo')
  cmRedo(view)
}

function focus() {
  view.focus()
}

// What the harness pokes at. Not part of the protocol, and only on the page
// when the harness asked for it.
const spike = {
  outbox: [],
  calls: [],
  nativeHistory: [],
  /// Off only to show what WebKit's undo would do without the guard.
  guardNativeHistory: true,
  get view() { return view },
  get seq() { return seq },
  get generation() { return generation },
  get savedDoc() { return savedDoc },
  setHistoryKeymap(on) {
    view.dispatch({ effects: keys.reconfigure(on ? [keymap.of(historyKeymap), baseKeys] : baseKeys) })
  },
  setBreakFilter(on) {
    view.dispatch({ effects: normaliseBreaks.reconfigure(on ? breakFilter : []) })
  },
  setDecorations(on) {
    view.dispatch({ effects: liveLook.reconfigure(on ? livePreviewOn : sourceLook) })
  },
  /// The true document text, as it would be saved.
  slice() { return view.state.sliceDoc() },
}

window.imarkEditor = {
  load,
  markSaved,
  resync,
  undo,
  redo,
  focus,
  find,
  findStep,
  findClear,
  setTheme,
  setPath,
  setFrontMatter,
  setTextScale,
  setWidth,
  setLanguage,
}
if (hooksEnabled) window.imarkEditor.__spike = spike

post('ready')
