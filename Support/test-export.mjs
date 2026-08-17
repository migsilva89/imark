// Tests for turning notes into text anybody can read.
//
//   node Support/test-export.mjs
//
// The exporter is a pure text transform, which is exactly the kind of thing
// that rots quietly. The module registers a resize listener when it loads, so
// there are two stand-ins below and nothing else.

globalThis.window = { addEventListener() {} }
globalThis.document = { querySelector: () => null, querySelectorAll: () => [] }

const { toVisibleText, extractComments } = await import('../renderer/src/comments.js')

let failures = 0

const check = (name, condition, detail = '') => {
  if (condition) {
    console.log(`OK   ${name}`)
  } else {
    failures += 1
    console.log(`FAIL ${name}  ${detail}`)
  }
}

/* ------------------------------------------------------------------ basic */
{
  const out = toVisibleText(
    [
      'The deadline is generous but achievable.',
      '',
      '<!-- imark quote="generous but achievable" by="john" at="2026-08-02T14:31Z"',
      'Achievable with which team?',
      '-->',
      '',
      'Rollback writes a reversal record.',
    ].join('\n'),
  )

  check('nothing of the block survives', !out.includes('<!--') && !out.includes('-->'))
  check('the document is untouched', out.includes('The deadline is generous but achievable.'))
  check('and so is what came after', out.includes('Rollback writes a reversal record.'))
  check('the author is in the quote', out.includes('**john,'))
  check('so is the phrase it is about', out.includes('on *“generous but achievable”*'))
  check('the note is quoted', out.includes('> Achievable with which team?'))
  check('every line of the block is a quote line', out.split('\n').filter((l) => l.startsWith('>')).length === 3)
}

/* --------------------------------------------------- a note over two paragraphs */
{
  const out = toVisibleText(
    ['Text.', '', '<!-- imark quote="Text" by="m" at="2026-08-02T14:31Z"', 'First.', '', 'Second.', '-->'].join('\n'),
  )
  const quoted = out.split('\n').filter((line) => line.startsWith('>'))
  check('a blank line inside the note stays a blank quote line', quoted.includes('>'))
  check('both paragraphs survive', out.includes('> First.') && out.includes('> Second.'))
}

/* ------------------------------------------------------ hard-wrapped in the file */
{
  const out = toVisibleText(
    ['Text.', '', '<!-- imark quote="Text" by="m" at="x"', 'one line', 'wrapped by hand', '-->'].join('\n'),
  )
  check('a hard-wrapped note is one paragraph again', out.includes('> one line wrapped by hand'))
}

/* --------------------------------------------------------------- no comments */
{
  const source = '# Just a document\n\nWith nothing to say about it.\n'
  check('a file with no notes comes back unchanged', toVisibleText(source) === source)
}

/* ------------------------------------------------------------ half-typed block */
{
  const source = '# Title\n\n<!-- imark quote="Title" by="m" at="x"\nsomebody is still typing\n'
  check('an unterminated block is left alone', toVisibleText(source) === source)
}

/* ---------------------------------------------------------- escaped characters */
{
  const out = toVisibleText(
    ['Text.', '', '<!-- imark quote="&quot;quoted&quot; &amp; more" by="m" at="x"', 'an arrow --&gt; here', '-->'].join('\n'),
  )
  check('the quote is unescaped for reading', out.includes('on *“"quoted" & more”*'), out)
  check('and so is the note', out.includes('an arrow --> here'), out)
}

/* -------------------------------------------------------- a fenced example */
// A document that teaches the format — this project's README does — used to grow
// a note nobody wrote: a dot in the margin, a line in the count, and an example
// exported as if it were somebody's feedback. Both readers of the file have to
// agree about that, so `extractComments` is checked here beside the exporter.
{
  const example = [
    '```markdown',
    '<!-- imark quote="a phrase" by="john" at="2026-08-02T14:31Z"',
    'An example, not a note.',
    '-->',
    '```',
  ]

  const fenced = ['# Doc', '', 'Nobody commented on this document.', '', ...example, ''].join('\n')
  check('a fenced example is not a note', extractComments(fenced).comments.length === 0)
  check('and the exporter leaves it as it found it', toVisibleText(fenced) === fenced)

  const after = [
    ...example,
    '',
    'A paragraph somebody read.',
    '',
    '<!-- imark quote="A paragraph somebody read." by="m" at="2026-08-02T14:31Z"',
    'A real one.',
    '-->',
  ].join('\n')
  const found = extractComments(after).comments
  check('a real note after an example is still read', found.length === 1 && found[0].text === 'A real one.',
    JSON.stringify(found.map((note) => note.text)))
  check('the example survives the export', toVisibleText(after).includes('```markdown'))

  const unclosed = [
    '# Doc',
    '',
    '```markdown',
    '<!-- imark quote="Doc" by="m" at="2026-08-02T14:31Z"',
    'Somebody is still typing the block.',
    '-->',
    '',
    'A paragraph.',
    '',
    '<!-- imark quote="A paragraph." by="m" at="2026-08-02T14:31Z"',
    'Below it, and still wanted.',
    '-->',
  ].join('\n')
  check('a fence that never closes swallows nothing', extractComments(unclosed).comments.length === 2,
    JSON.stringify(extractComments(unclosed).comments.map((note) => note.text)))

  const tildes = ['# Doc', '', '~~~markdown', ...example.slice(1, 4), '~~~', ''].join('\n')
  check('a tilde fence is a fence too', extractComments(tildes).comments.length === 0)

  const longer = ['# Doc', '', '````markdown', '```markdown', ...example.slice(1, 4), '```', '````', ''].join('\n')
  check('a longer fence is not closed by a shorter run', extractComments(longer).comments.length === 0)
}

console.log(failures === 0 ? '\nall good' : `\n${failures} failing`)
process.exit(failures === 0 ? 0 : 1)
