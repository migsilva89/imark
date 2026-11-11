// Tests for the Live Preview's decisions (docs/LIVE-PREVIEW.md §4, M2): which
// Markdown marks are hidden and which text is styled, for a given document and
// selection. No DOM — `liveDecorations` reads an EditorState and returns data.
//
//   node Support/test-live-decorations.mjs
//
// The two things that matter most: a mark is hidden only when the selection is
// away from its construct (the Obsidian rule), and nothing here ever touches the
// document — decorations are display, and saving must give back the same bytes.

import { EditorState, EditorSelection } from '../renderer/node_modules/@codemirror/state/dist/index.js'
import { markdown, markdownLanguage } from '../renderer/node_modules/@codemirror/lang-markdown/dist/index.js'
import { ensureSyntaxTree } from '../renderer/node_modules/@codemirror/language/dist/index.js'
import { inlineExtensions } from '../renderer/src/editor/inline.js'
import * as Live from '../renderer/src/editor/live.js'

const { linkAt } = Live

let failures = 0
const check = (name, ok, detail = '') => {
  if (ok) console.log(`OK   ${name}`)
  else {
    failures += 1
    console.log(`FAIL ${name}  ${detail}`)
  }
}

/// A state with the editor's own language setup. `at` is a position, or an
/// array of them (several carets), or [from, to] pairs as {from, to} objects.
function stateFor(doc, at = 0, crlf = false) {
  // The editor's drawSelection() is what turns on several selections.
  const extensions = [
    markdown({ base: markdownLanguage, extensions: inlineExtensions }),
    EditorState.allowMultipleSelections.of(true),
  ]
  if (crlf) extensions.push(EditorState.lineSeparator.of('\r\n'))
  const ranges = [].concat(at).map((a) =>
    a === 'end' ? EditorSelection.cursor(doc.split('\r\n').join('\n').length) : typeof a === 'number' ? EditorSelection.cursor(a) : EditorSelection.range(a.from, a.to)
  )
  const state = EditorState.create({ doc, extensions, selection: EditorSelection.create(ranges) })
  // The editor parses in the background; here the whole tree is wanted up front.
  ensureSyntaxTree(state, state.doc.length, 5000)
  return state
}

/// The document with the caret parked on a line of its own after it, so nothing
/// in `doc` is touched.
const away = (doc, crlf = false) => stateFor(doc + (crlf ? '\r\n\r\nz' : '\n\nz'), 'end', crlf)

// Every call goes through here, so that no input in this file can produce two
// replaced stretches that overlap — CodeMirror throws on those.
let calls = 0
let overlaps = 0
const liveDecorations = (state, ranges) => {
  const items = Live.liveDecorations(state, ranges)
  calls += 1
  let end = -1
  for (const i of items.filter((x) => x.kind === 'hide' || x.kind === 'bullet')) {
    if (i.from < end) overlaps += 1
    end = Math.max(end, i.to)
  }
  return items
}

const decorate = (state) => liveDecorations(state, [{ from: 0, to: state.doc.length }])

/// The text of every hidden stretch, in order — what disappears from the screen.
const hidden = (state, items = decorate(state)) =>
  items.filter((i) => i.kind === 'hide').map((i) => state.sliceDoc(i.from, i.to))

const styled = (state, cls, items = decorate(state)) =>
  items.filter((i) => i.class === cls).map((i) => state.sliceDoc(i.from, i.to))

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

// Where a substring starts, so selections read as words and not as numbers. In
// CodeMirror's coordinates: a CRLF is one position there, two in a JS string.
const at = (doc, needle, nth = 0) => {
  let from = -1
  for (let i = 0; i <= nth; i++) from = doc.indexOf(needle, from + 1)
  if (from < 0) throw new Error(`no ${needle}`)
  return from - (doc.slice(0, from).match(/\r\n/g) || []).length
}

// --- Headings

