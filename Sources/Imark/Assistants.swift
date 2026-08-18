import Foundation

/// The assistant CLIs already installed on this machine, and how to run one.
///
/// Ported from Loadout, for the same reason it works there: the CLI carries its
/// own subscription or login, so there is no API key to keep here, no account to
/// make, and nothing to leak. Imark runs it, shows what came back, and writes
/// nothing.
enum Assistants {
    struct CLI: Identifiable, Hashable {
        let id: String
        let label: String
        let executable: URL
        /// Whitespace-separated argv template, with `{prompt}` where the question
        /// goes — `-p {prompt}`, `exec {prompt}`.
        let argumentTemplate: String

        /// Builds argv for a run: the template's tokens, with the placeholder
        /// replaced by the whole prompt as one argument. This never touches a
        /// shell, so nothing in the prompt is ever re-parsed — a question with a
        /// quote or a semicolon in it stays one argument.
        func arguments(for prompt: String) -> [String] {
            argumentTemplate
                .split(whereSeparator: \.isWhitespace)
                .map { $0 == Self.placeholder ? prompt : String($0) }
        }

        /// What the panel says it runs, e.g. "claude -p" — the placeholder spelled
        /// out rather than the question itself.
        var invocationDescription: String {
            let flags = argumentTemplate.replacingOccurrences(of: Self.placeholder, with: "<prompt>")
            return "\(executable.lastPathComponent) \(flags)"
        }

        static let placeholder = "{prompt}"
    }

    /// Verified non-interactive syntax for each, as of the CLIs shipping today.
    private static let builtins: [(id: String, binary: String, label: String, template: String)] = [
        ("claude", "claude", "Claude Code", "-p {prompt}"),
        ("codex", "codex", "Codex", "exec {prompt}"),
        ("cursor-agent", "cursor-agent", "Cursor", "-p --output-format text {prompt}"),
        ("opencode", "opencode", "opencode", "run {prompt}"),
    ]

    static var builtinLabels: [String] { builtins.map(\.label) }

    /// Every one that is actually there, in the order above. Looked up each time
    /// rather than cached: somebody installing Claude Code should not have to
    /// restart Imark to find the button working.
    static var installed: [CLI] {
        builtins.compactMap { builtin in
            guard let url = locate(builtin.binary) else { return nil }
            return CLI(id: builtin.id, label: builtin.label, executable: url,
                       argumentTemplate: builtin.template)
        }
    }

    static func cli(id: String) -> CLI? {
        installed.first { $0.id == id }
    }

    /// The one the button goes to: whatever was used last, as long as it is still
    /// installed; otherwise the first one found.
    static var preferred: CLI? {
        if let stored = Settings.preferredAssistant, let found = cli(id: stored) { return found }
        return installed.first
    }

    /// Walks `PATH` the way a login shell would, then the usual install places. A
    /// GUI app inherits a bare `PATH` from launchd, which is why the list is
    /// spelled out rather than trusted to the environment alone.
    static func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        if name == "claude" { candidates.append("\(home)/.claude/local/claude") }
        candidates += [
            "\(home)/.local/bin/\(name)",
            "\(home)/.opencode/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        if let versions = try? fm.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            candidates += versions.map { "\(home)/.nvm/versions/node/\($0)/bin/\(name)" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Runs an assistant CLI and hands back what it printed.
///
/// It never writes anything: the answer comes back as text and the reader decides
/// what to do with it. One run at a time per panel, cancellable, with a ceiling —
/// a CLI that has gone away to think for an hour is not an answer.
final class AssistantRun: @unchecked Sendable {
    struct Result {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
    }

    private var process: Process?
    private let lock = NSLock()

    /// - Parameters:
    ///   - directory: the document's own folder, so the CLI can read the file it
    ///     is being asked about without being handed the contents.
    func run(
        _ cli: Assistants.CLI,
        prompt: String,
        in directory: URL,
        timeout: TimeInterval = 300
    ) throws -> Result {
        let task = Process()
        task.executableURL = cli.executable
        task.arguments = cli.arguments(for: prompt)
        task.currentDirectoryURL = directory
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        lock.lock(); process = task; lock.unlock()
        try task.run()

        // Read while it runs: a chatty answer fills the pipe's buffer and both
        // sides sit waiting for the other.
        let sink = Sink()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "pt.miguelsilva.imark.ask").async {
            sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        task.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()

        return Result(
            output: String(data: sink.get(), encoding: .utf8) ?? "",
            exitCode: task.terminationStatus,
            timedOut: timedOut
        )
    }

    func cancel() {
        lock.lock()
        let task = process
        lock.unlock()
        task?.terminate()
    }

    /// Hands the child's output from the reader queue back to the caller without
    /// sharing a var across threads.
    private final class Sink: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
