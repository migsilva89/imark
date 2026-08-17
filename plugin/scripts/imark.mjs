#!/usr/bin/env node
// The whole plugin, in one file: read `<!-- imark … -->` notes out of a
// markdown document, build a document for somebody to review, and block until
// they have decided.
//
// The escaping here is the mirror image of Sources/Imark/Comments.swift. If one
// side ever grows a rule the other must grow it too.

import { spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const OPEN_LINE = /^\s*<!--\s*imark\b/
const CLOSE_LINE = /^\s*-->\s*$/

// A code fence, the way CommonMark draws one: three or more backticks or tildes,
// indented by no more than three spaces. The run is captured because a fence
// closes only with the same character and at least as long a run.
const FENCE_LINE = /^ {0,3}(`{3,}|~{3,})(.*)$/

const closesFence = (line, opening) => {
  const fence = FENCE_LINE.exec(line)
  return (
    !!fence &&
    fence[1][0] === opening[0] &&
    fence[1].length >= opening.length &&
    // Only an opening fence may carry an info string.
    fence[2].trim() === ''
  )
}

/**
 * The lines of every closed code fence, the fences included.
 *
 * A note inside one is an example of the format, not a note. Without this a
 * document that teaches the format hands the agent feedback nobody wrote — and a
 * fenced example whose `quote=` happens to be one of the deciding words would
 * end a review with nobody having pressed anything.
 *
 * A fence that never closes is not a fence, it is somebody mid-sentence: taking
 * it at its word would drop every real note below it in silence. The renderer
 * asks the same question of the same file in renderer/src/comments.js, so the
 * two have to answer it alike.
 */
function fencedLines(lines) {
  const fenced = new Set()
  for (let i = 0; i < lines.length; i++) {
    const open = FENCE_LINE.exec(lines[i])
    if (!open) continue

    let end = i + 1
    while (end < lines.length && !closesFence(lines[end], open[1])) end++
    if (end >= lines.length) continue

    for (let j = i; j <= end; j++) fenced.add(j)
    i = end
  }
  return fenced
}

// The words the reviewer comments on to end the wait. Written into every review
// document, in the document, so nobody has to remember them.
//
// Only these two, and they are the two the document names. This list once held
// go, ok, ship, no, changes and rework as well — ordinary English, any of which
// a reviewer might quote to ask a question about. Commenting on the word "go"
// in "we go through the tables one at a time" approved the review, and because
// the deciding note is taken out of the feedback, the question disappeared with
// it. A word that ends a review has to be a word nobody types by accident.
const APPROVE = new Set(['approve', 'approved'])
const REVISE = new Set(['revise', 'revised'])

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
 * A line of markdown as the reader saw it, for comparing one against the other.
 *
 * `quote=` holds the *rendered* text — no `**`, no backticks, a link reduced to
 * its words — while the anchor check looks for it in the raw source. The two
 * have to be flattened the same way or every emphasised phrase reads as an
 * orphan, and an orphan tells the agent to stop and ask instead of acting.
 *
 * This started as a lone `\s+` collapse, for a paragraph the file wraps over
 * two lines and the quote carries as one. Inline formatting was the same bug a
 * step further on. Both live in this one function now so they cannot drift
 * apart again — every future rule belongs here too, on both sides at once.
 */
export function flatten(text) {
  const code = []
  return text
    // Code spans first, contents parked out of reach: a `*` between backticks
    // is a character, not emphasis, and stripping it would change the words.
    .replace(/(`+)([^`]*?)\1/g, (_, __, inner) => `\u0000${code.push(inner) - 1}\u0000`)
    // A link reads as its text. Images too — the alt text is what is spoken.
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/~~([\s\S]+?)~~/g, '$1')
    // The delimiter has to hug its words: `**a**` is bold, but a `* ` opening a
    // list item is a bullet, and pairing two of those across a list would join
    // lines that never touched.
    .replace(/\*\*(?!\s)([\s\S]+?)(?<!\s)\*\*/g, '$1')
    .replace(/\*(?!\s)([\s\S]+?)(?<!\s)\*/g, '$1')
    // Underscores only outside a word, or `some_var_name` loses its middle.
    .replace(/(?<![\w])__(?!\s)([\s\S]+?)(?<!\s)__(?![\w])/g, '$1')
    .replace(/(?<![\w])_(?!\s)([\s\S]+?)(?<!\s)_(?![\w])/g, '$1')
    .replace(/\u0000(\d+)\u0000/g, (_, i) => code[Number(i)])
    .replace(/\s+/g, ' ')
    .trim()
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
  const fenced = fencedLines(lines)

  for (let i = 0; i < lines.length; i++) {
    if (!OPEN_LINE.test(lines[i]) || fenced.has(i)) continue

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
      scope: attrs.scope === 'file' ? 'file' : 'block',
      by: attrs.by ?? '',
      at: attrs.at ?? '',
      nth: attrs.nth ? Number(attrs.nth) : 1,
      color: attrs.color ?? '',
      // A date, stamped by whoever acted on the note. A resolved note stays in
      // the document as the record of what was asked; it is no longer feedback.
      resolved: attrs.resolved ?? '',
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

  const flat = flatten(prose.join('\n'))

  for (const note of notes) {
    const at = note.line - 1
    for (let j = at - 1; j >= 0; j--) {
      if (!note.anchor && prose[j].trim()) note.anchor = prose[j].trim()
      if (/^#{1,6}\s/.test(prose[j])) { note.heading = prose[j].replace(/^#+\s*/, '').trim(); break }
    }
    note.orphan = note.scope !== 'file'
      && note.quote !== ''
      && !flat.includes(flatten(note.quote))
  }

  return notes
}

const when = (iso) => {
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toISOString().slice(0, 10)
}

/** Notes as something an agent can act on: what was said, and about what. */
export function formatNotes(notes) {
  if (notes.length === 0) return '_No notes._'
  return notes.map((note, i) => {
    const who = [note.by || 'anonymous', when(note.at)].filter(Boolean).join(', ')
    const head = note.scope === 'file'
      ? 'on the whole document'
      : (note.quote ? `on “${note.quote}”` : 'on the block above')
    const lines = [`### Note ${i + 1} — ${head}`, `${who} · line ${note.line}`]
    if (note.resolved) lines.push(`✓ Resolved ${when(note.resolved)}`)
    if (note.heading) lines.push(`Section: ${note.heading}`)
    if (note.orphan) lines.push('⚠️ Orphan — the quoted text is no longer in the document.')
    // A file note has nothing above it worth quoting — the front matter fence,
    // usually — and it is not about whatever it happens to follow.
    if (note.anchor && !note.orphan && note.scope !== 'file') lines.push(`> ${note.anchor}`)
    lines.push('', note.body || '_(empty)_')
    return lines.join('\n')
  }).join('\n\n')
}

