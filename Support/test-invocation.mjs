// Tests for the one question the script asks before it does anything: was I run,
// or was I imported?
//
//   node Support/test-invocation.mjs
//
// It got that wrong through a link. The guard compared the path the loader
// resolved against the path the caller typed, so a run from a linked folder — on
// macOS anything under /tmp, which is a link to /private/tmp — looked like an
// import. Nothing ran, nothing was printed, and the exit code said it went fine.

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

let failures = 0
const check = (name, ok, detail = '') => {
  if (ok) {
    console.log(`OK   ${name}`)
  } else {
    failures += 1
    console.log(`FAIL ${name}${detail ? ` — ${detail}` : ''}`)
  }
}

const repo = path.dirname(path.dirname(fs.realpathSync(new URL(import.meta.url).pathname)))
const script = ['plugin', 'scripts', 'imark.mjs']
const usage = 'usage: imark.mjs <notes|review|open|plan-hook>'

const run = (file) => execFileSync('node', [file], { encoding: 'utf8' })

console.log('▸ the usage line comes out whichever path leads to the file')
check('run directly', run(path.join(repo, ...script)).includes(usage))

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'imark-invocation-'))

// A link to the checkout, the shape an install reached through a shortcut has.
const linkedRepo = path.join(dir, 'shortcut')
fs.symlinkSync(repo, linkedRepo)
check('run through a linked checkout', run(path.join(linkedRepo, ...script)).includes(usage))

// And a link to the file alone, which is what a hand-made shortcut on PATH is.
const linkedFile = path.join(dir, 'imark.mjs')
fs.symlinkSync(path.join(repo, ...script), linkedFile)
check('run through a link to the script itself', run(linkedFile).includes(usage))

fs.rmSync(dir, { recursive: true, force: true })

console.log('▸ and importing it still runs nothing')
const imported = execFileSync('node', ['--input-type=module', '-e',
  `import ${JSON.stringify(new URL(`file://${path.join(repo, ...script)}`).href)}`,
], { encoding: 'utf8' })
check('no usage line when the file is imported', !imported.includes(usage),
  JSON.stringify(imported))

console.log(failures === 0 ? '\nall good' : `\n${failures} failing`)
process.exit(failures === 0 ? 0 : 1)
