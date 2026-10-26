#!/usr/bin/env swift
//
// Wide Mermaid diagrams at a readable size, and the viewer that zooms into
// one, in a real web view, off screen.
//
//   swift Support/test-diagram-zoom.swift [directory for snapshots]
//
// A sequence diagram with eight participants was squeezed into the column,
// its labels three to five pixels tall, and nothing made it bigger: the text
// size left SVGs alone and the web view does not pinch (issue #62).

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")
let shots = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }

// As in test-diagrams.swift: the page without its CSP, loaded from a file.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-diagram-zoom")
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
window.webkit = { messageHandlers: { imark: { postMessage: () => {} } } }

// The diagram from the issue.
const WIDE = [
  '```mermaid',
  'sequenceDiagram',
  '    autonumber',
  '    actor Client',
  '    participant Gateway as Spring Cloud Gateway',
  '    participant RoutePredicate as RoutePredicateHandlerMapping',
  '    participant Handler as FilteringWebHandler',
  '    participant FilterChain as DefaultGatewayFilterChain',
  '    participant LoadBalancer as ReactiveLoadBalancerClientFilter',
  '    participant NettyRoute as NettyRoutingFilter',
  '    participant Microservice as Backend Service',
  '    Client->>Gateway: HTTP Request',
  '    Gateway->>RoutePredicate: getHandler(exchange)',
  '    RoutePredicate-->>Gateway: Matched Route',
  '    Gateway->>Handler: handle(exchange)',
  '    Handler->>FilterChain: filter(exchange)',
  '    FilterChain->>LoadBalancer: Resolve Target IP:Port',
  '    FilterChain->>NettyRoute: Forward Request via NettyHttpClient',
  '    NettyRoute->>Microservice: HTTP Request',
  '    Microservice-->>NettyRoute: Response',
  '    NettyRoute-->>Client: Response Body',
  '```',
].join('\\n')
const SMALL = ['```mermaid', 'flowchart LR', '  A[Start] --> B[End]', '```'].join('\\n')
const doc = ['# Gateway', '', 'Some words before.', '', WIDE, '', 'A small one.', '', SMALL, ''].join('\\n')
const render = (markdown, path = '/tmp/a.md') => window.imark.render({ markdown, path, theme: 'light' })
// Frame callbacks do not run in a window nobody can see.
const frame = () => new Promise((r) => setTimeout(r, 50))

const results = {}
const geometry = {}

await render(doc)
const [wideBlock, smallBlock] = document.querySelectorAll('.mermaid-block')
const wide = wideBlock.querySelector('svg')
const small = smallBlock.querySelector('svg')

// 1. The wide one is drawn at its own size and scrolls sideways in its block.
const natural = wide.viewBox.baseVal.width
geometry.column = wideBlock.clientWidth
geometry.natural = natural
geometry.drawn = wide.getBoundingClientRect().width
results.aWideDiagramIsDrawnAtItsOwnSize = Math.abs(wide.getBoundingClientRect().width - natural) < 1
results.aWideDiagramScrollsSideways = wideBlock.scrollWidth > wideBlock.clientWidth
// Mermaid's labels are 16px in its own pixels: at its own size, so are they.
const label = [...wide.querySelectorAll('text')].find((t) => t.textContent.includes('Gateway'))
geometry.labelHeight = label.getBoundingClientRect().height
results.itsLabelsCanBeRead = label.getBoundingClientRect().height >= 12

// 2. A small one keeps its size, in the middle of the column, and does not scroll.
const smallRect = small.getBoundingClientRect()
const smallBox = smallBlock.getBoundingClientRect()
results.aSmallDiagramKeepsItsSize = Math.abs(smallRect.width - small.viewBox.baseVal.width) < 1
results.aSmallDiagramIsCentred = Math.abs((smallRect.left - smallBox.left) - (smallBox.right - smallRect.right)) < 2
results.aSmallDiagramDoesNotScroll = smallBlock.scrollWidth <= smallBlock.clientWidth

// 3. Bigger Text makes the diagrams bigger too.
window.imark.setTextScale(20)
await frame()
results.biggerTextMakesDiagramsBigger = Math.abs(wide.getBoundingClientRect().width - natural * 20 / 16) < 1
window.imark.setTextScale(16)
await frame()

