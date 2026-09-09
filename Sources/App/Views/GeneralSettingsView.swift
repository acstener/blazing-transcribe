import SwiftUI
import AppKit
import AVFoundation
import Overlay

struct GeneralSettingsView: View {
    @State private var stickyFieldRestore = !UserDefaults.standard.bool(forKey: "stickyFieldRestoreDisabled")
    @State private var itnEnabled = UserDefaults.standard.bool(forKey: "itnEnabled")
    @State private var showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BTSpacing.lg) {
                Text("Settings")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Recording")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        KeepMicActiveControl(style: .settingsCard)
                    }
                }

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Overlay")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        OverlayAppearanceSettingsCard()
                    }
                }

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Dock")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show icon in Dock")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.btText)
                                Text("When off, Blazing Transcribe runs from the menu bar only — no Dock icon. Open this window anytime from the menu bar icon → Show Window.")
                                    .font(.btCaption)
                                    .foregroundStyle(Color.btSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $showDockIcon)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .onChange(of: showDockIcon) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "showDockIcon")
                            NotificationCenter.default.post(name: .dockIconPreferenceDidChange, object: nil)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Permissions")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        PermissionsSettingsCard()
                    }
                }

                // MARK: - Hidden for launch
                // VStack(alignment: .leading, spacing: BTSpacing.sm) {
                //     Text("Onboarding")
                //         .font(.system(size: 14, weight: .medium))
                //         .foregroundStyle(Color.btText)
                //     BTCard {
                //         OnboardingSettingsCard()
                //     }
                // }

                // VStack(alignment: .leading, spacing: BTSpacing.sm) {
                //     Text("Testing")
                //         .font(.system(size: 14, weight: .medium))
                //         .foregroundStyle(Color.btText)
                //     BTCard {
                //         OnboardingTestingCard()
                //     }
                // }

                // Updates
                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Updates")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        BTTrailingActionRow(horizontalAlignment: .center, horizontalMinWidth: 360) {
                            Text("Check for Updates")
                                .font(.btBody)
                                .foregroundStyle(Color.btText)
                        } trailing: {
                            CheckForUpdatesButton()
                        }
                    }
                }

                // Diagnostics
                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Diagnostics")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        BTTrailingActionRow(horizontalAlignment: .center, horizontalMinWidth: 360) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Copy Logs")
                                    .font(.btBody)
                                    .foregroundStyle(Color.btText)
                                Text("Copy the last 100 lines of app logs to your clipboard for debugging.")
                                    .font(.btCaption)
                                    .foregroundStyle(Color.btSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } trailing: {
                            CopyLogsButton()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Experiments")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.md) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sticky Field Restore")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.btText)
                                    Text("Remember the exact input field and window when recording starts, and restore focus to it when delivering text.")
                                        .font(.btCaption)
                                        .foregroundStyle(Color.btSecondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: $stickyFieldRestore)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            .onChange(of: stickyFieldRestore) { _, newValue in
                                UserDefaults.standard.set(!newValue, forKey: "stickyFieldRestoreDisabled")
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voice Commands")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.btText)
                                Text("Say \"delete that\", \"copy that\", or \"paste\" as a complete utterance, like Voice Control. The phrase runs instead of being typed.")
                                    .font(.btCaption)
                                    .foregroundStyle(Color.btSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Divider()

                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Text Normalization (ITN)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.btText)
                                    Text("Convert spoken numbers and units to written form. \"one hundred dollars\" becomes \"$100\". Off by default.")
                                        .font(.btCaption)
                                        .foregroundStyle(Color.btSecondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: $itnEnabled)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            .onChange(of: itnEnabled) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "itnEnabled")
                            }
                        }
                    }
                }
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth, alignment: .leading)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
    }

}

private struct OverlayAppearanceSettingsCard: View {
    @State private var isOverlayEnabled = OverlayPreferences.isEnabled()
    @State private var selectedStyle = OverlayVisualStyle.current()

