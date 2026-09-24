import Foundation
import ServiceManagement

/// Registers Blazing as a login item. Only ever called from the visible
/// "Open Blazing at login" toggle; launch never enables it silently.
enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var hasPriorDecision: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: LaunchAtLoginChoice.userSetKey)
            || defaults.bool(forKey: LaunchAtLoginChoice.legacySilentDefaultKey)
    }

    static var initialToggleValue: Bool {
        LaunchAtLoginChoice.initialToggleValue(isCurrentlyEnabled: isEnabled, hasPriorDecision: hasPriorDecision)
    }

    /// Applies the person's choice and remembers that they made one.
    static func apply(_ enabled: Bool) {
        #if DEBUG
        // The service-free UI preview must never register a login item.
        if ProcessInfo.processInfo.arguments.contains("--experience-preview")
            || Bundle.main.bundleIdentifier == "com.blazingtranscribe.experience-preview" { return }
        #endif
        do {
            switch LaunchAtLoginChoice.change(desired: enabled, isCurrentlyEnabled: isEnabled) {
            case .register: try SMAppService.mainApp.register()
            case .unregister: try SMAppService.mainApp.unregister()
            case .none: break
            }
        } catch {
            appLog("Launch at login change failed: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(true, forKey: LaunchAtLoginChoice.userSetKey)
    }
}
