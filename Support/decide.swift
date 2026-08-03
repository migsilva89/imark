// Writes a review decision exactly as the toolbar buttons do, for the
// round-trip test in test-review.sh.
//
//   swift Support/decide.swift <review.md> approve|request-changes <notes>
//
// It calls Review.decide — the same function finishReview calls — so the test
// covers everything between pressing a button and the agent reading the result.
// The one step it cannot cover is the press itself: posting a synthetic click
// needs accessibility permission, which a terminal does not have.

import Foundation

@main
struct Decide {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fail("uso: decide.swift <review.md> <approve|request-changes> [notas]", 2)
        }
        let url = URL(fileURLWithPath: args[1])
        guard let decision = Review.Decision(rawValue: args[2]) else {
            fail("decisão desconhecida: \(args[2])", 2)
        }
        let notes = args.count > 3 ? Int(args[3]) ?? 0 : 0

        // The same gate the toolbar uses to decide whether the buttons exist at
        // all: a document that never asked to be reviewed cannot be decided.
        guard Review.isReview(url) else {
            fail("não é um documento de revisão: \(url.path)", 1)
        }

        do {
            try Review.decide(decision, notes: notes, for: url)
            print("decidido: \(decision.rawValue)")
        } catch {
            fail("falhou: \(error)", 1)
        }
    }

    static func fail(_ message: String, _ code: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }
}
