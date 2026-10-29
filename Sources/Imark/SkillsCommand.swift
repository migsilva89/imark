import Foundation

/// Terminal presentation only; AgentSetup owns every filesystem decision.
enum SkillsCommand {
    static let help = """
    usage: imark skills                  show agent skills and commands
           imark skills install          install missing files and update shipped copies
           imark skills update           update existing shipped copies only
           imark skills --help           show this help

    Supports Claude Code and Codex. Edited files are kept, never overwritten.
    Installs skills and loose commands only; no plugins or settings changes.
    No window opens. No --force option is provided.
    Exit codes: 0 = complete (edited files kept); 1 = missing/outdated files,
    no supported agents, or an error; 2 = invalid arguments.
    Absent agents and unsupported agents do not affect the result when a
    supported agent is present.
    """

    static func run(_ arguments: [String]) -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            print(help)
            return 0
        }
        guard arguments.isEmpty || arguments == ["install"] || arguments == ["update"] else {
            FileHandle.standardError.write(Data("imark skills: invalid arguments\n\(help)\n".utf8))
            return 2
        }
        do {
            if let action = arguments.first {
                let report = try action == "install" ? AgentSetup.install() : AgentSetup.refresh()
                print("\(action == "install" ? "Installed or updated" : "Updated") \(report.updated.count) file(s).")
                for file in report.kept { print("Kept edited file: \(file.path)") }
            }
            let statuses = try AgentSetup.status()
            for status in statuses {
                print("\(status.agent.name): \(status.present ? "present" : "not found")")
                for file in status.files {
                    print("  \(file.name): \(file.state.rawValue)\(file.state == .edited ? " (kept)" : "")")
                }
            }
            for agent in AgentSetup.unsupportedFound {
                print("\(agent.name): present (not supported)")
            }
            let present = statuses.filter(\.present)
            return present.isEmpty || present.contains { $0.files.contains {
                $0.state == .missing || $0.state == .outdated
            } } ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data("imark skills: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
