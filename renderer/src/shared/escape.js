// escapeHtml, alone. shared/diagrams.js imports it from markdown.js, which would
// drag markdown-it, highlight.js and KaTeX into editor-diagrams.js; build.mjs
// points that one import here for the diagrams build only, so the preview's
// bundle (which has all of markdown.js anyway) is untouched.
// Keep in step with escapeHtml in markdown.js.
export const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
