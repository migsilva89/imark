// Tests for turning notes into text anybody can read.
//
//   node Support/test-export.mjs
//
// The exporter is a pure text transform, which is exactly the kind of thing
// that rots quietly. The module registers a resize listener when it loads, so
// there are two stand-ins below and nothing else.

globalThis.window = { addEventListener() {} }
globalThis.document = { querySelector: () => null, querySelectorAll: () => [] }

const { toVisibleText } = await import('../renderer/src/comments.js')

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

console.log(failures === 0 ? '\nall good' : `\n${failures} failing`)
process.exit(failures === 0 ? 0 : 1)
