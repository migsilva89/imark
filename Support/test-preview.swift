#!/usr/bin/env swift
//
// What a click on a link does in the Quick Look panel, in a real web view, off
// screen.
//
//   swift Support/test-preview.swift
//
// The panel keeps links out of the pointer's reach with one CSS rule, and a
// rule on `pointer-events` is invisible to `element.click()`: a script can press
// a link no pointer can reach. So every click here goes where a pointer's would
// — to whatever `elementFromPoint` finds in the middle of the link — and a link
// the panel does not answer is one that never gets the click at all.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// Same stage as test-plus.swift: the page's own CSP only lets the app's scheme
// load the bundle, and a file:// load cannot satisfy it.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-preview")
try? FileManager.default.removeItem(at: stage)
try! FileManager.default.copyItem(at: resources, to: stage)
let page = stage.appendingPathComponent("index.html")
var html = try! String(contentsOf: page, encoding: .utf8)
html = html.replacingOccurrences(
    of: #"<meta[^>]*Content-Security-Policy[^>]*>"#,
    with: "",
    options: [.regularExpression, .caseInsensitive]
)
html = html.replacingOccurrences(of: "imark://app/", with: "")
try! html.write(to: page, atomically: true, encoding: .utf8)

let SCRIPT = """
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const sent = []
window.webkit = { messageHandlers: { imark: { postMessage: (p) => sent.push(p) } } }

const filler = (n) => Array.from({ length: n }, (_, i) =>
  `Paragraph ${i + 1}, long enough to take a line of its own in the column.`
).join('\\n\\n')

// Each link in a paragraph of its own, so the middle of one is never beside
// another.
const markdown = [
  '# Top',
  '',
  '[Down to the far section](#far-away)',
  '',
  'A sentence with a footnote.[^1]',
  '',
  '[A site](https://example.com)',
  '',
  '[Another file](other.md)',
  '',
  '[[Some note]]',
  '',
  filler(60),
  '',
  '## Far away',
  '',
  filler(60),
  '',
  '[^1]: The footnote itself.',
  '',
].join('\\n')

const results = {}
const root = document.getElementById('content')
const link = (selector) => root.querySelector(selector)

// Where a pointer would land in the middle of the element, and the click it
// would send there.
const clickAt = (element) => {
  const box = element.getClientRects()[0]
  const x = box.left + box.width / 2
  const y = box.top + box.height / 2
  const hit = document.elementFromPoint(x, y)
  hit?.dispatchEvent(new MouseEvent('click', {
    bubbles: true, cancelable: true, clientX: x, clientY: y,
  }))
  return hit
}

// Back to the top, and wait for its scroll event so a late one cannot land
// in the next check.
const toTop = async () => {
  if (window.scrollY === 0) return
  const scrolled = new Promise((r) => addEventListener('scroll', r, { once: true, capture: true }))
  window.scrollTo(0, 0)
  await scrolled
  await sleep(30)
}

// The page the way the extension builds it: the flag and the rail ride in the
// render payload.
await window.imark.render({ markdown, path: '/tmp/preview/t.md', theme: 'dark', preview: true, rail: 'left' })
await sleep(300)
results.inPreview = document.documentElement.dataset.preview === 'true'

// 1. A link to a heading gets the click and glides there. The glide finishes
//    on its failsafe here, where frames barely run.
const toHeading = link('a[href="#far-away"]')
results.headingLinkIsReached = clickAt(toHeading)?.closest('a') === toHeading
await sleep(800)
const far = document.getElementById('far-away')
results.headingLinkLandsOnTheHeading = !!far && Math.abs(far.getBoundingClientRect().top - 24) < 3

// 2. So does a footnote's, down to the note at the end of the page.
await toTop()
const toFootnote = link('.footnote-ref a')
results.footnoteLinkIsReached = clickAt(toFootnote)?.closest('a') === toFootnote
await sleep(800)
const note = document.getElementById('fn1')
const noteBox = note?.getBoundingClientRect()
results.footnoteLinkBringsTheNoteIntoView = window.scrollY > 0
  && !!noteBox && noteBox.top >= 0 && noteBox.bottom <= window.innerHeight

// 3. The ones that would leave the page have nobody to go to: the pointer
//    finds the paragraph around them, and nothing is sent.
await toTop()
sent.length = 0
const leaving = {
  site: link('a[href="https://example.com"]'),
  file: link('a[href^="imark://file"]'),
  wiki: link('a[data-wikilink]'),
}
for (const [name, element] of Object.entries(leaving)) {
  const hit = clickAt(element)
  results[`${name}LinkIsOutOfReach`] = !!hit && !hit.closest('a')
}
await sleep(100)
results.nothingLeavesThePanel = sent.every((m) => !String(m.type).startsWith('open'))

// 4. In a window every link still answers: the rule is the panel's alone.
window.imark.setPreview(false)
await sleep(30)
sent.length = 0
for (const [name, element] of Object.entries(leaving)) {
  results[`${name}LinkAnswersInAWindow`] = clickAt(element)?.closest('a') === element
}
const types = sent.map((m) => m.type)
results.windowSendsEachOnItsWay = ['openExternal', 'openLocal', 'openWiki'].every((t) => types.includes(t))

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_000))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
        // requestAnimationFrame never fires without a window, and the renderer
        // waits on it. Parked off screen, as in shoot.swift.
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 900, height: 1_000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window
        webView.loadFileURL(page, allowingReadAccessTo: stage)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            webView.callAsyncJavaScript(SCRIPT, in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    FileHandle.standardError.write(Data("js failed: \(error)\n".utf8))
                    exit(1)
                case .success(let value):
                    report(String(describing: value))
                }
            }
        }
    }
}

func report(_ json: String) {
    guard let data = json.data(using: .utf8),
          let checks = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
    else {
        FileHandle.standardError.write(Data("unreadable response: \(json)\n".utf8))
        exit(1)
    }
    var failed = 0
    for key in checks.keys.sorted() {
        let ok = checks[key] == true
        if !ok { failed += 1 }
        print("\(ok ? "OK  " : "FAIL ") \(key)")
    }
    print(failed == 0 ? "\nall good" : "\n\(failed) failing")
    exit(failed == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
harness.run()
app.run()
