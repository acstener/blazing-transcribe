import Foundation

/// Browser-hosted editors often expose AX-editable fields, but mutating them
/// via AX value replacement can bypass the page's own editor state. For the
/// Turbo realtime path, prefer real key events instead of AX-owned sessions.
enum BrowserHostPolicy {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.firefoxbeta",
        "org.mozilla.nightly",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    private static let browserNamePatterns: [String] = [
        "safari",
        "chrome",
        "brave",
        "edge",
        "arc",
        "firefox",
        "opera",
        "vivaldi",
    ]

    static func isBrowser(bundleIdentifier: String?, appName: String?) -> Bool {
        if let bundleID = bundleIdentifier, browserBundleIDs.contains(bundleID) {
            return true
        }
        if let name = appName?.lowercased() {
            for pattern in browserNamePatterns where name.contains(pattern) {
                return true
            }
        }
        return false
    }

    static func prefersDirectRealtimeTyping(bundleIdentifier: String?, appName: String?) -> Bool {
        isBrowser(bundleIdentifier: bundleIdentifier, appName: appName)
    }
}
