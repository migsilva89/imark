#!/usr/bin/env swift
//
// A note on one list item, or one table cell, in a real web view, off screen.
//
//   swift Support/test-pieces.swift
//
// Agents write long lists, and a note used to say only "somewhere in this list"
// — one dot at the top of nineteen items, and a `+` in the margin that offered
// the whole list or nothing. What is checked here is the pair that fixes it:
// the `+` offers the item or the cell the pointer is level with, and a note's
// dot sits down beside the words it quotes rather than at the top of the block.
//
// The file is not touched by any of it. A comment written between two list
// items splits the list in two, so notes still land after the block and the
// quote is what says which item — which is why the quote the `+` sends matters
// enough to be checked here.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// Same stage as test-plus.swift: the page's own CSP only lets the app's scheme
// load the bundle, and a file:// load cannot satisfy it.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-pieces")
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
const results = {}
const move = (target, x, y) => target.dispatchEvent(
  new MouseEvent('mousemove', { bubbles: true, clientX: x, clientY: y })
)
const plus = () => document.querySelector('.block-plus')
const lit = () => document.querySelector('.block-target')

// The notes go where the placeholder is: a note belongs to the block above it,
// so one written under the table would be a note about the table however well
// its quote matched an item of the list.
const RAW = [
  '# Heading',
  '',
  '- Item one',
  '- Item two that should have a comment attached to it',
  '- Item three',
  '',
  '<<after the list>>',
  '',
  '| Name | Verdict |',
  '| --- | --- |',
  '| alpha | keep |',
  '| beta | drop |',
  '| gamma | keep |',
  '',
  '<<after the table>>',
  '',
  'A closing paragraph.',
  '',
].join('\\n')

const strip = (text) => text.replace(/^<<[^>]*>>\\n\\n/gm, '')
const withNote = (where, lines) =>
  strip(RAW.replace(`<<${where}>>`, lines.join('\\n')))
const DOC = strip(RAW)

// 1. A note quoting the second item sits beside that item, not at the top of
//    the list — and the item, quoted whole, is washed rather than underlined.
await window.imark.render({
  markdown: withNote('after the list', [
    '<!-- imark quote="Item two that should have a comment attached to it"'
      + ' nth="1" by="miguel" at="2026-08-27T10:00Z"',
    'This item, and not the other two.',
    '-->',
  ]),
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)

const item = [...document.querySelectorAll('li')]
  .find((li) => li.textContent.includes('Item two'))
results.itemNoteFoundTheItem = !!item
results.itemIsWashedWhole = !!item?.classList.contains('note-piece')
const itemDot = document.querySelector('.note-dot')
const holder = itemDot?.parentElement
results.itemNoteHasOneDot = document.querySelectorAll('.note-dot').length === 1
{
  const want = item.getBoundingClientRect().top - holder.getBoundingClientRect().top
  const got = Number.parseInt(itemDot.style.top || '0', 10)
  results.itemDotSitsBesideTheItem = want > 8 && Math.abs(got - (want + 2)) <= 3
}

// 2. The same for one cell of a table, where the dot cannot live inside the
//    cell at all: the table scrolls sideways and would clip it.
await window.imark.render({
  markdown: withNote('after the table', [
    '<!-- imark quote="drop" nth="1" by="miguel" at="2026-08-27T10:00Z"',
    'This verdict.',
    '-->',
  ]),
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)
const cell = [...document.querySelectorAll('td')].find((td) => td.textContent.trim() === 'drop')
const cellDot = document.querySelector('.note-dot')
results.cellNoteFoundTheCell = !!cell?.querySelector('.note-anchor')
{
  const want = cell.getBoundingClientRect().top
    - cellDot.parentElement.getBoundingClientRect().top
  const got = Number.parseInt(cellDot.style.top || '0', 10)
  results.cellDotSitsOnItsOwnRow = want > 8 && Math.abs(got - (want + 2)) <= 3
}

// 3. Two notes on the same item still stack; two notes on different items do
//    not, which is the whole point of moving the dot in the first place.
await window.imark.render({
  markdown: withNote('after the list', [
    '<!-- imark quote="Item one" nth="1" by="miguel" at="2026-08-27T10:00Z"',
    'On the first.',
    '-->',
    '',
    '<!-- imark quote="Item three" nth="1" by="miguel" at="2026-08-27T10:01Z"',
    'On the third.',
    '-->',
  ]),
  path: '/tmp/t.md',
  theme: 'dark',
})
await sleep(300)
{
  const tops = [...document.querySelectorAll('.note-dot')]
    .map((dot) => Number.parseInt(dot.style.top || '0', 10))
  results.twoItemsGetTwoHeights = tops.length === 2 && Math.abs(tops[0] - tops[1]) > 12
}

// 4. The `+`: on the words of an item, the item is what lights up.
await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)
const third = [...document.querySelectorAll('li')].find((li) => li.textContent.includes('Item three'))
const thirdBox = third.getBoundingClientRect()
move(third, thirdBox.left + 20, thirdBox.top + 4)
await sleep(40)
results.plusOffersTheItem = lit() === third
results.plusShowsForTheItem = plus().style.display !== 'none'

// 5. And from out in the margin, level with it, where there is nothing under
//    the pointer to ask.
move(document.body, 5, 5)
await sleep(400)
move(document.body, thirdBox.left - 60, thirdBox.top + 4)
await sleep(40)
results.plusOffersTheItemFromTheMargin = lit() === third

// 6. Pressing it sends the item's own words as the quote — the only thing in
//    the file that can say which item, since the note goes after the list.
plus().dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
plus().click()
await sleep(30)
{
  const message = sent.filter((m) => m.type === 'selection').pop()
  results.itemPlusSendsTheItem = message?.text === 'Item three'
  results.itemPlusWritesAfterTheList =
    message?.block?.end === Number(document.querySelector('ul').dataset.line?.split(',')[1])
}

// 7. The same on a cell, and the copy it sends is the right one: two cells of
//    this table say "keep", and the note has to find the second.
const gamma = [...document.querySelectorAll('td')].find((td) => td.previousElementSibling?.textContent === 'gamma')
const gammaBox = gamma.getBoundingClientRect()
move(gamma, gammaBox.left + 6, gammaBox.top + 4)
await sleep(40)
results.plusOffersTheCell = lit() === gamma
plus().dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
plus().click()
await sleep(30)
{
  const message = sent.filter((m) => m.type === 'selection').pop()
  results.cellPlusSendsTheCell = message?.text === 'keep'
  results.cellPlusCountsTheCopies = message?.occurrence === 2
}

// 7b. From the margin beside the table, though, the offer is the table. A row
//     has four cells level with the pointer and choosing one would be a guess.
move(document.body, 5, 5)
await sleep(400)
const table = document.querySelector('table')
const tableBox = table.getBoundingClientRect()
move(document.body, tableBox.left - 60, gammaBox.top + 4)
await sleep(40)
results.marginBesideATableOffersTheTable = lit() === table

// 8. Nothing changed for a paragraph, which has no pieces in it.
const para = [...document.getElementById('content').children].find((el) => el.tagName === 'P')
const paraBox = para.getBoundingClientRect()
move(document.body, 5, 5)
await sleep(400)
move(para, paraBox.left + 20, paraBox.top + 4)
await sleep(40)
results.paragraphStillOffersItself = lit() === para
plus().dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
plus().click()
await sleep(30)
results.paragraphPlusStillSendsNoQuote =
  sent.filter((m) => m.type === 'selection').pop()?.text === ''

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 1_000))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
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
