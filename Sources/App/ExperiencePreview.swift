#if DEBUG
import AppKit

/// A service-free UI preview for visual checks, launched in a separate app bundle.
/// No microphone, hotkeys, model loading, or analytics are started.
extension AppDelegate {
    func configureExperiencePreview() {
        UserDefaults.standard.register(defaults: ["hasCompletedOnboarding": true])
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.arguments.contains("--experience-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        viewModel.isSpeechEngineReady = true
        viewModel.isAccessibilityGranted = true
        viewModel.isMicrophoneGranted = true
        viewModel.recordingMode = .manual
        showExperiencePreviewMenu()
        viewModel.onOpenOnboardingPreview = { [weak self] in self?.viewModel.isOnboardingPreviewActive = true }
        viewModel.onCloseOnboardingPreview = { [weak self] in self?.viewModel.isOnboardingPreviewActive = false }
    }
}
#endif
