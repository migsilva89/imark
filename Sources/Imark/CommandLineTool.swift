import AppKit

/// `imark` in a terminal: a symlink from a directory on the PATH to the script
/// inside the app bundle.
///
/// A symlink rather than a copy, so the command can never be a version behind
/// the app it opens documents in — and so removing it is one `rm`, which is
/// what somebody who installed a command by hand expects to be able to do.
///
/// The alternative was making Imark the handler for .md, which turns `open
/// notes.md` into a review of a file you meant to edit. The two are not the
/// same offer and this one is the smaller.
enum CommandLineTool {
    /// The script in the bundle. It ships with the app; a build that forgot it
    /// has nothing to link to and the offer is not made.
    static var source: URL? {
        if let test = ProcessInfo.processInfo.environment["IMARK_TEST_RESOURCES"] {
            return URL(fileURLWithPath: test).appendingPathComponent("imark")
        }
        return Bundle.main.resourceURL?.appendingPathComponent("imark")
    }

    /// Where it goes. `/usr/local/bin` is where a command installed by hand on
    /// a Mac has always gone and is on the PATH of every shell without anybody
    /// arranging it — but it belongs to root, and asking for an administrator
    /// password to install a convenience is out of proportion. So: there when
    /// Homebrew or somebody has already made it writable, and the home
    /// directory otherwise, where the alert says so and says what to add to
    /// the PATH if it is not there already.
    static var destination: URL {
        let shared = URL(fileURLWithPath: "/usr/local/bin")
        if test == nil, FileManager.default.isWritableFile(atPath: shared.path) {
            return shared.appendingPathComponent("imark")
        }
        return home.appendingPathComponent(".local/bin/imark")
    }

    /// Redirected for the test, which installs for real and must not do it in
    /// the home folder of whoever runs it — nor in /usr/local/bin, which is
    /// shared with every other program on the machine.
    private static var test: String? {
        ProcessInfo.processInfo.environment["IMARK_TEST_HOME"]
    }

    private static var home: URL {
        test.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Installed into this copy of Imark. A link to another copy is ours to
    /// repair, but it is not working for the app whose menu is being used now.
    static var isInstalled: Bool {
        guard let linked = linkedSource, let source else { return false }
        return linked.standardizedFileURL == source.standardizedFileURL
    }

    /// A command under the home directory may need one line in the shell's
    /// PATH. A GUI app does not inherit the shell's startup files, so it cannot
    /// truthfully claim whether that line is already there; it can only give
    /// the advice when it may be needed.
    static var mayNeedPathSetup: Bool {
        destination.path.hasPrefix(home.appendingPathComponent(".local/bin").path)
    }

    /// The destination of the installed link as an absolute URL, including a
    /// relative link somebody may have made by hand.
    private static var linkedSource: URL? {
        guard let raw = try? FileManager.default
            .destinationOfSymbolicLink(atPath: destination.path)
        else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return destination.deletingLastPathComponent().appendingPathComponent(raw)
    }

    /// A link installed by any copy of Imark is safe to repair. A regular file
    /// or a link to another command is somebody else's and remains untouched.
    private static var isManagedLink: Bool {
        linkedSource?.path.hasSuffix("/Contents/Resources/imark") == true
    }

    enum Failure: LocalizedError {
        case missing
        case occupied(String)

        var errorDescription: String? {
            switch self {
            case .missing: "This copy of Imark is missing the command."
            case .occupied(let path):
                "There is already something at \(path) that Imark did not put there. "
                    + "Remove it first, or link the command yourself."
            }
        }
    }

    static func install() throws {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            throw Failure.missing
        }
        let target = destination
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Replacing our own link is how an install after moving the app fixes
        // itself. Replacing anything else is taking somebody's file away
        // without asking, so it stops instead.
        if FileManager.default.fileExists(atPath: target.path) || linkedSource != nil {
            guard isManagedLink else { throw Failure.occupied(target.path) }
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
    }
}
