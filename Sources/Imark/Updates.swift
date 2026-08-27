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
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        if let previous = defaults.object(forKey: "checksForUpdates") as? Bool {
            controller.updater.automaticallyChecksForUpdates = previous
            defaults.removeObject(forKey: "checksForUpdates")
        }
        controller.startUpdater()
    }

    static func checkNow() {
        start()
        controller.checkForUpdates(nil)
    }
}
