#!/usr/bin/env node
// The whole plugin, in one file: read `<!-- imark … -->` notes out of a
// markdown document, build a document for somebody to review, and block until
// they have decided.
//
// The escaping here is the mirror image of Sources/Imark/Comments.swift. If one
// side ever grows a rule the other must grow it too.

import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const OPEN_LINE = /^\s*<!--\s*imark\b/
const CLOSE_LINE = /^\s*-->\s*$/

// The words the reviewer comments on to end the wait. Written into every review
// document, in the document, so nobody has to remember them.
const APPROVE = new Set(['seguir', 'aprovar', 'aprovado', 'approve', 'go', 'ok'])
const REVISE = new Set(['rever', 'reve', 'revisao', 'revise', 'reject', 'nao'])

// ---------------------------------------------------------------- parsing

/** Undo what Comments.swift escaped on the way in. `&amp;` goes last or it
 *  would turn `&amp;quot;` back into a quote character. */
const unescapeAttribute = (value) =>
  value.replaceAll('&quot;', '"').replaceAll('&amp;', '&')

const unescapeBody = (value) =>
  value.replaceAll('--&gt;', '-->').replaceAll('&amp;', '&')

function attributes(line) {
  const out = {}
  const start = line.indexOf('imark') + 'imark'.length
  const source = line.slice(start).replace(/-->\s*$/, '')
  for (const match of source.matchAll(/(\w+)="([^"]*)"/g)) {
    out[match[1]] = unescapeAttribute(match[2])
  }
  return out
}

/**
 * Every note in a document, in the order they appear.
 *
 * Each one carries where it landed as well as what it says: the heading it
 * falls under and the block above it are what let an agent act on "this is
 * wrong" without being told which paragraph.
 */
export function parseNotes(source) {
  const lines = source.split('\n')
  const notes = []
  const inside = new Set()

  for (let i = 0; i < lines.length; i++) {
    if (!OPEN_LINE.test(lines[i])) continue

    const attrs = attributes(lines[i])
    const body = []
    let end = i
    // A note that never closes runs to the end of the file rather than
    // swallowing the parse; the file is somebody's document, not our format.
    for (let j = i + 1; j < lines.length; j++) {
      if (CLOSE_LINE.test(lines[j])) { end = j; break }
      body.push(lines[j])
      end = j
    }
    for (let j = i; j <= end; j++) inside.add(j)

    notes.push({
      quote: attrs.quote ?? '',
      by: attrs.by ?? '',
      at: attrs.at ?? '',
      nth: attrs.nth ? Number(attrs.nth) : 1,
      color: attrs.color ?? '',
      body: unescapeBody(body.join('\n')).trim(),
      line: i + 1,
      heading: '',
      anchor: '',
      orphan: false,
    })
    i = end
  }

  // Prose only — a quote that appears inside another note is not an anchor.
  const prose = lines.map((line, i) => (inside.has(i) ? '' : line))

  for (const note of notes) {
    const at = note.line - 1
    for (let j = at - 1; j >= 0; j--) {
      if (!note.anchor && prose[j].trim()) note.anchor = prose[j].trim()
      if (/^#{1,6}\s/.test(prose[j])) { note.heading = prose[j].replace(/^#+\s*/, '').trim(); break }
    }
    note.orphan = note.quote !== '' && !prose.join('\n').includes(note.quote)
  }

  return notes
}

const when = (iso) => {
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toISOString().slice(0, 10)
}

/** Notes as something an agent can act on: what was said, and about what. */
export function formatNotes(notes) {
  if (notes.length === 0) return '_Sem notas._'
  return notes.map((note, i) => {
    const who = [note.by || 'anónimo', when(note.at)].filter(Boolean).join(', ')
    const head = note.quote ? `sobre “${note.quote}”` : 'sobre o documento'
    const lines = [`### Nota ${i + 1} — ${head}`, `${who} · linha ${note.line}`]
    if (note.heading) lines.push(`Secção: ${note.heading}`)
    if (note.orphan) lines.push('⚠️ Órfã — o texto citado já não existe no documento.')
    if (note.anchor && !note.orphan) lines.push(`> ${note.anchor}`)
    lines.push('', note.body || '_(vazia)_')
    return lines.join('\n')
  }).join('\n\n')
}

// ------------------------------------------------------------- the decision

const fold = (value) =>
  value.normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]/g, '')

/** The reviewer's verdict, or null while there still isn't one. */
function verdict(notes) {
  for (const note of notes) {
    const word = fold(note.quote)
    if (APPROVE.has(word)) return { approved: true, note }
    if (REVISE.has(word)) return { approved: false, note }
  }
  return null
}

const DECISION = `
---

## Decisão

Comenta em **seguir** para aprovar, ou em **rever** para devolver as notas ao
agente. Tudo o resto que comentares acima é feedback e não decide nada — podes
anotar o documento inteiro e só no fim escolher.
`

