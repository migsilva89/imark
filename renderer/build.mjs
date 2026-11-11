import * as esbuild from 'esbuild'
import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs'

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

// One metafile for both bundles, so the credits cover the editor's packages too.
const meta = {
  inputs: { ...result.metafile.inputs, ...editor.metafile.inputs },
  outputs: { ...result.metafile.outputs, ...editor.metafile.outputs },
}
writeFileSync('.esbuild-meta.json', JSON.stringify(meta))

copyFileSync('src/index.html', `${OUT}/index.html`)
copyFileSync('src/editor.html', `${OUT}/editor.html`)

console.log('renderer → Resources/{index.html,bundle.js,bundle.css,editor.html,editor.js,editor.css}')
