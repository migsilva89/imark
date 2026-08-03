import Foundation

@main struct T {
    static var pass = 0, fail = 0
    static func check(_ name: String, _ ok: Bool) {
        if ok { pass += 1; print("OK   \(name)") } else { fail += 1; print("FALHA \(name)") }
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
        check("encontra os dois agentes", AgentSetup.found.count == 2)
        check("nada instalado à partida", !AgentSetup.isInstalled)
        try AgentSetup.install()
        check("instalado", AgentSetup.isInstalled)

        let review = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/commands/imark-review.md")
        let text = try String(contentsOf: review, encoding: .utf8)
        check("o comando existe", FileManager.default.fileExists(atPath: review.path))
        check("sem o marcador do plugin", !text.contains("CLAUDE_PLUGIN_ROOT"))
        check("com o caminho real do script", text.contains(AgentSetup.script!.path))

        let skill = try String(contentsOf: root
            .appendingPathComponent(".claude/skills/imark-comments/SKILL.md"), encoding: .utf8)
        check("a skill também foi reescrita", !skill.contains("CLAUDE_PLUGIN_ROOT"))

        let codex = root.appendingPathComponent(".codex/skills/imark-comments/SKILL.md")
        check("o Codex levou a mesma skill", FileManager.default.fileExists(atPath: codex.path))
        check("com o mesmo conteúdo", (try? String(contentsOf: codex, encoding: .utf8)) == skill)
        // Codex removed its global commands folder, so writing one there would
        // be litter in a place nothing reads.
        check("e nenhum comando", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".codex/commands").path))

        try AgentSetup.uninstall()
        check("desinstalado", !AgentSetup.isInstalled)
        check("o comando foi apagado", !FileManager.default.fileExists(atPath: review.path))
        check("e a skill do Codex também", !FileManager.default.fileExists(atPath: codex.path))

        print(fail == 0 ? "\nall good (\(pass))" : "\n\(fail) a falhar")
        exit(fail == 0 ? 0 : 1)
    }
}
