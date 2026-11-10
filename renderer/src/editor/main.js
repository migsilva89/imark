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

import { EditorState, Compartment, Text, Transaction } from '@codemirror/state'
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
import { syntaxHighlighting, defaultHighlightStyle, syntaxTree } from '@codemirror/language'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { search } from '@codemirror/search'
import './editor.css'

const handler = () => window.webkit?.messageHandlers?.imarkEditor

let generation = 0
let seq = 0

function post(type, payload = {}) {
  const message = { type, generation, ...payload }
  const h = handler()
  if (h) h.postMessage(message)
  else spike.outbox.push(message) // Outside the app (a plain browser, node): keep for inspection.
}

// ⌘Z, ⇧⌘Z and ⌘F belong to the app's menu, which calls `undo()` / `redo()` /
// `find()` here. CodeMirror's own bindings for them would fire a second time,
// so historyKeymap and searchKeymap stay out. `keys` is a compartment only so the
// spike can put historyKeymap back and measure what that does.
const keys = new Compartment()
const baseKeys = keymap.of([...defaultKeymap, indentWithTab])

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

// --- Spike-only: a decoration that changes with the caret, so IME can be
// tried with marks appearing and disappearing around the composition. Off
// unless the harness turns it on. Not the M2 implementation.
const spikeDecorations = new Compartment()
const caretMarks = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = this.build(view) }
    update(u) { if (u.docChanged || u.selectionSet) this.decorations = this.build(u.view) }
    build(view) {
      const head = view.state.selection.main.head
      const ranges = []
      syntaxTree(view.state).iterate({
        enter(node) {
          if (node.name !== 'EmphasisMark' && node.name !== 'HeaderMark') return
          // Shown while the caret is inside the construct the mark belongs to.
          const owner = node.node.parent
          if (owner && head >= owner.from && head <= owner.to) return
          ranges.push(Decoration.replace({}).range(node.from, node.to))
        },
      })
      return Decoration.set(ranges, true)
    }
  },
  { decorations: (v) => v.decorations }
)

function extensions(lineSeparator) {
  const list = [
    highlightSpecialChars(),
    history(),
    drawSelection(),
    highlightActiveLine(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    markdown({ base: markdownLanguage }),
    search(),
    keys.of(baseKeys),
    normaliseBreaks.of(breakFilter),
    spikeDecorations.of([]),
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
// cancelled here and counted, so the spike can see whether one ever arrives.
document.addEventListener(
  'beforeinput',
  (event) => {
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      spike.nativeHistory.push(event.inputType)
      if (!spike.guardNativeHistory) return
      event.preventDefault()
    }
  },
  true
)

function load(args) {
  generation = args.generation
  seq = 0
  const lineSeparator = args.lineSeparator === '\r\n' ? '\r\n' : '\n'
  // `text` arrives with its original line breaks. With the CRLF facet set,
  // CodeMirror splits only on `\r\n`; a `\n`-joined text would be one line.
  view.setState(EditorState.create({ doc: args.text, extensions: extensions(lineSeparator) }))
  reported = noHistory
  post('history', reported)
}

function resync() {
  post('fullText', { seq, text: view.state.doc.toString() })
}

function undo() {
  spike.calls.push('undo')
  cmUndo(view)
}

function redo() {
  spike.calls.push('redo')
  cmRedo(view)
}

function focus() {
  view.focus()
}

// What the harness pokes at. Not part of the protocol.
const spike = {
  outbox: [],
  calls: [],
  nativeHistory: [],
  /// Off only to show what WebKit's undo would do without the guard.
  guardNativeHistory: true,
  get view() { return view },
  get seq() { return seq },
  setHistoryKeymap(on) {
    view.dispatch({ effects: keys.reconfigure(on ? [keymap.of(historyKeymap), baseKeys] : baseKeys) })
  },
  setBreakFilter(on) {
    view.dispatch({ effects: normaliseBreaks.reconfigure(on ? breakFilter : []) })
  },
  setDecorations(on) {
    view.dispatch({ effects: spikeDecorations.reconfigure(on ? caretMarks : []) })
  },
  /// The true document text, as it would be saved.
  slice() { return view.state.sliceDoc() },
}

window.imarkEditor = { load, resync, undo, redo, focus, __spike: spike }

post('ready')
