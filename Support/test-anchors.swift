#!/usr/bin/env swift
//
// Links to a heading, in a real web view, off screen.
//
//   swift Support/test-anchors.swift
//
// Two bugs lived here. A link to a heading written in anything but ASCII went
// nowhere: markdown-it percent-encodes the href, and the page looked the
// encoded string up as an id. And the id itself was wrong for letters that
// only look like an accented letter — `й` and `ї` are letters of their own in
// Ukrainian, and taking the accent off turned `мій` into `міи`.
//
// The ids are GitHub's, so the links a document was written with on GitHub
// work here too — and the ones written against the ids Imark used to make.
//
// The other half is what Back needs: a jump inside the page has to tell the app
// where the reader was, the app has to be able to put them back there, and a
// link to a heading in another file has to say which heading.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-anchors")
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

// Enough text between the headings that every one of them can be scrolled to
// the top of the window, the last one included.
const filler = Array.from({ length: 40 }, (_, i) => `Filler paragraph number ${i}.`).join('\\n\\n')

const DOC = [
  '# Зміст',
  '',
  '- [Мій розділ](#мій-розділ)',
  '- [Їжак і ґанок](#їжак-і-ґанок)',
  '- [Ação rápida](#ação-rápida)',
  '- [The old spelling](#acao-rapida)',
  '- [Old underscores](#somefunc)',
  '- [Old spaces](#a-b)',
  '- [Hello world](#hello-world)',
  '- [Nowhere](#no-such-heading)',
  '- [Another file](other.md#мій-розділ)',
  '',
  filler,
  '',
  '## Мій розділ',
  '',
  filler,
  '',
  '## Їжак і ґанок',
  '',
  filler,
  '',
  '## Ação rápida',
  '',
  filler,
  '',
  '## some_func',
  '',
  filler,
  '',
  '## a  b',
  '',
  filler,
  '',
  '## Repeat',
  '',
  '## Repeat',
  '',
  '## Repeat-1',
  '',
  '## Hello world',
  '',
  filler,
  '',
].join('\\n')

const byId = (id) => document.getElementById(id)
const link = (label) => [...document.querySelectorAll('#content a')].find((a) => a.textContent === label)
const jumps = () => sent.filter((m) => m.type === 'jump')
// The glide lands in under half a second.
const landed = () => sleep(600)
// The heading sits just under the top of the window, where a jump puts it.
const atTop = (el) => !!el && Math.abs(el.getBoundingClientRect().top - 24) < 3

const results = {}

await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)

// 1. The ids are the ones GitHub gives the same headings, letters intact.
results.ukrainianIdKeepsItsLetters = !!byId('мій-розділ')
results.yiAndGheKeepTheirs = !!byId('їжак-і-ґанок')
results.portugueseIdKeepsItsAccents = !!byId('ação-rápida')
results.asciiIdIsUnchanged = !!byId('hello-world')
results.underscoresStay = !!byId('some_func')
results.everySpaceIsAHyphen = !!byId('a--b')
results.repeatsAreNumberedTheWayGitHubDoes =
  !!byId('repeat') && !!byId('repeat-1') && !!byId('repeat-1-1')

// 2. A Ukrainian link goes to its heading, and says where the reader was.
window.scrollTo(0, 0)
await sleep(50)
link('Мій розділ').click()
await landed()
results.ukrainianLinkLands = atTop(byId('мій-розділ'))
results.jumpIsReported = jumps().length === 1
results.jumpSaysWhereTheReaderWas = jumps()[0]?.from === 0
results.jumpSaysWhereItIsGoing = Math.abs(jumps()[0]?.to - window.scrollY) < 2

window.scrollTo(0, 0)
await sleep(50)
link('Їжак і ґанок').click()
await landed()
results.yiAndGheLinkLands = atTop(byId('їжак-і-ґанок'))

window.scrollTo(0, 0)
await sleep(50)
link('Ação rápida').click()
await landed()
results.portugueseLinkLands = atTop(byId('ação-rápida'))

// 2b. With the toolbar standing on the page — taller with a tab bar under it —
//     the heading lands just under the toolbar, not behind it, and is the one
//     the outline marks as current.
window.imark.setTopInset(80)
window.scrollTo(0, 0)
await sleep(50)
link('Мій розділ').click()
await landed()
results.theHeadingClearsTheToolbar =
  Math.abs(byId('мій-розділ').getBoundingClientRect().top - (80 + 24)) < 3
