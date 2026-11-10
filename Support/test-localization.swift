#!/usr/bin/env swift
//
// Localized renderer labels, preview mode, and English fallback in a real web view.
//
//   swift Support/test-localization.swift
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
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-localization")
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

// Resolve real Foundation language resources as well as the renderer labels.
let appBundle = Bundle(path: repo.appendingPathComponent("dist/Imark.app").path)!
precondition(Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: ["zh-Hans"]).first == "zh-Hans")
precondition(Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: ["en"]).first == "en")
let chineseBundle = Bundle(path: appBundle.path(forResource: "zh-Hans", ofType: "lproj")!)!
let englishBundle = Bundle(path: appBundle.path(forResource: "en", ofType: "lproj")!)!
precondition(chineseBundle.localizedString(forKey: "File", value: nil, table: nil) == "文件")
precondition(englishBundle.localizedString(forKey: "File", value: nil, table: nil) == "File")
precondition(String(format: chineseBundle.localizedString(forKey: "%@ of %@", value: nil, table: nil), "2", "5") == "第 2 项，共 5 项")
print("OK   nativeLanguageSelectionAndFormattedText")

let SCRIPT = #"""
window.webkit = { messageHandlers: { imark: { postMessage: () => {} } } }
const markdown = '# 标题\n\n原文 stays unchanged.\n\n```js\nconst x = 1\n```\n\n<!-- imark quote="原文" at="2026-10-26T00:00Z"\n用户评论 stays unchanged.\n-->\n'
const results = {}
for (const preview of [false, true]) {
  await window.imark.render({ markdown, path: '/tmp/test.md', language: 'zh-Hans', preview })
  const root = document.getElementById('content')
  results[`chineseCopyInPreview${preview}`] = root.querySelector('.copy-btn')?.textContent === '复制'
  results[`chineseCommentActionInPreview${preview}`] = root.querySelector('.note-edit')?.title === '编辑此评论'
  results[`chineseBlockControlInPreview${preview}`] = document.querySelector('.block-plus')?.getAttribute('aria-label') === '评论此段落'
  results[`chinesePageLanguageInPreview${preview}`] = document.documentElement.lang === 'zh-Hans'
  results[`documentIsUnchangedInPreview${preview}`] = root.textContent.includes('原文 stays unchanged.') && root.textContent.includes('用户评论 stays unchanged.')
}
await window.imark.render({ markdown, path: '/tmp/test.md', language: 'en', preview: false })
results.englishCopy = document.querySelector('.copy-btn')?.textContent === 'Copy'
results.englishCommentAction = document.querySelector('.note-edit')?.title === 'Edit this note'
await window.imark.render({ markdown, language: 'fr' })
results.unsupportedLanguageFallsBackToEnglish = document.documentElement.lang === 'en' && document.querySelector('.copy-btn')?.textContent === 'Copy'
return JSON.stringify(results)
"""#

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

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    fputs("FAIL localization test timed out\n", stderr)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
harness.run()
app.run()