// ------------------------------------------------------------- the decision

const fold = (value) =>
  value.normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]/g, '')

const verdictWord = (note) => APPROVE.has(fold(note.quote)) || REVISE.has(fold(note.quote))

/** The reviewer's verdict, or null while there still isn't one. */
function verdict(notes) {
  for (const note of notes) {
    const word = fold(note.quote)
    if (APPROVE.has(word)) return { approved: true, note }
    if (REVISE.has(word)) return { approved: false, note }
  }
  return null
}

/**
 * What the agent is told when the review comes back.
 *
 * Written as an instruction rather than a report. An earlier version opened
 * with "the review asked for changes", and that reads to an agent as an
 * opinion it can weigh against its own plan — which is exactly the argument
 * the reviewer already had and won.
 */
function sendBackFeedback(result, file, toolName) {
  return [
    'THE REVIEWER DID NOT APPROVE THIS. Do not rewrite anything yet.',
    '',
    'Work through this in order. Do not skip to the last step.',
    '',
    '1. Read every note below. Open the annotated document when a note needs the',
    `   text around it: ${file}`,
    '2. Before changing anything, reply to the reviewer. Take the notes one at a',
    '   time, quote the words each is attached to, and say what you understood and',
    '   what you intend to do about it.',
    '3. If a note is ambiguous, if two of them pull in different directions, or if',
    '   acting on one would break something else — ask. Put the questions in that',
    '   same message, together. Do not guess, and do not decide for the reviewer.',
    '4. If you think a note is wrong, say so and say why. Do not drop it in silence,',
    '   and do not quietly do something you believe is a mistake.',
    '5. When you act on a note, mark it done instead of deleting it: add',
    '   resolved="<date>" to its opening `<!-- imark` line. The note is the',
    '   reviewer\'s record of what was asked; resolved is yours of having done it.',
    `6. Only once every note is answered, and any question you asked has an answer,`,
    `   rewrite and call ${toolName} again.`,
    '',
    'Two things that are not negotiable: do not resubmit the same thing unchanged,',
    'and treat a note marked orphan as having lost its anchor — the paragraph above',
    'it is not reliably what it refers to, so ask instead of assuming.',
    '',
    result.decision.body || '',
    '',
    formatNotes(result.notes),
  ].join('\n')
}

