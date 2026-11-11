// The drawing of ```mermaid fences for the Live editor, built on its own into
// Resources/editor-diagrams.js (build.mjs) and loaded by mermaid-block.js the
// first time a document has a diagram. Mermaid is most of what the editor would
// otherwise weigh, and nearly no document needs it.
//
// It is a script of its own, with its own copy of i18n.js, so the page's
// language is passed in (`setLanguage`) before anything is drawn.

export { readPalette, placeDrawnDiagrams, drawDiagrams, diagramsDrawn } from '../shared/diagrams.js'
export { openDiagram, close as closeDiagram, isViewing } from '../zoom.js'
export { setLanguage } from '../i18n.js'
