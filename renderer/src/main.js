import MarkdownIt from 'markdown-it'
import anchor from 'markdown-it-anchor'
import taskLists from 'markdown-it-task-lists'
import footnote from 'markdown-it-footnote'
import deflist from 'markdown-it-deflist'
import mark from 'markdown-it-mark'
import hljs from 'highlight.js'
import { load as parseYaml } from 'js-yaml'
import katex from 'katex'
import renderMathInElement from 'katex/contrib/auto-render'
import mermaid from 'mermaid'

import wikilink from './wikilink.js'
import './style.css'

const bridge = (payload) => {
  window.webkit?.messageHandlers?.imark?.postMessage(payload)
}

/* ------------------------------------------------------------------ paths */

// Absolute path of the directory holding the document currently rendered.
let docDir = '/'

function normalizePath(path) {
  const parts = path.split('/')
  const out = []
  for (const part of parts) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return '/' + out.join('/')
}

function resolveLocal(href) {
  const path = href.startsWith('/') ? href : `${docDir}/${href}`
  return normalizePath(decodeURI(path))
}

// Local files are served by a WKURLSchemeHandler on the Swift side so that
// images next to the document load without granting file:// access.
const fileURL = (absPath) => `imark://file${absPath.split('/').map(encodeURIComponent).join('/')}`

const isExternal = (href) => /^[a-z][a-z0-9+.-]*:/i.test(href) && !href.startsWith('imark:')

/* ----------------------------------------------------------------- parser */

const slugCounts = new Map()

function slugify(text) {
  const base =
    text
      .toLowerCase()
      .trim()
      .replace(/[̀-ͯ]/g, '')
      .normalize('NFD')
      .replace(/[^\p{L}\p{N}\s-]/gu, '')
      .replace(/\s+/g, '-') || 'section'
  const seen = slugCounts.get(base) ?? 0
  slugCounts.set(base, seen + 1)
  return seen === 0 ? base : `${base}-${seen}`
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

md.use(anchor, { slugify, permalink: false, tabIndex: false })
  .use(taskLists, { enabled: true, label: true })
  .use(footnote)
  .use(deflist)
  .use(mark)
  .use(wikilink)

// Fenced ```mermaid blocks are held aside and rendered after the HTML lands.
const defaultFence = md.renderer.rules.fence.bind(md.renderer.rules)
md.renderer.rules.fence = (tokens, idx, options, env, self) => {
  const token = tokens[idx]
  const info = (token.info || '').trim().split(/\s+/)[0]
  if (info === 'mermaid') {
    return `<div class="mermaid-block" data-graph="${encodeURIComponent(token.content)}"></div>`
  }
  const html = defaultFence(tokens, idx, options, env, self)
  const label = info || 'text'
  return `<div class="code-wrap" data-lang="${label}">${html}</div>`
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
        token.attrs[i][1] = fileURL(resolveLocal(value))
      }
    }
    return original
      ? original(tokens, idx, options, env, self)
      : self.renderToken(tokens, idx, options)
  }
}
patchAttr(md.renderer.rules, 'image', 'src')
patchAttr(md.renderer.rules, 'link_open', 'href')

/* ------------------------------------------------------- front matter */

function splitFrontMatter(text) {
  if (!text.startsWith('---')) return { data: null, body: text }
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text)
  if (!match) return { data: null, body: text }
  try {
    const data = parseYaml(match[1])
    if (data && typeof data === 'object') {
      return { data, body: text.slice(match[0].length) }
    }
  } catch {
    /* malformed front matter is shown as-is */
  }
  return { data: null, body: text }
}

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

