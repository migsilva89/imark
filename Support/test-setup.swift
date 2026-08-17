import Foundation

@main struct T {
    static var pass = 0, fail = 0
    static func check(_ name: String, _ ok: Bool) {
        if ok { pass += 1; print("OK   \(name)") } else { fail += 1; print("FAIL \(name)") }
    }

    /// Changes a file inside the bundle, the way a new release of the app would:
    /// same file, different words, and no longer the one on disk.
    static func newerVersion(of file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        try (text + "\nNewer instructions.\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func main() throws {
        let home = ProcessInfo.processInfo.environment["IMARK_TEST_HOME"]!
        let root = URL(fileURLWithPath: home)
        // Both agents present, so both must be served by the one skill file.
        for folder in [".claude", ".codex"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        check("finds both agents", AgentSetup.found.count == 2)
        check("nothing installed to begin with", !AgentSetup.isInstalled)
        try AgentSetup.install()
        check("installed", AgentSetup.isInstalled)

        let review = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/commands/imark-review.md")
        let text = try String(contentsOf: review, encoding: .utf8)
        check("the command exists", FileManager.default.fileExists(atPath: review.path))
        check("no plugin placeholder left", !text.contains("CLAUDE_PLUGIN_ROOT"))
        check("carries the real script path", text.contains(AgentSetup.script!.path))

        let skill = try String(contentsOf: root
            .appendingPathComponent(".claude/skills/imark-comments/SKILL.md"), encoding: .utf8)
        check("the skill was rewritten too", !skill.contains("CLAUDE_PLUGIN_ROOT"))

        let codex = root.appendingPathComponent(".codex/skills/imark-comments/SKILL.md")
        check("Codex got the same skill", FileManager.default.fileExists(atPath: codex.path))
        check("with the same contents", (try? String(contentsOf: codex, encoding: .utf8)) == skill)
        // Codex removed its global commands folder, so writing one there would
        // be litter in a place nothing reads.
        check("and no commands", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".codex/commands").path))

        // MARK: - Bringing the copies up to date

        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo
            .environment["IMARK_TEST_RESOURCES"]!).appendingPathComponent("agent")
        check("the bundle carries the shipped-file manifest", FileManager.default
            .fileExists(atPath: bundle.appendingPathComponent("shipped.txt").path))

        // Just installed, so what is on disk is already the bundle's own copy.
        check("a fresh install has nothing to bring forward", try AgentSetup.refresh().isEmpty)

        // An update, from here: the app now carries a newer command and a newer
        // skill than the ones written at setup.
        try newerVersion(of: bundle.appendingPathComponent("commands/imark-review.md"))
        try newerVersion(of: bundle.appendingPathComponent("SKILL.md"))

        // And somebody's own editing, in the skill Claude Code reads. Codex's
        // copy of the same skill is untouched, so one pass has to do both things.
        let edited = root.appendingPathComponent(".claude/skills/imark-comments/SKILL.md")
        let mine = "My own version of this. Please keep it.\n"
        try mine.write(to: edited, atomically: true, encoding: .utf8)

        let report = try AgentSetup.refresh()
        check("the out-of-date command was rewritten", report.updated.contains(review))
        check("with what the app now carries", try String(contentsOf: review, encoding: .utf8)
            .contains("Newer instructions."))
        check("Codex's untouched copy of the skill too", report.updated.contains(codex))
        check("the edited skill was left alone", report.kept == [edited])
        check("with the edit still in it",
              try String(contentsOf: edited, encoding: .utf8) == mine)
        check("the notes command was already current", !report.updated.contains(root
            .appendingPathComponent(".claude/commands/imark-notes.md")))
        // The bug as it was reported: a file from a past release, put there by an
        // app that lived somewhere else. It is still one of ours, so it comes
        // forward, and the path in it comes with it.
        if let old = ProcessInfo.processInfo.environment["IMARK_TEST_OLD_NOTES"] {
            let notes = root.appendingPathComponent(".claude/commands/imark-notes.md")
            try String(contentsOf: URL(fileURLWithPath: old), encoding: .utf8)
                .write(to: notes, atomically: true, encoding: .utf8)
            let past = try AgentSetup.refresh()
            check("a copy from an older release was rewritten", past.updated == [notes])
            check("pointing at this app's script",
                  try String(contentsOf: notes, encoding: .utf8).contains(AgentSetup.script!.path))
        }

        // The second launch of the same version finds nothing left to write. The
        // edited file keeps being reported, because it keeps being somebody's.
        check("nothing to rewrite the next time", try AgentSetup.refresh().updated.isEmpty)

        try AgentSetup.uninstall()
        check("uninstalled", !AgentSetup.isInstalled)
        check("the command was deleted", !FileManager.default.fileExists(atPath: review.path))
        check("and Codex's skill too", !FileManager.default.fileExists(atPath: codex.path))

        print(fail == 0 ? "\nall good (\(pass))" : "\n\(fail) failing")
        exit(fail == 0 ? 0 : 1)
    }
}
