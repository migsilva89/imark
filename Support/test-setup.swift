import Foundation

@main struct T {
    static var pass = 0, fail = 0
    static func check(_ name: String, _ ok: Bool) {
        if ok { pass += 1; print("OK   \(name)") } else { fail += 1; print("FAIL \(name)") }
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

        try AgentSetup.uninstall()
        check("uninstalled", !AgentSetup.isInstalled)
        check("the command was deleted", !FileManager.default.fileExists(atPath: review.path))
        check("and Codex's skill too", !FileManager.default.fileExists(atPath: codex.path))

        print(fail == 0 ? "\nall good (\(pass))" : "\n\(fail) failing")
        exit(fail == 0 ? 0 : 1)
    }
}