function renderFrontMatter(data) {
  if (!data) return ''
  const title = data.title ?? data.name
  const rows = Object.entries(data)
    .filter(([key]) => key !== 'title' && key !== 'name')
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

/* --------------------------------------------------------------- mermaid */

let mermaidSeq = 0

// Mermaid ships its own palette, which clashes badly with ours. Feeding it the
// live CSS variables keeps diagrams on-theme in both light and dark.
function mermaidTheme() {
  const css = getComputedStyle(document.documentElement)
  const token = (name) => css.getPropertyValue(name).trim()
  return {
    background: token('--bg'),
    primaryColor: token('--code-bg'),
    primaryTextColor: token('--text'),
    primaryBorderColor: token('--diagram'),
    secondaryColor: token('--accent-soft'),
    secondaryBorderColor: token('--diagram'),
    tertiaryColor: token('--bg'),
    tertiaryBorderColor: token('--border'),
    lineColor: token('--secondary'),
    textColor: token('--text'),
    mainBkg: token('--code-bg'),
    nodeBorder: token('--diagram'),
    clusterBkg: token('--bg'),
    clusterBorder: token('--border'),
    edgeLabelBackground: token('--bg'),
    fontSize: '14px',
  }
}

async function renderMermaid(root, theme) {
  const blocks = root.querySelectorAll('.mermaid-block')
  if (!blocks.length) return
  mermaid.initialize({
    startOnLoad: false,
    theme: 'base',
    themeVariables: mermaidTheme(),
    securityLevel: 'strict',
    fontFamily: 'inherit',
  })
  for (const block of blocks) {
    const source = decodeURIComponent(block.dataset.graph || '')
    try {
      const { svg } = await mermaid.render(`mermaid-${mermaidSeq++}`, source)
      block.innerHTML = svg
      block.classList.add('is-rendered')
    } catch (error) {
      block.classList.add('is-error')
      block.innerHTML = `<div class="diagram-error"><strong>Invalid diagram</strong><pre>${escapeHtml(
        error?.message ?? error,
      )}</pre></div>`
    }
  }
}

/* ------------------------------------------------------------------ math */

function renderMath(root) {
  try {
    renderMathInElement(root, {
      delimiters: [
        { left: '$$', right: '$$', display: true },
        { left: '\\[', right: '\\]', display: true },
        { left: '$', right: '$', display: false },
        { left: '\\(', right: '\\)', display: false },
      ],
      ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code'],
      throwOnError: false,
    })
  } catch {
    /* math is best-effort */
  }
}

/* ------------------------------------------------------------------- toc */

function buildToc(root) {
  const headings = [...root.querySelectorAll('h1, h2, h3, h4, h5, h6')].filter((h) => h.id)
  bridge({
    type: 'toc',
    items: headings.map((h) => ({
      id: h.id,
      level: Number(h.tagName.slice(1)),
      title: h.textContent.trim(),
    })),
  })
  return headings
}

/* ------------------------------------------------------------------ rail */

// A slim column of ticks standing in for the sidebar in Quick Look, where
// there is no room for one. Every heading gets a tick; the three either side
// of where you are taper away, so the eye is pulled to the current section
// without losing the shape of the whole document.
const RAIL_REACH = 3

let railTicks = []

function buildRail(headings) {
  const existing = document.querySelector('.rail')
  if (existing) existing.remove()
  railTicks = []
  if (headings.length < 2) return

  const rail = document.createElement('nav')
  rail.className = 'rail'
  rail.setAttribute('aria-hidden', 'true')

  headings.forEach((heading) => {
    // The dash lives inside a taller transparent row so there is something
    // big enough to actually hit with a pointer.
    const slot = document.createElement('span')
    slot.className = 'rail-tick'
    slot.dataset.level = heading.tagName.slice(1)
    slot.appendChild(document.createElement('i'))
    rail.appendChild(slot)
    railTicks.push(slot)
  })

  attachRailScrubbing(rail, headings)
  document.body.appendChild(rail)
}

/* Click to jump, press and drag to scrub. */
function attachRailScrubbing(rail, headings) {
  let scrubbing = false

  const nearest = (clientY) => {
    let best = 0
    let bestDistance = Infinity
    railTicks.forEach((tick, index) => {
      const box = tick.getBoundingClientRect()
      const distance = Math.abs(clientY - (box.top + box.height / 2))
      if (distance < bestDistance) {
        bestDistance = distance
        best = index
      }
    })
    return best
  }

  const goTo = (clientY, smooth) => {
    const index = nearest(clientY)
    const target = headings[index]
    if (!target) return
    const top = target.getBoundingClientRect().top + window.scrollY - 24
    window.scrollTo({ top, behavior: smooth ? 'smooth' : 'auto' })
    updateRail(index)
  }

  rail.addEventListener('pointerdown', (event) => {
    scrubbing = true
    rail.classList.add('is-scrubbing')
    rail.setPointerCapture(event.pointerId)
    // A press lands instantly; only a plain click gets the smooth ride.
    goTo(event.clientY, false)
    event.preventDefault()
  })

  rail.addEventListener('pointermove', (event) => {
    if (scrubbing) goTo(event.clientY, false)
  })

  const release = (event) => {
    if (!scrubbing) return
    scrubbing = false
    rail.classList.remove('is-scrubbing')
    if (rail.hasPointerCapture?.(event.pointerId)) rail.releasePointerCapture(event.pointerId)
  }
  rail.addEventListener('pointerup', release)
  rail.addEventListener('pointercancel', release)
}

function updateRail(activeIndex) {
  if (!railTicks.length) return

  railTicks.forEach((tick, index) => {
    const distance = Math.abs(index - activeIndex)
    const depth = Number(tick.dataset.level || 2)

    const dash = tick.firstElementChild
    if (!dash) return

    // The resting state has to stay legible on its own: these are most of the
    // rail most of the time, and at 14% they read as noise rather than as the
    // shape of the document.
    if (distance > RAIL_REACH) {
      dash.style.width = '9px'
      dash.style.opacity = '0.34'
      tick.classList.remove('is-active')
      return
    }

    // Linear taper: full width at the cursor, down to the resting width three
    // headings out. Deeper headings sit a little shorter at every step.
    // Taper down to the resting values rather than to zero, so there is no
    // visible step where the funnel ends.
    const falloff = 1 - distance / (RAIL_REACH + 1)
    const reach = 24 - Math.min(depth, 4) * 2
    dash.style.width = `${9 + falloff * reach}px`
    dash.style.opacity = `${0.34 + falloff * 0.66}`
    tick.classList.toggle('is-active', distance === 0)
  })
}

/* -------------------------------------------------------- code copy button */

function addCopyButtons(root) {
  for (const wrap of root.querySelectorAll('.code-wrap')) {
    const button = document.createElement('button')
    button.className = 'copy-btn'
    button.type = 'button'
    button.textContent = 'Copiar'
    button.addEventListener('click', async () => {
      const code = wrap.querySelector('code')?.textContent ?? ''
      try {
        await navigator.clipboard.writeText(code)
        button.textContent = 'Copiado'
      } catch {
        button.textContent = 'Falhou'
      }
      setTimeout(() => {
        button.textContent = 'Copiar'
      }, 1400)
    })
    wrap.appendChild(button)
  }
}

/* ---------------------------------------------------------------- render */

const content = () => document.getElementById('content')

let activeHeadings = []
let renderToken = 0

async function render({ markdown, path, theme, preview }) {
  const token = ++renderToken
  docDir = path ? path.slice(0, path.lastIndexOf('/')) || '/' : '/'
  slugCounts.clear()

  // The very first render carries the theme and the preview flag — without this
  // the page keeps the defaults from index.html until something calls the
  // setters, and in Quick Look those calls arrive before the page exists.
  if (theme) document.documentElement.dataset.theme = theme
  if (preview) document.documentElement.dataset.preview = 'true'

  const { data, body } = splitFrontMatter(markdown ?? '')
  const root = content()
  const previousScroll = window.scrollY

  root.innerHTML = renderFrontMatter(data) + md.render(body)
  if (token !== renderToken) return

  // The highlight elements went out with the old DOM.
  matches = []
  matchIndex = -1

  addCopyButtons(root)
  renderMath(root)
  activeHeadings = buildToc(root)
  buildRail(activeHeadings)
  await renderMermaid(root, theme)
  if (token !== renderToken) return

  const words = root.textContent.trim().split(/\s+/).filter(Boolean).length
  bridge({ type: 'meta', words, minutes: Math.max(1, Math.round(words / 220)) })

  // Swift resolves these against the filesystem and tells us which ones are
  // dead, so the renderer never has to know where notes live.
  const targets = [...root.querySelectorAll('a.wikilink')].map((a) => a.dataset.wikilink)
  if (targets.length) bridge({ type: 'wikilinks', targets: [...new Set(targets)] })

  window.scrollTo(0, Math.min(previousScroll, document.body.scrollHeight))
  updateActiveHeading()
  bridge({ type: 'rendered' })
}

/* --------------------------------------------------------- scroll tracking */

let scrollQueued = false

function updateActiveHeading() {
  if (!activeHeadings.length) return
  let index = 0
  for (let i = 0; i < activeHeadings.length; i += 1) {
    if (activeHeadings[i].getBoundingClientRect().top <= 80) index = i
    else break
  }
  updateRail(index)
  bridge({ type: 'active', id: activeHeadings[index].id })
}

window.addEventListener(
  'scroll',
  () => {
    if (scrollQueued) return
    scrollQueued = true
    requestAnimationFrame(() => {
      scrollQueued = false
      updateActiveHeading()
    })
  },
  { passive: true },
)

/* ----------------------------------------------------------- link routing */

document.addEventListener('click', (event) => {
  const anchorEl = event.target.closest('a')
  if (!anchorEl) return

  const wiki = anchorEl.dataset.wikilink
  if (wiki) {
    event.preventDefault()
    bridge({ type: 'openWiki', target: wiki })
    return
  }

  const href = anchorEl.getAttribute('href') ?? ''
  if (href.startsWith('#')) {
    event.preventDefault()
    scrollToAnchor(href.slice(1))
    return
  }

  event.preventDefault()
  if (href.startsWith('imark://file')) {
    const path = decodeURIComponent(href.replace('imark://file', ''))
    bridge({ type: 'openLocal', path })
  } else if (isExternal(href)) {
    bridge({ type: 'openExternal', url: href })
  }
})

function scrollToAnchor(id) {
  const target = document.getElementById(id)
  if (!target) return
  const top = target.getBoundingClientRect().top + window.scrollY - 24
  window.scrollTo({ top, behavior: 'smooth' })
}

/* ------------------------------------------------------------------ find */

let matches = []
let matchIndex = -1

function clearFind() {
  for (const hit of [...document.querySelectorAll('mark.find')]) {
    const parent = hit.parentNode
    if (!parent) continue
    parent.replaceChild(document.createTextNode(hit.textContent), hit)
    parent.normalize()
  }
  matches = []
  matchIndex = -1
}

function runFind(query) {
  clearFind()
  const needle = (query ?? '').toLowerCase()
  if (needle.length === 0) return report()

  const root = content()
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT
      const tag = node.parentElement?.tagName
      return tag === 'SCRIPT' || tag === 'STYLE'
        ? NodeFilter.FILTER_REJECT
        : NodeFilter.FILTER_ACCEPT
    },
  })

  // Collected up front: splitting text nodes while walking invalidates it.
  const nodes = []
  for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node)

  for (const node of nodes) {
    const text = node.nodeValue
    const lower = text.toLowerCase()
    let at = lower.indexOf(needle)
    if (at < 0) continue

    const fragment = document.createDocumentFragment()
    let from = 0
    while (at >= 0) {
      fragment.appendChild(document.createTextNode(text.slice(from, at)))
      const hit = document.createElement('mark')
      hit.className = 'find'
      hit.textContent = text.slice(at, at + needle.length)
      fragment.appendChild(hit)
      matches.push(hit)
      from = at + needle.length
      at = lower.indexOf(needle, from)
    }
    fragment.appendChild(document.createTextNode(text.slice(from)))
    node.parentNode?.replaceChild(fragment, node)
  }

  if (matches.length) step(0)
  return report()
}