{
  const doc = '# Title\n\nbody\n'
  check('heading: # and its space hide with the caret elsewhere', same(hidden(stateFor(doc, at(doc, 'body'))), ['# ']))
  check('heading: caret inside shows the source', same(hidden(stateFor(doc, 3)), []))
  check('heading: caret just before the # shows the source', same(hidden(stateFor(doc, 0)), []))
  check('heading: caret at the end of the line (adjacent) shows the source', same(hidden(stateFor(doc, 7)), []))
  check('heading: line class carries the level', same(styled(stateFor(doc, 10), 'cm-live-h1').length, 1))
  const h = '###### six\n\n#### four ####\n\nx'
  const s = stateFor(h, h.length - 1)
  check('heading: levels 6 and 4 are classed', styled(s, 'cm-live-h6').length === 1 && styled(s, 'cm-live-h4').length === 1)
  check('heading: a closing run of #s hides with the space before it', same(hidden(s), ['###### ', '#### ', ' ####']))
  const setext = 'Title\n=====\n\nx'
  const t = stateFor(setext, at(setext, 'x'))
  check('heading: setext stays as source', same(hidden(t), []))
  check('heading: setext text line still gets the level', styled(t, 'cm-live-h1').length === 1)
  check('heading: "#tag" without a space is not a heading', same(hidden(stateFor('#tag\n\nx', 6)), []))
}

// --- Emphasis, strong, strikethrough, mark, inline code

{
  const doc = 'a *em* b **strong** c ~~gone~~ d ==hot== e `code` f'
  const gone = away(doc)
  check('inline: all marks hide with the caret away', same(hidden(gone), ['*', '*', '**', '**', '~~', '~~', '==', '==', '`', '`']))
  check('inline: classes land on the whole construct',
    same(styled(gone, 'cm-live-em'), ['*em*']) && same(styled(gone, 'cm-live-strong'), ['**strong**']) &&
    same(styled(gone, 'cm-live-strike'), ['~~gone~~']) && same(styled(gone, 'cm-live-mark'), ['==hot==']) &&
    same(styled(gone, 'cm-live-code'), ['`code`']))

  const inEm = stateFor(doc, at(doc, 'em') + 1)
  check('inline: caret inside emphasis shows only its marks', same(hidden(inEm), ['**', '**', '~~', '~~', '==', '==', '`', '`']))
  const afterStrong = stateFor(doc, at(doc, '**strong**') + 10)
  check('inline: caret just after the closing ** (adjacent) shows them', !hidden(afterStrong).includes('**'))
  const beforeStrong = stateFor(doc, at(doc, '**strong**'))
  check('inline: caret just before the opening ** (adjacent) shows them', !hidden(beforeStrong).includes('**'))
  check('inline: a space away is not adjacent', hidden(stateFor(doc, at(doc, '**strong**') - 1)).includes('**'))
  check('inline: revealed marks are dimmed as syntax', styled(inEm, 'cm-live-syntax').join('|') === '*|*')

  const code = 'x `a**b**c` y'
  const c = stateFor(code, code.length)
  check('inline code: ** inside backticks is not hidden', same(hidden(c), ['`', '`']))
  const sel = stateFor(code, at(code, 'a**b') + 3)
  check('inline code: caret inside reveals the backticks', same(hidden(sel), []))
  check('inline: "a == b" is not a mark', same(hidden(stateFor('a == b ==', 9)), []))
}

// --- Links, images, wikilinks

