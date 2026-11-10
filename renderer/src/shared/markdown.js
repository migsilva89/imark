// The markdown-it pipeline, and everything it needs, with nothing in it that
// touches the page: no document, no window, no bridge to the app. The preview
// builds its HTML here, and so does anything else that has to show a piece of
// Markdown the way the preview shows it — a table, a formula, a diagram, a
// footnote — because the one way to be sure two views agree is for both to ask
// the same parser.
//
// Anything that belongs to the page rather than the parser comes in through
// `createMarkdown`'s options: where a relative link points, and whether the
// document is being shown read-only.

import MarkdownIt from 'markdown-it'
import anchor from 'markdown-it-anchor'
import taskLists from 'markdown-it-task-lists'
import footnote from 'markdown-it-footnote'
import deflist from 'markdown-it-deflist'
import mark from 'markdown-it-mark'
import hljs from 'highlight.js'
import { load as parseYaml } from 'js-yaml'

import math from '../math.js'
import wikilink from '../wikilink.js'

export const isExternal = (href) => /^[a-z][a-z0-9+.-]*:/i.test(href) && !href.startsWith('imark:')

export const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const newTaskKey = () =>
  [...crypto.getRandomValues(new Uint32Array(4))].map((n) => n.toString(36)).join('')

/**
 * A ```diff block, rendered the way everybody already reads a diff: the whole
 * row tinted rather than just the `+` or the `-`, with the old and new line
 * numbers down the side.
 *
 * highlight.js colours the marker character and leaves the rest of the line on
 * the block's own background, which is legible but has to be read a character
 * at a time. Tinting the row is what makes a diff scannable.
 *
 * Unified only. A reading column is one column, and two columns of code inside
 * it is a different app.
 */
export function renderDiff(source) {
  const HUNK = /^@@+ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/
  let oldNo = 0
  let newNo = 0

  const rows = source.split('\n').map((line) => {
    const cell = (kind, left, right) =>
      `<div class="diff-row diff-${kind}">`
      + `<span class="diff-num">${left}</span>`
      + `<span class="diff-num">${right}</span>`
      + `<code>${escapeHtml(line) || '&nbsp;'}</code>`
      + '</div>'

    const hunk = line.match(HUNK)
    if (hunk) {
      oldNo = Number(hunk[1])
      newNo = Number(hunk[2])
      return cell('hunk', '', '')
    }
    // The `diff --git`, `index`, `---` and `+++` preamble. Matched before the
    // +/- tests, or the file headers would be read as an added and a removed
    // line and tinted as changes nobody made.
    if (/^(diff --git |index |--- |\+\+\+ |new file|deleted file|similarity|rename |Binary files )/.test(line)) {
      return cell('meta', '', '')
    }
    if (line.startsWith('+')) return cell('add', '', newNo++)
    if (line.startsWith('-')) return cell('del', oldNo++, '')
    if (line.startsWith('\\')) return cell('meta', '', '')
    return cell('ctx', oldNo++, newNo++)
  })

  return `<div class="diff-block">${rows.join('')}</div>`
}

/* ------------------------------------------------------- front matter */

export function splitFrontMatter(text) {
  if (!text.startsWith('---')) return { data: null, body: text, offset: 0 }
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text)
  if (!match) return { data: null, body: text, offset: 0 }
  try {
    const data = parseYaml(match[1])
    if (data && typeof data === 'object') {
      return {
        data,
        body: text.slice(match[0].length),
        offset: match[0].split('\n').length - 1,
      }
    }
  } catch {
    /* malformed front matter is shown as-is */
  }
  return { data: null, body: text, offset: 0 }
}

export function renderFrontMatter(data) {
  if (!data) return ''
  const title = data.title ?? data.name
  const rows = Object.entries(data)
    // `imark:` is how a document tells the app what it is — machinery, not
    // something the person reading it put there or needs to see.
    .filter(([key]) => key !== 'title' && key !== 'name' && key !== 'imark')
    .map(([key, value]) => {
      const shown = Array.isArray(value)
        ? value.map((v) => `<span class="fm-chip">${escapeHtml(v)}</span>`).join('')
        : value && typeof value === 'object'
          ? `<code>${escapeHtml(JSON.stringify(value))}</code>`
          : escapeHtml(value)
      return `<div class="fm-row"><dt>${escapeHtml(key)}</dt><dd>${shown}</dd></div>`
    })
    .join('')
  if (!title && !rows) return ''
  return `<header class="front-matter">
    ${title ? `<h1 class="fm-title">${escapeHtml(title)}</h1>` : ''}
    ${rows ? `<dl class="fm-grid">${rows}</dl>` : ''}
  </header>`
}