const DECISION = `
---

## Decision

**Approve** and **Send Back**, at the top of the window, end this review.
*Send Back* hands the agent everything you commented on; *Approve* lets it
carry on.

Comment wherever you like until then — nothing you write decides anything.

If you are reading this in a build of Imark without those buttons, commenting on
the word **approve** or the word **revise** does the same thing.
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
  // The round-trip test drives the decision from Swift rather than from a
  // click, so it needs the waiting without a window appearing on somebody's
  // screen every time the suite runs.
  if (process.env.IMARK_TEST_NO_OPEN) return
  const result = spawnSync('/usr/bin/open', ['-a', 'Imark', file], { encoding: 'utf8' })
  if (result.status !== 0) throw new Error(result.stderr?.trim() || 'open failed')
}

/**
 * Block until a decision note appears. Polls rather than watches: fs.watch on
 * macOS misses the write-to-temporary-and-rename that Imark does on purpose,
 * which is exactly the write we are waiting for.
 */
async function waitForDecision(file, request, { timeoutMs = 4 * 60 * 60 * 1000 } = {}) {
  const started = Date.now()
  let seen = ''

  // What the agent acts on. Verdict words are machinery, not feedback; a note
  // already marked resolved is a record of a previous round, already dealt with.
  const feedback = (notes) => notes.filter((note) => !verdictWord(note) && !note.resolved)

  while (Date.now() - started < timeoutMs) {
    // The buttons in the app's toolbar, which is how anybody finds this. They
    // write into the handshake directory rather than into the document, so the
    // notes stay the only thing in the file the reviewer put there.
    try {
      const answer = JSON.parse(fs.readFileSync(request.decision, 'utf8'))
      const notes = parseNotes(fs.readFileSync(file, 'utf8'))
      return {
        approved: answer.decision === 'approve',
        decision: { body: '' },
        notes: feedback(notes),
      }
    } catch { /* no decision yet */ }

    // The words, still — for a document opened in a build of Imark without the
    // toolbar, and because a review that only one version of one app can finish
    // is not the file-is-the-bridge thing this was supposed to be.
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
            notes: feedback(notes.filter((n) => n !== decided.note)),
          }
        }
      }
    } catch { /* the file is mid-rename; look again in half a second */ }

    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  return null
}

// -------------------------------------------------------------- the handshake

// A review no longer copies the document. The file the reviewer annotates is
// the file — notes land in it, stay in it, and travel with it, which is the
// whole thesis of the app. What passes between the script and the app is only
// the request and the decision, and those live here: two small JSON files in a
// directory neither project ever sees, deleted the moment they are read.
//
// The nonce is what makes two reviews two reviews. The old archive keyed
// everything on a per-second timestamp, and a name collision made the second
// review find the first one's decision already on disk — an approval nobody
// gave. A fresh nonce per invocation has no history to find.
function pendingDir() {
  const dir = process.env.IMARK_PENDING_DIR
    || path.join(os.homedir(), '.imark', 'pending')
  fs.mkdirSync(dir, { recursive: true })
  // A crashed script leaves its request behind. Anything old enough that
  // nobody can still be waiting on it is litter, not state.
  const cutoff = Date.now() - 2 * 24 * 60 * 60 * 1000
  for (const name of fs.readdirSync(dir)) {
    const file = path.join(dir, name)
    try { if (fs.statSync(file).mtimeMs < cutoff) fs.rmSync(file) } catch { /* raced */ }
  }
  return dir
}

/**
 * The requests an earlier round left behind for this same file.
 *
 * A review nobody finished — the session ended, the agent was interrupted,
 * the terminal went — leaves its request on disk with no decision beside it,
 * and the app cannot tell that corpse from somebody actually waiting. Two of
 * them for one document is how a decision went to a script that was no longer
 * listening while the live one waited for four hours. The app now answers the
 * newest, and this clears the rest so there is nothing to be confused by.
 */
function forgetEarlierRequests(dir, target) {
  const resolved = fs.realpathSync(target)
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith('.json') || name.endsWith('.decision.json')) continue
    const file = path.join(dir, name)
    try {
      const payload = JSON.parse(fs.readFileSync(file, 'utf8'))
      if (!payload.file) continue
      if (fs.realpathSync(payload.file) !== resolved) continue
      fs.rmSync(file, { force: true })
      fs.rmSync(path.join(dir, `${name.slice(0, -'.json'.length)}.decision.json`), { force: true })
    } catch { /* unreadable, or gone while we looked: not ours to keep */ }
  }
}

/** Announce to the app that opening `target` is a review, not a read. */
function requestReview(target) {
  const dir = pendingDir()
  forgetEarlierRequests(dir, target)
  for (let attempt = 0; attempt < 3; attempt++) {
    const nonce = crypto.randomBytes(6).toString('hex')
    const file = path.join(dir, `${nonce}.json`)
    try {
      fs.writeFileSync(file, `${JSON.stringify({
        file: target,
        at: new Date().toISOString(),
        by: process.env.CLAUDE_CODE_ENTRYPOINT ? 'Claude Code' : 'terminal',
      }, null, 2)}\n`, { flag: 'wx' })
      return { file, decision: path.join(dir, `${nonce}.decision.json`) }
    } catch { /* the one-in-2⁴⁸ collision; roll again */ }
  }
  throw new Error('could not register the review')
}

function withdraw(request) {
  fs.rmSync(request.file, { force: true })
  fs.rmSync(request.decision, { force: true })
}

/**
 * Take the request down if this process is killed rather than answered.
 *
 * A review is a long wait, and the thing waiting is a coding agent inside a
 * session somebody can close at any moment. Withdrawing only on the happy path
 * meant every abandoned round left a request on disk for the app to answer
 * later instead of the live one.
 */
function withdrawWhenKilled(request) {
  // The codes a shell reports for a signal, so being killed still reads as
  // being killed rather than as a review that finished.
  for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
    process.once(signal, () => {
      withdraw(request)
      process.exit(code)
    })
  }
}

/**
 * A document, ready to be pasted inside another one.
 *
 * Its front matter has to go: fenced between `---` in the middle of a file it
 * is no longer front matter, it is a setext heading — `title: …` with a line of
 * dashes under it — which put the reviewed file's metadata in the outline as a
 * clipped two-line entry nobody could read. Kept as a fenced block instead, so
 * it is still there to read and cannot become anything.
 */
function embed(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text)
  if (!match) return text
  return `\`\`\`yaml\n${match[1]}\n\`\`\`\n\n${text.slice(match[0].length)}`
}

