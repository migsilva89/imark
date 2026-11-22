import AppKit
import Sparkle

/// The standard macOS update window: find, verify, install and reopen Imark.
/// Sparkle owns the schedule and its one preference, so the menu, Settings and
/// the automatic check cannot drift into three answers to the same question.
@MainActor
enum Updates {
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private static var started = false

    /// Sparkle only runs inside Imark.app. A binary run on its own (the test
    /// suites compile the app's sources into one) has no feed and no key to
    /// check against, and Sparkle answers that with a modal alert that it could
    /// not start, which waits for a click nobody makes: test-settings hung on
    /// it, reached through the Settings window's updates box.
    private static var isApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    nonisolated static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var automaticallyChecksForUpdates: Bool {
        get {
            start()
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            start()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// The previous updater kept its own preference under this key. Move it
    /// once, before Sparkle starts, so somebody who turned checks off stays off.
    static func start() {
        guard !started, isApp else { return }
        started = true
        let defaults = UserDefaults.standard
        if let previous = defaults.object(forKey: "checksForUpdates") as? Bool {
            controller.updater.automaticallyChecksForUpdates = previous
            defaults.removeObject(forKey: "checksForUpdates")
        }
        controller.startUpdater()
    }

    static func checkNow() {
        guard isApp else { return NSSound.beep() }
        start()
        controller.checkForUpdates(nil)
    }
}