// ------------------------------------------------------------------ the app

function imarkInstalled() {
  const found = spawnSync('/usr/bin/mdfind', [
    'kMDItemCFBundleIdentifier == "pt.miguelsilva.imark"',
  ], { encoding: 'utf8' })
  if (found.status === 0 && found.stdout.trim()) return true
  return fs.existsSync('/Applications/Imark.app')
}

function openInImark(file) {
  const result = spawnSync('/usr/bin/open', ['-a', 'Imark', file], { encoding: 'utf8' })
  if (result.status !== 0) throw new Error(result.stderr?.trim() || 'open falhou')
}

/**
 * Block until a decision note appears. Polls rather than watches: fs.watch on
 * macOS misses the write-to-temporary-and-rename that Imark does on purpose,
 * which is exactly the write we are waiting for.
 */
async function waitForDecision(file, { timeoutMs = 4 * 60 * 60 * 1000 } = {}) {
  const started = Date.now()
  let seen = ''
  while (Date.now() - started < timeoutMs) {
    try {
      const stat = fs.statSync(file)
      const stamp = `${stat.size}:${stat.mtimeMs}`
      if (stamp !== seen) {
        seen = stamp
        const notes = parseNotes(fs.readFileSync(file, 'utf8'))
        const decided = verdict(notes)
        if (decided) {
          return {
            approved: decided.approved,
            decision: decided.note,
            notes: notes.filter((n) => n !== decided.note),
          }
        }
      }
    } catch { /* the file is mid-rename; look again in half a second */ }
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  return null
}

// -------------------------------------------------------------- review docs

/** `.imark/reviews/` ignores itself, so no project's .gitignore has to change. */
function reviewsDir(root) {
  const dir = path.join(root, '.imark', 'reviews')
  fs.mkdirSync(dir, { recursive: true })
  const ignore = path.join(root, '.imark', '.gitignore')
  if (!fs.existsSync(ignore)) fs.writeFileSync(ignore, '*\n')
  return dir
}

const slug = (value) =>
  fold(value).slice(0, 40) || 'revisao'

function writeReview(root, { title, body, kind }) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
  const file = path.join(reviewsDir(root), `${slug(kind)}-${stamp}.md`)
  const front = [
    '---',
    `title: ${JSON.stringify(title)}`,
    `date: ${new Date().toISOString()}`,
    '---',
    '',
    '',
  ].join('\n')
  fs.writeFileSync(file, `${front}${body}\n${DECISION}`)
  return file
}

