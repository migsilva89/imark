#!/usr/bin/env swift
//
// Renders a local page in an offscreen WKWebView and writes a PNG.
//
//   swift shoot.swift <page-url> <out.png> [js-to-run-first]
//
// Exists so UI work can be looked at without screenshotting the whole desktop.
//
// Two things to know, both learned the hard way:
//
//  * requestAnimationFrame never fires in a web view with no window, so the
//    page gets one parked off-screen.
//  * even then the window composites once and then stops, so anything that
//    changes after load will not appear. To capture an interaction, run it,
//    dump `document.documentElement.outerHTML`, strip the scripts, and shoot
//    that as a static page.

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: shoot.swift <url> <out.png> [js]\n".utf8))
    exit(2)
}
let pageURL = URL(string: args[1])!
let output = URL(fileURLWithPath: args[2])
let script = args.count > 3 ? args[3] : nil
let probe = args.count > 4 ? args[4] : nil
// Optional crop, in page points: the rail lives in a narrow strip and the rest
// of the document is just noise when the strip is what is being judged.
let cropWidth = args.count > 5 ? Double(args[5]) ?? 900 : 900
let cropHeight = args.count > 6 ? Double(args[6]) ?? 1_100 : 1_100

final class Shooter: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 1_100),
            configuration: config
        )
        super.init()
        webView.navigationDelegate = self
    }

    private var window: NSWindow?

    func run() {
        // requestAnimationFrame never fires in a web view that has no window,
        // so the page gets one — parked far off-screen where nobody sees it.
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 900, height: 1_100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window

        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give the bundle time to parse, render mermaid and settle its layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let script else { return self.snap() }
            webView.evaluateJavaScript(script) { result, error in
                if let error { print("js erro: \(error)") }
                if let result { print("js: \(result)") }
                // Then let the transitions land before the shutter.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let probe else { return self.snap() }
                    webView.evaluateJavaScript(probe) { value, error in
                        if let error { print("probe erro: \(error)") }
                        if let value { print("probe: \(value)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.snap() }
                    }
                }
            }
        }
    }

    private func snap() {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight)
        webView.takeSnapshot(with: config) { image, error in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("snapshot falhou: \(error?.localizedDescription ?? "?")\n".utf8))
                exit(1)
            }
            try? png.write(to: output)
            print(output.path)
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no Dock icon, no stealing focus
let shooter = Shooter()
shooter.run()
app.run()
