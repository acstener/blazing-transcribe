import SwiftUI

// First-run pieces for Home (workstream G2). Kept out of HomeView.swift so they
// don't collide with other Home work.

// MARK: - First dictation nudge

/// One line under the keycap until the person has dictated into another app once.
struct FirstDictationNudge: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        if !model.hasCompletedFirstExternalDelivery {
            Text(model.recordingMode == .manual
                 ? "Try it in any app — hold \(model.pttShortcutLabel) and speak"
                 : "Try it in any app — click a text box and start speaking")
                .font(.system(size: 13))
                .foregroundStyle(Color.btSecondaryText)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        }
    }
}

// MARK: - Missing permission banner

/// Amber banner at the top of Home when the microphone or Accessibility is missing.
/// Folds down to its title; the fix buttons only ever prompt on click.
struct MissingPermissionBanner: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("home.permissionBannerCollapsed") private var isCollapsed = false

    private var missingMicrophone: Bool { !model.isMicrophoneGranted }
    private var missingAccessibility: Bool { !model.isAccessibilityGranted }
    private var isVisible: Bool { missingMicrophone || missingAccessibility }

    private var title: String {
        switch (missingMicrophone, missingAccessibility) {
        case (true, true): return "Blazing needs two permissions"
        case (true, false): return "Microphone access is off"
        default: return "Accessibility access is off"
        }
    }

    private var detail: String {
        switch (missingMicrophone, missingAccessibility) {
        case (true, true): return "Without them Blazing can’t hear you or type into other apps."
        case (true, false): return "Blazing can’t hear you until the microphone is switched on."
        default: return "Blazing can hear you, but can’t type into other apps without Accessibility."
        }
    }

    var body: some View {
        Group {
            if isVisible {
                content
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .btSoft, value: isVisible)
        .task(id: isVisible) {
            // Notice grants made in System Settings while Home is open.
            while isVisible && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.refreshPermissionState()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .btSnappy) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: BTSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.btWarning)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.btText)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.btSecondaryText)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isCollapsed ? "Show details" : "Hide details")

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail)
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: BTSpacing.sm) {
                        if missingMicrophone {
                            BTButton("Allow microphone", style: .secondary) {
                                model.onRequestMicrophonePermission?()
                            }
                        }
                        if missingAccessibility {
                            BTButton("Allow Accessibility", style: .secondary) {
                                model.onRequestAccessibilityPermission?()
                            }
                        }
                    }
                }
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.btWarning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.btWarning.opacity(0.45), lineWidth: 1))
        .padding(.top, 20)
    }
}

// MARK: - Model warm-up

/// Calm loading state for someone who is set up but whose speech model is still
/// loading (e.g. the first launch after an update), or failed to load.
/// Replaces "Continue setup", which only belongs to incomplete setup.
struct HomeModelWarmup: View {
    @Environment(AppViewModel.self) private var model

    /// Not loading and not ready: offer a button rather than an endless bar.
    private var needsRetry: Bool {
        model.hasStartedServices && !model.isEngineLoading
            && !model.isModelDownloadRetryScheduled && !model.isSpeechEngineReady
    }

    private var caption: String {
        if model.isModelDownloadRetryScheduled {
            return model.modelLoadErrorMessage ?? "Retrying automatically…"
        }
        if model.modelDownloadFraction != nil {
            return "Downloading the speech model. One time only."
        }
        return "Loading the speech model. The first launch after an update can take a minute."
    }

    var body: some View {
        VStack(spacing: 10) {
            if needsRetry {
                Text(model.modelLoadErrorMessage ?? "The speech model isn’t loaded yet.")
                    .font(.btCaption)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                BTButton(model.modelLoadErrorMessage == nil ? "Load speech model" : "Retry") {
                    model.onRetryModelDownload?()
                }
            } else {
                ActivationProgressBar(fraction: model.modelDownloadFraction)
                    .frame(width: 220)
                Text(caption)
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 360)
    }
}

extension AppViewModel {
    /// Permissions are fine; only the speech model is loading or failed. Home shows
    /// a warm-up state rather than sending the person back into setup.
    var isOnlyWaitingForSpeechModel: Bool {
        guard isAccessibilityGranted, isMicrophoneGranted, !isMicrophonePermissionError else { return false }
        if isEngineLoading || isModelDownloadRetryScheduled { return true }
        if modelLoadErrorMessage != nil { return true }
        return !isSpeechEngineReady
    }
}
