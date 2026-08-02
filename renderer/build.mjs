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

writeFileSync('.esbuild-meta.json', JSON.stringify(result.metafile))

copyFileSync('src/index.html', `${OUT}/index.html`)

console.log('renderer → Resources/{index.html,bundle.js,bundle.css}')