// Asked through a reload, which keeps the place and names the current heading
// straight away; after a scroll that waits for a frame this harness never gets.
await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)
results.andIsTheCurrentOne = sent.filter((m) => m.type === 'active').pop()?.id === 'мій-розділ'
window.imark.setTopInset(0)

// 3. Links written against the ids Imark used to make — accents off,
//    underscores gone, a run of spaces as one hyphen — still find their heading.
window.scrollTo(0, 0)
await sleep(50)
link('The old spelling').click()
await landed()
results.accentlessLinkStillLands = atTop(byId('ação-rápida'))

window.scrollTo(0, 0)
await sleep(50)
link('Old underscores').click()
await landed()
results.underscorelessLinkStillLands = atTop(byId('some_func'))

window.scrollTo(0, 0)
await sleep(50)
link('Old spaces').click()
await landed()
results.oneHyphenLinkStillLands = atTop(byId('a--b'))

// 4. A link to nothing moves nothing, and is not a step of history.
window.scrollTo(0, 500)
await sleep(50)
const before = jumps().length
link('Nowhere').click()
await landed()
results.missingTargetDoesNotMove = window.scrollY === 500
results.missingTargetIsNotAJump = jumps().length === before

// 5. Neither is following a link a second time, to where the page already is.
window.scrollTo(0, 0)
await sleep(50)
link('Hello world').click()
await landed()
const beforeAgain = jumps().length
link('Hello world').click()
await landed()
results.stayingPutIsNotAJump = atTop(byId('hello-world')) && jumps().length === beforeAgain

// 6. The outline in the sidebar asks for the plain id, not an encoded one.
window.scrollTo(0, 0)
await sleep(50)
const beforeOutline = jumps().length
window.imark.scrollToAnchor('мій-розділ')
await landed()
results.outlineLands = atTop(byId('мій-розділ'))
results.outlineIsAJump = jumps().length === beforeOutline + 1

// 7. Back puts the page where it was told, and is not a jump of its own.
const beforeBack = jumps().length
window.imark.scrollToOffset(700)
await landed()
results.backLandsOnTheOffset = Math.abs(window.scrollY - 700) < 2
results.backIsNotAJump = jumps().length === beforeBack

// 7b. Back pressed while the glide is still under way lands where it was
//     told. The old glide's failsafe used to outlive it and put the page back
//     on the heading the link had been going to. Before the first frame is the
//     one moment a test can hit every time.
window.scrollTo(0, 0)
await sleep(50)
window.imark.scrollToAnchor('hello-world')
window.imark.scrollToOffset(0)
await sleep(800)
results.quickBackIsNotOverruled = window.scrollY === 0

// 8. The app is told where the page is.
await sleep(300)
const reports = sent.filter((m) => m.type === 'scrolled')
results.restingPlaceIsReported =
  reports.length > 0 && Math.abs(reports.pop().y - window.scrollY) < 2

// 9. A link to a heading in another file keeps the heading apart from the
//    file's name, and hands both to the app.
const other = link('Another file')
results.theFragmentStaysOutOfThePath =
  other?.getAttribute('href').startsWith('imark://file/tmp/other.md#') === true
other?.click()
const opened = sent.filter((m) => m.type === 'openLocal').pop()
results.theAppIsToldTheFile = opened?.path === '/tmp/other.md'
results.andTheHeading = decodeURIComponent(opened?.anchor ?? '') === 'мій-розділ'

// 10. Rendering keeps the place for a reload, and goes where it is told for
//     another document, a step back, or a heading a link named.
window.scrollTo(0, 1500)
await sleep(50)
await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)
results.reloadKeepsThePlace = Math.abs(window.scrollY - 1500) < 2

await window.imark.render({ markdown: DOC, path: '/tmp/other.md', theme: 'dark', scroll: 0 })
await sleep(300)
results.anotherDocumentStartsAtTheTop = window.scrollY === 0

await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark', scroll: 1200 })
await sleep(300)
results.aStepBackLandsWhereItLeft = Math.abs(window.scrollY - 1200) < 2

await window.imark.render({
  markdown: DOC, path: '/tmp/other.md', theme: 'dark', scroll: 0, anchor: opened?.anchor,
})
await sleep(300)
results.aLinkedHeadingIsWhereItOpens = atTop(byId('мій-розділ'))

await window.imark.render({
  markdown: DOC, path: '/tmp/other.md', theme: 'dark', scroll: 0, anchor: 'no-such-heading',
})
await sleep(300)
results.aMissingHeadingOpensAtTheTop = window.scrollY === 0

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 1_000))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
        // requestAnimationFrame never fires without a window, and the glide
        // runs on it. Parked off screen, as in test-plus.swift.
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