    var body: some View {
        VStack(alignment: .leading, spacing: BTSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show recording overlay")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                    Text("Shows the floating status pill while recording and transcribing. Turn this off if you want transcription to run without the overlay.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $isOverlayEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .onChange(of: isOverlayEnabled) { _, newValue in
                OverlayPreferences.setEnabled(newValue)
                NotificationCenter.default.post(name: .overlayEnabledDidChange, object: nil)
            }

            Text("Choose the compact recording pill finish. Glass keeps the frosted fallback on older Macs, and Black swaps in a solid dark shell without changing overlay behavior when the overlay is enabled.")
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: BTSpacing.sm) {
                ForEach(OverlayVisualStyle.allCases, id: \.self) { style in
                    OverlayAppearanceOption(
                        icon: iconName(for: style),
                        title: style.title,
                        subtitle: style.subtitle,
                        isSelected: selectedStyle == style
                    ) {
                        updateStyle(style)
                    }
                }
            }
            .opacity(isOverlayEnabled ? 1 : 0.72)
        }
    }

    private func updateStyle(_ style: OverlayVisualStyle) {
        guard selectedStyle != style else { return }
        selectedStyle = style
        style.persist()
        NotificationCenter.default.post(name: .overlayAppearanceDidChange, object: nil)
    }

    private func iconName(for style: OverlayVisualStyle) -> String {
        switch style {
        case .glass:
            return "sparkles"
        case .black:
            return "capsule.fill"
        }
    }
}

private struct OverlayAppearanceOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BTSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.btText)
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.accentColor : Color.btActiveBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                    Text(subtitle)
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(BTSpacing.sm)
            .background(isSelected ? Color.btActiveBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.32) : Color.btBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Isolated subview — reads AppViewModel only for the update callback,
/// preventing GeneralSettingsView from re-rendering on unrelated viewModel changes.
private struct CheckForUpdatesButton: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        BTButton("Check Now", style: .secondary) {
            viewModel.onCheckForUpdates?()
        }
    }
}

private struct CopyLogsButton: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var copied = false

    var body: some View {
        BTButton(copied ? "Copied!" : "Copy Logs", style: .secondary) {
            viewModel.onCopyLogs?()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copied = false
            }
        }
    }
}

private struct OnboardingSettingsCard: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        BTTrailingActionRow(horizontalAlignment: .center, horizontalMinWidth: 360) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replay onboarding")
                    .font(.btBody)
                    .foregroundStyle(Color.btText)
                Text("Open the new first-run flow from Settings without needing to relaunch the app.")
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            BTButton("Open", style: .secondary) {
                viewModel.onOpenOnboardingPreview?()
            }
        }
    }
}

private struct OnboardingTestingCard: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: BTSpacing.md) {
            Text("Use these when you want to verify the onboarding setup path against a cold machine state.")
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingTestingRow(
                title: "Remove voice models",
                detail: "Deletes the cached ASR and VAD models. Use Download below to re-fetch them.",
                buttonTitle: "Remove",
                action: { viewModel.onResetVoiceModels?() }
            )

            Divider()

            OnboardingTestingRow(
                title: "Download voice models",
                detail: "Triggers the engine to re-download and compile models. Progress shows in the onboarding setup step.",
                buttonTitle: "Download",
                action: { viewModel.onReloadEngine?() }
            )

            Divider()

            OnboardingTestingRow(
                title: "Reset Accessibility access",
                detail: "Runs tccutil for the current app and opens the Accessibility pane so you can grant it again.",
                buttonTitle: "Reset",
                action: { viewModel.onResetAccessibilityPermission?() }
            )

            Divider()

            OnboardingTestingRow(
                title: "Reset Microphone access",
                detail: "Clears macOS microphone permission for this app and opens the matching System Settings screen.",
                buttonTitle: "Reset",
                action: { viewModel.onResetMicrophonePermission?() }
            )

            Divider()

            OnboardingTestingRow(
                title: "Reset Onboarding",
                detail: "Clears the onboarding completion flag so the onboarding flow shows again on next window open.",
                buttonTitle: "Reset",
                action: { UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding") }
            )
        }
    }
}

private struct OnboardingTestingRow: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        BTTrailingActionRow(horizontalAlignment: .center, horizontalMinWidth: 500) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.btBody)
                    .foregroundStyle(Color.btText)
                Text(detail)
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            BTButton(buttonTitle, style: .secondary, action: action)
        }
    }
}

private struct PermissionsSettingsCard: View {
    @Environment(AppViewModel.self) private var viewModel
    private let runtimeDiagnostics = PermissionRuntimeDiagnostics.current

    var body: some View {
        VStack(alignment: .leading, spacing: BTSpacing.md) {
            Text(summaryText)
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            PermissionStatusRow(
                icon: "hand.raised.fill",
                title: "Accessibility Access",
                detail: "Needed to type transcribed text into other apps.",
                badgeText: viewModel.isAccessibilityGranted ? "Granted" : "Missing",
                badgeColor: viewModel.isAccessibilityGranted ? .green : .orange,
                settingsAction: openAccessibilitySettings
            )

            Divider()

            PermissionStatusRow(
                icon: "mic.fill",
                title: "Microphone Access",
                detail: microphoneDetail,
                badgeText: microphoneBadgeText,
                badgeColor: microphoneBadgeColor,
                settingsAction: openMicrophoneSettings
            )
        }
        .onAppear {
            viewModel.refreshPermissionState()
        }
    }

