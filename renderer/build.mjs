import * as esbuild from 'esbuild'
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const OUT = '../Resources'
mkdirSync(OUT, { recursive: true })

const result = await esbuild.build({
  entryPoints: ['src/main.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari17'],
  outfile: `${OUT}/bundle.js`,
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

// Mermaid, for the editor, as a script of its own: it is most of what the editor
// would weigh, and mermaid-block.js only loads it for a document with a diagram.
// The IIFE's global is `imarkDiagrams` (diagrams-entry.js lists what it holds).
const diagrams = await esbuild.build({
  entryPoints: { 'editor-diagrams': 'src/editor/diagrams-entry.js' },
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'imarkDiagrams',
  plugins: [
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
  inputs: { ...result.metafile.inputs, ...editor.metafile.inputs, ...diagrams.metafile.inputs },
  outputs: { ...result.metafile.outputs, ...editor.metafile.outputs, ...diagrams.metafile.outputs },
}
writeFileSync('.esbuild-meta.json', JSON.stringify(meta))

copyFileSync('src/index.html', `${OUT}/index.html`)
copyFileSync('src/editor.html', `${OUT}/editor.html`)

console.log('renderer → Resources/{index.html,bundle.js,bundle.css,editor.html,editor.js,editor.css,editor-diagrams.js}')
