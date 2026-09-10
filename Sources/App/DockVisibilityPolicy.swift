import Foundation

enum DockVisibilityPolicy {
    static let defaultsKey = "showDockIcon"
    /// Packaged builds already set LSUIElement. Default off so the app can stay
    /// running in the menu bar without a Dock icon, which keeps Toggle Mic alive
    /// after this window is closed.
    static let defaultWantsDockIcon = false

    static func wantsDockIcon(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? defaultWantsDockIcon
    }

    static func setWantsDockIcon(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }
}
