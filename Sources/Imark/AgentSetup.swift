import Foundation

/// Installing the Claude Code integration from inside the app, for somebody who
/// downloaded a disk image and has no repository to add.
///
/// Skills and commands only — never the plugin. A plugin is not a folder of
/// files: Claude Code keeps its own registry of what is installed and where it
/// came from, and writing into another program's bookkeeping is how you break
/// the plugins somebody already had and get blamed for it. A skill is a file in
/// a folder, read on sight, and uninstalling is deleting it.
///
/// Which leaves one thing this cannot do: register the `ExitPlanMode` hook. A
/// hook belongs to a plugin, and the alternative — editing somebody's
/// `settings.json` from a button — is exactly the kind of reach this is
/// avoiding. That one stays a line to copy.
enum AgentSetup {
    private static var home: URL {
        // Redirected for the test, which installs and uninstalls for real and
        // must not do it in whoever is running it's actual home folder.
        if let test = ProcessInfo.processInfo.environment["IMARK_TEST_HOME"] {
            return URL(fileURLWithPath: test)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var skillFile: URL {
        home.appendingPathComponent(".claude/skills/imark-comments/SKILL.md")
    }

    static var commandsDirectory: URL {
        home.appendingPathComponent(".claude/commands")
    }

    /// The commands this writes, named after the app rather than after the
    /// plugin: installed loose they have no `imark:` namespace in front of them,
    /// and `/imark-review` beside somebody's own `/review` should still say
    /// whose it is.
    private static let commands = ["imark-review.md", "imark-notes.md"]

    private static var commandFiles: [URL] {
        commands.map { commandsDirectory.appendingPathComponent($0) }
    }

    /// Where the app keeps its own files. `Bundle.main` is the app when the app
    /// is running and the test binary when the test is, so the test says which
    /// bundle it means.
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

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: skillFile.path)
    }

    /// Claude Code has to be there for any of this to mean anything. Its folder
    /// is the only signal available without running it.
    static var claudeCodeFound: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
    }

    enum Failure: LocalizedError {
        case missingResources
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .missingResources:
                "This copy of Imark is missing the agent files."
            case .cannotWrite(let path):
                "Imark couldn't write to \(path)."
            }
        }
    }

    static func install() throws {
        guard let resources,
              let script,
              FileManager.default.fileExists(atPath: script.path)
        else { throw Failure.missingResources }

        let source = resources.appendingPathComponent("agent")
        let manager = FileManager.default

        try write(
            rewritten(at: source.appendingPathComponent("SKILL.md"), script: script),
            to: skillFile,
            using: manager
        )
        for name in commands {
            try write(
                rewritten(at: source.appendingPathComponent("commands/\(name)"), script: script),
                to: commandsDirectory.appendingPathComponent(name),
                using: manager
            )
        }
    }

    static func uninstall() throws {
        let manager = FileManager.default
        try? manager.removeItem(at: skillFile.deletingLastPathComponent())
        for file in commandFiles where manager.fileExists(atPath: file.path) {
            try manager.removeItem(at: file)
        }
    }

    /// The files ship with the plugin's own `${CLAUDE_PLUGIN_ROOT}` in them,
    /// which means nothing outside a plugin. Installed loose they need the real
    /// path — this bundle's, wherever somebody happened to put the app.
    private static func rewritten(at url: URL, script: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.missingResources
        }
        return text
            .replacingOccurrences(
                of: "\"${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs\"",
                with: "\"\(script.path)\""
            )
            .replacingOccurrences(
                of: "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs",
                with: script.path
            )
    }

    private static func write(_ text: String, to url: URL, using manager: FileManager) throws {
        let folder = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.cannotWrite(folder.path)
        }
    }
}
