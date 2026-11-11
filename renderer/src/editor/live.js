// The Live Preview: which Markdown marks to hide, and which text to style, for
// the part of the document on screen (docs/LIVE-PREVIEW.md §4, M2).
//
// Display only. Every decoration here is a replace, a mark or a line class, so
// the document, the selection and the mirror in Swift never see any of it — the
// invariant in §1 is that saving what was opened gives back the same bytes, and
// nothing in this file can break it.
//
// Two halves. `liveDecorations(state, ranges)` is pure: it reads the syntax tree
// and the selection and returns plain data, so node can test it without a DOM.
// The ViewPlugin below turns that data into Decorations and decides when to
// recompute.
//
// The block widgets of M3 — task boxes, comment cards, and the rest to come —
// live in blocks.js and come in through `livePreview()`. Two of them do edit,
// and each says so where it does: always as a transaction on the buffer.

import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view'
import { syntaxTree } from '@codemirror/language'
import MarkdownIt from 'markdown-it'
import { blockRanges, frontMatterEnd, liveBlocks } from './blocks.js'
// Each registers its kind of block with blocks.js as it loads.
import './tasks.js'
import './note-card.js'

export { frontMatterEnd }

// markdown-it's own unescaping of a link destination (backslash escapes and
// HTML entities), so the editor opens what the preview would.
const { unescapeAll, normalizeReference } = new MarkdownIt('zero').utils

// The Obsidian rule: a construct shows its source while any part of the
// selection touches it. Inclusive at both ends, so a caret just before or just
// after is "adjacent" — typing at the edge of `**bold**` must not make the
// marks vanish under the cursor.
const touches = (selection, from, to) =>
  selection.ranges.some((range) => range.from <= to && range.to >= from)

const emphasis = {
  Emphasis: { class: 'cm-live-em', mark: 'EmphasisMark' },
  StrongEmphasis: { class: 'cm-live-strong', mark: 'EmphasisMark' },
  Strikethrough: { class: 'cm-live-strike', mark: 'StrikethroughMark' },
  Highlight: { class: 'cm-live-mark', mark: 'HighlightMark' },
}

const scheme = /^[a-z][a-z0-9+.-]*:/i

// Link reference definitions of the document, by normalised label. Found once
// per syntax tree, and only when a reference link asks.
const definitions = new WeakMap()
function definitionsOf(state) {
  const tree = syntaxTree(state)
  let found = definitions.get(tree)
  if (found) return found
  found = new Map()
  const containers = new Set(['Document', 'Blockquote', 'BulletList', 'OrderedList', 'ListItem'])
  tree.iterate({
    enter(ref) {
      if (ref.name === 'LinkReference') {
        const label = ref.node.getChild('LinkLabel')
        const url = ref.node.getChild('URL')
        if (label && url) {
          const key = normalizeReference(state.sliceDoc(label.from + 1, label.to - 1))
          if (!found.has(key)) found.set(key, unescapeAll(state.sliceDoc(url.from, url.to).replace(/^<|>$/g, '')))
        }
        return false
      }
      return containers.has(ref.name)
    },
  })
  definitions.set(tree, found)
  return found
}

/// What a Link node points at, or null when it is not a link at all: an inline
/// destination as written (unescaped as markdown-it does), or a reference
/// resolved against the document's definitions the way CommonMark matches
/// labels — case-insensitive, whitespace collapsed. `[x][nope]` with no
/// definition is plain text, and so is a bare `[x]`.
function linkTarget(state, node) {
  const url = node.getChild('URL')
  if (url) return { href: unescapeAll(state.sliceDoc(url.from, url.to).replace(/^<|>$/g, '')) }
  const marks = node.getChildren('LinkMark')
  if (marks.length < 2) return null
  const label = node.getChild('LinkLabel')
  let key = label ? state.sliceDoc(label.from + 1, label.to - 1) : ''
  if (!key.trim()) key = state.sliceDoc(marks[0].to, marks[1].from) // `[x][]` and `[x]`
  const href = definitionsOf(state).get(normalizeReference(key))
  return href === undefined ? null : { href }
}

