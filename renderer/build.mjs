import * as esbuild from 'esbuild'
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const OUT = '../Resources'
mkdirSync(OUT, { recursive: true })

// Mermaid is most of the renderer's weight, and both pages draw diagrams. It is
// built once, into mermaid.js (src/mermaid-global.js), and every other bundle
// reads it from the global that script sets instead of carrying its own copy.
// Read once, when the bundle starts: a document's HTML is put in the page later,
// and an element named like the global can never stand in for it.
const sharedMermaid = {
  name: 'shared-mermaid',
  setup(build) {
    build.onResolve({ filter: /^mermaid$/ }, () => ({ path: 'mermaid', namespace: 'shared-mermaid' }))
    build.onLoad({ filter: /.*/, namespace: 'shared-mermaid' }, () => ({
      contents: 'const mermaid = window.imarkMermaid\nexport default mermaid\n',
      loader: 'js',
    }))
  },
}

// Mermaid asks for KaTeX only when a label has math, by a dynamic import that
// runs then and not before; by then the page's own bundle has set the global
// (src/math.js). Without this, mermaid.js carried a second KaTeX, 270 KB.
const pageKatex = {
  name: 'page-katex',
  setup(build) {
    build.onResolve({ filter: /^katex$/ }, () => ({ path: 'katex', namespace: 'page-katex' }))
    build.onLoad({ filter: /.*/, namespace: 'page-katex' }, () => ({
      contents: 'const katex = globalThis.imarkKatex\nexport default katex\n',
      loader: 'js',
    }))
  },
}

const mermaid = await esbuild.build({
  entryPoints: { mermaid: 'src/mermaid-global.js' },
  plugins: [pageKatex],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari17'],
  outdir: OUT,
  legalComments: 'none',
  logLevel: 'warning',
  metafile: true,
})

const result = await esbuild.build({
  entryPoints: ['src/main.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari17'],
  outfile: `${OUT}/bundle.js`,
  plugins: [sharedMermaid],
  // KaTeX fonts ride along inside the CSS so the bundle stays a single pair of
  // files and nothing is ever fetched over a URL.
  loader: {
    '.woff2': 'dataurl',
    '.woff': 'dataurl',
    '.ttf': 'dataurl',
  },
  legalComments: 'none',
  logLevel: 'warning',
  // Support/licences.mjs reads this to credit exactly what ended up in the
  // bundle, rather than everything that happens to be in node_modules.
  metafile: true,
})

// The Live editor: its own page and bundle, so the preview (and Quick Look,
// which gets a copy of Resources without editor.*) never loads CodeMirror.
const editor = await esbuild.build({
  entryPoints: { editor: 'src/editor/main.js' },
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari17'],
  outdir: OUT,
  // The formulas' fonts, inside the CSS like the preview's: the page may load
  // nothing over a URL (editor.html's policy), and a font is only ever data:.
  loader: {
    '.woff2': 'dataurl',
    '.woff': 'dataurl',
    '.ttf': 'dataurl',
  },
  legalComments: 'none',
  logLevel: 'warning',
  metafile: true,
})

// KaTeX's stylesheet lists each font three times (woff2, woff, ttf) as fallbacks
// for browsers that cannot read woff2; the editor's web view always can, so only
// the first is kept. Two thirds of editor.css were fonts nothing would use.
const editorCss = `${OUT}/editor.css`
writeFileSync(
  editorCss,
  readFileSync(editorCss, 'utf8').replace(
    /,url\(data:font\/(?:woff|ttf);base64,[A-Za-z0-9+/=]*\) format\("(?:woff|truetype)"\)/g,
    '',
  ),
)

// The editor's diagram drawing (shared/diagrams.js and the zoom viewer), as a
// script of its own that mermaid-block.js loads, after mermaid.js, the first
// time a document has a diagram. The IIFE's global is `imarkDiagrams`
// (diagrams-entry.js lists what it holds).
const diagrams = await esbuild.build({
  entryPoints: { 'editor-diagrams': 'src/editor/diagrams-entry.js' },
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'imarkDiagrams',
  plugins: [
    sharedMermaid,
    {
      // diagrams.js wants one function out of markdown.js; see shared/escape.js.
      name: 'slim-markdown',
      setup(build) {
        build.onResolve({ filter: /markdown\.js$/ }, (args) =>
          args.importer.endsWith('shared/diagrams.js') ? { path: resolve('src/shared/escape.js') } : undefined,
        )
      },
    },
  ],
  target: ['safari17'],
  outdir: OUT,
  legalComments: 'none',
  logLevel: 'warning',
  metafile: true,
})

// One metafile for all of them, so the credits cover the editor's packages too.
const meta = {
  inputs: { ...mermaid.metafile.inputs, ...result.metafile.inputs, ...editor.metafile.inputs, ...diagrams.metafile.inputs },
  outputs: { ...mermaid.metafile.outputs, ...result.metafile.outputs, ...editor.metafile.outputs, ...diagrams.metafile.outputs },
}
writeFileSync('.esbuild-meta.json', JSON.stringify(meta))

copyFileSync('src/index.html', `${OUT}/index.html`)
copyFileSync('src/editor.html', `${OUT}/editor.html`)

console.log('renderer → Resources/{index.html,mermaid.js,bundle.js,bundle.css,editor.html,editor.js,editor.css,editor-diagrams.js}')
