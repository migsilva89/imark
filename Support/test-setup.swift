import Foundation

@main struct T {
    static var pass = 0, fail = 0
    static func check(_ name: String, _ ok: Bool) {
        if ok { pass += 1; print("OK   \(name)") } else { fail += 1; print("FALHA \(name)") }
    }

    static func main() throws {
        let home = ProcessInfo.processInfo.environment["IMARK_TEST_HOME"]!
        check("nada instalado à partida", !AgentSetup.isInstalled)
        try AgentSetup.install()
        check("instalado", AgentSetup.isInstalled)

        let review = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/commands/imark-review.md")
        let text = try String(contentsOf: review, encoding: .utf8)
        check("o comando existe", FileManager.default.fileExists(atPath: review.path))
        check("sem o marcador do plugin", !text.contains("CLAUDE_PLUGIN_ROOT"))
        check("com o caminho real do script", text.contains(AgentSetup.script!.path))

        let skill = try String(contentsOf: URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/skills/imark-comments/SKILL.md"), encoding: .utf8)
        check("a skill também foi reescrita", !skill.contains("CLAUDE_PLUGIN_ROOT"))

        try AgentSetup.uninstall()
        check("desinstalado", !AgentSetup.isInstalled)
        check("o comando foi apagado", !FileManager.default.fileExists(atPath: review.path))

        print(fail == 0 ? "\nall good (\(pass))" : "\n\(fail) a falhar")
        exit(fail == 0 ? 0 : 1)
    }
}
