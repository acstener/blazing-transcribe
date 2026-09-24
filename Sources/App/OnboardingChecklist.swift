import Foundation

/// Pure state derivation for the onboarding Setup checklist, the practice word
/// reveal and the launch-at-login toggle. Views only render what this returns.
enum SetupChecklist {
    /// What a checklist row shows on its trailing edge.
    enum Status: Equatable {
        /// Not started: show a button with this title.
        case needsAction(String)
        /// The user has been sent to System Settings (or a prompt is up); we're watching.
        /// The optional title is a quiet link to reopen Settings.
        case waiting(String?)
        /// Work in progress. `fraction` nil = indeterminate.
        case working(fraction: Double?)
        /// Something went wrong: show the caption as an error and a button with this title.
        case failed(String)
        case done
    }

    struct Row: Equatable {
        var title: String
        var caption: String
        var status: Status

        var isDone: Bool { status == .done }
    }

    enum MicrophoneAuthorization: Equatable {
        case notDetermined, denied, granted
    }

    static func microphone(
        authorization: MicrophoneAuthorization,
        hasRequested: Bool,
        hasPermissionError: Bool
    ) -> Row {
        let title = "Microphone"
        switch authorization {
        case .granted:
            // A stale "mic denied" error must never outlive the grant.
            return Row(title: title, caption: "Blazing can hear you when you dictate.", status: .done)
        case .denied:
            if hasPermissionError {
                return Row(title: title,
                           caption: "Microphone access is off. Switch Blazing on in System Settings, then try again.",
                           status: .failed("Try again"))
            }
            return Row(title: title,
                       caption: "Microphone access is off. Switch Blazing on in System Settings → Microphone.",
                       status: .needsAction("Open Settings"))
        case .notDetermined:
            return Row(title: title,
                       caption: "So Blazing can hear you. It only listens while you dictate.",
                       status: hasRequested ? .waiting(nil) : .needsAction("Allow"))
        }
    }

    static func accessibility(granted: Bool, hasRequested: Bool) -> Row {
        let title = "Accessibility"
        if granted {
            return Row(title: title, caption: "Blazing can type into your other apps.", status: .done)
        }
        return Row(title: title,
                   caption: hasRequested
                       ? "Switch Blazing on in System Settings → Accessibility. We’ll notice straight away."
                       : "Lets Blazing type your words into other apps.",
                   status: hasRequested ? .waiting("Open Settings") : .needsAction("Allow"))
    }

    static func speechModel(
        isReady: Bool,
        isLoading: Bool,
        isDownloadPending: Bool,
        downloadFraction: Double?,
        completedBytes: Int64,
        totalBytes: Int64,
        errorMessage: String?,
        isRetryScheduled: Bool
    ) -> Row {
        let title = "Speech model"
        if isReady && !isLoading {
            return Row(title: title, caption: "On your Mac and ready. Nothing you say leaves it.", status: .done)
        }
        if isRetryScheduled {
            return Row(title: title,
                       caption: errorMessage ?? "Couldn’t download the speech model. Retrying automatically…",
                       status: .working(fraction: nil))
        }
        if let errorMessage, !isLoading {
            return Row(title: title, caption: errorMessage, status: .failed("Retry"))
        }
        if isLoading {
            if let fraction = downloadFraction {
                let clamped = min(max(fraction, 0), 1)
                let caption: String
                if totalBytes > 0 {
                    let done = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                    caption = "Downloading, \(done) of \(total). One time only."
                } else {
                    caption = "Downloading, \(Int((clamped * 100).rounded()))%. One time only."
                }
                return Row(title: title, caption: caption, status: .working(fraction: clamped))
            }
            if isDownloadPending {
                return Row(title: title, caption: "Starting the one-time download (about 500 MB)…",
                           status: .working(fraction: nil))
            }
            return Row(title: title, caption: "Almost ready. Optimising for your Mac (first time only).",
                       status: .working(fraction: nil))
        }
        return Row(title: title, caption: "A one-time download (about 500 MB) that runs on your Mac.",
                   status: .needsAction("Download"))
    }

    /// Continue needs both permissions; the model may still be downloading.
    static func canContinue(microphone: Row, accessibility: Row) -> Bool {
        microphone.isDone && accessibility.isDone
    }

    /// The line under Continue.
    static func continueHint(microphone: Row, accessibility: Row, speechModel: Row) -> String {
        switch (microphone.isDone, accessibility.isDone) {
        case (false, false): return "Allow the microphone and Accessibility to continue."
        case (false, true): return "Allow the microphone to continue."
        case (true, false): return "Allow Accessibility to continue."
        case (true, true):
            if speechModel.isDone { return "All set." }
            if case .failed = speechModel.status {
                return "You can continue. Retry the speech model when you’re ready."
            }
            return "The model keeps downloading in the background."
        }
    }

    static func completedCount(_ rows: [Row]) -> Int {
        rows.filter(\.isDone).count
    }
}

/// Word-by-word reveal for the practice box.
enum WordReveal {
    /// Per-word fade/rise duration.
    static let wordDuration: TimeInterval = 0.2
    /// The whole reveal never takes longer than this, however many words.
    static let maxTotalStagger: TimeInterval = 1.2

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Delay between consecutive words: 40 ms, compressed for long results.
    static func stagger(forWordCount count: Int) -> TimeInterval {
        guard count > 1 else { return 0 }
        return min(0.04, maxTotalStagger / Double(count - 1))
    }

    static func totalDuration(forWordCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return stagger(forWordCount: count) * Double(count - 1) + wordDuration
    }
}

/// The "Open Blazing at login" toggle on the final onboarding step.
enum LaunchAtLoginChoice {
    /// Set once the person has seen and confirmed the visible toggle.
    static let userSetKey = "launchAtLoginUserSet"
    /// Written by older builds that registered launch-at-login silently.
    static let legacySilentDefaultKey = "launchAtLoginDefaultApplied"

    /// Default ON for a first decision; otherwise reflect what's actually registered.
    static func initialToggleValue(isCurrentlyEnabled: Bool, hasPriorDecision: Bool) -> Bool {
        hasPriorDecision ? isCurrentlyEnabled : true
    }

    enum Change: Equatable { case register, unregister, none }

    static func change(desired: Bool, isCurrentlyEnabled: Bool) -> Change {
        switch (desired, isCurrentlyEnabled) {
        case (true, false): return .register
        case (false, true): return .unregister
        default: return .none
        }
    }
}
