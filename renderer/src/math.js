// $x$ and $$x$$ handed to KaTeX while the Markdown is being parsed.
//
// The obvious alternative — let markdown-it produce the HTML and then walk the
// DOM with KaTeX's auto-render — cannot work: by the time the HTML exists, the
// underscores in `\mathbf{K}_e^L` have been read as emphasis and the formula is
// spread over several elements, so the delimiters no longer sit in one piece of
// text. A block rule claims the formula before any of that happens, which is
// also the only way a display equation may span several lines.

import katex from 'katex'
import * as plugin from '@vscode/markdown-it-katex'

// esbuild and Node disagree about the default export of a CommonJS module that
// declares `__esModule`, and this file has to load the same way in the bundle
// and in the test runner.
const katexPlugin = plugin.default.default ?? plugin.default

/**
 * @param md         markdown-it instance
 * @param options.lines  called with a math block's token, returns the
 *   `data-line` attribute to put on it — with the front matter offset already
 *   applied. Without it a note written under an equation would anchor to
 *   whatever block came before the equation instead.
 */
export default function mathPlugin(md, options = {}) {
  md.use(katexPlugin, {
    // The bundled copy, so nothing is ever loaded over a URL and the version
    // the About panel credits is the version doing the rendering.
    katex,
    // A formula with a typo in it shows up in red where it stands, rather than
    // taking the rest of the document down with it.
    throwOnError: false,
  })

  const lines = options.lines ?? (() => '')
  const renderBlock = md.renderer.rules.math_block

  md.renderer.rules.math_block = (tokens, idx, opts, env, self) => {
    const token = tokens[idx]
    const html = renderBlock(tokens, idx, opts, env, self)
    // Only a formula standing on its own lines knows where it came from. The
    // same token also arrives from inside a sentence — `given $$x$$ then` —
    // where the paragraph the plugin emits cannot be nested inside the
    // paragraph already open: the browser closes the outer one and the sentence
    // ends up in two halves. A span with the same class holds the equation on
    // its own line and leaves the sentence whole.
    if (!token.map) {
      return html.replace(/^<p /, '<span ').replace(/<\/p>\n?$/, '</span>')
    }
    const attr = lines(token)
    return attr ? html.replace('<p class="katex-block"', `<p${attr} class="katex-block"`) : html
  }
}
