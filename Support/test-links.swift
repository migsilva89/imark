// Tests for what a document's links and resources are allowed to reach.
//
//   swiftc -parse-as-library Sources/Imark/LinkRouter.swift \
//          Sources/Imark/MarkdownType.swift \
//          Sources/ImarkRender/SchemeHandler.swift \
//          Support/test-links.swift -o /tmp/imark-test-links && /tmp/imark-test-links
//
// A document is somebody else's writing. These are the three answers that keep
// it from doing more than being read: which page the web view may show, which
// files the page may load, and which links go out without asking.

import Foundation

@main
enum LinksTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)  \(detail())")
        }
    }

    static func url(_ string: String) -> URL { URL(string: string)! }

    static func main() {
        // The page, and only the page.
        check("the renderer page may load", SchemeHandler.isPage(url("imark://app/index.html")))
        check("a fragment is still the page", SchemeHandler.isPage(url("imark://app/index.html#intro")))
        check("a resource is not a page", !SchemeHandler.isPage(url("imark://app/bundle.js")))
        check("a file is not a page", !SchemeHandler.isPage(url("imark://file/Users/someone/notes.md")))
        check("the web is not a page", !SchemeHandler.isPage(url("https://example.com/index.html")))
        check("file:// is not a page", !SchemeHandler.isPage(url("file:///index.html")))
        check("about:blank is not a page", !SchemeHandler.isPage(url("about:blank")))
        check("no URL is not a page", !SchemeHandler.isPage(nil))

        // Images beside the document load; nothing else does.
        for image in ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "PNG"] {
            check("a .\(image) is an image", SchemeHandler.isImage(URL(fileURLWithPath: "/tmp/x.\(image)")))
        }
        for other in ["md", "txt", "js", "css", "html", "json", "plist", "sh", "command", ""] {
            check(".\(other) is not an image", !SchemeHandler.isImage(URL(fileURLWithPath: "/tmp/x.\(other)")))
        }

        // Links out of the document.
        check("https opens", LinkRouter.external(url("https://example.com")) == .open)
        check("http opens", LinkRouter.external(url("http://example.com")) == .open)
        check("mailto opens", LinkRouter.external(url("mailto:someone@example.com")) == .open)
        check("the scheme is not case sensitive", LinkRouter.external(url("HTTPS://example.com")) == .open)
        check(
            "file:// is a local file, never opened",
            LinkRouter.external(url("file:///Applications/Calculator.app")) == .local(path: "/Applications/Calculator.app")
        )
        check(
            "file:// with a host is still only its path",
            LinkRouter.external(url("file://example.com/share/x")) == .local(path: "/share/x")
        )
        for scheme in ["smb://example.com/share", "vscode://file/tmp", "ssh://example.com", "x-apple.systempreferences:", "javascript:void(0)"] {
            check("\(scheme) asks first", LinkRouter.external(url(scheme)) == .ask)
        }

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nall passed")
    }
}
