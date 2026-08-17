// Tests for the notes the agent is handed: which ones, and whether they still
// point at anything.
//
//   node Support/test-notes.mjs
//
// Two bugs live here, and both were quiet. A quote holds the *rendered* text,
// so every emphasised phrase compared unequal against the raw markdown and came
// back marked orphan — which tells an agent to stop and ask instead of act. And
// `notes` returned resolved notes along with the open ones, so a document on
// its third round handed back twenty finished requests to bury the two live
// ones.

import { flatten, parseNotes } from '../plugin/scripts/imark.mjs'
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

// ------------------------------------------------------------------ flatten

const same = (name, raw, rendered) =>
  check(name, flatten(raw).includes(flatten(rendered)),
    `${JSON.stringify(flatten(raw))} does not contain ${JSON.stringify(flatten(rendered))}`)

console.log('▸ the raw line and the rendered quote flatten alike')
same('bold', 'A **bold** word', 'A bold word')
same('italic with stars', 'A *slanted* word', 'A slanted word')
same('italic with underscores', 'A _slanted_ word', 'A slanted word')
same('code span', 'Run `npm ci` first', 'Run npm ci first')
same('struck through', 'It is ~~gone~~ now', 'It is gone now')
same('a link is its words', 'See [the docs](https://x.dev) for more', 'See the docs for more')
same('an image is its alt text', 'Here ![a cat](cat.png) sits', 'Here a cat sits')
same('bold and code at once',
  '1. **Nome da pasta.** `~/produtos/` ou preferes `~/projects/`?',
  'Nome da pasta. ~/produtos/ ou preferes ~/projects/?')
same('a paragraph the file wrapped', 'one line\nand the next', 'one line and the next')

console.log('▸ and flattening leaves alone what is not formatting')
check('a bullet is not emphasis', flatten('* item one\n* item two') === '* item one * item two',
  JSON.stringify(flatten('* item one\n* item two')))
check('stars inside code stay', flatten('`a*b*c` here') === 'a*b*c here',
  JSON.stringify(flatten('`a*b*c` here')))
check('underscores inside a word stay', flatten('the some_var_name thing') === 'the some_var_name thing',
  JSON.stringify(flatten('the some_var_name thing')))
check('numbers survive', flatten('In 2021 he made 3 things') === 'In 2021 he made 3 things',
  JSON.stringify(flatten('In 2021 he made 3 things')))

// ------------------------------------------------------------------ orphans

const doc = [
  '# Spec',
  '',
  '1. **Nome da pasta.** `~/produtos/` ou preferes `~/projects/`?',
  '',
  '<!-- imark quote="Nome da pasta. ~/produtos/ ou preferes ~/projects/?" by="m" at="2026-08-09T10:00Z"',
  'Still open.',
  '-->',
  '',
  'A plain paragraph.',
  '',
  '<!-- imark quote="A plain paragraph." by="m" at="2026-08-08T10:00Z" resolved="2026-08-09T09:00Z"',
  'Already handled.',
  '-->',
  '',
  '<!-- imark quote="a sentence nobody ever wrote" by="m" at="2026-08-08T11:00Z"',
  'Genuinely lost.',
  '-->',
  '',
].join('\n')

console.log('▸ orphan means the words are gone, not that they were formatted')
const notes = parseNotes(doc)
check('the formatted quote is anchored', notes[0].orphan === false)
check('the plain quote is anchored', notes[1].orphan === false)
check('the missing quote is an orphan', notes[2].orphan === true)

// ------------------------------------------------------------------- fences

// A document that shows the comment format used to grow a note by an author
// nobody has met: the reader scanned line by line and a fenced example line is
// the same line as a real one. This project's README is the example.
const example = [
  '```markdown',
  '<!-- imark quote="a phrase" by="john" at="2026-08-02T14:31Z"',
  'An example, not a note.',
  '-->',
  '```',
]

console.log('▸ a note inside a fence is an example, not a note')
check('a fenced example is not a note',
  parseNotes(['# Doc', '', 'Nobody commented on this document.', '', ...example, ''].join('\n')).length === 0)

const mixed = parseNotes([
  '# Doc',
  '',
  'The format looks like this:',
  '',
  ...example,
  '',
  'A paragraph somebody read.',
  '',
  '<!-- imark quote="A paragraph somebody read." by="m" at="2026-08-09T10:00Z"',
  'A real one.',
  '-->',
  '',
].join('\n'))
check('a real note after an example is still read', mixed.length === 1 && mixed[0].body === 'A real one.',
  JSON.stringify(mixed.map((note) => note.body)))

console.log('▸ and an unclosed fence is not a fence')
const unclosed = parseNotes([
  '# Doc',
  '',
  '```markdown',
  '<!-- imark quote="Doc" by="m" at="2026-08-09T10:00Z"',
  'Somebody is still typing the block.',
  '-->',
  '',
  'A paragraph.',
  '',
  '<!-- imark quote="A paragraph." by="m" at="2026-08-09T11:00Z"',
  'Below it, and still wanted.',
  '-->',
  '',
].join('\n'))
check('a fence that never closes swallows nothing', unclosed.length === 2,
  JSON.stringify(unclosed.map((note) => note.body)))

check('a tilde fence is a fence too',
  parseNotes(['# Doc', '', '~~~markdown', ...example.slice(1, 4), '~~~', ''].join('\n')).length === 0)

// A longer fence closes only with a run at least as long, so the inner three
// backticks below are content and the example stays inside one block.
check('a longer fence is not closed by a shorter run',
  parseNotes([
    '# Doc',
    '',
    '````markdown',
    '```markdown',
    ...example.slice(1, 4),
    '```',
    '````',
    '',
  ].join('\n')).length === 0)

// -------------------------------------------------------------- the command

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'imark-notes-'))
const file = path.join(dir, 'SPEC.md')
fs.writeFileSync(file, doc)
const script = new URL('../plugin/scripts/imark.mjs', import.meta.url).pathname
const run = (...args) => execFileSync('node', [script, 'notes', file, ...args], { encoding: 'utf8' })

console.log('▸ notes hands over the work, not the archive')
const plain = run()
check('the resolved note is left out', !plain.includes('Already handled'))
check('the open one is there', plain.includes('Still open'))
check('and so is the orphan, which is still open', plain.includes('Genuinely lost'))
check('the header counts what it hid', plain.includes('2 active, 1 resolved — use --all to see them'),
  plain.split('\n')[0])

const all = run('--all')
check('--all brings the resolved one back', all.includes('Already handled'))
check('marked as resolved', all.includes('✓ Resolved 2026-08-09'))
check('and the header goes quiet again', all.split('\n')[0].includes('(3)'), all.split('\n')[0])

check('--json obeys the same rule', JSON.parse(run('--json')).length === 2)
check('--all --json returns everything', JSON.parse(run('--all', '--json')).length === 3)

fs.writeFileSync(file, '# T\n\nA paragraph.\n\n<!-- imark quote="A paragraph." by="m" at="2026-08-09T10:00Z"\nOne.\n-->\n')
check('a file with nothing resolved keeps the plain count', run().split('\n')[0].includes('(1)'),
  run().split('\n')[0])

fs.writeFileSync(file, '# T\n\nNothing to see.\n')
check('a file with no notes still says so', run().includes('_No notes._'))

fs.rmSync(dir, { recursive: true, force: true })

console.log(failures === 0 ? '\nall good' : `\n${failures} failing`)
process.exit(failures === 0 ? 0 : 1)
