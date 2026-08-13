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
        case requestChanges = "request-changes"
    }

    /// A review is announced, not marked. The agent writes a small request file
    /// here before opening the document, the buttons appear over the document
    /// itself, and the decision goes back beside the request — so the reviewed
    /// file is the reviewer's own file, carrying their notes and nothing else.
    ///
    /// The environment override exists for the round-trip test, which must not
    /// share a directory with a real review that happens to be open.
    private static var pendingDir: URL {
        if let override = ProcessInfo.processInfo.environment["IMARK_PENDING_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".imark/pending")
    }

    /// The request an agent registered for this document, if one is waiting.
    /// Matched on the file's resolved path: the request names the file, and a
    /// symlink must not make one document two.
    ///
    /// A request that already has its answer belongs to a script that crashed
    /// before cleaning up. One still unanswered always wins over it — otherwise
    /// the leftovers of a dead review would show a fresh one as already decided,
    /// and the buttons the reviewer needs would never appear.
    ///
    /// Between two unanswered requests for the same file the newest wins, and it
    /// has to be the newest: a review the reviewer walked away from leaves its
    /// request behind unanswered, and the whoever-sorts-first version handed the
    /// decision to that corpse — the agent actually waiting was never told
    /// anything and the window looked answered. The one that opened the window
    /// in front of the reviewer is the last one to have asked.
    private static func request(for url: URL) -> URL? {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: pendingDir.path) else { return nil }
        let target = url.resolvingSymlinksInPath().path
        var waiting: (file: URL, at: String)?
        var answered: (file: URL, at: String)?
        for name in names
        where name.hasSuffix(".json") && !name.hasSuffix(".decision.json") {
            let file = pendingDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requested = payload["file"] as? String,
                  URL(fileURLWithPath: requested).resolvingSymlinksInPath().path == target
            else { continue }
            // The stamp the script wrote when it asked. All of them are UTC in
            // the same shape, so later reads as greater; a request without one
            // is older than anything that has one, never newer.
            let candidate = (file, payload["at"] as? String ?? "")
            if FileManager.default.fileExists(atPath: answer(to: file).path) {
                if answered == nil || candidate.1 > answered!.at { answered = candidate }
            } else if waiting == nil || candidate.1 > waiting!.at {
                waiting = candidate
            }
        }
        return (waiting ?? answered)?.file
    }

    private static func answer(to request: URL) -> URL {
        request.deletingPathExtension().appendingPathExtension("decision.json")
    }

    /// The front matter is the older announcement, kept for documents built to
    /// carry it — a plan with no file of its own, or a review opened by a
    /// script newer than this app:
    ///
    ///     ---
    ///     imark: review
    ///     ---
    ///
    /// Cached because `validateToolbarItem` asks on every pass of the run loop
    /// and this reads from disk. The pending directory is asked fresh each
    /// time — it is a listing of at most a few entries, and a request appears
    /// *after* the document may already be open, which is exactly when a stale
    /// cache would hide the buttons.
    private nonisolated(unsafe) static var known: (url: URL, review: Bool)?

    static func isReview(_ url: URL) -> Bool {
        if request(for: url) != nil { return true }
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

    /// Never written into the document. The document is the reviewer's — it
    /// carries their notes and nothing else. The answer goes beside the request
    /// that announced the review; for a front-matter review with no request, it
    /// falls back to a sidecar beside the file, as it always did.
    static func decide(_ decision: Decision, notes: Int, for url: URL) throws {
        let payload: [String: Any] = [
            "decision": decision.rawValue,
            "notes": notes,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let destination = request(for: url).map(answer(to:)) ?? sidecar(for: url)
        try data.write(to: destination, options: .atomic)
    }

    /// What was decided already, so reopening a review shows the answer instead
    /// of offering the choice again. Once the agent has read the answer it
    /// deletes the whole handshake, and the document goes back to being a
    /// document.
    static func decision(for url: URL) -> Decision? {
        let source = request(for: url).map(answer(to:)) ?? sidecar(for: url)
        guard let data = try? Data(contentsOf: source),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = payload["decision"] as? String
        else { return nil }
        return Decision(rawValue: raw)
    }

    private static func sidecar(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("decision.json")
    }
}