/// What to paint over `ranges` (normally `view.visibleRanges`), as plain data:
///
///   {from, to, kind: 'hide'}                  source that is not shown
///   {from, to, kind: 'bullet'}                a list marker, shown as a bullet
///   {from, to, kind: 'mark', class}           styling over text
///   {from, to, kind: 'line', class}           styling on a whole line (from == to == line start)
///
/// Sorted by position. Nothing is invented: every range is a stretch of the
/// document that is there.
export function liveDecorations(state, ranges) {
  const doc = state.doc
  const selection = state.selection
  const out = []
  const seen = new Set()

  const add = (from, to, kind, cls) => {
    const key = `${kind}:${from}:${to}:${cls ?? ''}`
    if (seen.has(key)) return // A node spanning two visible ranges is met twice.
    seen.add(key)
    out.push(cls ? { from, to, kind, class: cls } : { from, to, kind })
  }

  // A replace decoration cannot cross a line break when it comes from a plugin
  // (CodeMirror throws), and a mark split over two lines would leave half of it
  // on screen. Such a mark is left as source.
  const hide = (from, to) => {
    if (to <= from || doc.lineAt(from).to < to) return
    add(from, to, 'hide')
  }

  // Marks that are shown (the construct is touched) are dimmed, so they read as
  // syntax and not as prose.
  const reveal = (from, to) => {
    if (to > from) add(from, to, 'mark', 'cm-live-syntax')
  }

  const lineClass = (from, to, cls, range) => {
    let a = Math.max(from, range.from)
    let b = Math.min(to, range.to)
    if (a > b) return
    // A node that ends just past its last line break has not started that line.
    if (b > a && doc.lineAt(b).from === b) b -= 1
    let line = doc.lineAt(a)
    for (;;) {
      add(line.from, line.from, 'line', cls)
      if (line.to >= b || line.number >= doc.lines) break
      line = doc.line(line.number + 1)
    }
  }

  const spaceAfter = (pos) => {
    const next = doc.sliceString(pos, pos + 1)
    return next === ' ' || next === '\t' ? pos + 1 : pos
  }

  const tree = syntaxTree(state)
  const frontMatter = frontMatterEnd(state)

  for (const range of ranges) {
    if (frontMatter) lineClass(0, frontMatter, 'cm-live-frontmatter', range)
    tree.iterate({
      from: range.from,
      to: range.to,
      enter: (ref) => {
        const name = ref.name
        const from = ref.from
        const to = ref.to

        let level = /^ATXHeading([1-6])$/.exec(name)
        if (level) {
          lineClass(from, to, `cm-live-h${level[1]}`, range)
          const touched = touches(selection, from, to)
          let opening = true
          let floor = from
          for (let child = ref.node.firstChild; child; child = child.nextSibling) {
            if (child.name !== 'HeaderMark') continue
            if (touched) reveal(child.from, child.to)
            else if (opening) {
              floor = spaceAfter(child.to)
              hide(child.from, floor)
            } else {
              // A closing run of #s, with the spaces that lead up to it — but
              // not into what the opening mark already hid (`# #`).
              let start = child.from
              while (start > floor && /[ \t]/.test(doc.sliceString(start - 1, start))) start -= 1
              hide(start, child.to)
            }
            opening = false
          }
          return
        }

        level = /^SetextHeading([12])$/.exec(name)
        if (level) {
          // The text lines get the heading's look; the underline is left as
          // source, and so is its `---`/`===`.
          const underline = ref.node.lastChild
          if (underline?.name === 'HeaderMark' && underline.from > from) {
            lineClass(from, underline.from - 1, `cm-live-h${level[1]}`, range)
          }
          return
        }

        const style = emphasis[name]
        if (style) {
          add(from, to, 'mark', style.class)
          const touched = touches(selection, from, to)
          for (let child = ref.node.firstChild; child; child = child.nextSibling) {
            if (child.name !== style.mark) continue
            if (touched) reveal(child.from, child.to)
            else hide(child.from, child.to)
          }
          return
        }

        switch (name) {
          case 'InlineCode': {
            add(from, to, 'mark', 'cm-live-code')
            const touched = touches(selection, from, to)
            for (let child = ref.node.firstChild; child; child = child.nextSibling) {
              if (child.name !== 'CodeMark') continue
              if (touched) reveal(child.from, child.to)
              else hide(child.from, child.to)
            }
            return false
          }

          case 'Link': {
            const node = ref.node
            // `[x]` alone, and `[x][nope]`, are Links to Lezer whether or not
            // anything defines them; only one that goes somewhere is a link.
            const target = linkTarget(state, node)
            const marks = []
            for (let child = node.firstChild; child; child = child.nextSibling) {
              if (child.name === 'LinkMark') marks.push(child)
            }
            const open = marks[0]
            const close = marks[1]
            if (!target || !open || !close || close.from <= open.to) return
            add(open.to, close.from, 'mark', 'cm-live-link')
            if (touches(selection, from, to)) {
              reveal(open.from, open.to)
              reveal(close.from, to)
            } else {
              hide(open.from, open.to)
              hide(close.from, to)
            }
            return // The text may hold emphasis, code, and so on.
          }

          // An image stays source in M2, and the `[` inside `![` is not a link.
          case 'Image':
            add(from, to, 'mark', 'cm-live-dim')
            return false

          // Left as source in M2, but dimmed or coloured so they do not read as
          // prose: the default highlight style that used to do this is off in
          // Live mode. Classes rather than a HighlightStyle, so they are data
          // here too and need no direct dependency on @lezer/highlight.
          case 'Autolink':
            add(from, to, 'mark', 'cm-live-link')
            return false

          case 'URL':
            // Under a Link, Image or Autolink it is part of that; on its own it
            // is a bare URL that the preview's linkify makes a link.
            if (!['Link', 'Image', 'Autolink'].includes(ref.node.parent?.name)) {
              add(from, to, 'mark', 'cm-live-link')
            }
            return false

          // A task marker and an imark comment block are drawn as widgets
          // (blocks.js); this is how they look while their source shows.
          case 'HTMLBlock':
          case 'HTMLTag':
          case 'CommentBlock':
          case 'Comment':
          case 'ProcessingInstructionBlock':
          case 'ProcessingInstruction':
          case 'LinkReference':
          case 'TaskMarker':
          case 'TableDelimiter':
            add(from, to, 'mark', 'cm-live-dim')
            return false

          case 'Wikilink': {
            const touched = touches(selection, from, to)
            for (let child = ref.node.firstChild; child; child = child.nextSibling) {
              if (child.name === 'WikilinkLabel') add(child.from, child.to, 'mark', 'cm-live-wikilink')
              else if (touched) reveal(child.from, child.to)
              else hide(child.from, child.to)
            }
            return false
          }

          case 'Blockquote':
            lineClass(from, to, 'cm-live-quote', range)
            return

          // Met as a node of its own, not through the Blockquote: inside a
          // fenced code block the `>` of each line is a child of the fence.
          // Per line, not per quote — a caret in one line of a long quote
          // should not bring back every `>` in it.
          case 'QuoteMark': {
            const line = doc.lineAt(from)
            if (touches(selection, line.from, line.to)) reveal(from, to)
            else hide(from, spaceAfter(to))
            return false
          }

          case 'ListMark': {
            const item = ref.node.parent
            const list = item?.parent
            if (list?.name === 'OrderedList') {
              add(from, to, 'mark', 'cm-live-number')
            } else if (list?.name === 'BulletList') {
              // Beside a box the preview draws no bullet, so the `- ` goes;
              // it comes back with the box's source (tasks.js), the two being
              // one piece of syntax to whoever is editing it.
              const marker = item.getChild('Task')?.getChild('TaskMarker')
              if (touches(selection, from, marker ? marker.to : to)) reveal(from, to)
              else if (marker) hide(from, spaceAfter(to))
              else add(from, to, 'bullet')
            }
            return false
          }

          case 'HorizontalRule':
            if (!touches(selection, from, to)) lineClass(from, to, 'cm-live-hr', range)
            return false

          case 'FencedCode':
          case 'CodeBlock': {
            // Monospace on a tinted ground, the fences still showing. The
            // contents are never touched: not hidden, not restyled per token.
            lineClass(from, to, 'cm-live-codeline', range)
            if (name === 'FencedCode') {
              if (from >= range.from) add(doc.lineAt(from).from, doc.lineAt(from).from, 'line', 'cm-live-codeline-first')
              if (to <= range.to) add(doc.lineAt(to).from, doc.lineAt(to).from, 'line', 'cm-live-codeline-last')
            }
            // Not `return false`: inside a quote, each line's `>` is a child of
            // the fence, and still has to be hidden.
            return
          }
        }
      },
    })
  }

  // Nothing inside front matter is Markdown; whatever Lezer made of it (a rule,
  // a setext heading) is dropped, and the block is left as plain monospace.
  const kept = frontMatter ? out.filter((i) => i.from >= frontMatter || i.class === 'cm-live-frontmatter') : out
  kept.sort((a, b) => a.from - b.from || a.to - b.to)

  // Nor is anything under a block widget that is drawn (blocks.js): it is not
  // on screen, and a hidden stretch inside a replaced block is two replaces
  // over the same text. Both lists are sorted, and the blocks never overlap.
  const drawn = blockRanges(state).filter((b) => b.block && !b.revealed)
  if (!drawn.length) return kept
  let next = 0
  return kept.filter((item) => {
    while (next < drawn.length && drawn[next].to < item.from) next += 1
    const block = drawn[next]
    return !(block && item.from >= block.from && item.to <= block.to)
  })
}

