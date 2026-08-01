import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the whole page over a private `imark://` scheme:
///
///   imark://app/bundle.js        → Contents/Resources/bundle.js
///   imark://file/abs/path/x.png  → /abs/path/x.png
///
/// Going through a scheme handler instead of `file://` means images sitting
/// next to the document load normally without handing the web view read access
/// to a directory, and it keeps the CSP in index.html airtight.
public final class SchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "imark"

    private let resources = SchemeHandler.resourcesDirectory()

    public override init() { super.init() }

    /// The Quick Look extension carries its own copy of the renderer: it runs
    /// sandboxed, and reaching up into the containing app's Resources is not
    /// something the sandbox reliably allows. Fall back to walking up anyway,
    /// so a bundle built without the copy still works.
    private static func resourcesDirectory() -> URL {
        let bundle = Bundle.main
        if let own = bundle.resourceURL,
           FileManager.default.fileExists(atPath: own.appendingPathComponent("index.html").path) {
            return own
        }
        if bundle.bundleURL.pathExtension == "appex" {
            return bundle.bundleURL
                .deletingLastPathComponent()    // PlugIns
                .deletingLastPathComponent()    // Contents
                .appendingPathComponent("Resources")
        }
        return bundle.resourceURL ?? bundle.bundleURL
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host else {
            return task.didFailWithError(URLError(.badURL))
        }

        let path = url.path.removingPercentEncoding ?? url.path

        let target: URL
        switch host {
        case "app":
            // Reject traversal out of Resources before touching the disk.
            let candidate = resources.appendingPathComponent(path).standardizedFileURL
            guard candidate.path.hasPrefix(resources.standardizedFileURL.path) else {
                return task.didFailWithError(URLError(.noPermissionsToReadFile))
            }
            target = candidate
        case "file":
            target = URL(fileURLWithPath: path).standardizedFileURL
        default:
            return task.didFailWithError(URLError(.unsupportedURL))
        }

        guard let data = try? Data(contentsOf: target) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }

        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: target),
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
