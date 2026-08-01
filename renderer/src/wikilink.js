// [[target]] and [[target|label]] inline syntax.
// Resolution happens on the Swift side — here we only emit a tagged anchor.

const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const escapeAttr = (s) => escapeHtml(s).replace(/"/g, '&quot;')

export default function wikilinkPlugin(md) {
  md.inline.ruler.before('link', 'wikilink', (state, silent) => {
    const src = state.src
    const start = state.pos
    if (src.charCodeAt(start) !== 0x5b) return false // [
    if (src.charCodeAt(start + 1) !== 0x5b) return false
    const end = src.indexOf(']]', start + 2)
    if (end < 0) return false

    const raw = src.slice(start + 2, end)
    if (raw.includes('\n') || raw.length === 0) return false

    if (!silent) {
      const pipe = raw.indexOf('|')
      const target = (pipe < 0 ? raw : raw.slice(0, pipe)).trim()
      const label = (pipe < 0 ? raw : raw.slice(pipe + 1)).trim()
      if (!target) return false
      const token = state.push('wikilink', '', 0)
      token.content = label || target
      token.meta = { target }
    }

    state.pos = end + 2
    return true
  })

  md.renderer.rules.wikilink = (tokens, idx) => {
    const { content, meta } = tokens[idx]
    return `<a class="wikilink" href="#" data-wikilink="${escapeAttr(meta.target)}">${escapeHtml(content)}</a>`
  }
}
