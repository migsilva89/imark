// Tests for the LaTeX that reaches KaTeX.
//
//   node Support/test-math.mjs
//
// The formula in the issue that started this — a display equation broken over
// two lines — rendered as raw text because the math was picked up after
// markdown-it had already read `\mathbf{K}_e^L` as emphasis. So what is checked
// here is the parse: that the delimiters are claimed during the Markdown pass,
// and that the three things that must NOT become math still do not.

// Reached by path because the dependencies live under renderer/, not beside
// this file — the plugin itself resolves its own imports from there.
import MarkdownIt from '../renderer/node_modules/markdown-it/index.mjs'
import math from '../renderer/src/math.js'

const md = new MarkdownIt({ html: true, linkify: true, typographer: true }).use(math, {
  lines: (token) => (token.map ? ` data-line="${token.map[0]},${token.map[1]}"` : ''),
})

let failures = 0

const check = (name, condition, detail = '') => {
  if (condition) {
    console.log(`OK   ${name}`)
  } else {
    failures += 1
    console.log(`FAIL ${name}  ${detail}`)
  }
}

/* ------------------------------------------------ display, across lines */
{
  const out = md.render(['$$ \\mathbf{K}_e^L = \\mathbf{K}_m^L', '+ \\mathbf{K}_b^L $$'].join('\n'))

  check('the equation is rendered', out.includes('class="katex'), out)
  check('as a display block', out.includes('katex-display'))
  check('no dollars survive as text', !out.includes('$$'), out)
  check('the underscores were not read as emphasis', !out.includes('<em>'), out)
  check('the second line is part of the same formula', out.split('katex-display').length === 2, out)
  check('and it carries its line range', out.includes('data-line="0,2"'), out)
}

/* -------------------------------------------------- display, one line */
{
  const out = md.render('$$ \\mathbf{K}_e^L = \\mathbf{K}_m^L + \\mathbf{K}_b^L $$')

  check('a one-line display equation still renders', out.includes('katex-display'), out)
  check('one-line: nothing left over', !out.includes('$$'), out)
}

/* ------------------------------------------------------------- inline */
{
  const out = md.render('The mass is $E = mc^2$ in the end.')

  check('inline math renders', out.includes('class="katex"'), out)
  check('inline math is not a display block', !out.includes('katex-display'), out)
  check('the prose around it is untouched', out.includes('The mass is') && out.includes('in the end.'))
}

/* --------------------------------------------- display inside a sentence */
{
  const out = md.render('Given $$x^2$$ the rest follows.')

  check('display math inside a sentence renders', out.includes('katex-display'), out)
  check('and does not open a paragraph inside one', !out.includes('<p class="katex-block"'), out)
  check('so the sentence stays in one piece', out.split('<p>').length === 2, out)
}

/* --------------------------------------------------------- plain money */
{
  const out = md.render('The plan costs $5 a month, or $50 a year.')

  check('a dollar sign in prose is left alone', !out.includes('katex'), out)
  check('both amounts survive', out.includes('$5') && out.includes('$50'), out)
}

/* ---------------------------------------------------------------- code */
{
  const fenced = md.render(['```', '$$ x^2 $$', '```'].join('\n'))
  check('math in a fence stays literal', fenced.includes('$$ x^2 $$'), fenced)
  check('a fence renders no math', !fenced.includes('katex'), fenced)

  const inline = md.render('Write it as `$x^2$` in the file.')
  check('math in inline code stays literal', inline.includes('<code>$x^2$</code>'), inline)
}

/* --------------------------------------------------------- broken math */
{
  const out = md.render('$$ \\frac{1}{ $$')

  check('a formula with a typo does not throw', typeof out === 'string')
  check('and is reported where it stands', out.includes('katex-error'), out)
}

console.log(failures === 0 ? '\nall good' : `\n${failures} failing`)
process.exit(failures === 0 ? 0 : 1)
