import CryptoKit
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

    /// One file the app carries: what it is called inside the bundle's `agent`
    /// folder, and where that copy has to land. Named as a pair because every
    /// operation here needs both halves — writing needs the source, refreshing
    /// needs to compare the two.
    private struct Payload {
        let name: String
        let destination: URL
    }

    private static func payloads(for agent: Agent) -> [Payload] {
        [Payload(name: "SKILL.md", destination: skillFile(for: agent))]
            + zip(commandNames, commandFiles(for: agent)).map {
                Payload(name: "commands/\($0)", destination: $1)
            }
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

    /// Whether any copy of ours is out there at all — the question the refresh
    /// asks, where `isInstalled` answers the stricter one the welcome window
    /// needs. An agent installed since setup makes `isInstalled` false, and that
    /// must not stop the files of the agent that *was* set up from moving
    /// forward.
    static var hasInstalledFiles: Bool {
        plannedFiles.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every path this will write, in the order it will write them. Shown before
    /// anything is written: this is the one thing Imark does outside its own
    /// files and somebody's documents, and it lands in folders other programs
    /// own.
    static var plannedFiles: [URL] {
        found.flatMap { payloads(for: $0).map(\.destination) }
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
        let script = try readyScript()
        for agent in found {
            for file in payloads(for: agent) {
                try write(contents(of: file, script: script), to: file.destination)
            }
        }
    }

    // MARK: - Keeping the copies current

    /// What a refresh did, in the two terms that matter to whoever reads it:
    /// which copies were brought up to date, and which were left as they are
    /// because they had stopped being Imark's to overwrite.
    struct Refresh {
        var updated: [URL] = []
        var kept: [URL] = []

        var isEmpty: Bool { updated.isEmpty && kept.isEmpty }
    }

    /// Brings the installed copies back in line with the ones this app carries.
    ///
    /// The skill is the instructions an agent follows, and it used to be copied
    /// out of the bundle exactly once, at setup. Nothing moved it forward after
    /// that: somebody who set up in August was still running August's
    /// instructions four releases later, with no reason to suspect it — they had
    /// updated the app, so they had updated everything. Imark does not install
    /// itself, so the first launch of a new version is the first moment new code
    /// runs, and that is where this belongs.
    ///
    /// Nobody is asked again. The question was answered once, and the answer was
    /// about the integration rather than about a particular version of a file.
    ///
    /// Two things it deliberately does not do. It does not touch a file whose
    /// contents are not on the shipped list — that file has somebody's editing in
    /// it, and an edit is theirs to keep even when it is out of date, so it is
    /// reported instead of replaced. And it does not create a file that is not
    /// there: an agent installed since setup is the setup offer's business, not
    /// this one's.
    static func refresh() throws -> Refresh {
        let script = try readyScript()
        var report = Refresh()
        for agent in found {
            for file in payloads(for: agent) {
                guard let current = try? String(contentsOf: file.destination, encoding: .utf8)
                else { continue }
                let wanted = try contents(of: file, script: script)
                // Compared against the text as it would be written, path and
                // all, so dragging the app somewhere else is repaired too.
                if current == wanted { continue }
                guard shipped(file.name).contains(fingerprint(of: current)) else {
                    report.kept.append(file.destination)
                    continue
                }
                try write(wanted, to: file.destination)
                report.updated.append(file.destination)
            }
        }
        return report
    }

    /// The hashes of every version of one file that Imark has shipped, written
    /// into the bundle at build time from `Support/shipped-agent-files.txt`.
    ///
    /// A bundle with no manifest — anything built before this existed —
    /// recognises nothing and therefore leaves everything alone. Refusing to
    /// touch a file we cannot vouch for is the safe way to be wrong.
    private static func shipped(_ name: String) -> Set<String> {
        guard let resources,
              let text = try? String(
                  contentsOf: resources.appendingPathComponent("agent/shipped.txt"),
                  encoding: .utf8
              )
        else { return [] }
        var hashes: Set<String> = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[1] == name else { continue }
            hashes.insert(String(fields[0]))
        }
        return hashes
    }

    /// A file identified by what it says rather than by where this Mac keeps
    /// Imark. Installed copies carry the absolute path of the app that wrote
    /// them, so one shipped file hashes differently on two machines, and
    /// differently again after somebody moves the app. Putting the placeholder
    /// back before hashing is what makes the manifest a list of files instead of
    /// a list of paths.
    ///
    /// It only recognises the path in the quoted `node "…/imark.mjs"` form the
    /// files have always used. Anything else canonicalises to itself, so the
    /// file reads as edited and is left alone — the direction to be wrong in.
    private static func fingerprint(of text: String) -> String {
        // `$` opens a group reference in a replacement template, and the
        // placeholder starts with one, so it is escaped rather than expanded.
        let template = "\"\(placeholder.replacingOccurrences(of: "$", with: "\\$"))\""
        let canonical = text.replacingOccurrences(
            of: "\"[^\"\n]*imark\\.mjs\"",
            with: template,
            options: .regularExpression
        )
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    /// What the app carries, ready to be written. Read every time rather than
    /// cached: the bundle is the only copy that is ever authoritative, and it
    /// changes when the app is replaced.
    ///
    /// The files ship with the plugin's own `${CLAUDE_PLUGIN_ROOT}` in them,
    /// which means nothing outside a plugin. Installed loose they need the real
    /// path — this bundle's, wherever somebody happened to put the app.
    private static func contents(of file: Payload, script: URL) throws -> String {
        guard let resources,
              let text = try? String(
                  contentsOf: resources.appendingPathComponent("agent/\(file.name)"),
                  encoding: .utf8
              )
        else { throw Failure.missingResources }
        return text.replacingOccurrences(of: placeholder, with: script.path)
    }

    private static let placeholder = "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs"

    /// The script both writing paths need, checked once: a bundle without it has
    /// nothing worth writing anywhere.
    private static func readyScript() throws -> URL {
        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            throw Failure.missingResources
        }
        return script
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
