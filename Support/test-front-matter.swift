#!/usr/bin/env swift
//
// Showing and hiding the front matter card, in a real web view, off screen.
//
//   swift Support/test-front-matter.swift
//
// The card is put away with CSS and the document is not built again, and this
// is the test that says so: a note in a file that starts with front matter has
// to report the same lines whether the card is on screen or not. Get that wrong
// and hiding a card would silently rewrite somebody else's file three lines off.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-front-matter")
try? FileManager.default.removeItem(at: stage)
try! FileManager.default.copyItem(at: resources, to: stage)
let page = stage.appendingPathComponent("index.html")
var html = try! String(contentsOf: page, encoding: .utf8)
html = html.replacingOccurrences(
    of: #"<meta[^>]*Content-Security-Policy[^>]*>"#,
    with: "",
    options: [.regularExpression, .caseInsensitive]
)
// And the bundle is asked for by scheme, which only the app's handler answers.
html = html.replacingOccurrences(of: "imark://app/", with: "")
try! html.write(to: page, atomically: true, encoding: .utf8)

let SCRIPT = """
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const sent = []
window.webkit = { messageHandlers: { imark: { postMessage: (p) => sent.push(p) } } }

const DOC = [
  '---',
  'title: A document',
  'tags: [one, two]',
  '---',
  '',
  '# Heading',
  '',
  'A paragraph with a note in it.',
  '',
  '<!-- imark quote="a note" by="miguel" at="2026-08-17T10:00Z"',
  'The note that must not move.',
  '-->',
  '',
].join('\\n')

// Asking the note itself where it lives: the edit button is what the app reads
// before it writes back into the file.
const linesOfTheNote = () => {
  document.querySelector('.note-edit').click()
  const command = sent.filter((m) => m.type === 'noteCommand').pop()
  return `${command?.line}-${command?.endLine}`
}

const card = () => document.querySelector('.front-matter')

// Where the note's mark sits in the rail. The mark is placed against where the
// note is on the page, so a card that comes out of the page takes the note up
// with it and leaves the mark behind.
const markTop = () => Math.round(
  parseFloat(document.querySelector('.note-mark').style.top)
)

const results = {}

await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)

// 1. Nothing said otherwise, so the card is there — the behaviour every
//    document has had until now.
results.cardShowsByDefault = !!card() && card().offsetHeight > 0
const shownLines = linesOfTheNote()
results.noteReportsItsLines = /^\\d+-\\d+$/.test(shownLines)
const shownMark = markTop()

// 2. Put away from the View menu. Hidden, but still in the page: the document
//    underneath it was not built again.
window.imark.setFrontMatter(false)
await sleep(60)
results.cardHidesWhenPutAway = !!card() && card().offsetHeight === 0
results.documentIsNotRebuilt = document.querySelectorAll('.note-dot').length === 1

// 3. And the note still points at the same three lines of the file.
results.noteKeepsItsLines = linesOfTheNote() === shownLines
const hiddenMark = markTop()
results.railMarkFollowsTheNote = hiddenMark !== shownMark

// 4. The next document opens the way it was left, without the card flashing
//    past for the length of one render.
await window.imark.render({
  markdown: DOC,
  path: '/tmp/t.md',
  theme: 'dark',
  frontMatter: false,
})
await sleep(300)
results.staysHiddenOnTheNextDocument = !!card() && card().offsetHeight === 0
results.noteKeepsItsLinesOnTheNextDocument = linesOfTheNote() === shownLines
// The document built from scratch is the answer to compare against: toggling
// has to leave the rail exactly where rendering would have put it.
results.togglingPlacesTheMarkWhereARenderWould = Math.abs(markTop() - hiddenMark) <= 2

// 5. Brought back, the card is exactly where it was.
window.imark.setFrontMatter(true)
await sleep(60)
results.cardComesBack = card().offsetHeight > 0
results.cardComesBackFirst = document.getElementById('content').firstElementChild === card()

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 1_000))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
        // requestAnimationFrame never fires without a window, and the renderer
        // waits on it. Parked off screen, as in test-plus.swift.
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 1_400, height: 1_000),
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
