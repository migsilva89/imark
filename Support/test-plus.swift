#!/usr/bin/env swift
//
// Drives the `+` in the margin in a real web view, off screen.
//
//   swift Support/test-plus.swift
//
// The interaction it covers cannot be checked by looking at a screenshot: the
// button only exists while the pointer is somewhere, and the bug it was written
// for — the button vanishing on the way to it, because the route out of the
// text crosses margin that belongs to no block — is invisible in a still.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-plus")
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

await window.imark.render({
  markdown: '# Título\\n\\nUm parágrafo com palavras que chegam para uma linha inteira.\\n\\nOutro parágrafo.\\n',
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)

const results = {}
const root = document.getElementById('content')
const para = [...root.children].find((el) => el.tagName === 'P')
results.foundParagraph = !!para

const move = (target, x, y) => target.dispatchEvent(
  new MouseEvent('mousemove', { bubbles: true, clientX: x, clientY: y })
)

// 1. Pointer on the paragraph: the button appears and the block lights up.
const box = para.getBoundingClientRect()
move(para, box.left + 40, box.top + 5)
await sleep(30)
const plus = document.querySelector('.block-plus')
results.plusAppears = !!plus && plus.style.display !== 'none'
results.blockLitOnHover = para.classList.contains('block-target')

// 2. The pointer leaves the text on its way to the button. This is the bug:
//    the margin belongs to no block, and hiding immediately took the button
//    away exactly as the hand arrived.
move(document.body, box.left - 20, box.top + 5)
await sleep(90)
results.plusSurvivesTheGap = plus.style.display !== 'none'

// 3. On the button itself: still there, and the block is armed.
plus.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
await sleep(30)
results.plusStaysOnButton = plus.style.display !== 'none'
results.blockArmed = para.classList.contains('block-armed')

// 4. And it leaves when the pointer goes somewhere else entirely.
plus.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }))
move(document.body, 5, 5)
await sleep(400)
results.plusHidesEventually = plus.style.display === 'none'

// 5. Pressing it sends a selection with no text, on the paragraph's lines.
move(para, box.left + 40, box.top + 5)
await sleep(30)
plus.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
plus.click()
await sleep(30)
const message = sent.filter((m) => m.type === 'selection').pop()
results.sentSelection = !!message
results.sentEmptyText = message?.text === ''
results.sentBlockLines = !!message?.block && Number.isFinite(message.block.end)
results.blockStillLit = para.classList.contains('block-target')

// 6. A single note shows a mark on the rail. It used to take two before the
//    rail existed at all, so the first comment anybody ever wrote vanished.
await window.imark.render({
  markdown: [
    '# Título',
    '',
    'Um parágrafo com uma nota.',
    '',
    '<!-- imark quote="uma nota" by="miguel" at="2026-08-03T14:00Z"',
    'A única nota do documento.',
    '-->',
    '',
  ].join('\\n'),
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)
results.oneNoteMakesADot = document.querySelectorAll('.note-dot').length === 1
results.oneNoteMakesARailMark = document.querySelectorAll('.note-mark').length === 1
// A quoted note underlines; it must not also wash the block.
results.quotedNoteDoesNotWashTheBlock = document.querySelectorAll('.note-block').length === 0

// 7. A note with no quote washes its block instead, in the note's own colour.
await window.imark.render({
  markdown: [
    '# Título',
    '',
    'Um parágrafo comentado inteiro.',
    '',
    '<!-- imark by="miguel" at="2026-08-03T14:00Z" color="green"',
    'Sobre o bloco todo.',
    '-->',
    '',
  ].join('\\n'),
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)
const washed = document.querySelector('.note-block')
results.blockNoteWashesTheBlock = !!washed
results.blockNoteKeepsItsColour = washed?.dataset.color === 'green'
results.blockNoteIsNotAnOrphan = document.querySelectorAll('.note-dot.orphan').length === 0

// 8. In the Quick Look panel there is nothing to write to, so no `+` — but the
//    notes already in the file still have to show.
window.imark.setPreview(true)
await window.imark.render({
  markdown: [
    '# Título',
    '',
    'Um parágrafo com uma nota.',
    '',
    '<!-- imark quote="uma nota" by="miguel" at="2026-08-03T14:00Z"',
    'Visível em preview.',
    '-->',
    '',
  ].join('\\n'),
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)
const previewPara = [...document.getElementById('content').children]
  .find((el) => el.tagName === 'P' || el.querySelector?.('p'))
move(previewPara, previewPara.getBoundingClientRect().left + 40,
     previewPara.getBoundingClientRect().top + 5)
await sleep(60)
results.noPlusInPreview = document.querySelector('.block-plus').style.display === 'none'
results.notesStillShowInPreview = document.querySelectorAll('.note-anchor').length > 0
window.imark.setPreview(false)

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_100))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
        // requestAnimationFrame never fires without a window, and the renderer
        // waits on it. Parked off screen, as in shoot.swift.
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 900, height: 1_100),
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
                    FileHandle.standardError.write(Data("js falhou: \(error)\n".utf8))
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
        FileHandle.standardError.write(Data("resposta ilegível: \(json)\n".utf8))
        exit(1)
    }
    var failed = 0
    for key in checks.keys.sorted() {
        let ok = checks[key] == true
        if !ok { failed += 1 }
        print("\(ok ? "OK  " : "FALHA") \(key)")
    }
    print(failed == 0 ? "\nall good" : "\n\(failed) a falhar")
    exit(failed == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
harness.run()
app.run()
