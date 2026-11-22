// Mermaid on its own, built into Resources/mermaid.js (build.mjs) so the reading
// page and the Live editor share one copy. index.html loads it before bundle.js;
// the editor loads it the first time a document has a diagram. Every other
// `import mermaid from 'mermaid'` is pointed at this global by build.mjs.
import mermaid from 'mermaid'

window.imarkMermaid = mermaid