/**
 * A document that exists only to be reviewed — a plan from stdin, or several
 * files that need a single window. It lives beside the handshake files and is
 * deleted with them; there is no original for the notes to belong to.
 *
 * The `imark: review` front matter stays on these: a build of Imark from
 * before the handshake still shows its buttons for them.
 */
function writeEphemeral({ title, body }) {
  const file = path.join(pendingDir(), `${crypto.randomBytes(6).toString('hex')}.md`)
  const front = [
    '---',
    'imark: review',
    `title: ${JSON.stringify(title)}`,
    `date: ${new Date().toISOString()}`,
    `by: ${process.env.CLAUDE_CODE_ENTRYPOINT ? 'Claude Code' : 'terminal'}`,
    '---',
    '',
    '',
  ].join('\n')
  fs.writeFileSync(file, `${front}${body}\n${DECISION}`)
  return file
}

// ------------------------------------------------------------------- output

const say = (text) => process.stdout.write(`${text}\n`)

function report(file, result, { ephemeral = false } = {}) {
  if (!result) return say(`No decision — the wait timed out. The document is at ${file}.`)

  if (!result.approved) return say(sendBackFeedback(result, file, 'this command'))

  say('APPROVED — the reviewer accepted this.')
  if (result.notes.length > 0) {
    say(`\nThey still left ${result.notes.length} note(s). Act on them as you go, `
      + 'and say what you did for each.')
    if (!ephemeral) {
      say('When one is done, mark it rather than deleting it: add '
        + 'resolved="<date>" to its opening `<!-- imark` line.')
    }
    say('')
    say(formatNotes(result.notes))
  }
  if (!ephemeral) say(`\nThe reviewer's notes are in the document itself: ${file}.`)
}

