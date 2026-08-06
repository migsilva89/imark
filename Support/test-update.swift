// The version comparison behind "Imark X is available".
//
//   swiftc -parse-as-library Sources/Imark/Updates.swift \
//          Sources/Imark/Settings.swift Sources/Imark/NoteColour.swift \
//          Support/test-update.swift -o /tmp/imark-test-update && /tmp/imark-test-update
//
// Small on purpose: the network side is a GET and a JSON field, but a string
// comparison that called 1.10 older than 1.9 would tell everybody on 1.9 that
// they are up to date, forever, quietly.

import Foundation

@main
struct TestUpdate {
    static var pass = 0
    static var fail = 0

    static func check(_ name: String, _ got: Bool, _ want: Bool) {
        if got == want { print("OK   \(name)"); pass += 1 }
        else { print("FAIL \(name)"); fail += 1 }
    }

    static func main() {
        check("0.2.0 is newer than 0.1.0", Updates.newer("0.2.0", than: "0.1.0"), true)
        check("0.1.0 is not newer than 0.2.0", Updates.newer("0.1.0", than: "0.2.0"), false)
        check("a version is not newer than itself", Updates.newer("0.2.0", than: "0.2.0"), false)
        check("1.10 beats 1.9 — numeric, not lexicographic", Updates.newer("1.10", than: "1.9"), true)
        check("1.9 does not beat 1.10", Updates.newer("1.9", than: "1.10"), false)
        check("0.2 equals 0.2.0", Updates.newer("0.2", than: "0.2.0"), false)
        check("0.2.1 beats 0.2", Updates.newer("0.2.1", than: "0.2"), true)
        check("2.0.0 beats 1.99.99", Updates.newer("2.0.0", than: "1.99.99"), true)
        check("garbage counts as zero", Updates.newer("abc", than: "0.1.0"), false)

        print(fail == 0 ? "\nall good (\(pass))" : "\n\(fail) failing of \(pass + fail)")
        exit(fail == 0 ? 0 : 1)
    }
}
