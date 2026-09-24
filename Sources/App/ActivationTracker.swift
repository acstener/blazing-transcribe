import Foundation

/// Once-per-install activation milestones for analytics.
///
/// Privacy: events carry timings, outcomes and enum-like labels only — never
/// transcript text, app names or device names.
///
/// Every milestone fires at most once per install (persisted in UserDefaults)
/// and includes `secondsSinceSetupStarted` and `secondsSincePreviousMilestone`
/// when those are known.
final class ActivationTracker {
    enum Milestone: String, CaseIterable {
        case setupStarted = "activationSetupStarted"
        case microphoneGranted = "activationMicrophoneGranted"
        case microphoneDenied = "activationMicrophoneDenied"
        case accessibilityGranted = "activationAccessibilityGranted"
        case modelReady = "activationModelReady"
        case firstPracticeSuccess = "activationFirstPracticeSuccess"
        case firstExternalDelivery = "activationFirstExternalDelivery"

        var defaultsKey: String { "activation.\(rawValue).at" }
    }

    static let lastMilestoneAtKey = "activation.lastMilestoneAt"
    static let hasCompletedFirstExternalDeliveryKey = "activation.hasCompletedFirstExternalDelivery"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let send: (String, [String: Any]) -> Void

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        send: @escaping (String, [String: Any]) -> Void
    ) {
        self.defaults = defaults
        self.now = now
        self.send = send
    }

    func hasRecorded(_ milestone: Milestone) -> Bool {
        defaults.object(forKey: milestone.defaultsKey) != nil
    }

    var hasCompletedFirstExternalDelivery: Bool {
        defaults.bool(forKey: Self.hasCompletedFirstExternalDeliveryKey)
    }

    /// Records the milestone if it hasn't fired before. Returns true when it fired now.
    @discardableResult
    func record(_ milestone: Milestone, parameters: [String: Any] = [:]) -> Bool {
        guard !hasRecorded(milestone) else { return false }
        let timestamp = now()
        var payload = parameters

        if milestone != .setupStarted,
           let setupStartedAt = storedDate(for: Milestone.setupStarted.defaultsKey) {
            payload["secondsSinceSetupStarted"] = Self.rounded(timestamp.timeIntervalSince(setupStartedAt))
        }
        if let previous = storedDate(for: Self.lastMilestoneAtKey) {
            payload["secondsSincePreviousMilestone"] = Self.rounded(timestamp.timeIntervalSince(previous))
        }

        defaults.set(timestamp.timeIntervalSince1970, forKey: milestone.defaultsKey)
        defaults.set(timestamp.timeIntervalSince1970, forKey: Self.lastMilestoneAtKey)
        if milestone == .firstExternalDelivery {
            defaults.set(true, forKey: Self.hasCompletedFirstExternalDeliveryKey)
        }
        send(milestone.rawValue, payload)
        return true
    }

    /// Existing installs are already activated: mark first external delivery done
    /// without sending anything, so G2's first-run nudges never show for them.
    func markExistingInstallActivated() {
        guard !hasCompletedFirstExternalDelivery else { return }
        defaults.set(true, forKey: Self.hasCompletedFirstExternalDeliveryKey)
    }

    private func storedDate(for key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    static func rounded(_ seconds: TimeInterval) -> Double {
        (max(0, seconds) * 10).rounded() / 10
    }
}
