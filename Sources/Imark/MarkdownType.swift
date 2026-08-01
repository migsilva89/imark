import AppKit
import UniformTypeIdentifiers

enum MarkdownType {
    /// Extensions Imark claims in Info.plist. Kept in one place so the open
    /// panel, the sibling-file list and the plist can never drift apart.
    static let extensions = ["md", "markdown", "mdown", "mkd", "mdtext", "mdx", "qmd"]

    static let contentTypes: [UTType] = {
        var types: [UTType] = [.init(filenameExtension: "md") ?? .plainText]
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        return types
    }()

    static func matches(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Registers Imark as the handler for markdown, so the user does not have
    /// to walk through Get Info → Open with → Change All.
    static func makeImarkDefault(completion: @escaping (Bool) -> Void) {
        guard let markdown = UTType("net.daringfireball.markdown") else {
            return completion(false)
        }
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpen: markdown
        ) { error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
}
