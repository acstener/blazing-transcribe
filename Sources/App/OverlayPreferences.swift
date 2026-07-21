import Foundation

enum OverlayPreferences {
    static let enabledDefaultsKey = "overlayEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledDefaultsKey) as? Bool) ?? true
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: enabledDefaultsKey)
    }
}
