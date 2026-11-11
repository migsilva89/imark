// Four inline constructs the preview renders that Lezer's GFM does not know:
// `==mark==` (markdown-it-mark), `[[target]]` / `[[target|label]]`
// (src/wikilink.js), `$math$` (math.js, through @vscode/markdown-it-katex) and
// `[^1]` footnote references (markdown-it-footnote). The Live editor can only
// hide and style what the tree names, so each gets a node here, parsed by the
// same rules as its preview plugin — otherwise a construct would be styled in
// one view and plain text in the other (docs/LIVE-PREVIEW.md §4).
//
// Plain MarkdownConfig objects, nothing imported: node names are strings, so this
// file needs no direct dependency on @lezer/markdown.

const EQUALS = 61 // =
const OPEN_BRACKET = 91 // [
const DOLLAR = 36 // $
const CARET = 94 // ^

const punctuation = /[\p{P}\p{S}]/u

// Flanking, as markdown-it-mark (and Lezer's own strikethrough) decide it: `==`
// opens next to text and closes after text, so `a == b` is never a mark.
const highlight = {
  resolve: 'Highlight',
  mark: 'HighlightMark',
}

const Highlight = {
  defineNodes: ['Highlight', 'HighlightMark'],
  parseInline: [
    {
      name: 'Highlight',
      parse(cx, next, pos) {
        if (next !== EQUALS || cx.char(pos + 1) !== EQUALS || cx.char(pos + 2) === EQUALS) return -1
        const before = cx.slice(pos - 1, pos)
        const after = cx.slice(pos + 2, pos + 3)
        const spaceBefore = /\s|^$/.test(before)
        const spaceAfter = /\s|^$/.test(after)
        const puncBefore = punctuation.test(before)
        const puncAfter = punctuation.test(after)
        return cx.addDelimiter(
          highlight,
          pos,
          pos + 2,
          !spaceAfter && (!puncAfter || spaceBefore || puncBefore),
          !spaceBefore && (!puncBefore || spaceAfter || puncAfter)
        )
      },
      after: 'Emphasis',
    },
  ],
}

// `[[target]]` shows the target; `[[target|label]]` shows the label. The node
// is Wikilink, with WikilinkMark for the brackets (and `target|`, which is
// syntax too once there is a label) and WikilinkLabel for what is displayed.
// One line only and a non-empty target, as in the preview. Ahead of Link: both
// start at a `[`, and `[[a]](b)` is a wikilink first in the preview too.
const Wikilink = {
  defineNodes: ['Wikilink', 'WikilinkMark', 'WikilinkLabel'],
  parseInline: [
    {
      name: 'Wikilink',
      parse(cx, next, pos) {
        if (next !== OPEN_BRACKET || cx.char(pos + 1) !== OPEN_BRACKET) return -1
        // Looked for on this line only: a wikilink cannot span lines, and
        // slicing to the end of a long paragraph at every `[[` adds up.
        const newline = cx.text.indexOf('\n', pos + 2 - cx.offset)
        const rest = cx.slice(pos + 2, newline < 0 ? cx.end : cx.offset + newline)
        const close = rest.indexOf(']]')
        if (close <= 0) return -1
        const raw = rest.slice(0, close)
        if (raw.includes('\n')) return -1
        const pipe = raw.indexOf('|')
        const target = (pipe < 0 ? raw : raw.slice(0, pipe)).trim()
        if (!target) return -1

        const start = pos + 2
        // An empty label shows the target, like the preview, so `target|` is
        // syntax with the closing brackets and what is displayed is the target.
        const labelled = pipe >= 0 && raw.slice(pipe + 1).trim() !== ''
        const labelFrom = labelled ? start + pipe + 1 : start
        const labelTo = start + (labelled || pipe < 0 ? close : pipe)
        const end = start + close + 2
        return cx.addElement(
          cx.elt('Wikilink', pos, end, [
            cx.elt('WikilinkMark', pos, labelFrom),
            cx.elt('WikilinkLabel', labelFrom, labelTo),
            cx.elt('WikilinkMark', labelTo, end),
          ])
        )
      },
      before: 'Link',
    },
  ],
}