/**
 * Builds a markdown-it instance configured the way the preview is, and returns
 * it with the state its rules read.
 *
 * Three things are per instance rather than global, because the rules close
 * over them: the ids already handed to headings, the line the front matter
 * pushed the body down by, and the key that marks a task box as ours.
 *
 * @param options.resolveFile  turns the path part of a relative link or image
 *   (fragment and query already taken off) into the URL to put in the page.
 *   Without it relative paths are left as written.
 * @param options.isPreview    true while the document is shown read-only, where
 *   a task box is not offered. Asked at render time, never cached.
 */
export function createMarkdown({ resolveFile = (file) => file, isPreview = () => false } = {}) {

  // Every id handed out in this document, and how many times each heading text
  // has come round.
  const slugCounts = new Map()

  // The id GitHub gives the same heading, so a link written for GitHub — or by
  // any of the tools that write a table of contents the way GitHub reads it —
  // lands here too. Checked against github-slugger for every character it knows.
  //
  // Marks stay on their letters: `й` and `ї` are letters of their own in
  // Ukrainian, not an `и` and an `і` with something to take off. Underscores stay,
  // and every space is a hyphen of its own, so `a  b` is `a--b`.
  function slugify(text) {
    const base =
      text
        .toLowerCase()
        .trim()
        .replace(/[^\p{Alphabetic}\p{M}\p{Nd}\p{Pc} -]/gu, '')
        .replace(/ /g, '-') || 'section'
    // A repeat is numbered, and so is a number that is already somebody's
    // heading: `a`, `a`, `a-1` come out as `a`, `a-1`, `a-1-1`.
    let slug = base
    while (slugCounts.has(slug)) {
      slugCounts.set(base, slugCounts.get(base) + 1)
      slug = `${base}-${slugCounts.get(base)}`
    }
    slugCounts.set(slug, 0)
    return slug
  }

  const md = new MarkdownIt({
    html: true,
    linkify: true,
    typographer: true,
    breaks: false,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) {
        try {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value
        } catch {
          /* fall through to auto */
        }
      }
      try {
        return hljs.highlightAuto(code).value
      } catch {
        return ''
      }
    },
  })

  // No `label`: it wrapped the item's words in a <label>, so a click anywhere on
  // them ticked the box — on its way to a comment or a selection, as often as not.
  // Only the box itself ticks.
  md.use(anchor, { slugify, permalink: false, tabIndex: false })
    .use(taskLists, { enabled: true })
    .use(footnote)
    .use(deflist)
    .use(mark)
    .use(wikilink)

  // Every block token knows which lines of the source produced it. Emitting that
  // into the DOM is what lets a selection on screen be turned back into a
  // position in the file — without it, writing anything next to a paragraph is
  // guesswork.
  // The front matter is stripped before parsing, so markdown-it counts from the
  // body while the file counts from the top. Everything it reports is short by
  // however many lines the front matter took.
  let lineOffset = 0

  const stampLines = (token) => {
    if (!token.map) return
    token.attrSet('data-line', `${token.map[0] + lineOffset},${token.map[1] + lineOffset}`)
  }

  // For the blocks whose HTML is built by hand below, which never reach
  // renderToken and so have to be given the same attribute themselves.
  const lineAttr = (token) =>
    token.map ? ` data-line="${token.map[0] + lineOffset},${token.map[1] + lineOffset}"` : ''

  // Down here rather than in the chain above only because it needs lineAttr.
  md.use(math, { lines: lineAttr })

  /* ------------------------------------------------------------ task boxes */

  // A tick is written to the file, so a box has to know the line its `[ ]` is on.
  // That is taken from the parser, never from the page: the document is allowed
  // HTML of its own, and an <input> it wrote with a line on it would be a way to
  // make a click change some other line. Each render picks a new key and only a
  // box carrying it is believed.
  let taskKey = ''

  // The plugin marks the item and puts its box first in the item's inline
  // content, as raw HTML. Here that box becomes a token of our own, which the
  // document cannot write, carrying the line of the paragraph the `[ ]` opens —
  // the item's first line, or the one after it when the marker stands alone.
  md.core.ruler.after('github-task-lists', 'imark-task-boxes', (state) => {
    const tokens = state.tokens
    for (let i = 0; i + 2 < tokens.length; i++) {
      const item = tokens[i]
      if (item.type !== 'list_item_open' || !/\btask-list-item\b/.test(item.attrGet('class') ?? '')) continue
      const paragraph = tokens[i + 1]
      const box = tokens[i + 2].children?.[0]
      if (!paragraph?.map || box?.type !== 'html_inline') continue
      if (!box.content.startsWith('<input class="task-list-item-checkbox"')) continue
      box.type = 'task_box'
      box.meta = { checked: box.content.includes('checked'), line: paragraph.map[0] }
    }
  })

  md.renderer.rules.task_box = (tokens, idx) => {
    const { checked, line } = tokens[idx].meta
    // Quick Look cannot write to anything, so a box there is not offered.
    const disabled = isPreview() ? ' disabled=""' : ''
    return `<input class="task-list-item-checkbox"${checked ? ' checked=""' : ''}${disabled}`
      + ` type="checkbox" data-task="${taskKey}:${line + lineOffset}">`
  }

  const defaultRenderToken = md.renderer.renderToken.bind(md.renderer)
  md.renderer.renderToken = (tokens, idx, options) => {
    if (tokens[idx].nesting !== -1) stampLines(tokens[idx])
    return defaultRenderToken(tokens, idx, options)
  }

  // Fenced ```mermaid blocks are held aside and rendered after the HTML lands.
  const defaultFence = md.renderer.rules.fence.bind(md.renderer.rules)
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx]
    const info = (token.info || '').trim().split(/\s+/)[0]
    // Built by hand rather than through renderToken, so the offset has to be
    // applied here too — this is exactly where it was forgotten once already.
    const lines = lineAttr(token)
    if (info === 'mermaid') {
      return `<div class="mermaid-block"${lines} data-graph="${encodeURIComponent(token.content)}"></div>`
    }
    if (info === 'diff') {
      return `<div class="code-wrap diff-wrap"${lines} data-lang="diff">${renderDiff(token.content)}</div>`
    }
    const html = defaultFence(tokens, idx, options, env, self)
    const label = info || 'text'
    return `<div class="code-wrap"${lines} data-lang="${label}">${html}</div>`
  }

  // Rewrite relative hrefs/srcs so they resolve against the document's folder.
  const patchAttr = (rules, rule, attr) => {
    const original = rules[rule]
    rules[rule] = (tokens, idx, options, env, self) => {
      const token = tokens[idx]
      const i = token.attrIndex(attr)
      if (i >= 0) {
        const value = token.attrs[i][1]
        if (!isExternal(value) && !value.startsWith('#')) {
          // The fragment is not part of the file's name. Resolved along with it,
          // it was encoded into the path — `other.md%23section` — and named a
          // file that is not there.
          const hash = value.indexOf('#')
          const path = hash < 0 ? value : value.slice(0, hash)
          const fragment = hash < 0 ? '' : value.slice(hash)
          // A query is for a web server, not part of the name: GitHub's
          // `?plain=1` for a file's source, `?raw=true` for an image.
          const query = path.indexOf('?')
          const file = query < 0 ? path : path.slice(0, query)
          // `?plain=1#L12` alone is a link within this page.
          token.attrs[i][1] = file ? resolveFile(file) + fragment : fragment
        }
      }
      return original
        ? original(tokens, idx, options, env, self)
        : self.renderToken(tokens, idx, options)
    }
  }
  patchAttr(md.renderer.rules, 'image', 'src')
  patchAttr(md.renderer.rules, 'link_open', 'href')

  /* ------------------------------------------------------------ rendering */

  return {
    md,

    // The line the front matter pushed the body down by, for the render last
    // made, and the key the task boxes in it carry.
    get lineOffset() {
      return lineOffset
    },
    get taskKey() {
      return taskKey
    },

    /**
     * A whole document: the front matter split off and drawn as its card, the
     * body rendered with its lines counted from the top of the file.
     *
     * @param options.prepare  called with the body and the front matter's line
     *   count before parsing, may return a replacement body. The app uses it to
     *   lift its comment blocks out, blanked rather than deleted so the line map
     *   stays honest.
     * @returns {{ html: string, offset: number }}
     */
    renderDocument(markdown, { prepare } = {}) {
      slugCounts.clear()
      const { data, body, offset } = splitFrontMatter(markdown ?? '')
      lineOffset = offset
      const clean = prepare ? prepare(body, offset) : body
      taskKey = newTaskKey()
      const html = clean.trim()
        ? renderFrontMatter(data) + md.render(clean)
        : `${renderFrontMatter(data)}<p class="empty">This file is empty</p>`
      return { html, offset }
    },

    /**
     * A piece of a document, rendered on its own.
     *
     * @param env  markdown-it's `env`. Reference definitions and footnotes live
     *   there, so a slice that uses a `[label]` or a `[^1]` defined elsewhere
     *   in the file is given the env the whole document was parsed into.
     * @param options.lineOffset  the line of the file the slice starts on, so
     *   its `data-line` attributes are the file's and not the slice's.
     */
    renderSlice(source, env = {}, { lineOffset: offset = 0 } = {}) {
      lineOffset = offset
      if (!taskKey) taskKey = newTaskKey()
      return md.render(source, env)
    },

    // Forgets the ids handed out so far, so the next heading starts over.
    resetSlugs() {
      slugCounts.clear()
    },
  }
}