function git(root, args) {
  try {
    return execFileSync('/usr/bin/git', args, { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  } catch (error) {
    throw new Error(`git ${args.join(' ')} falhou: ${error.stderr?.trim() || error.message}`)
  }
}

/** One fenced block per file, because a note anchors inside a code block and
 *  a single 4000-line diff gives the outline nothing to hold on to. */
function diffDocument(root, args, { untracked = false } = {}) {
  const names = git(root, ['diff', '--name-only', ...args]).split('\n').filter(Boolean)
  const blocks = names.map((name) => {
    const patch = git(root, ['diff', ...args, '--', name]).trimEnd()
    return `## ${name}\n\n\`\`\`diff\n${patch}\n\`\`\``
  })

  // A new file is the change most worth reviewing and the one `git diff` says
  // nothing about. --no-index against /dev/null gives it the same shape as
  // everything else, so it reads the same in the document.
  if (untracked) {
    for (const name of git(root, ['ls-files', '--others', '--exclude-standard']).split('\n').filter(Boolean)) {
      // --no-index exits 1 whenever there is a difference, which here is always,
      // so the patch arrives on the error rather than the return value.
      let patch = ''
      try {
        patch = execFileSync('/usr/bin/git', ['diff', '--no-index', '--', '/dev/null', name], {
          cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
        })
      } catch (error) { patch = error.stdout || '' }
      names.push(name)
      blocks.push(`## ${name} (novo)\n\n\`\`\`diff\n${patch.trimEnd()}\n\`\`\``)
    }
  }

  if (names.length === 0) return null
  return `# Alterações\n\n${names.length} ficheiro(s).\n\n${blocks.join('\n\n')}`
}

// ------------------------------------------------------------------- output

const say = (text) => process.stdout.write(`${text}\n`)

function report(file, result) {
  say(`Documento: ${file}`)
  if (!result) { say('\nSem decisão — o tempo de espera acabou.'); return }
  say(`\nDecisão: ${result.approved ? 'SEGUIR' : 'REVER'}`)
  if (result.decision.body) say(`\n${result.decision.body}`)
  say(`\n## Notas (${result.notes.length})\n\n${formatNotes(result.notes)}`)
}

// ----------------------------------------------------------------- commands

async function cmdNotes(argv) {
  const file = argv.find((a) => !a.startsWith('-'))
  if (!file) throw new Error('uso: imark.mjs notes <ficheiro.md> [--json]')
  const notes = parseNotes(fs.readFileSync(file, 'utf8'))
  if (argv.includes('--json')) say(JSON.stringify(notes, null, 2))
  else say(`# Notas em ${path.basename(file)} (${notes.length})\n\n${formatNotes(notes)}`)
}

async function cmdReview(argv) {
  const root = process.cwd()
  const wait = !argv.includes('--no-wait')
  const files = argv.filter((a) => !a.startsWith('-'))

  let document
  let kind
  // No arguments means the working tree: the common case, and the one where
  // reading stdin instead would hang a slash command with nothing to read.
  if (argv.includes('--diff') || (files.length === 0 && !argv.includes('--staged') && !argv.includes('--stdin'))) {
    // Against HEAD, not the index: "what I have not committed" is one question,
    // and splitting it in two by whether something happens to be staged is not
    // a distinction anybody reviewing wants to make.
    document = diffDocument(root, ['HEAD'], { untracked: true })
    kind = 'diff'
    if (!document) { say('Nada por commitar — não há o que rever.'); return }
  } else if (argv.includes('--staged')) {
    document = diffDocument(root, ['--cached'])
    kind = 'staged'
    if (!document) { say('Nada em staging — não há o que rever.'); return }
  } else if (files.length > 0) {
    document = files.map((file) => {
      const text = fs.readFileSync(file, 'utf8')
      return file.endsWith('.md')
        ? `# ${file}\n\n${text}`
        : `# ${file}\n\n\`\`\`${path.extname(file).slice(1)}\n${text}\n\`\`\``
    }).join('\n\n---\n\n')
    kind = path.basename(files[0])
  } else {
    document = fs.readFileSync(0, 'utf8')
    kind = 'nota'
    if (!document.trim()) throw new Error('nada no stdin e nenhum ficheiro dado')
  }

  const title = argv.includes('--title') ? argv[argv.indexOf('--title') + 1] : `Revisão — ${kind}`
  const file = writeReview(root, { title, body: document, kind })

  if (!imarkInstalled()) {
    say(`O Imark não está instalado. O documento ficou em ${file}.`)
    return
  }
  openInImark(file)
  if (!wait) { say(`Aberto no Imark: ${file}`); return }
  say(`Aberto no Imark: ${file}\nÀ espera de uma nota em "seguir" ou "rever"…`)
  report(file, await waitForDecision(file))
}

/** The ExitPlanMode gate. Off unless IMARK_PLAN_REVIEW is set: ExitPlanMode is
 *  crowded territory, and two blocking hooks on one event is a hung session. */
async function cmdPlanHook() {
  const raw = fs.readFileSync(0, 'utf8')
  const pass = () => say('{}')

  if (!process.env.IMARK_PLAN_REVIEW) return pass()

  let event
  try { event = JSON.parse(raw) } catch { return pass() }

  const plan = event?.tool_input?.plan ?? ''
  if (!plan.trim()) return pass()
  if (!imarkInstalled()) {
    process.stderr.write('imark: a app não está instalada — o plano segue sem revisão.\n')
    return pass()
  }

  const root = event.cwd || process.cwd()
  const file = writeReview(root, { title: 'Plano', body: plan, kind: 'plano' })
  try { openInImark(file) } catch (error) {
    process.stderr.write(`imark: ${error.message}\n`)
    return pass()
  }

  const result = await waitForDecision(file)
  // Only a timeout falls through to the normal prompt. Approving in the app and
  // then being asked again in the terminal would make the review pointless.
  if (!result) return pass()

  if (result.approved) {
    const notes = result.notes.length > 0
      ? `A revisão no Imark aprovou o plano, com notas a ter em conta:\n\n${formatNotes(result.notes)}`
      : ''
    return say(JSON.stringify({
      ...(notes && { systemMessage: notes }),
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: { behavior: 'allow' },
      },
    }))
  }

  const feedback = [
    'A revisão no Imark pediu alterações ao plano.',
    result.decision.body ? `\n${result.decision.body}` : '',
    `\n${formatNotes(result.notes)}`,
    `\nO documento anotado está em ${file}.`,
  ].join('\n')

  say(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PermissionRequest',
      decision: { behavior: 'deny', message: feedback },
    },
  }))
}

// --------------------------------------------------------------------- main

const [command, ...argv] = process.argv.slice(2)

try {
  switch (command) {
    case 'notes': await cmdNotes(argv); break
    case 'review': await cmdReview(argv); break
    case 'plan-hook': await cmdPlanHook(); break
    case 'open': openInImark(argv[0]); break
    default:
      say('uso: imark.mjs <notes|review|open|plan-hook> …')
      process.exit(command ? 1 : 0)
  }
} catch (error) {
  process.stderr.write(`imark: ${error.message}\n`)
  process.exit(1)
}