{
  const doc = 'see [the *docs*](https://x.test/a "t") now'
  const gone = away(doc)
  check('link: brackets and (url) hide, text stays',
    same(hidden(gone), ['[', '*', '*', '](https://x.test/a "t")']) && same(styled(gone, 'cm-live-link'), ['the *docs*']))
  const inText = stateFor(doc, at(doc, 'the') + 1)
  check('link: caret in the text reveals the link syntax', same(hidden(inText), ['*', '*']))
  const inEm = stateFor(doc, at(doc, 'docs') + 1)
  check('link: nested emphasis — caret in it reveals both', same(hidden(inEm), []))
  const inUrl = stateFor(doc, at(doc, 'x.test'))
  check('link: caret in the url reveals the link, emphasis stays hidden', same(hidden(inUrl), ['*', '*']))
  const lone = '[x] and [r][ref]\n\n[ref]: http://x.test\n'
  check('link: a bare [x] is not hidden; a reference link hides its label part',
    same(hidden(stateFor(lone, lone.length - 2)), ['[', '][ref]']))
  const img = '![alt](p.png) [a](b)'
  check('image: stays source while the link beside it hides', same(hidden(away(img)), ['[', '](b)']))
  const wide = 'text [[Note]] and [[Target|label]] end'
  const w = away(wide)
  check('wikilink: brackets hide; with a label, target| hides too', same(hidden(w), ['[[', ']]', '[[Target|', ']]']))
  check('wikilink: label (or target) is styled', same(styled(w, 'cm-live-wikilink'), ['Note', 'label']))
  const inW = stateFor(wide, at(wide, 'Note') + 1)
  check('wikilink: caret inside reveals only that one', same(hidden(inW), ['[[Target|', ']]']))
  check('wikilink: a newline breaks it', same(hidden(stateFor('[[a\nb]]', 7)), []))
  check('wikilink: [[ ]] with nothing in it is not one', same(hidden(stateFor('[[]] x', 6)), []))
  check('wikilink: [text](url) next to [[ ]] still a link', same(hidden(away('[[a]] [b](c)')), ['[[', ']]', '[', '](c)']))
}

// --- ⌘-click targets

{
  const doc = 'go [here](./a.md#top) or [[Page|there]] or <https://e.test> or ![i](p.png)'
  const state = stateFor(doc, 0)
  check('click: a link gives its href', same(linkAt(state, at(doc, 'here') + 1, -1), { href: './a.md#top' }))
  check('click: a wikilink gives its target, not its label', same(linkAt(state, at(doc, 'there') + 1, -1), { wiki: 'Page' }))
  check('click: an autolink gives its href', same(linkAt(state, at(doc, 'e.test') + 1, 1), { href: 'https://e.test' }))
  check('click: plain text and images give nothing', linkAt(state, 1, 1) === null && linkAt(state, at(doc, 'p.png'), 1) === null)
}

// --- Review round: click targets and link kinds

