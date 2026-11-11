// Where the document lives, for the things a widget has to point at: an image
// next to the file, a link inside a table cell. The preview learns this from
// each render (main.js, `docDir`); the editor is told once, in the payload of
// `load`, and again by `setPath` if the file moves under it.
//
// The rules below are main.js's, written out again because that file is the
// preview page — it sets up listeners and talks to the app's bridge the moment
// it loads — and may not be imported from here. Support/test-live-blocks.mjs
// runs a sample of paths through this and through the preview's own copy of the
// rules, so the two cannot drift apart unseen.

import { isExternal } from '../shared/markdown.js'

let docDir = '/'

/// Absolute path of the file being edited; its folder is what relative paths
/// are read against. Empty (a plain browser, a document with no file yet) is the
/// root, as in the preview.
export function setDocumentPath(path) {
  docDir = path ? path.slice(0, path.lastIndexOf('/')) || '/' : '/'
}

export const documentFolder = () => docDir

function normalizePath(path) {
  const out = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return '/' + out.join('/')
}

// Each part decoded whole, as in the preview: `%3F` and `%23` are the only way
// to write a name with `?` or `#` in it. A stray `%` is kept as it is.
const decodePart = (part) => {
  try {
    return decodeURIComponent(part)
  } catch {
    return part
  }
}

function resolveLocal(href) {
  const path = href.startsWith('/') ? href : `${docDir}/${href}`
  return normalizePath(path.split('/').map(decodePart).join('/'))
}

/// The URL the scheme handler on the Swift side serves a local file under, so
/// that an image beside the document loads without granting file:// access.
export const fileURL = (absPath) => `imark://file${absPath.split('/').map(encodeURIComponent).join('/')}`

/// A relative path (fragment and query already taken off) as a URL to put in
/// the page. The `resolveFile` the markdown pipeline is given.
export const resolveFile = (file) => fileURL(resolveLocal(file))

/// An `href` or `src` as the preview writes it into the page: anything with a
/// scheme and a bare `#fragment` as written, a relative path against the
/// document's folder with its query dropped and its fragment kept.
export function resolveHref(value) {
  if (isExternal(value) || value.startsWith('#')) return value
  const hash = value.indexOf('#')
  const path = hash < 0 ? value : value.slice(0, hash)
  const fragment = hash < 0 ? '' : value.slice(hash)
  const query = path.indexOf('?')
  const file = query < 0 ? path : path.slice(0, query)
  return file ? resolveFile(file) + fragment : fragment
}
