import Foundation

/// Determines whether a frontmost app is a terminal emulator,
/// so we can skip AX provisional sessions and use append-only streaming.
enum TerminalHostPolicy {
    private static let pasteUnsafeBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    private static let pasteUnsafeNamePatterns: [String] = [
        "terminal",
        "iterm",
        "ghostty",
        "warp",
        "kitty",
        "wezterm",
        "hyper",
        "alacritty",
    ]

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.fleet",
    ]

    private static let terminalNamePatterns: [String] = [
        "terminal",
        "iterm",
        "ghostty",
        "warp",
        "kitty",
        "wezterm",
        "hyper",
        "alacritty",
    ]

    static func isPasteUnsafeTarget(bundleIdentifier: String?, appName: String?) -> Bool {
        if let bundleID = bundleIdentifier, pasteUnsafeBundleIDs.contains(bundleID) {
            return true
        }
        if let name = appName?.lowercased() {
            for pattern in pasteUnsafeNamePatterns where name.contains(pattern) {
                return true
            }
        }
        return false
    }

    static func isTerminalLike(bundleIdentifier: String?, appName: String?) -> Bool {
        if let bundleID = bundleIdentifier, terminalBundleIDs.contains(bundleID) {
            return true
        }
        if let name = appName?.lowercased() {
            for pattern in terminalNamePatterns {
                if name.contains(pattern) {
                    return true
                }
            }
        }
        return false
    }
}