{
  const edge = stateFor('[a](u)xyz and [b](v)[c](w)', 0)
  check('click: the left half of the x after a link does not open the link', linkAt(edge, 6, 1) === null)
  check('click: the right half of the link text does', same(linkAt(edge, 6, -1), { href: 'u' }))
  const two = at('[a](u)xyz and [b](v)[c](w)', '[c]')
  check('click: at the boundary of two links, each side opens its own',
    same(linkAt(edge, two, -1), { href: 'v' }) && same(linkAt(edge, two, 1), { href: 'w' }))

  const bare = stateFor('see https://x.test/a and www.example.org/p ok\n\n<me@x.co> <https://y.test>', 0)
  const d = bare.doc.toString()
  check('click: a bare URL opens as written', same(linkAt(bare, at(d, 'x.test') + 2, 1), { href: 'https://x.test/a' }))
  check('click: a www. URL gets the scheme linkify gives it', same(linkAt(bare, at(d, 'example') + 2, 1), { href: 'http://www.example.org/p' }))
  check('click: an email autolink becomes mailto:', same(linkAt(bare, at(d, 'me@') + 2, 1), { href: 'mailto:me@x.co' }))
  check('click: a URL autolink stays itself', same(linkAt(bare, at(d, 'y.test') + 2, 1), { href: 'https://y.test' }))
  check('bare URL and autolink are styled as links', styled(bare, 'cm-live-link').length === 4, JSON.stringify(styled(bare, 'cm-live-link')))

  const refs = 'a [Text][Foo  Bar] b [coll][] c [short] d [no][nope] e\n\n[foo bar]: http://r.test/1\n[coll]: <http://r.test/2>\n[SHORT]: ./s.md "t"\n\nz'
  const r = stateFor(refs, 'end')
  const rd = r.doc.toString()
  check('ref: labels match case-insensitively with whitespace collapsed', same(linkAt(r, at(rd, 'Text') + 1, 1), { href: 'http://r.test/1' }))
  check('ref: collapsed and shortcut forms resolve too',
    same(linkAt(r, at(rd, 'coll]') + 1, 1), { href: 'http://r.test/2' }) && same(linkAt(r, at(rd, 'short') + 1, 1), { href: './s.md' }))
  check('ref: with no definition it is plain text — not styled, not hidden, not clickable',
    linkAt(r, at(rd, 'no]') , 1) === null && !styled(r, 'cm-live-link').includes('no') && !hidden(r).some((h) => h.includes('nope')))
  check('ref: the ones that resolve are styled and hide their syntax',
    same(styled(r, 'cm-live-link'), ['Text', 'coll', 'short']) && hidden(r).includes('][Foo  Bar]'))

  const esc = stateFor('[a](my\\_notes.md) [b](x&amp;y.md) [c](<a b.md>)', 0)
  const ed = esc.doc.toString()
  check('href: backslash escapes and entities are decoded as markdown-it does',
    same(linkAt(esc, at(ed, 'a]') , 1), { href: 'my_notes.md' }) && same(linkAt(esc, at(ed, 'b]'), 1), { href: 'x&y.md' }) &&
    same(linkAt(esc, at(ed, 'c]'), 1), { href: 'a b.md' }))
}

// --- Front matter

{
  const doc = '---\ntitle: x\ntags: [a, b]\n---\n\n# Real\n\nbody **b**\n'
  const s = stateFor(doc, doc.length - 3)
  const items = decorate(s)
  check('front matter: no rule, no heading style, nothing hidden inside it',
    items.filter((i) => i.from < doc.indexOf('# Real')).every((i) => i.class === 'cm-live-frontmatter'), JSON.stringify(items.slice(0, 6)))
  check('front matter: its lines are plain monospace', items.filter((i) => i.class === 'cm-live-frontmatter').length === 4)
  check('front matter: the document after it is decorated as usual', same(hidden(s, items), ['# ']) || same(hidden(s, items), ['# ', '**', '**']), JSON.stringify(hidden(s, items)))
  const notYaml = '---\n: : [\n---\n\nbody'
  check('front matter: the preview shows broken YAML as Markdown, and so does this',
    styled(stateFor(notYaml, 'end'), 'cm-live-frontmatter').length === 0)
  const crlf = '---\r\ntitle: x\r\n---\r\n\r\nbody'
  check('front matter: found in a CRLF document', decorate(stateFor(crlf, 'end', true)).filter((i) => i.class === 'cm-live-frontmatter').length === 3)
  check('front matter: only at the very top', styled(stateFor('x\n\n---\ntitle: x\n---\n\nz', 'end'), 'cm-live-frontmatter').length === 0)
}

// --- Overlaps, wikilink with an empty label, dimmed constructs

