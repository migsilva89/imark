// Formulas in the Live Preview (docs/LIVE-PREVIEW.md §4, M3): `$$…$$` standing
// on lines of its own is drawn as a block, `$…$` inside a sentence as a piece of
// the line. Both go through the preview's markdown-it and so through math.js and
// KaTeX; a formula KaTeX cannot read comes out as the red message the preview
// shows (`throwOnError: false`), never as an exception here.
//
// The inline form is a node of the tree (inline.js, `InlineMath`) parsed by the
// delimiter rules of the plugin math.js loads. The display form is found here by
// the plugin's block rule, line by line, because Lezer reads the inside of a
// multi-line formula as whatever Markdown it happens to look like — a `- ` line
// is a list, a `#` line a heading.

import { syntaxTree } from '@codemirror/language'
import { frontMatterEnd, registerBlock } from './blocks.js'
import { RenderedBlock } from './rendered.js'

// Blocks that own their lines: a `$$` inside one of these is theirs, not a
// formula (the plugin's rule runs inside lists and quotes too, but cut out of
// them its lines would not be the ones the preview shows).
const OWNERS = /^(Blockquote|ListItem|BulletList|OrderedList|FencedCode|CodeBlock|HTMLBlock|CommentBlock|ProcessingInstructionBlock|Table|SetextHeading[12]|ATXHeading[1-6]|LinkReference)$/

function atTopLevel(tree, pos) {
  for (let node = tree.resolveInner(pos, 1); node; node = node.parent) {
    if (OWNERS.test(node.name)) return false
  }
  return true
}

// The columns of leading whitespace; four or more is a code block, not a formula.
function indentOf(text) {
  let columns = 0
  for (const ch of text) {
    if (ch === ' ') columns += 1
    else if (ch === '\t') columns += 4 - (columns % 4)
    else break
  }
  return columns
}

/// The display formulas of `state`, as `[from, to]` line ranges: the plugin's
/// `blockMath`, ported rule for rule.
///
///   - a line that starts, after its indentation, with `$$`;
///   - `$$x$$` on that one line is the whole formula; a second `$$` on it means
///     the line is a sentence with formulas in it (inline), and a single one not
///     at the end means the formula goes on;
///   - otherwise the formula runs to the first line that ends with `$$` or has
///     one anywhere.
///
/// One difference, deliberately: the plugin lets a `$$` that never closes run to
/// the end of the document. Drawn that way, typing the first `$$` of a formula
/// would swallow everything below it into a red message, so here it is left as
/// the text it is until it is closed.
export function displayMath(state) {
  const doc = state.doc
  const tree = syntaxTree(state)
  const front = frontMatterEnd(state)
  const found = []
  for (let n = front ? doc.lineAt(front).number + 1 : 1; n <= doc.lines; n++) {
    const line = doc.line(n)
    const text = line.text
    const lead = /^[ \t]*/.exec(text)[0]
    if (!text.startsWith('$$', lead.length) || indentOf(lead) >= 4) continue
    if (text.length - lead.length < 2) continue

    let firstLine = text.slice(lead.length + 2)
    const ends = [...firstLine.matchAll(/\$\$/g)]
    let done = false
    if (ends.length === 1 && ends[0].index === firstLine.length - 2) done = true
    else if (ends.length > 1) continue

    let last = n
    for (let next = n + 1; !done && next <= doc.lines; next++) {
      const body = doc.line(next).text.trim()
      if (body.slice(-2) === '$$' || body.includes('$$')) {
        done = true
        last = next
      }
    }
    if (!done || !atTopLevel(tree, line.from + lead.length)) continue
    found.push({ from: line.from, to: doc.line(last).to })
    n = last
  }
  return found
}

class DisplayMathWidget extends RenderedBlock {
  get kind() {
    return 'cm-live-math'
  }

  get bare() {
    return true
  }

  get estimatedHeight() {
    return this.source.split('\n').length * 28 + 24
  }
}

registerBlock({
  type: 'math',
  scan: (state) => displayMath(state),
  widget: (data, info) => new DisplayMathWidget(info.source, data),
})

// The inline form: the preview's `<span class="katex">` and nothing around it.
class InlineMathWidget extends RenderedBlock {
  get kind() {
    return 'cm-live-math-inline'
  }

  get bare() {
    return true
  }

  render(view) {
    const dom = super.render(view)
    // markdown-it wraps what it is given in a paragraph, which has no business
    // inside a line of text.
    const paragraph = dom.firstElementChild
    const span = document.createElement('span')
    span.className = 'cm-live-md cm-live-math-inline'
    if (paragraph?.tagName === 'P') span.append(...paragraph.childNodes)
    else span.textContent = this.source
    return span
  }
}

registerBlock({
  type: 'math-inline',
  nodes: ['InlineMath'],
  block: false,
  reveal: 'range',
  match: (node) => ({ from: node.from, to: node.to }),
  widget: (data, info) => new InlineMathWidget(info.source, data),
})