// 4. A click on a diagram opens it in the viewer, fitted to the window.
wideBlock.scrollLeft = 0
wide.dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0 }))
const viewer = document.querySelector('.diagram-viewer')
results.aClickOpensTheViewer = !!viewer && !viewer.hidden
const copy = viewer.querySelector('svg')
const fitted = copy.getBoundingClientRect()
results.theViewerFitsItInTheWindow = fitted.width <= window.innerWidth && fitted.height <= window.innerHeight
results.theViewerShowsItBiggerThanTheColumnCould = fitted.width > geometry.column
// No id twice on the page: a drawing styles itself and finds its arrowheads by id.
const ids = [...document.querySelectorAll('[id]')].map((el) => el.id)
geometry.dupes = ids.filter((id, i) => ids.indexOf(id) !== i)
results.theCopyHasIdsOfItsOwn = new Set(ids).size === ids.length && !!copy.id && copy.id !== wide.id
results.theCopyKeepsItsArrowheads = !!copy.querySelector('marker')
  && [...copy.querySelectorAll('[marker-end]')].every((el) => {
    const id = el.getAttribute('marker-end').match(/#([^)]+)/)?.[1]
    return id && copy.querySelector(`#${CSS.escape(id)}`)
  })

// 5. A pinch zooms around the fingers.
const before = copy.getBoundingClientRect().width
const cx = window.innerWidth / 2
const cy = window.innerHeight / 2
window.imark.magnify(0.5, cx, cy)
results.aPinchZoomsIn = copy.getBoundingClientRect().width > before * 1.4
window.imark.magnify(-0.4, cx, cy)
results.aPinchZoomsOut = copy.getBoundingClientRect().width < before * 1.4

// 6. The buttons: in, out, actual size, fit.
const buttons = Object.fromEntries([...viewer.querySelectorAll('button')].map((b) => [b.getAttribute('aria-label'), b]))
buttons['Actual size'].click()
results.actualSizeIsItsOwnSize = Math.abs(copy.getBoundingClientRect().width - natural) < 1
buttons['Zoom in'].click()
results.zoomInGrowsIt = copy.getBoundingClientRect().width > natural * 1.2
buttons['Fit to window'].click()
results.fitPutsItBack = Math.abs(copy.getBoundingClientRect().width - fitted.width) < 1

// 7. Two fingers move it, and it never leaves the window entirely.
const left = copy.getBoundingClientRect().left
const stageEl = viewer.querySelector('.diagram-viewer-stage')
stageEl.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaX: 100, deltaY: 0 }))
results.twoFingersMoveIt = Math.abs(copy.getBoundingClientRect().left - (left - 100)) < 1
stageEl.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaX: 100000, deltaY: 0 }))
results.itCannotBeLostOffTheEdge = copy.getBoundingClientRect().right >= 79

// 8. The page behind does not scroll while it is open.
const y = window.scrollY
viewer.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }))
results.spaceDoesNotScrollThePageBehind = window.scrollY === y

// 9. Escape puts it away.
viewer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
results.escapeClosesIt = viewer.hidden && !viewer.querySelector('svg')

// 10. A pinch on a diagram opens it; a pinch on the words does nothing.
const p = document.querySelector('p').getBoundingClientRect()
window.imark.magnify(0.3, p.left + 5, p.top + p.height / 2)
results.aPinchOnWordsDoesNothing = viewer.hidden
const s = small.getBoundingClientRect()
window.imark.magnify(0.3, s.left + s.width / 2, s.top + s.height / 2)
results.aPinchOnADiagramOpensIt = !viewer.hidden
// The two-finger double tap closes it.
window.imark.smartMagnify(10, 10)
results.aDoubleTapClosesIt = viewer.hidden

// 11. A save of the same file keeps it open; another file closes it.
wide.dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0 }))
await render(doc + '\\nMore words.\\n')
results.theSameFileSavedKeepsItOpen = !viewer.hidden
await render(doc, '/tmp/b.md')
results.anotherFileClosesIt = viewer.hidden

// 12. Another palette closes it; the copy would be in the old colours.
document.querySelector('.mermaid-block svg').dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0 }))
window.imark.setTheme('light')
results.theSamePaletteKeepsItOpen = !viewer.hidden
window.imark.setTheme('dark')
results.anotherPaletteClosesIt = viewer.hidden
window.imark.setTheme('light')
await new Promise((r) => setTimeout(r, 800))

// 13. Selecting words in a diagram is not a click on it.
const words = document.querySelector('.mermaid-block svg text')
const range = document.createRange()
range.selectNodeContents(words)
getSelection().removeAllRanges()
getSelection().addRange(range)
words.dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0 }))
results.selectingWordsDoesNotOpenIt = viewer.hidden
getSelection().removeAllRanges()

return JSON.stringify({ results, geometry })
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 1_200, height: 900),
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
                    self.snapshots { report(String(describing: value)) }
                }
            }
        }
    }

    /// Pictures to look at, when asked for: the page, and the viewer open.
    func snapshots(then done: @escaping () -> Void) {
        guard let shots else { return done() }
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let take = { (name: String, next: @escaping () -> Void) in
            self.webView.takeSnapshot(with: nil) { image, _ in
                if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: shots.appendingPathComponent("\(name).png"))
                }
                next()
            }
        }
        webView.evaluateJavaScript("document.querySelector('.mermaid-block').scrollIntoView({block:'start'}); window.scrollBy(0,-40)") { _, _ in
            take("page") {
                self.webView.evaluateJavaScript("document.querySelector('.mermaid-block svg').dispatchEvent(new MouseEvent('click', {bubbles:true, button:0}))") { _, _ in
                    take("viewer") {
                        self.webView.evaluateJavaScript("window.imark.magnify(1.2, 400, 300)") { _, _ in
                            take("viewer-zoomed", done)
                        }
                    }
                }
            }
        }
    }
}

func report(_ json: String) {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let checks = object["results"] as? [String: Bool]
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
    if failed > 0, let geometry = object["geometry"] { print("\n\(geometry)") }
    print(failed == 0 ? "\nall good" : "\n\(failed) failing")
    exit(failed == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
harness.run()
app.run()