{
  const s = stateFor('# #\n\n## a ## ##\n\nz', 'end')
  check('heading: "# #" hides without overlapping', same(hidden(s), ['# ', '#', '## ', ' ##', ' ##']) || hidden(s).length >= 2, JSON.stringify(hidden(s)))
  const w = away('[[a|]] and [[b| ]] and [[c|d]]')
  check('wikilink: an empty label shows the target, the | is syntax', same(hidden(w), ['[[', '|]]', '[[', '| ]]', '[[c|', ']]']) && same(styled(w, 'cm-live-wikilink'), ['a', 'b', 'd']), JSON.stringify(hidden(w)))
  const long = '[[a]] '.repeat(2000) + '[[open\nbroken]]'
  check('wikilink: a long paragraph of them parses', same(styled(away(long), 'cm-live-wikilink').length, 2000))
  // A plain HTML comment: an imark note is drawn as a card since M3.
  const dim = away('![i](p.png)\n\n<!-- x -->\n\n[r]: http://x.test\n\n- [ ] t\n\n| a | b |\n|---|---|\n| 1 | 2 |')
  check('dimmed: images, comments, definitions, task markers and table rules are not left unstyled',
    styled(dim, 'cm-live-dim').length >= 5, JSON.stringify(styled(dim, 'cm-live-dim')))
}

// --- Blocks

{
  const doc = '> one\n> two\n> > deep\n\nafter'
  const gone = stateFor(doc, doc.length)
  check('quote: > markers hide, with the space', same(hidden(gone), ['> ', '> ', '> ', '> ']))
  check('quote: every quoted line gets the quote class, the paragraph after does not', styled(gone, 'cm-live-quote').length === 3, String(styled(gone, 'cm-live-quote').length))
  const onTwo = stateFor(doc, at(doc, 'two'))
  check('quote: only the caret line shows its >', same(hidden(onTwo), ['> ', '> ', '> ']))
  check('quote: nothing hidden after the quote', !hidden(gone).some((h) => h.includes('after')))

  const lists = '- a\n* b\n+ c\n1. d\n- [ ] t\n\nx'
  const s = stateFor(lists, lists.length)
  const items = decorate(s)
  check('list: -, * and + become bullets', items.filter((i) => i.kind === 'bullet').map((i) => s.sliceDoc(i.from, i.to)).join('') === '-*+')
  check('list: ordered numbers stay, dimmed', same(styled(s, 'cm-live-number', items), ['1.']))
  check('list: a task item gets no bullet', items.filter((i) => i.kind === 'bullet').length === 3)
  const near = stateFor(lists, 1)
  check('list: caret at the marker shows it', decorate(near).filter((i) => i.kind === 'bullet').length === 2)
  // M3: beside a drawn box the "- " hides, as the preview draws no bullet there
  // (Support/test-live-blocks.mjs has the rest of it).
  check('list: only a task item hides its marker, with the space', same(hidden(s), ['- ']), JSON.stringify(hidden(s)))

  const hr = 'a\n\n---\n\nb'
  check('rule: styled while the caret is off it', styled(stateFor(hr, 0), 'cm-live-hr').length === 1)
  check('rule: source shows with the caret on it', styled(stateFor(hr, 4), 'cm-live-hr').length === 0)
  check('rule: --- under text is a setext heading, not a rule', styled(stateFor('a\n---\n', 0), 'cm-live-hr').length === 0)
}

// --- Code

{
  const doc = 'x\n\n```js\n**not** [a](b) # no\n```\n\n    indented *x*\n\ny `a` **b**'
  const s = away(doc)
  const items = decorate(s)
  check('code: nothing inside a fence or indented block is hidden', same(hidden(s, items), ['`', '`', '**', '**']))
  const codeLines = items.filter((i) => i.class === 'cm-live-codeline').length
  check('code: fence lines and content get the code line class', codeLines === 4, String(codeLines))
  check('code: first and last fence lines are marked', items.some((i) => i.class === 'cm-live-codeline-first') && items.some((i) => i.class === 'cm-live-codeline-last'))
  const inside = stateFor(doc, at(doc, 'not'))
  check('code: a caret inside changes nothing in the fence', same(hidden(inside), ['`', '`', '**', '**']))
  const quoted = '> ```\n> **x**\n> ```\n\nz'
  check('code: a fence inside a quote keeps its contents, hides the >', same(hidden(stateFor(quoted, quoted.length)), ['> ', '> ', '> ']))
}

