import Foundation
import ServiceManagement

enum LaunchAtLoginPreferences {
    static let userSetKey = "launchAtLoginUserSet"
    static let appliedKey = "launchAtLoginDefaultApplied"

    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool, markUserSet: Bool = true) throws {
        if markUserSet {
            UserDefaults.standard.set(true, forKey: userSetKey)
        }
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