    private var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private var summaryText: String {
        if !runtimeDiagnostics.isMicrophonePermissionReliable {
            return "This looks like a Terminal or unbundled dev launch. macOS permissions can be attributed to the host app instead of Blazing Transcribe, so microphone status here is not authoritative."
        }

        if viewModel.isAccessibilityGranted && viewModel.isMicrophoneGranted {
            return "Everything looks good. Blazing Transcribe can capture audio and type into other apps."
        }

        return "Accessibility is required for text injection, and Microphone access is required for speech capture."
    }

    private var microphoneDetail: String {
        if !runtimeDiagnostics.isMicrophonePermissionReliable {
            return runtimeDiagnostics.microphoneReliabilityDetail
        }

        switch microphoneStatus {
        case .authorized:
            return "Ready for live transcription and push-to-talk capture."
        case .notDetermined:
            return "Needed to capture speech from your selected input device."
        case .denied, .restricted:
            return "Grant access in System Settings → Privacy & Security → Microphone."
        @unknown default:
            return "Microphone permission needs attention."
        }
    }

    private var microphoneBadgeText: String {
        if !runtimeDiagnostics.isMicrophonePermissionReliable {
            return "Dev Run"
        }

        switch microphoneStatus {
        case .authorized:
            return "Granted"
        case .notDetermined:
            return "Needs Access"
        case .denied, .restricted:
            return "Denied"
        @unknown default:
            return "Unknown"
        }
    }

    private var microphoneBadgeColor: Color {
        if !runtimeDiagnostics.isMicrophonePermissionReliable {
            return .orange
        }

        switch microphoneStatus {
        case .authorized:
            return .green
        case .notDetermined:
            return .orange
        case .denied, .restricted:
            return .red
        @unknown default:
            return .orange
        }
    }

    private func openAccessibilitySettings() {
        KeyboardInjector.requestAccessibilityPermission()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
        viewModel.refreshPermissionState()
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
        viewModel.refreshPermissionState()
    }
}

private struct PermissionRuntimeDiagnostics {
    let bundleIdentifier: String?
    let bundleURL: URL
    let microphoneUsageDescription: String?

    static var current: PermissionRuntimeDiagnostics {
        PermissionRuntimeDiagnostics(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            microphoneUsageDescription: Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        )
    }

    var isPackagedApp: Bool {
        bundleURL.pathExtension == "app"
    }

    var hasBundleIdentifier: Bool {
        guard let bundleIdentifier else { return false }
        return !bundleIdentifier.isEmpty
    }

    var hasMicrophoneUsageDescription: Bool {
        guard let microphoneUsageDescription else { return false }
        return !microphoneUsageDescription.isEmpty
    }

    var isMicrophonePermissionReliable: Bool {
        isPackagedApp && hasBundleIdentifier && hasMicrophoneUsageDescription
    }

    var microphoneReliabilityDetail: String {
        if !isPackagedApp {
            return "This build is running outside a packaged .app bundle, so macOS may attribute microphone access to Terminal instead of this process."
        }

        if !hasBundleIdentifier {
            return "This build does not have a bundle identifier at runtime, so macOS permission reporting is ambiguous."
        }

        if !hasMicrophoneUsageDescription {
            return "This build is missing NSMicrophoneUsageDescription, so microphone permission reporting is not trustworthy."
        }

        return "Microphone permission reporting is unavailable for this launch."
    }
}

private struct PermissionStatusRow: View {
    let icon: String
    let title: String
    let detail: String
    let badgeText: String
    let badgeColor: Color
    let settingsAction: () -> Void

    var body: some View {
        Button(action: settingsAction) {
            BTTrailingActionRow(horizontalMinWidth: 500) {
                HStack(alignment: .top, spacing: BTSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(badgeColor.opacity(0.12))
                            .frame(width: 34, height: 34)

                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(badgeColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.btBody)
                            .foregroundStyle(Color.btText)
                        Text(detail)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                HStack(spacing: BTSpacing.sm) {
                    BTBadge(text: badgeText, color: badgeColor)

                    HStack(spacing: 6) {
                        Text("Open Settings")
                            .font(.btCaption)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.btSecondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