// --- Selections

{
  const doc = '**a** and *b* and ~~c~~'
  const two = stateFor(doc, [2, at(doc, '~~c') + 3])
  check('selection: several carets reveal each of their constructs', same(hidden(two), ['*', '*']), JSON.stringify(hidden(two)))
  const range = stateFor(doc, { from: 0, to: at(doc, ' and *b') })
  check('selection: a range touching a construct reveals it', same(hidden(range), ['*', '*', '~~', '~~']))
  const across = stateFor(doc, { from: 3, to: 12 })
  check('selection: a range across constructs reveals every one it touches', same(hidden(across), ['~~', '~~']))
}

// --- Visible ranges

{
  const doc = '**a**\n\n' + 'filler\n'.repeat(50) + '\n**z**'
  const s = stateFor(doc, 8)
  const last = doc.length
  const items = liveDecorations(s, [{ from: last - 5, to: last }])
  check('ranges: only the visible part is decorated', same(hidden(s, items), ['**', '**']) && items.every((i) => i.from >= last - 5))
  const twice = liveDecorations(s, [{ from: 0, to: 4 }, { from: 2, to: 5 }])
  check('ranges: a construct in two visible ranges is not doubled', same(hidden(s, twice), ['**', '**']))
}

// --- CRLF and CJK

{
  const doc = '# 标题\r\n\r\n这是**加粗**和*斜体*的文字\r\n\r\n> 引用\r\n'
  const s = stateFor(doc, 'end', true)
  check('crlf: the document is one position per break', s.doc.lines === 6)
  const items = decorate(s)
  check('crlf: hidden ranges are the same marks, at CodeMirror offsets',
    same(hidden(s, items), ['# ', '**', '**', '*', '*', '> ']) &&
    items.filter((i) => i.kind === 'hide').every((i) => s.doc.sliceString(i.from, i.to) === s.sliceDoc(i.from, i.to)))
  check('cjk: strong text inside is styled whole', same(styled(s, 'cm-live-strong', items), ['**加粗**']))
  const inside = stateFor(doc, at(doc, '加粗') + 1, true)
  check('cjk: caret inside reveals just that emphasis', same(hidden(inside), ['# ', '*', '*', '> ']))
  const link = '[链接](http://x.test)\r\n[[笔记|别名]]'
  check('cjk: link/wikilink syntax hides around CJK text',
    same(hidden(away(link, true)), ['[', '](http://x.test)', '[[笔记|', ']]']))
}

// --- Hidden stretches never cross a line break (CodeMirror refuses those from a plugin)

{
  const doc = '[a](u "one\ntwo") and **b\nc** x\n\nz'
  const s = stateFor(doc, 'end')
  const items = decorate(s)
  check('lines: nothing hidden spans a break',
    items.filter((i) => i.kind === 'hide').every((i) => !s.sliceDoc(i.from, i.to).includes('\n')))
}

// --- The document is never changed

{
  const doc = '# T\r\n\r\n**b** [a](b) [[w]] ==m== ~~s~~ `c`\r\n> q\r\n- l\r\n\r\n---\r\n\r\n```\r\ncode\r\n```\r\n'
  let state = stateFor(doc, 0, true)
  const before = state.sliceDoc()
  let ok = state.sliceDoc() === doc
  for (let pos = 0; pos <= state.doc.length; pos += 3) {
    state = state.update({ selection: { anchor: pos } }).state
    decorate(state)
    ok = ok && state.sliceDoc() === before
  }
  check('fidelity: moving the caret everywhere leaves the document untouched', ok && before === doc)
  check('fidelity: decorations are data only — no change in any item', decorate(state).every((i) => !('insert' in i)))
}

check(`no two replaced stretches overlap, over ${calls} calls`, overlaps === 0, String(overlaps))

console.log(failures ? `\n${failures} failed` : '\nall passed')
process.exit(failures ? 1 : 0)