/// Where a ⌘-click at `pos` should go, or null: `{href}` for a link, an autolink
/// or a bare URL, `{wiki}` for a wikilink. Reads the same tree the decorations
/// do, so a link that is hidden is as clickable as one that is not.
///
/// `side` is which of the two characters around `pos` was hit (CodeMirror's
/// `assoc`: -1 the one before, 1 the one after). Only that side is looked at: at
/// the edge between `[a](u)` and `xyz` the hidden syntax has no width, and a
/// click on the `x` must not open `u`.
export function linkAt(state, pos, side) {
  for (let node = syntaxTree(state).resolveInner(pos, side); node; node = node.parent) {
    switch (node.name) {
      case 'Image':
        return null
      case 'Wikilink': {
        // Whatever precedes the first `|` is the target, labelled or not.
        const target = state.sliceDoc(node.from + 2, node.to - 2).split('|')[0].trim()
        return target ? { wiki: target } : null
      }
      case 'Link': {
        const target = linkTarget(state, node)
        return target?.href ? target : null
      }
      case 'Autolink': {
        const url = node.getChild('URL')
        if (!url) return null
        const href = state.sliceDoc(url.from, url.to).replace(/^<|>$/g, '')
        // `<a@b.co>` is an address, not a path.
        return { href: !scheme.test(href) && href.includes('@') ? `mailto:${href}` : href }
      }
      case 'URL': {
        // A bare URL: the preview's linkify makes these links, `www.` ones
        // with the scheme markdown-it-linkify gives them.
        const kind = node.parent?.name
        if (kind === 'Link' || kind === 'Image' || kind === 'Autolink') break
        const text = state.sliceDoc(node.from, node.to)
        return { href: /^www\./i.test(text) ? `http://${text}` : text }
      }
    }
  }
  return null
}