// ----------------------------------------------------------------- commands

/**
 * The notes in a document — by default only the ones still asking for
 * something.
 *
 * A resolved note stays in the file forever, which is the point: it is the
 * record of what was asked. But handing all of them back on every round buries
 * the two that matter under twenty that are done, and invites an agent to
 * solve the same thing twice. `--all` is there for when the history is what
 * you actually want.
 */
async function cmdNotes(argv) {
  const file = argv.find((a) => !a.startsWith('-'))
  if (!file) throw new Error('usage: imark.mjs notes <file.md> [--all] [--json]')

  const notes = parseNotes(fs.readFileSync(file, 'utf8'))
  const all = argv.includes('--all')
  const shown = all ? notes : notes.filter((note) => !note.resolved)
  const hidden = notes.length - shown.length

  if (argv.includes('--json')) return say(JSON.stringify(shown, null, 2))

  // The count says what was left out as well as what is here, so an agent
  // that needs the history knows it exists and how to ask for it.
  const count = hidden > 0
    ? `${shown.length} active, ${hidden} resolved — use --all to see them`
    : `${shown.length}`
  say(`# Notes in ${path.basename(file)} (${count})\n\n${formatNotes(shown)}`)
}

async function cmdReview(argv) {
  const wait = !argv.includes('--no-wait')
  const files = argv.filter((a) => !a.startsWith('-'))

  // The reviewer's notes land in this file and stay there. For a real document
  // that is the document itself; only something with no file of its own — a
  // plan on stdin, a bundle of several files — gets a stand-in, deleted with
  // the handshake because there is nowhere for its notes to live on.
  let target
  let ephemeral = false

  if (files.length > 0) {
    // Markdown only. Imark is a markdown reader, and a review of a `.js` here
    // would be prose typography wrapped around something that has no prose in
    // it. Reviewing code is a real job and this is not the tool for it.
    const wrong = files.filter((file) => !file.endsWith('.md'))
    if (wrong.length > 0) {
      throw new Error(`markdown only: ${wrong.join(', ')}`)
    }
    if (files.length === 1) {
      target = path.resolve(files[0])
      fs.accessSync(target, fs.constants.R_OK | fs.constants.W_OK)
    } else {
      const title = argv.includes('--title')
        ? argv[argv.indexOf('--title') + 1]
        : `Review — ${path.parse(files[0]).name}`
      const body = files
        .map((file) => `# ${file}\n\n${embed(fs.readFileSync(file, 'utf8'))}`)
        .join('\n\n---\n\n')
      target = writeEphemeral({ title, body })
      ephemeral = true
    }
  } else {
    // Reading fd 0 from a terminal blocks forever, so the usage line has to
    // come before the read rather than after it: the version that checked for
    // empty input afterwards simply hung.
    if (process.stdin.isTTY) {
      throw new Error('usage: imark.mjs review <file.md> [--no-wait]')
    }
    const document = fs.readFileSync(0, 'utf8')
    if (!document.trim()) {
      throw new Error('usage: imark.mjs review <file.md> [--no-wait]')
    }
    const title = argv.includes('--title') ? argv[argv.indexOf('--title') + 1] : 'Review — note'
    target = writeEphemeral({ title, body: document })
    ephemeral = true
  }

  if (!imarkInstalled()) {
    say(`Imark is not installed. The document is at ${target}.`)
    return
  }

  const request = requestReview(target)
  withdrawWhenKilled(request)
  try {
    openInImark(target)
  } catch (error) {
    withdraw(request)
    if (ephemeral) fs.rmSync(target, { force: true })
    throw error
  }
  if (!wait) { say(`Opened in Imark: ${target}`); return }
  say(`Opened in Imark: ${target}\nWaiting for Approve or Send Back in the window…`)

  const result = await waitForDecision(target, request)
  withdraw(request)
  // A sent-back ephemeral stays: the feedback points the agent at its notes.
  // The pending purge sweeps it up once nobody can still be reading it.
  if (ephemeral && result?.approved) fs.rmSync(target, { force: true })
  report(target, result, { ephemeral })
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
    process.stderr.write('imark: the app is not installed — the plan goes on unreviewed.\n')
    return pass()
  }

  // A plan has no file of its own — it arrives in the hook's stdin — so it is
  // the one review that still goes through a stand-in document.
  const file = writeEphemeral({ title: 'Plan', body: plan })
  const request = requestReview(file)
  withdrawWhenKilled(request)
  try { openInImark(file) } catch (error) {
    process.stderr.write(`imark: ${error.message}\n`)
    withdraw(request)
    fs.rmSync(file, { force: true })
    return pass()
  }

  const result = await waitForDecision(file, request)
  withdraw(request)
  if (result?.approved) fs.rmSync(file, { force: true })
  // Only a timeout falls through to the normal prompt. Approving in the app and
  // then being asked again in the terminal would make the review pointless.
  if (!result) return pass()

  if (result.approved) {
    const notes = result.notes.length > 0
      ? `The review approved the plan, with notes to take into account:\n\n${formatNotes(result.notes)}`
      : ''
    return say(JSON.stringify({
      ...(notes && { systemMessage: notes }),
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: { behavior: 'allow' },
      },
    }))
  }

  const feedback = sendBackFeedback(result, file, 'ExitPlanMode')

  say(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PermissionRequest',
      decision: { behavior: 'deny', message: feedback },
    },
  }))
}

// --------------------------------------------------------------------- main

// Only when run as a command. This file exports its parser so tests can reach
// it, and without the guard importing it ran the dispatch, printed the usage
// line, and left the exports unusable for the thing they exist for.
const invoked = process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href

if (invoked) {
  const [command, ...argv] = process.argv.slice(2)

  try {
    switch (command) {
      case 'notes': await cmdNotes(argv); break
      case 'review': await cmdReview(argv); break
      case 'plan-hook': await cmdPlanHook(); break
      case 'open': openInImark(argv[0]); break
      default:
        say('usage: imark.mjs <notes|review|open|plan-hook> …')
        process.exit(command ? 1 : 0)
    }
  } catch (error) {
    process.stderr.write(`imark: ${error.message}\n`)
    process.exit(1)
  }
}
