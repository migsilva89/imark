import Foundation

enum LinkRouter {
    /// Resolves `[[target]]` against the folder holding the document.
    ///
    /// Order matters: an exact neighbour always wins over a fuzzy match deeper
    /// in the tree, so renaming a note never silently redirects a link.
    static func resolveWiki(_ target: String, from document: URL) -> URL? {
        let folder = document.deletingLastPathComponent()
        let fm = FileManager.default

        // 1. Exact name in the same folder, with or without an extension.
        for candidate in names(for: target) {
            let url = folder.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }

        // 2. Exact name anywhere below the folder.
        guard let walker = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let wanted = normalize(target)
        var fuzzy: URL?

        for case let url as URL in walker {
            guard MarkdownType.matches(url) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            if base == target { return url }
            // 3. Remember an accent/hyphen-insensitive hit as a fallback.
            if fuzzy == nil, normalize(base) == wanted { fuzzy = url }
        }

        return fuzzy
    }

    private static func names(for target: String) -> [String] {
        if !URL(fileURLWithPath: target).pathExtension.isEmpty { return [target] }
        return MarkdownType.extensions.map { "\(target).\($0)" }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[-_\\s]+", with: "", options: .regularExpression)
    }
}
