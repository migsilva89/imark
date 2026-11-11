// Two inline constructs the preview renders that Lezer's GFM does not know:
// `==mark==` (markdown-it-mark) and `[[target]]` / `[[target|label]]`
// (src/wikilink.js). The Live editor can only hide and style what the tree
// names, so each gets a node here, parsed by the same rules as its preview
// plugin — otherwise a construct would be styled in one view and plain text in
// the other (docs/LIVE-PREVIEW.md §4).
//
// Plain MarkdownConfig objects, nothing imported: node names are strings, so this
// file needs no direct dependency on @lezer/markdown.
//
// `$math$` and `[^1]` footnote references are not here yet; they stay unstyled
// until M3 gives them widgets.

const EQUALS = 61 // =
const OPEN_BRACKET = 91 // [

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

export const inlineExtensions = [Highlight, Wikilink]
