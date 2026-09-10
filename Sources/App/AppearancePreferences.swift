import AppKit
import SwiftUI

enum AppearancePreferences: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "appAppearance"

    var id: String { rawValue }

    static func current(defaults: UserDefaults = .standard) -> AppearancePreferences {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let preference = AppearancePreferences(rawValue: rawValue) else {
            return .system
        }
        return preference
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return "Follow macOS light or dark. The recording overlay keeps its own look."
        case .light:
            return "Keep the app window on the current warm light look."
        case .dark:
            return "Warm dark window. Does not change the recording overlay."
        }
    }

    var windowAppearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark:
            return .darkAqua
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
