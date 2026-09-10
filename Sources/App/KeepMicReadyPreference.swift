import Foundation

enum KeepMicReadyPreference {
    static let disableKey = "disableKeepMicReady"

    /// Default off so the macOS orange privacy light is not stuck on between uses.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let disabled = defaults.object(forKey: disableKey) as? Bool else {
            return false
        }
        return !disabled
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: disableKey)
    }

    /// Always-on must capture to hear speech. Manual only keeps the device open
    /// when Keep Mic Active is on. Realtime manual no longer forces a warm mic.
    static func shouldKeepCaptureRunning(
        recordingMode: RecordingMode,
        keepMicReady: Bool
    ) -> Bool {
        recordingMode == .alwaysOn || keepMicReady
    }
}
