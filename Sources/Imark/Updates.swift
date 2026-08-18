import AppKit

/// Once a day, ask GitHub whether a newer Imark exists, and say so — once.
///
/// This is the one place the app touches the network, and it is deliberately
/// the smallest possible touch: a GET of the latest release's metadata, no
/// identifiers attached beyond what any HTTP request carries. Documents never
/// leave the machine; this call carries none of them. It can be turned off in
/// Settings, and the setting is respected before the request is ever built.
///
/// No Sparkle, no downloading, no installing. The app points at the site and
/// gets out of the way — for an app this size, an update mechanism that could
/// rewrite the binary would be a bigger risk than the staleness it prevents.
enum Updates {
    /// Where "Download" lands: the site, not the release page on GitHub. The
    /// version numbers still come from GitHub, because that is where a release is
    /// made, but somebody who pressed Download is being sent somewhere to read —
    /// and a page of assets and checksums is not that.
    static let page = URL(string: "https://imarkmd.com")!

    private static let api = URL(
        string: "https://api.github.com/repos/migsilva89/imark/releases/latest"
    )!

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// `"1.10.0"` against `"1.9"` numerically, field by field — string order
    /// would call 1.10 older. Anything non-numeric in a field counts as zero.
    static func newer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The automatic path: quiet on failure, quiet when current, quiet when it
    /// already offered this version — an update it nagged about every launch
    /// would train people to turn the whole thing off.
    static func checkQuietly() {
        guard Settings.checksForUpdates else { return }
        guard Date().timeIntervalSince(Settings.lastUpdateCheck) > 20 * 60 * 60 else { return }
        Settings.lastUpdateCheck = Date()
        fetch { version in
            guard newer(version, than: current), Settings.offeredUpdate != version else { return }
            Settings.offeredUpdate = version
            offer(version)
        }
    }

    /// The menu item. Somebody asked, so every outcome gets an answer —
    /// including the network being down.
    static func checkNow() {
        fetch { version in
            if newer(version, than: current) {
                offer(version)
            } else {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "Imark \(current) is the latest version."
                alert.runModal()
            }
        } failed: {
            let alert = NSAlert()
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "GitHub could not be reached. Try again later."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func fetch(
        then found: @escaping (String) -> Void,
        failed: @escaping () -> Void = {}
    ) {
        var request = URLRequest(url: api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = payload["tag_name"] as? String
            else { return DispatchQueue.main.async(execute: failed) }
            // Tags are `v0.2.0`; versions are `0.2.0`.
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async { found(version) }
        }.resume()
    }

    private static func offer(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Imark \(version) is available"
        alert.informativeText =
            "You have \(current). The download is a drag-and-drop over the old one."
        alert.addButton(withTitle: "View Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }
}