class BulletWidget extends WidgetType {
  eq() { return true }
  toDOM() {
    const span = document.createElement('span')
    span.className = 'cm-live-bullet'
    span.textContent = '•'
    return span
  }
}

const bullet = Decoration.replace({ widget: new BulletWidget() })
const hidden = Decoration.replace({})
const marks = new Map()
const markFor = (cls) => {
  let deco = marks.get(cls)
  if (!deco) marks.set(cls, (deco = Decoration.mark({ class: cls })))
  return deco
}
const lines = new Map()
const lineFor = (cls) => {
  let deco = lines.get(cls)
  if (!deco) lines.set(cls, (deco = Decoration.line({ class: cls })))
  return deco
}

function build(view) {
  const items = liveDecorations(view.state, view.visibleRanges)
  return Decoration.set(
    items.map((item) => {
      switch (item.kind) {
        case 'hide': return hidden.range(item.from, item.to)
        case 'bullet': return bullet.range(item.from, item.to)
        case 'line': return lineFor(item.class).range(item.from)
        default: return markFor(item.class).range(item.from, item.to)
      }
    }),
    true
  )
}

const live = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = build(view)
      // Held from the start of a composition until a moment after it ends. A
      // rebuild in the transaction that commits the composition would hide or
      // show marks right beside text the input method has only just let go of;
      // the rebuild waits for the empty transaction the timer dispatches.
      this.holding = false
      this.behind = false
      this.timer = 0
    }

    update(update) {
      const view = update.view
      // Hiding or showing marks beside text being composed re-renders that
      // line under the input method, which loses the candidate window or
      // duplicates characters (§5). The old decorations are kept, moved with
      // the edit, until the composition is committed.
      if (view.compositionStarted || this.holding) {
        if (update.docChanged) this.decorations = this.decorations.map(update.changes)
        this.behind = true
        return
      }
      if (
        this.behind ||
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged ||
        syntaxTree(update.state) !== syntaxTree(update.startState)
      ) {
        this.behind = false
        this.decorations = build(view)
      }
    }

    destroy() {
      clearTimeout(this.timer)
    }
  },
  {
    decorations: (plugin) => plugin.decorations,
    eventHandlers: {
      compositionstart() {
        // A second composition inside the grace period of the first keeps the
        // hold: the timer of the first must not release it.
        this.holding = true
        clearTimeout(this.timer)
      },
      compositionend(_event, view) {
        clearTimeout(this.timer)
        this.timer = setTimeout(() => {
          this.holding = false
          if (view.dom.isConnected && !view.compositionStarted) view.dispatch({})
        }, 50)
      },
    },
  }
)

/// The Live Preview as an extension. `openLink({href} | {wiki})` is called for a
/// ⌘-click on a link; a plain click only places the caret.
export function livePreview({ openLink }) {
  return [
    liveBlocks(),
    live,
    EditorView.domEventHandlers({
      mousedown(event, view) {
        // ⌘ is also CodeMirror's "add a cursor"; on a link it means "follow".
        // A double or triple click is selecting a word or a line, not following.
        if (!event.metaKey || event.button !== 0 || event.detail > 1) return false
        const hit = view.posAndSideAtCoords({ x: event.clientX, y: event.clientY })
        const target = hit ? linkAt(view.state, hit.pos, hit.assoc) : null
        if (!target) return false
        event.preventDefault()
        openLink(target)
        return true
      },
    }),
  ]
}
