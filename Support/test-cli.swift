import Foundation

/// Installing `imark` on the PATH: where the link goes, what it points at, and
/// what it refuses to touch.
///
/// Compiled and run by Support/test-cli.sh, which gives it a throwaway home.
@main struct T {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() {
        let files = FileManager.default
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IMARK_TEST_HOME"]!)
        let link = CommandLineTool.destination

        check("it goes under the home directory in a test", link.path.hasPrefix(home.path), link.path)
        check("nothing is installed to begin with", !CommandLineTool.isInstalled)

        do { try CommandLineTool.install() } catch {
            check("the first install works", false, "\(error)")
        }
        check("it says so afterwards", CommandLineTool.isInstalled)
        check("and it is a link, not a copy",
              (try? files.destinationOfSymbolicLink(atPath: link.path))?
                .hasSuffix("/Contents/Resources/imark") == true)
        check("which runs", files.isExecutableFile(atPath: link.path))

        // Installing twice is how somebody who moved the app repairs the link,
        // so it replaces its own work without complaining.
        do {
            try CommandLineTool.install()
            check("installing again is not an error", CommandLineTool.isInstalled)
        } catch {
            check("installing again is not an error", false, "\(error)")
        }

        // Somebody else's imark is not ours to delete.
        try? files.removeItem(at: link)
        files.createFile(atPath: link.path, contents: Data("#!/bin/sh\n".utf8))
        check("a file we did not write is not reported as ours", !CommandLineTool.isInstalled)
        do {
            try CommandLineTool.install()
            check("and it is not overwritten", false, "install went ahead anyway")
        } catch {
            check("and it is not overwritten", true)
        }
        check("the other file is still there", files.fileExists(atPath: link.path))

        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }
}
