import AppKit

// SwiftPM builds a plain executable, so the NSApplication bootstrap that
// @main would normally generate is done by hand here.
let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