// `$x$`, by the rules of @vscode/markdown-it-katex's inline rules, which run
// ahead of the code-span rule — so `$a `b$` c` is math there and is here — and
// in the order the plugin registers them: `$$…$$` inside a sentence first, then
// a single `$`. The one deliberate difference is that a `$$…$$` is consumed and
// given no node: the preview draws it on a line of its own, and only the block
// (math-block.js) knows how to show that.
//
// A delimiter opens after the start, whitespace or a character that is not a
// letter, digit or underscore, and never after `\` or another `$`; it closes
// before the end, whitespace or such a character — which is why `$5 and $6`
// is two prices and not a formula. A `$` with an odd number of backslashes
// before it is escaped. Positions are read from the paragraph's own text, as
// markdown-it reads them: the character before the first `$` is whatever stands
// there, and past either end there is none.
const isSpace = (c) => /^\s$/u.test(c)
const isWord = (c) => /^[\w\d]$/u.test(c)

const InlineMath = {
  defineNodes: ['InlineMath'],
  parseInline: [
    {
      name: 'InlineMath',
      parse(cx, next, pos) {
        if (next !== DOLLAR) return -1
        const rest = cx.slice(pos, cx.end)
        const before = cx.slice(pos - 1, pos) || undefined
        // The character at `i` of `rest`, or before it for a negative `i`.
        const at = (i) => (i >= 0 ? rest[i] : i === -1 ? before : undefined)

        // Where an unescaped `needle` first stands after `from`, or -1.
        const closing = (needle, from, step) => {
          let match = from
          while ((match = rest.indexOf(needle, match)) !== -1) {
            let back = match - 1
            while (at(back) === '\\') back -= 1
            if ((match - back) % 2 === 1) return match
            match += step
          }
          return -1
        }

        if (rest.startsWith('$$')) {
          const prev = before
          const opens = prev !== '$' && prev !== '\\' && at(2) !== '$'
          if (!opens) return pos + 2
          const match = closing('$$', 2, 2)
          if (match === -1) return pos + 2
          if (match - 2 === 0) return pos + 4
          const p = at(match - 1)
          if (p === '$' || p === '\\' || at(match + 2) === '$') return pos + 2
          return pos + match + 2
        }

        const prev = before
        const opens = prev !== '$' && prev !== '\\' && (prev === undefined || isSpace(prev) || !isWord(prev))
        if (!opens) return -1
        const match = closing('$', 1, 1)
        if (match === -1) return -1
        const following = at(match + 1)
        const closes = following !== '$' && (following === undefined || isSpace(following) || !isWord(following))
        if (!closes) return -1
        return cx.addElement(cx.elt('InlineMath', pos, pos + match + 1))
      },
      before: 'Escape',
    },
  ],
}

// `[^label]`: a label with no space or line break in it, as markdown-it-footnote
// reads one. Whether the document defines it is not something the parser can
// know, so the node is made for the shape and footnote.js asks the document.
// Ahead of Link, which would take `[^1]` for a link to nothing.
const FootnoteRef = {
  defineNodes: ['FootnoteRef'],
  parseInline: [
    {
      name: 'FootnoteRef',
      parse(cx, next, pos) {
        if (next !== OPEN_BRACKET || cx.char(pos + 1) !== CARET) return -1
        const newline = cx.text.indexOf('\n', pos + 2 - cx.offset)
        const rest = cx.slice(pos + 2, newline < 0 ? cx.end : cx.offset + newline)
        const close = rest.indexOf(']')
        if (close <= 0 || rest.slice(0, close).includes(' ')) return -1
        // `[^1]:` at the start of a line is a definition (markdown-it-footnote's
        // block rule, which may start inside a paragraph), not a use of one.
        if (rest[close + 1] === ':') {
          const lineStart = cx.text.lastIndexOf('\n', pos - cx.offset - 1) + 1
          if (/^ {0,3}$/.test(cx.text.slice(lineStart, pos - cx.offset))) return -1
        }
        return cx.addElement(cx.elt('FootnoteRef', pos, pos + 2 + close + 1))
      },
      before: 'Link',
    },
  ],
}

export const inlineExtensions = [Highlight, Wikilink, InlineMath, FootnoteRef]
