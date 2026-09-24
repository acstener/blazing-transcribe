import Foundation

/// Decides, at launch, whether this is a brand-new install or an existing one,
/// and which defaults a brand-new install gets.
///
/// The rule that matters: only *real legacy signals* (paid-app trial/license
/// state, or evidence the person actually dictated) may mark onboarding complete.
/// Keys the app itself writes on first launch — the transcription preset
/// migration, the default text cleanup, telemetry IDs, launch-at-login markers —
/// must never count, otherwise a relaunch mid-onboarding skips it for good.
enum FirstLaunchPolicy {
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static let recordingModeKey = "recordingMode"
    static let disableKeepMicReadyKey = "disableKeepMicReady"

    /// UserDefaults keys that only exist after genuine use or a paid-app install.
    /// Values are checked for "meaningful" content (non-zero counters), not mere presence.
    static let legacyDefaultsPresenceKeys = [
        "trialStartDate",               // paid-app trial
    ]

    static let legacyDefaultsCounterKeys = [
        "stats.totalUtterances",        // at least one real dictation
        "stats.totalWords",
    ]

    /// Keychain keys written only by the paid app.
    static let legacyKeychainKeys = [
        "com.blazing.fast-transcription.licenseKey",
        "com.blazing.fast-transcription.instanceId",
        "com.blazing.fast-transcription.trialStartDate",
    ]

    /// Default on-disk history file (mirrors `TranscriptionHistoryStore`'s location).
    static var defaultHistoryFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlazingTranscribe")
            .appendingPathComponent("history.json")
    }

    static func hasLegacyInstallEvidence(
        defaults: UserDefaults,
        keychainService: String,
        historyFileURL: URL?
    ) -> Bool {
        if legacyDefaultsPresenceKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            return true
        }
        if legacyDefaultsCounterKeys.contains(where: { defaults.integer(forKey: $0) > 0 }) {
            return true
        }
        if legacyKeychainKeys.contains(where: {
            AppKeychainStore.load(key: $0, service: keychainService) != nil
        }) {
            return true
        }
        if let historyFileURL, historyFileHasEntries(at: historyFileURL) {
            return true
        }
        return false
    }

    /// A history file with at least one record. An empty array ("[]") doesn't count.
    static func historyFileHasEntries(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 2 else { return false }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return false }
        return !array.isEmpty
    }

    static func shouldSkipOnboardingForExistingInstall(
        defaults: UserDefaults,
        keychainService: String,
        historyFileURL: URL?
    ) -> Bool {
        guard defaults.object(forKey: hasCompletedOnboardingKey) == nil else { return false }
        return hasLegacyInstallEvidence(
            defaults: defaults,
            keychainService: keychainService,
            historyFileURL: historyFileURL
        )
    }

    enum LaunchResolution: Equatable {
        /// `hasCompletedOnboarding` was already stored (true, or false for a replay / relaunch mid-onboarding).
        case alreadyDecided
        /// No onboarding flag but real legacy evidence: marked complete.
        case existingInstall
        /// No onboarding flag and no legacy evidence: first launch of a new install.
        case newInstall
    }

    /// Resolve the onboarding flag at launch. Must run before anything else
    /// writes defaults. Always leaves `hasCompletedOnboarding` explicitly stored,
    /// so the existing-install heuristic only ever runs once.
    @discardableResult
    static func resolveOnboardingOnLaunch(
        defaults: UserDefaults,
        keychainService: String,
        historyFileURL: URL?
    ) -> LaunchResolution {
        guard defaults.object(forKey: hasCompletedOnboardingKey) == nil else { return .alreadyDecided }
        if hasLegacyInstallEvidence(defaults: defaults, keychainService: keychainService, historyFileURL: historyFileURL) {
            defaults.set(true, forKey: hasCompletedOnboardingKey)
            return .existingInstall
        }
        defaults.set(false, forKey: hasCompletedOnboardingKey)
        return .newInstall
    }

    struct DefaultsToWrite: Equatable {
        var recordingMode: RecordingMode?
        var disableKeepMicReady: Bool?
    }

    /// Which recording-mode / mic defaults to persist at launch.
    ///
    /// - New installs: Manual (hold-to-talk) and mic off between recordings.
    /// - Anyone who has completed onboarding with no saved mode ran on the old
    ///   implicit Always-on default: persist that so their behaviour doesn't change.
    /// - Someone mid-onboarding (flag stored as false) with no saved mode gets Manual.
    /// - Stored values are never overwritten.
    static func launchDefaults(
        resolution: LaunchResolution,
        hasCompletedOnboarding: Bool,
        storedRecordingMode: String?,
        hasStoredKeepMicPreference: Bool
    ) -> DefaultsToWrite {
        var result = DefaultsToWrite()
        if storedRecordingMode == nil {
            result.recordingMode = (resolution != .newInstall && hasCompletedOnboarding) ? .alwaysOn : .manual
        }
        if resolution == .newInstall && !hasStoredKeepMicPreference {
            result.disableKeepMicReady = true
        }
        return result
    }

    /// Run both steps against `defaults` and return the resolution.
    @discardableResult
    static func applyLaunchPolicy(
        defaults: UserDefaults,
        keychainService: String,
        historyFileURL: URL?
    ) -> LaunchResolution {
        let resolution = resolveOnboardingOnLaunch(
            defaults: defaults,
            keychainService: keychainService,
            historyFileURL: historyFileURL
        )
        let toWrite = launchDefaults(
            resolution: resolution,
            hasCompletedOnboarding: defaults.bool(forKey: hasCompletedOnboardingKey),
            storedRecordingMode: defaults.string(forKey: recordingModeKey),
            hasStoredKeepMicPreference: defaults.object(forKey: disableKeepMicReadyKey) != nil
        )
        if let mode = toWrite.recordingMode {
            defaults.set(mode.rawValue, forKey: recordingModeKey)
        }
        if let disable = toWrite.disableKeepMicReady {
            defaults.set(disable, forKey: disableKeepMicReadyKey)
        }
        return resolution
    }
}
