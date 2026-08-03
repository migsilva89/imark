import Foundation

/// Installing the coding-agent integration from inside the app, for somebody who
/// downloaded a disk image and has no repository to add.
///
/// Skills only — never a plugin. A plugin is not a folder of files: Claude Code
/// keeps its own registry of what is installed and where it came from, and
/// writing into another program's bookkeeping is how you break the plugins
/// somebody already had and get blamed for it. A skill is a file in a folder,
/// read on sight, and uninstalling is deleting it.
///
/// It is also the same file everywhere. Claude Code and Codex both read a
/// `SKILL.md` out of a `skills` folder, so one document serves both — Codex's
/// own custom prompts are deprecated in favour of exactly this. Commands are
/// where they differ: only Claude Code has a global folder for them.
///
/// Which leaves one thing this cannot do: register the `ExitPlanMode` hook. A
/// hook belongs to a plugin, and the alternative — editing somebody's
/// `settings.json` from a button — is the same reach this is avoiding. That one
/// stays a line to copy.
enum AgentSetup {
    struct Agent {
        let name: String
        /// What says the agent is on this machine at all.
        let home: String
        let skills: String
        /// Only Claude Code takes loose commands. Codex removed its equivalent.
        let commands: String?
    }

    /// Only agents whose skills folder is actually known. An agent added here on
    /// a guess would have Imark writing files into a place nothing reads, which
    /// looks exactly like working until somebody tries to use it. Others get
    /// named in the alert as found-but-not-handled instead.
    static let known = [
        Agent(name: "Claude Code", home: ".claude", skills: ".claude/skills", commands: ".claude/commands"),
        Agent(name: "Codex", home: ".codex", skills: ".codex/skills", commands: nil),
    ]

    /// Agents on the machine that this does not know how to set up. Named rather
    /// than ignored: somebody with Gemini installed should be told it was seen
    /// and skipped, not left wondering whether it was handled quietly.
    static let others = [
        Agent(name: "Cursor", home: ".cursor", skills: "", commands: nil),
        Agent(name: "Gemini CLI", home: ".gemini", skills: "", commands: nil),
        Agent(name: "Copilot", home: ".copilot", skills: "", commands: nil),
        Agent(name: "OpenCode", home: ".config/opencode", skills: "", commands: nil),
    ]

    static var unsupportedFound: [Agent] {
        others.filter {
            FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent($0.home).path)
        }
    }

    private static var homeDirectory: URL {
        // Redirected for the test, which installs and uninstalls for real and
        // must not do it in the actual home folder of whoever runs it.
        if let test = ProcessInfo.processInfo.environment["IMARK_TEST_HOME"] {
            return URL(fileURLWithPath: test)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static let skillName = "imark-comments"
    private static let commandNames = ["imark-review.md", "imark-notes.md"]

    static func skillFile(for agent: Agent) -> URL {
        homeDirectory.appendingPathComponent("\(agent.skills)/\(skillName)/SKILL.md")
    }

    private static func commandFiles(for agent: Agent) -> [URL] {
        guard let commands = agent.commands else { return [] }
        return commandNames.map { homeDirectory.appendingPathComponent("\(commands)/\($0)") }
    }

    /// The agents on this machine. An offer to set up something you do not have
    /// is a puzzle rather than a feature.
    static var found: [Agent] {
        known.filter {
            FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent($0.home).path)
        }
    }

    static var installed: [Agent] {
        found.filter { FileManager.default.fileExists(atPath: skillFile(for: $0).path) }
    }

    static var isInstalled: Bool {
        !found.isEmpty && installed.count == found.count
    }

    /// Every path this will write, in the order it will write them. Shown before
    /// anything is written: this is the one thing Imark does outside its own
    /// files and somebody's documents, and it lands in folders other programs
    /// own.
    static var plannedFiles: [URL] {
        found.flatMap { [skillFile(for: $0)] + commandFiles(for: $0) }
    }

    // MARK: - Where the app keeps its copy

    /// `Bundle.main` is the app when the app is running and the test binary when
    /// the test is, so the test says which bundle it means.
    private static var resources: URL? {
        if let test = ProcessInfo.processInfo.environment["IMARK_TEST_RESOURCES"] {
            return URL(fileURLWithPath: test)
        }
        return Bundle.main.resourceURL
    }

    /// The script, inside the bundle. It travels with the app so that updating
    /// the app updates it, and so there is nothing to keep in sync by hand.
    static var script: URL? {
        resources?.appendingPathComponent("agent/imark.mjs")
    }

    enum Failure: LocalizedError {
        case missingResources
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .missingResources: "This copy of Imark is missing the agent files."
            case .cannotWrite(let path): "Imark couldn't write to \(path)."
            }
        }
    }

    static func install() throws {
        guard let resources, let script,
              FileManager.default.fileExists(atPath: script.path)
        else { throw Failure.missingResources }

        let source = resources.appendingPathComponent("agent")
        for agent in found {
            try write(
                rewritten(at: source.appendingPathComponent("SKILL.md"), script: script),
                to: skillFile(for: agent)
            )
            guard let commands = agent.commands else { continue }
            for name in commandNames {
                try write(
                    rewritten(at: source.appendingPathComponent("commands/\(name)"), script: script),
                    to: homeDirectory.appendingPathComponent("\(commands)/\(name)")
                )
            }
        }
    }

    /// Removes from every agent it knows, not only the ones currently found: an
    /// agent uninstalled since is exactly the case where our leftovers would sit
    /// there forever.
    static func uninstall() throws {
        let manager = FileManager.default
        for agent in known {
            try? manager.removeItem(at: skillFile(for: agent).deletingLastPathComponent())
            for file in commandFiles(for: agent) where manager.fileExists(atPath: file.path) {
                try? manager.removeItem(at: file)
            }
        }
    }

    /// The files ship with the plugin's own `${CLAUDE_PLUGIN_ROOT}` in them,
    /// which means nothing outside a plugin. Installed loose they need the real
    /// path — this bundle's, wherever somebody happened to put the app.
    private static func rewritten(at url: URL, script: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.missingResources
        }
        return text.replacingOccurrences(
            of: "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs",
            with: script.path
        )
    }

    private static func write(_ text: String, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.cannotWrite(folder.path)
        }
    }
}
