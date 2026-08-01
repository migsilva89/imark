import AppKit
import ImarkRender
import QuickLookUI

/// Space-bar preview in the Finder. Reuses the app's renderer wholesale — same
/// bundle, same CSS, same everything — so a preview and an open document never
/// disagree about how a file looks.
@objc(ImarkPreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let renderer = RendererView(frame: .zero)

    /// Previews must feel instant while arrowing through a folder, so this cap
    /// is tighter than the app's.
    private static let sizeLimit = 2 * 1_024 * 1_024

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_100))
        // Quick Look sizes its panel from this; the default is small enough
        // that a document arrives looking cramped.
        preferredContentSize = NSSize(width: 900, height: 1_100)
        renderer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            renderer.topAnchor.constraint(equalTo: container.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        renderer.setPreviewMode()
    }


    func preparePreviewOfFile(at url: URL) async throws {
        // Capped at 2 MB, so reading inline stays well inside the budget and
        // avoids bouncing between actors for no gain.
        let data = try Data(contentsOf: url)
        let clipped = data.count > Self.sizeLimit ? Data(data.prefix(Self.sizeLimit)) : data

        guard var body = String(data: clipped, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        if data.count > Self.sizeLimit {
            body += "\n\n---\n\n> Preview truncated — open in Imark to see everything."
        }

        renderer.setPreviewMode()
        renderer.render(markdown: body, path: url.path)
    }
}
