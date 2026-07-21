import Foundation

enum OverlayDiagnostics {
    private static let defaults = UserDefaults.standard

    static var isCompareModeEnabled: Bool {
        bool(forKey: "overlayCompareMode", default: defaultCompareMode)
    }

    static var usePureGlassHost: Bool {
        bool(forKey: "overlayPureGlassMode", default: true)
    }

    static var forceKeyWindowAppearance: Bool {
        bool(forKey: "overlayForceKeyWindowTest", default: false)
    }

    static var usePrivateGlassAPI: Bool {
        bool(forKey: "overlayPrivateGlassAPI", default: true)
    }

    static var privateGlassVariant: Int {
        int(forKey: "overlayPrivateGlassVariant", default: 2)
    }

    static var privateGlassScrimState: Int {
        int(forKey: "overlayPrivateGlassScrimState", default: 0)
    }

    static var privateGlassSubduedState: Int {
        int(forKey: "overlayPrivateGlassSubduedState", default: 0)
    }

    static var forcePrivateActiveAppearance: Bool {
        bool(forKey: "overlayPrivateForceActiveAppearance", default: true)
    }

    static var summary: String {
        "compare=\(isCompareModeEnabled),pureGlass=\(usePureGlassHost),forceKeyWindow=\(forceKeyWindowAppearance),privateGlass=\(usePrivateGlassAPI),fallbackVariant=\(privateGlassVariant),fallbackScrim=\(privateGlassScrimState),fallbackSubdued=\(privateGlassSubduedState),forceActive=\(forcePrivateActiveAppearance)"
    }

    private static var defaultCompareMode: Bool {
        false
    }

    private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if let stored = defaults.object(forKey: key) as? Bool {
            return stored
        }
        return defaultValue
    }

    private static func int(forKey key: String, default defaultValue: Int) -> Int {
        if let stored = defaults.object(forKey: key) as? NSNumber {
            return stored.intValue
        }
        return defaultValue
    }
}
