// The `<!-- imark … -->` comment blocks of a document, found by the rules the
// preview uses (src/comments.js, `extractComments`), so a block drawn as a note
// card in the Live editor is exactly a block the preview shows in its rail.
//
// A copy and not an import: comments.js belongs to the preview page and sets up
// listeners on `window` when it loads, which the editor page has no use for and
// node has no `window` for. The rules are short, and Support/test-live-blocks.mjs
// runs both parsers over the same samples so the two cannot drift apart unseen.
// Kept in step, too, with Comments.swift's `fencedLines`: a note inside a closed
// code fence is an example of the format, and a fence that never closes is not
// a fence.
//
// Nothing here imports anything, so blocks.js and the note card can both use it.

const OPEN = /^\s*<!--\s*imark\b(.*)$/
const ATTR = /(\w+)="([^"]*)"/g

/// A code fence, the way CommonMark draws one: a run of three or more backticks
/// or tildes, indented by no more than three spaces.
const FENCE = /^ {0,3}(`{3,}|~{3,})(.*)$/

/// A fence closes only with its own character and at least as long a run, and
/// carries nothing else after it.
const closesFence = (line, opening) => {
  const fence = FENCE.exec(line)
  return !!fence && fence[1][0] === opening[0] && fence[1].length >= opening.length && fence[2].trim() === ''
}

/// The indices of every line inside a closed code fence, the fences included.
export function fencedLines(lines) {
  const fenced = new Set()
  for (let index = 0; index < lines.length; index += 1) {
    const open = FENCE.exec(lines[index])
    if (!open) continue
    let end = index + 1
    while (end < lines.length && !closesFence(lines[end], open[1])) end += 1
    if (end >= lines.length) continue
    for (let i = index; i <= end; i += 1) fenced.add(i)
    index = end
  }
  return fenced
}

// A closed set, as in the preview: the value comes from somebody's file and
// ends up in an attribute.
const COLOURS = new Set(['amber', 'green', 'blue', 'red'])

const unescapeHTML = (value) =>
  value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&')

/// A note hard-wrapped in the file is one paragraph, not one line per line.
const unwrap = (text) =>
  text
    .split(/\n\s*\n/)
    .map((paragraph) => paragraph.replace(/\s*\n\s*/g, ' ').trim())
    .join('\n\n')

/// The notes in `lines` (the document split on its line breaks), each with the
/// index of its opening and closing line:
///
///   {line, endLine, by, at, quote, scope, nth, colour, resolved, text}
///
/// An unterminated block is somebody's half-typed comment, and is left as text.
export function notesIn(lines) {
  const notes = []
  const fenced = fencedLines(lines)
  for (let index = 0; index < lines.length; index += 1) {
    const open = OPEN.exec(lines[index])
    if (!open || fenced.has(index)) continue
    let end = index
    while (end < lines.length && !lines[end].includes('-->')) end += 1
    if (end >= lines.length) continue

    const attributes = {}
    for (const [, key, value] of open[1].matchAll(ATTR)) attributes[key] = unescapeHTML(value)
    notes.push({
      line: index,
      endLine: end,
      by: attributes.by ?? '',
      at: attributes.at ?? '',
      quote: attributes.quote ?? '',
      scope: attributes.scope === 'file' ? 'file' : 'block',
      nth: Number(attributes.nth) || 1,
      colour: COLOURS.has(attributes.color) ? attributes.color : '',
      resolved: attributes.resolved ?? '',
      text: unwrap(unescapeHTML(lines.slice(index + 1, end).join('\n').trim())),
    })
    index = end
  }
  return notes
}
