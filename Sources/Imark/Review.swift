import AppKit

/// A document handed over for review by something that is waiting for an answer
/// — a coding agent, usually, through the Claude Code plugin in `plugin/`.
///
/// This is the one place where Imark knows another tool exists. It is kept to
/// two facts: whether the open document asked to be reviewed, and a small file
/// written beside it when you decide. Nothing about the tool on the other end
/// reaches any further into the app than that.
enum Review {
    enum Decision: String {
        case approve
        case sendBack = "send-back"
    }

    /// Marked in the front matter rather than by which folder the file sits in:
    /// a review that gets moved or renamed is still a review, and a folder name
    /// is not something the person reading can see.
    ///
    ///     ---
    ///     imark: review
    ///     ---
    ///
    /// Cached because `validateToolbarItem` asks on every pass of the run loop
    /// and this reads from disk.
    private nonisolated(unsafe) static var known: (url: URL, review: Bool)?

    static func isReview(_ url: URL) -> Bool {
        if let known, known.url == url { return known.review }
        let review = readsAsReview(url)
        known = (url, review)
        return review
    }

    /// The document changed under us — the front matter may have gone with it.
    static func forget() { known = nil }

    private static func readsAsReview(_ url: URL) -> Bool {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = source.components(separatedBy: "\n").makeIterator()
        guard lines.next()?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        // Front matter only. A line saying `imark: review` in the body is prose
        // about this feature, not an instruction — this very file would trip it.
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { return false }
            if trimmed.replacingOccurrences(of: " ", with: "") == "imark:review" { return true }
        }
        return false
    }

    /// Written beside the document, never into it. The document is the reviewer's
    /// — it carries their notes and nothing else. Anything the machinery needs
    /// to say goes in its own file, where deleting it costs nothing.
    static func decide(_ decision: Decision, notes: Int, for url: URL) throws {
        let payload: [String: Any] = [
            "decision": decision.rawValue,
            "notes": notes,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: sidecar(for: url), options: .atomic)
    }

    /// What was decided already, so reopening a review shows the answer instead
    /// of offering the choice again.
    static func decision(for url: URL) -> Decision? {
        guard let data = try? Data(contentsOf: sidecar(for: url)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = payload["decision"] as? String
        else { return nil }
        return Decision(rawValue: raw)
    }

    private static func sidecar(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("decision.json")
    }
}
