// Which lines of a document differ from the text it was saved as: the Live
// editor's version of the source editor's `MarkdownEditorView.modifiedLines`
// (docs/LIVE-PREVIEW.md §5). A real line diff rather than a positional compare,
// so one inserted line marks that line and not everything below it, and a line
// that was deleted marks nothing — there is no line left to mark.
//
// Pure, no CodeMirror: the gutter (gutter.js) feeds it line arrays, and the node
// test (Support/test-live-gutter.mjs) feeds it the same.
//
// Cheap on purpose, because it runs on every edit. The lines both texts share
// at the top and at the bottom are taken off first, which for typing leaves a
// middle of one line against one. Only that middle is diffed (Myers, O(ND)), and
// past `maxEdits` steps — a pasted rewrite of thousands of lines — the whole
// middle is marked instead of the page stalling to find the few lines in it
// that happen to match.

const maxEdits = 1000

/// Indices into `current`, counted from zero and ascending, of the lines that
/// are not in `saved`.
export const changedLines = (saved, current) => diffAgainst(saved, current).list

/// The same, with what an editor already knows passed in and handed back, so
/// a keystroke costs the lines it touched rather than the whole document.
///
/// `current` is an array, or `{ length, line(i) }` for a document that should
/// not be copied out line by line. `known.prefix` / `known.suffix`, when given,
/// are counts of lines at the top and at the bottom already known to be the
/// same in both — a lower bound; the comparison carries on from there. Returns
/// the marked lines and how far the sameness reaches at each end.
export function diffAgainst(saved, current, known = {}) {
  const at = Array.isArray(current) ? (i) => current[i] : (i) => current.line(i)
  const length = current.length
  const shortest = Math.min(saved.length, length)
  let start = Math.min(known.prefix ?? 0, shortest)
  while (start < shortest && saved[start] === at(start)) start += 1
  const tail = Math.min(known.suffix ?? 0, shortest - start)
  let endSaved = saved.length - tail
  let endCurrent = length - tail
  while (endSaved > start && endCurrent > start && saved[endSaved - 1] === at(endCurrent - 1)) {
    endSaved -= 1
    endCurrent -= 1
  }
  const result = (list) => ({ list, prefix: start, suffix: length - endCurrent })
  if (endCurrent === start) return result([])
  if (endSaved === start) return result(range(start, endCurrent))

  const middle = []
  for (let i = start; i < endCurrent; i += 1) middle.push(at(i))
  const inserted = insertions(saved, start, endSaved, middle, 0, middle.length)
  return result(inserted ? inserted.map((i) => i + start) : range(start, endCurrent))
}

function range(from, to) {
  const out = []
  for (let i = from; i < to; i += 1) out.push(i)
  return out
}

/// Myers' diff of `a[aFrom..<aTo]` against `b[bFrom..<bTo]`, returning the
/// indices in `b` that are insertions, or null past `maxEdits`.
function insertions(a, aFrom, aTo, b, bFrom, bTo) {
  const n = aTo - aFrom
  const m = bTo - bFrom
  const limit = Math.min(n + m, maxEdits)
  const offset = limit + 1
  const v = new Int32Array(2 * limit + 3)
  const trace = []
  for (let d = 0; d <= limit; d += 1) {
    // Only the diagonals step d can reach, which keeps the trace O(D²).
    trace.push(v.slice(offset - d - 1, offset + d + 2))
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1])
        ? v[offset + k + 1]
        : v[offset + k - 1] + 1
      let y = x - k
      while (x < n && y < m && a[aFrom + x] === b[bFrom + y]) {
        x += 1
        y += 1
      }
      v[offset + k] = x
      if (x >= n && y >= m) return walkBack(trace, d, n, m, bFrom)
    }
  }
  return null
}

function walkBack(trace, steps, n, m, bFrom) {
  const out = []
  let x = n
  let y = m
  for (let d = steps; d > 0; d -= 1) {
    // trace[d] is V as it stood before step d, holding diagonals -d-1 … d+1.
    const before = trace[d]
    const at = (k) => before[k + d + 1]
    const k = x - y
    const down = k === -d || (k !== d && at(k - 1) < at(k + 1))
    const prevK = down ? k + 1 : k - 1
    const prevX = at(prevK)
    const prevY = prevX - prevK
    // A step down is a line of `b` that `a` does not have.
    if (down) out.push(bFrom + prevY)
    x = prevX
    y = prevY
  }
  return out.reverse()
}
