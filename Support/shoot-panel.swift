// Draws one of the app's panels into a PNG, without photographing the screen.
//
//   swiftc -parse-as-library -I .build/debug/Modules \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/shoot-panel.swift -o /tmp/imark-panel
//
//   /tmp/imark-panel ask /tmp/ask.png            empty, light
//   /tmp/imark-panel dark-ask /tmp/ask.png       empty, dark
//   /tmp/imark-panel dark-filled /tmp/ask.png    with a conversation in it
//
// Exists because a sheet cannot be looked at from a terminal, and the first Ask
// panel shipped 38 points wide and modal for exactly that reason: it compiled, so
// it was assumed to lay out. `bitmapImageRepForCachingDisplay` draws a hierarchy
// into an image in-process — no screen-recording permission, no window on screen —
// and it collapses the same way the real sheet does when the layout is wrong.
//
// It also prints every view's frame, so a control that is invisible can be told
// from one that was never laid out at all.

import AppKit

@main
enum ShootPanel {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: shoot-panel <ask|dark-ask|dark-filled> <out.png>\n".utf8))
            exit(2)
        }
        let which = args[1]
        let output = URL(fileURLWithPath: args[2])
        let filled = which.contains("filled")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if which.hasPrefix("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }

        // A parent for the sheet, parked off-screen and never brought forward.
        let parent = NSWindow(
            contentRect: NSRect(x: -8_000, y: 0, width: 1_100, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.contentView = NSView()
        parent.orderFrontRegardless()

        // `echo` answers with the prompt itself: a long, multi-line reply, which is
        // what needs looking at — wrapping, spacing, and whether it scrolls.
        let cli = Assistants.CLI(
            id: "claude", label: "Claude Code",
            executable: URL(fileURLWithPath: filled ? "/bin/echo" : "/usr/bin/true"),
            argumentTemplate: "{prompt}"
        )
        let panel = AskPanel()
        panel.show(for: URL(fileURLWithPath: "/tmp/imark-edit-test.md"), using: cli, in: parent)

        // Every step is its own block on the main queue. A nested `RunLoop.run`
        // inside one block turns timers but cannot drain the queue — it is serial
        // and already busy running that block — so the answer never arrives and the
        // panel looks stuck when it is the harness that is.
        step(1.0) { if filled { drive("Is the second paragraph clear enough to keep?", parent) } }
        step(2.6) { if filled { drive("And the table at the end?", parent) } }
        step(4.4) { shoot(parent, to: output) }

        app.run()
    }

    private static func step(_ delay: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Drives the panel through its own controls rather than through a seam cut
    /// into it for testing: the composer is the composer, and Ask is the button
    /// somebody clicks.
    private static func drive(_ question: String, _ parent: NSWindow) {
        guard let view = parent.attachedSheet?.contentView else { return }
        if let composer = find(NSTextView.self, in: view, where: { $0.isEditable }) {
            composer.string = question
            // Setting a string is not typing, and the delegate only hears typing.
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: composer)
        }
        find(NSButton.self, in: view, where: { $0.title == "Ask" })?.performClick(nil)
    }

    private static func find<T: NSView>(
        _ type: T.Type,
        in view: NSView,
        where match: (T) -> Bool
    ) -> T? {
        if let hit = view as? T, match(hit) { return hit }
        for child in view.subviews {
            if let hit = find(type, in: child, where: match) { return hit }
        }
        return nil
    }

    private static func shoot(_ parent: NSWindow, to output: URL) {
        guard let sheet = parent.attachedSheet, let view = sheet.contentView else {
            FileHandle.standardError.write(Data("no sheet came up\n".utf8))
            exit(1)
        }
        view.layoutSubtreeIfNeeded()
        print("sheet: \(NSStringFromSize(sheet.frame.size))")
        dump(view, 0)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("could not make a bitmap\n".utf8))
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode a png\n".utf8))
            exit(1)
        }
        try? png.write(to: output)
        print(output.path)
        exit(0)
    }

    private static func dump(_ view: NSView, _ depth: Int) {
        let name = (view as? NSTextField)?.stringValue
            ?? (view as? NSButton)?.title
            ?? String(describing: type(of: view))
        print(String(repeating: "  ", count: depth) + name + " " + NSStringFromRect(view.frame))
        for child in view.subviews { dump(child, depth + 1) }
    }
}
