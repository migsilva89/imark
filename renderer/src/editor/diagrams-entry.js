// The drawing of ```mermaid fences for the Live editor, built on its own into
// Resources/editor-diagrams.js (build.mjs) and loaded by mermaid-block.js the
// first time a document has a diagram. Mermaid itself is not in here: it is
// mermaid.js, the reading page's copy, loaded just before this.

export { readPalette, placeDrawnDiagrams, drawDiagrams, diagramsDrawn } from '../shared/diagrams.js'
export { openDiagram, close as closeDiagram, isViewing } from '../zoom.js'