function step(delta) {
  if (!matches.length) return report()
  matches[matchIndex]?.classList.remove('is-active')
  matchIndex = (matchIndex + delta + matches.length) % matches.length
  if (matchIndex < 0) matchIndex = 0
  const hit = matches[matchIndex]
  hit.classList.add('is-active')
  hit.scrollIntoView({ block: 'center', behavior: 'smooth' })
  return report()
}

function report() {
  bridge({ type: 'find', count: matches.length, index: matches.length ? matchIndex + 1 : 0 })
}

/* ------------------------------------------------------------------- api */

window.imark = {
  render,
  scrollToAnchor,
  setTheme(theme) {
    document.documentElement.dataset.theme = theme
    const blocks = document.querySelectorAll('.mermaid-block')
    if (blocks.length) renderMermaid(content(), theme)
  },
  setWidth(width) {
    document.documentElement.dataset.width = width
  },
  setPreview(on) {
    document.documentElement.dataset.preview = on ? 'true' : 'false'
  },
  find: runFind,
  findStep: step,
  findClear: clearFind,
  setTextScale(scale) {
    document.documentElement.style.setProperty('--size-body', `${scale}px`)
  },
  markMissing(targets) {
    const dead = new Set(targets)
    for (const link of document.querySelectorAll('a.wikilink')) {
      if (dead.has(link.dataset.wikilink)) link.dataset.missing = 'true'
    }
  },
}

// KaTeX is imported for its side-effect-free API; keep a reference so the
// bundler cannot tree-shake the font-bearing CSS away.
window.imark.katexVersion = katex.version

bridge({ type: 'ready' })
